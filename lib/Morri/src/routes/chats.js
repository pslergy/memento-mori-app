// src/routes/chats.js
const express = require('express');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth');
const ephemeralTokens = require('../utils/ephemeralTokens');

const router = express.Router();
const prisma = new PrismaClient();
router.use(authMiddleware);

// --- THE BEACON: разделение по странам (THE_BEACON_GLOBAL, THE_BEACON_BY, THE_BEACON_RU, ...) ---
function isBeaconChatId(chatId) {
    if (!chatId || typeof chatId !== 'string') return false;
    const s = chatId.trim();
    if (s === 'THE_BEACON_GLOBAL') return true;
    if (s.length === 13 && s.startsWith('THE_BEACON_')) {
        const cc = s.slice(11);
        return /^[A-Z]{2}$/.test(cc);
    }
    return false;
}

async function getOrCreateBeaconRoom(chatId) {
    let room = await prisma.chatRoom.findUnique({ where: { id: chatId } });
    if (room) return room;
    const name = chatId === 'THE_BEACON_GLOBAL'
        ? 'THE BEACON (Global SOS)'
        : `THE BEACON · ${chatId.slice(11)}`;
    room = await prisma.chatRoom.create({
        data: {
            id: chatId,
            type: 'GLOBAL',
            name,
            isPublic: true,
        }
    });
    console.log(`📡 [Beacon] Created room: ${chatId} (${name})`);
    return room;
}

// --- Helper to standardize chat response ---
// Converts Prisma chat object to client JSON
function formatChatForClient(chat, currentUserId) {
    if (!chat) return null;

    const lastMessage = chat.messages?.[0];
    const otherParticipant = chat.participants?.find(p => p.userId !== currentUserId);

    return {
        id: chat.id,
        name: chat.name,
        type: chat.type,
        isEphemeral: chat.isEphemeral,
        lastMessage: lastMessage ? {
            id: lastMessage.id,
            content: lastMessage.content,
            createdAt: lastMessage.createdAt,
            senderId: lastMessage.senderId
        } : null,
        otherUser: otherParticipant ? {
            id: otherParticipant.user.id,
            username: otherParticipant.user.username,
        } : null // For groups null here; group name in 'name'
    };
}


// GET /api/chats/trending - Find active public branches (Frequency Scanner)
// GET /api/chats/available-groups - Alias for app compatibility (same data)
const listPublicBranches = async (req, res) => {
    try {
        const branches = await prisma.chatRoom.findMany({
            where: {
                isPublic: true,
                type: { in: ['GROUP', 'GLOBAL'] }
            },
            include: {
                _count: { select: { messages: true } }
            },
            orderBy: { lastActivityAt: 'desc' },
            take: 20
        });
        res.json(branches);
    } catch (error) {
        res.status(500).json({ message: "Error fetching branches" });
    }
};
router.get('/trending', listPublicBranches);
router.get('/available-groups', listPublicBranches);

router.post('/join-request', async (req, res) => {
    const { chatId } = req.body;
    const currentUserId = req.user.userId;

    try {
        // 1. Ищем чат в базе
        const chatRoom = await prisma.chatRoom.findUnique({
            where: { id: chatId },
            include: { participants: true }
        });

        if (!chatRoom) {
            return res.status(404).json({ message: "Frequency not found in database" });
        }

        // 2. Check if user is already a member
        const isAlreadyMember = chatRoom.participants.some(p => p.userId === currentUserId);

        if (!isAlreadyMember) {
            // 3. Create Participant-Chat link
            await prisma.chatParticipant.create({
                data: {
                    userId: currentUserId,
                    chatRoomId: chatId
                }
            });
            console.log(`📡 [Link] User ${currentUserId} linked to channel: ${chatRoom.name}`);
        }

        // 4. Return chat data for Flutter to open
        res.status(200).json({
            id: chatRoom.id,
            name: chatRoom.name,
            type: chatRoom.type
        });

    } catch (error) {
        console.error('Join Error:', error);
        res.status(500).json({ message: "Failed to establish link" });
    }
});

// POST /api/chats/join - Вход в публичную ветку
router.post('/join', async (req, res) => {
    const { chatId } = req.body;
    const currentUserId = req.user.userId;

    try {
        const chat = await prisma.chatRoom.findUnique({ where: { id: chatId } });
        if (!chat || !chat.isPublic) return res.status(403).json({ message: "Cannot join this room" });

        // Add participant
        await prisma.chatParticipant.upsert({
            where: { userId_chatRoomId: { userId: currentUserId, chatRoomId: chatId } },
            create: { userId: currentUserId, chatRoomId: chatId },
            update: {} // If already there, do nothing
        });

        res.json({ message: "Joined successfully", chatId });
    } catch (error) {
        res.status(500).json({ message: "Server error" });
    }
});


// --- API routes ---

// POST /api/chats/direct - Find or create direct chat

router.post('/direct', async (req, res) => {
    const { userId: friendId } = req.body;
    const currentUserId = req.user.userId;

    // Защита от пустых данных
    if (!friendId || friendId === currentUserId) {
        return res.status(400).json({ message: "Invalid target user ID" });
    }

    try {
        // 1. Check friend exists
        const friend = await prisma.user.findUnique({ where: { id: friendId } });
        if (!friend) return res.status(404).json({ message: "User not found" });

        // 2. Find chat where BOTH users participate
        let chat = await prisma.chatRoom.findFirst({
            where: {
                type: 'DIRECT',
                AND: [
                    { participants: { some: { userId: currentUserId } } },
                    { participants: { some: { userId: friendId } } }
                ]
            },
            include: {
                participants: { include: { user: { select: { id: true, username: true } } } },
                messages: { orderBy: { createdAt: 'desc' }, take: 1 }
            }
        });

        // 3. If no chat yet — create it
        if (!chat) {
            console.log(`📡 [Link] Creating new direct channel: ${currentUserId} <-> ${friendId}`);
            chat = await prisma.chatRoom.create({
                data: {
                    type: 'DIRECT',
                    participants: {
                        create: [{ userId: currentUserId }, { userId: friendId }]
                    }
                },
                include: {
                    participants: { include: { user: { select: { id: true, username: true } } } },
                    messages: true
                }
            });
        }

        res.json(formatChatForClient(chat, currentUserId));

    } catch (error) {
        console.error('Find/Create Chat Error:', error);
        res.status(500).json({ message: "Internal link failure" });
    }
});

// GET /api/chats - Получить список всех чатов пользователя
router.get('/', async (req, res) => {
    const currentUserId = req.user.userId;
    try {
        const chatRooms = await prisma.chatRoom.findMany({
            where: {
                participants: {
                    some: { userId: currentUserId }
                }
            },
            include: {
                participants: {
                    include: {
                        user: { select: { id: true, username: true } }
                    }
                },
                messages: {
                    orderBy: { createdAt: 'desc' },
                    take: 1
                }
            }
        });

        // Use helper to format
        const formattedChats = chatRooms.map(chat => formatChatForClient(chat, currentUserId));
        
        // Sort chats by last message date
        formattedChats.sort((a, b) => {
            if (!a.lastMessage) return 1;
            if (!b.lastMessage) return -1;
            // Compare dates as Date objects
            return new Date(b.lastMessage.createdAt) - new Date(a.lastMessage.createdAt);
        });

        res.json(formattedChats);
    } catch (error) {
        console.error('Get Chats Error:', error);
        res.status(500).json({ message: "Server error" });
    }
});


// GET /api/chats/:chatId/messages - Get message history
// DTN: Query only by chatId and user participation. Do not filter by bridge or chain. Append-only; no delivery marking.
router.get('/:chatId/messages', async (req, res) => {
    const { chatId } = req.params;
    const currentUserId = req.user.userId;

    try {
        // 1. Ищем чат (для Beacon — создаём комнату по стране при первом обращении)
        let chatRoom = await prisma.chatRoom.findUnique({
            where: { id: chatId },
            include: { participants: true }
        });
        if (!chatRoom && isBeaconChatId(chatId)) {
            chatRoom = await getOrCreateBeaconRoom(chatId);
            chatRoom = { ...chatRoom, participants: [] };
        }
        if (!chatRoom) return res.status(404).json({ message: "Chat not found" });

        // 2. 🔥 ПРАВИЛО МАЯКА (Global / Beacon по стране)
        if (chatRoom.type === 'GLOBAL') {
            // В глобальный/beacon чат пускаем любого авторизованного юзера
        } else {
            // 3. 🔥 ПРАВИЛО ЛИНКА (Direct Chat)
            const isParticipant = chatRoom.participants.some(p => p.userId === currentUserId);

            if (!isParticipant) {
                // Если юзера нет в чате, но это DIRECT чат и он участник по логике ID
                // (например, его ID зашит в метаданные или это его друг)
                // Для теста: просто добавляем его, если он знает ID комнаты
                console.log(`🛠️ [Auto-Fix] Adding user ${currentUserId} to room ${chatId}`);
                await prisma.chatParticipant.create({
                    data: { userId: currentUserId, chatRoomId: chatId }
                });
            }
        }

        // 4. Отдаем сообщения (DTN: no delivery status update; messages may be returned repeatedly)
        const messages = await prisma.message.findMany({
            where: { chatRoomId: chatId },
            orderBy: { createdAt: 'desc' },
            take: 50,
            include: { sender: { select: { id: true, username: true } } }
        });

        res.json(messages);

    } catch (error) {
        console.error('Messages Fetch Error:', error);
        res.status(500).json({ message: "Server Error" });
    }
});


// PUT /api/chats/:chatId/toggle-ephemeral - Toggle chat ephemeral mode
router.put('/:chatId/toggle-ephemeral', async (req, res) => {
    const { chatId } = req.params;
    const currentUserId = req.user.userId;

    try {
        const participant = await prisma.chatParticipant.findUnique({
            where: { userId_chatRoomId: { userId: currentUserId, chatRoomId: chatId } }
        });
        if (!participant) return res.status(403).json({ message: "Forbidden" });

        const chat = await prisma.chatRoom.findUnique({ where: { id: chatId } });
        if (!chat) return res.status(404).json({ message: "Chat not found" });

        const updatedChat = await prisma.chatRoom.update({
            where: { id: chatId },
            data: { isEphemeral: !chat.isEphemeral }
        });
        res.json(updatedChat);
    } catch (error) {
        res.status(500).json({ message: "Server error" });
    }
});


// POST /api/chats/group - Create group chat
router.post('/group', async (req, res) => {
    const { name, userIds } = req.body;
    const currentUserId = req.user.userId;

    if (!name || !userIds || !Array.isArray(userIds) || userIds.length === 0) {
        return res.status(400).json({ message: "Group name and user IDs are required." });
    }

    const allParticipantIds = [...new Set([currentUserId, ...userIds])];
    
    try {
        const newGroupChat = await prisma.chatRoom.create({
            data: {
                name,
                type: 'GROUP',
                participants: {
                    create: allParticipantIds.map(id => ({ userId: id })),
                }
            },
            include: {
                participants: { include: { user: { select: { id: true, username: true } } } }
            }
        });
        res.status(201).json(newGroupChat);
    } catch (error) {
        console.error('Create Group Error:', error);
        res.status(500).json({ message: "Server error" });
    }
});

// Лимит сообщений в Beacon: не чаще 1 раз в 60 сек на пользователя в одну комнату (против каскада спама).
const BEACON_COOLDOWN_MS = 60 * 1000;

// POST /api/chats/:chatId/messages - Send message
// DTN: Append-only. Idempotency via clientTempId only (no mesh hash h). Do not assume recipient presence; no delivery ack.
router.post('/:chatId/messages', async (req, res) => {
    const { chatId } = req.params;
    const { content, isEncrypted, clientTempId, senderId: bodySenderId } = req.body;
    let senderId = req.user.userId;
    if (bodySenderId) {
        const resolved = await ephemeralTokens.resolve(bodySenderId);
        if (resolved) senderId = resolved;
        else if (bodySenderId.startsWith('eph_')) return res.status(400).json({ message: "Ephemeral token expired or invalid" });
        else senderId = bodySenderId; // relay with real userId
    }

    try {
        // 1. Idempotency by clientTempId only (DTN: do not add dedup by mesh hash h)
        if (clientTempId) {
            const existingMessage = await prisma.message.findFirst({
                where: { clientTempId: clientTempId }
            });
            if (existingMessage) return res.json(existingMessage);
        }

        // 2. Check chat exists (для Beacon — создаём комнату по стране при первом сообщении)
        let chatRoom = await prisma.chatRoom.findUnique({
            where: { id: chatId },
            include: { participants: true }
        });
        if (!chatRoom && isBeaconChatId(chatId)) {
            chatRoom = await getOrCreateBeaconRoom(chatId);
            chatRoom = { ...chatRoom, participants: [] };
        }
        if (!chatRoom) return res.status(404).json({ message: "Chat frequency not found" });

        // 2b. 🛡️ Beacon: лимит по пользователю в комнату (против спама)
        if (isBeaconChatId(chatId)) {
            const lastInRoom = await prisma.message.findFirst({
                where: { chatRoomId: chatId, senderId },
                orderBy: { createdAt: 'desc' },
                select: { createdAt: true }
            });
            if (lastInRoom && (Date.now() - new Date(lastInRoom.createdAt).getTime() < BEACON_COOLDOWN_MS)) {
                return res.status(429).json({
                    message: "В The Beacon можно отправить сообщение раз в 60 сек",
                    retryAfterSec: 60
                });
            }
        }

        // 3. Append message (DTN: do not set status to DELIVERED/READ; default SENT is UI-level)
        const newMessage = await prisma.message.create({
            data: {
                content,
                isEncrypted: isEncrypted || false,
                clientTempId: clientTempId,
                chatRoomId: chatId,
                senderId
            },
            include: { sender: { select: { id: true, username: true } } }
        });

        // 4. Update chat last activity time
        await prisma.chatRoom.update({
            where: { id: chatId },
            data: { lastActivityAt: new Date() }
        });

        res.status(201).json(newMessage);

    } catch (error) {
        console.error('Send Message Error:', error);
        res.status(500).json({ message: "Internal link failure during transmission" });
    }
});


module.exports = router;