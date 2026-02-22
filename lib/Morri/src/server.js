const express = require('express');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');
const cors = require('cors');
require('dotenv').config();
const morgan = require('morgan');
const { PrismaClient } = require('@prisma/client');
const jwt = require('jsonwebtoken');
const url = require('url');
const admin = require('firebase-admin');

// --- GLOBAL STORES (In-Memory Aggregator) ---
const sectorAlerts = new Map(); // sectorId -> Map(userId -> timestamp)
const lastSOSByUserId = new Map(); // userId -> lastTimestamp (Spam Guard)

const SIGNAL_WINDOW = 10 * 60 * 1000; // Aggregation window 10 minutes
const EMERGENCY_THRESHOLD = 5; // Emergency threshold (5 unique users)
const SOS_COOLDOWN = 5 * 60 * 1000; // Per-user cooldown 5 minutes

const prisma = new PrismaClient();
const app = express();
const clients = new Map(); // WebSocket -> UserId

const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// --- ВСПОМОГАТЕЛЬНАЯ ЛОГИКА (The Brain) ---

// 1. Очистка старых сигналов в секторе
function cleanupOldSignals(sectorId) {
    const now = Date.now();
    const signals = sectorAlerts.get(sectorId);
    if (!signals) return;

    for (const [userId, timestamp] of signals.entries()) {
        if (now - timestamp > SIGNAL_WINDOW) {
            signals.delete(userId);
        }
    }
}

// 2. Broadcast mass emergency notification to all WebSocket clients
function broadcastMassEmergency(sectorId, count) {
    const payload = JSON.stringify({
        type: 'MASS_EMERGENCY',
        data: {
            sectorId,
            intensity: count >= 20 ? 'CRITICAL' : 'MEDIUM',
            count,
            timestamp: Date.now()
        }
    });

    for (const [ws, userId] of clients.entries()) {
        if (ws.readyState === 1) ws.send(payload);
    }
    console.log(`🚨 [Mass SOS] Sector ${sectorId} is now a HOT ZONE (${count} signals)`);
}

// --- ЭНДПОИНТЫ ---

// Роут для приема SOS (Сюда летит твой JSON SOS_BURST)
app.post('/api/emergency/signal', async (req, res) => {
    // ВНИМАНИЕ: Здесь нужен middleware авторизации (auth.js), чтобы достать req.user.id
    // Для примера берем из токена вручную:
    const authHeader = req.headers.authorization;
    if (!authHeader) return res.status(401).send("Unauthorized");
    
    try {
        const token = authHeader.split(' ')[1];
        const decoded = jwt.verify(token, process.env.JWT_SECRET);
        const userId = decoded.userId;
        const { sectorId } = req.body;

        // 🛡️ SPAM GUARD: No more than once per 5 minutes
        const lastSeen = lastSOSByUserId.get(userId) || 0;
        if (Date.now() - lastSeen < SOS_COOLDOWN) {
            return res.status(429).json({ error: "Cooldown active. Stay calm." });
        }
        lastSOSByUserId.set(userId, Date.now());

        // AGGREGATION
        if (!sectorAlerts.has(sectorId)) sectorAlerts.set(sectorId, new Map());
        sectorAlerts.get(sectorId).set(userId, Date.now());

        cleanupOldSignals(sectorId);

        const uniqueCount = sectorAlerts.get(sectorId).size;

        if (uniqueCount >= EMERGENCY_THRESHOLD) {
            // Сохраняем статус в БД (Upsert)
            await prisma.emergencyZone.upsert({
                where: { id: sectorId },
                update: { count: uniqueCount, isActive: true },
                create: { id: sectorId, count: uniqueCount }
            });
            broadcastMassEmergency(sectorId, uniqueCount);
        }

        res.status(202).json({ status: "Signal captured by grid." });
    } catch (e) { res.status(401).send("Invalid token"); }
});

// Legalize only in routes/auth.js (single source of truth)

// Mount remaining routes
app.use('/api/auth', require('./routes/auth'));
app.use('/api/users', require('./routes/user'));
app.use('/api/friends', require('./routes/friends'));
app.use('/api/chats', require('./routes/chats'));
app.use('/api/channels', require('./routes/channels'));
app.use('/api/guardian', require('./routes/guardian'));
app.use('/api/reports', require('./routes/reports'));
app.use('/api/ads', require('./routes/ads'));

// --- SSL & START ---
const sslOptions = {
    key: fs.readFileSync(path.join(__dirname, '..', 'localhost+1-key.pem')), 
    cert: fs.readFileSync(path.join(__dirname, '..', 'localhost+1.pem'))    
};

const server = https.createServer(sslOptions, app);
const wss = new WebSocketServer({ server });


app.use((req, res, next) => {
    // Add random noise to each server response
    const crypto = require('crypto');
    res.setHeader('X-Entropy', crypto.randomBytes(16).toString('hex'));
    res.setHeader('Cache-Control', 'no-store'); // Prevent caching and fingerprinting
    next();
});
// --- WEBSOCKET ЛОГИКА ---
// DTN: Idempotency by clientTempId only. Append-only; no delivery status update. Do not assume recipient presence.
wss.on('connection', (ws, req) => {
    let currentUserId;
    try {
        const queryParams = url.parse(req.url, true).query;
        const token = queryParams.token;
        const decodedToken = jwt.verify(token, process.env.JWT_SECRET);
        currentUserId = decodedToken.userId;
        clients.set(ws, currentUserId);
        console.log(`🔌 [WS] Secure link: ${currentUserId}`);
    } catch (e) { ws.close(1008); return; }

    ws.on('message', async (messageStr) => {
        try {
            const data = JSON.parse(messageStr);
            const senderId = clients.get(ws);

            if (data.type === 'message') {
                const { chatId, content, isEncrypted, clientTempId } = data;

                // DTN: Idempotency by clientTempId only (no mesh hash h). Existing idempotency check retained.
                const existing = await prisma.message.findFirst({ where: { clientTempId } });
                if (existing) return;

                const newMessage = await prisma.message.create({
                    data: { 
                        content, 
                        senderId, 
                        chatRoomId: chatId, 
                        isEncrypted: !!isEncrypted, 
                        clientTempId 
                    },
                    include: { sender: { select: { id: true, username: true } }, chatRoom: { include: { participants: true } } }
                });

                const broadcastPayload = JSON.stringify({ type: 'newMessage', message: newMessage });

                // Рассылка (DTN: no delivery guarantee; recipients may be offline; mesh handles transport)
                for (const [clientWs, clientUserId] of clients.entries()) {
                    const chat = newMessage.chatRoom;
                    const isParticipant = chat.participants.some(p => p.userId === clientUserId);
                    if (clientWs.readyState === 1 && (chat.type === 'GLOBAL' || isParticipant)) {
                        clientWs.send(broadcastPayload);
                    }
                }
            }
        } catch (e) { console.error('WS Error:', e); }
    });

    ws.on('close', () => clients.delete(ws));
});

// --- GLOBAL CHAT ---
async function initGlobalChat() {
    const id = 'THE_BEACON_GLOBAL';
    const exists = await prisma.chatRoom.findUnique({ where: { id } });
    if (!exists) {
        await prisma.chatRoom.create({
            data: { id, name: "THE BEACON", type: 'GLOBAL', isPublic: true }
        });
        console.log("📡 [System] GLOBAL BEACON INITIALIZED.");
    }
}
initGlobalChat();

server.listen(PORT, '0.0.0.0', () => {
    console.log(`🛡️ GHOST COMMAND CENTER ACTIVE ON PORT ${PORT}`);
});