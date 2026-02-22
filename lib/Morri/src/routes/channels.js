// Каналы (Telegram-style). Онлайн-only: обновления через сервер.
// Расширено: тип канала, закрытые каналы, инвайт по ссылке, лимит 2 канала на аккаунт.

const express = require('express');
const crypto = require('crypto');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
const prisma = new PrismaClient();
const MAX_CHANNELS_PER_USER = 2;
const INVITE_TOKEN_BYTES = 24;
const INVITE_BASE_URL = process.env.INVITE_BASE_URL || 'https://memento.app/channel/join?invite=';

router.use(authMiddleware);

function mapChannel(c) {
  const count = c._count?.participants ?? 0;
  return {
    id: c.id,
    name: c.name || 'Channel',
    description: c.description || '',
    type: c.channelType || 'other',
    isPrivate: !!c.isPrivate,
    subscribersCount: count,
    createdAt: c.createdAt,
    lastActivityAt: c.lastActivityAt,
  };
}

// GET /api/channels — список каналов (Discover). Опционально: category, sort, q
router.get('/', async (req, res) => {
  try {
    const { category, sort, q } = req.query;
    const where = { type: 'CHANNEL' };
    // В каталоге показываем только открытые каналы (закрытые — только по инвайту)
    where.isPrivate = false;
    if (category && category !== '') where.channelType = category;
    if (q && String(q).trim() !== '') {
      const term = `%${String(q).trim()}%`;
      where.OR = [
        { name: { contains: term, mode: 'insensitive' } },
        { description: { contains: term, mode: 'insensitive' } },
      ];
    }

    let orderBy = [{ lastActivityAt: 'desc' }];
    if (sort === 'newest') orderBy = [{ createdAt: 'desc' }];
    if (sort === 'popular' || sort === 'subscribers') orderBy = [{ participants: { _count: 'desc' } }];

    const channels = await prisma.chatRoom.findMany({
      where,
      include: { _count: { select: { participants: true } } },
      orderBy,
    });
    const list = channels.map(mapChannel);
    res.json(list);
  } catch (e) {
    console.error('[channels] list error:', e);
    res.status(500).json({ message: 'Error fetching channels' });
  }
});

// GET /api/channels/mine — каналы, созданные текущим пользователем (лимит 2)
router.get('/mine', async (req, res) => {
  try {
    const userId = req.user.userId;
    const channels = await prisma.chatRoom.findMany({
      where: { type: 'CHANNEL', ownerId: userId },
      include: { _count: { select: { participants: true } } },
      orderBy: { createdAt: 'desc' },
    });
    res.json(channels.map(mapChannel));
  } catch (e) {
    console.error('[channels] mine error:', e);
    res.status(500).json({ message: 'Error fetching my channels' });
  }
});

// GET /api/channels/subscribed — каналы, на которые подписан текущий пользователь
router.get('/subscribed', async (req, res) => {
  try {
    const userId = req.user.userId;
    const participants = await prisma.chatParticipant.findMany({
      where: {
        userId,
        chatRoom: { type: 'CHANNEL' },
      },
      include: {
        chatRoom: {
          include: { _count: { select: { participants: true } } },
        },
      },
    });
    const list = participants.map((p) => mapChannel(p.chatRoom));
    res.json(list);
  } catch (e) {
    console.error('[channels] subscribed error:', e);
    res.status(500).json({ message: 'Error fetching subscribed channels' });
  }
});

// GET /api/channels/recommended — рекомендуемые (топ по подписчикам, открытые)
router.get('/recommended', async (req, res) => {
  try {
    const channels = await prisma.chatRoom.findMany({
      where: { type: 'CHANNEL', isPrivate: false },
      include: { _count: { select: { participants: true } } },
      orderBy: [{ participants: { _count: 'desc' } }],
      take: 10,
    });
    res.json(channels.map(mapChannel));
  } catch (e) {
    console.error('[channels] recommended error:', e);
    res.status(500).json({ message: 'Error fetching recommended' });
  }
});

// POST /api/channels — создать канал (лимит 2 на пользователя)
router.post('/', async (req, res) => {
  try {
    const userId = req.user.userId;
    const { name, description, type, isPrivate } = req.body;

    const myCount = await prisma.chatRoom.count({
      where: { type: 'CHANNEL', ownerId: userId },
    });
    if (myCount >= MAX_CHANNELS_PER_USER) {
      return res.status(403).json({
        message: `Limit: ${MAX_CHANNELS_PER_USER} channels per account`,
      });
    }

    const validTypes = ['news', 'entertainment', 'tech', 'education', 'lifestyle', 'sports', 'other'];
    const channelType = validTypes.includes(type) ? type : 'other';

    const room = await prisma.chatRoom.create({
      data: {
        type: 'CHANNEL',
        name: name || 'Channel',
        description: description || null,
        ownerId: userId,
        channelType,
        isPrivate: !!isPrivate,
      },
      include: { _count: { select: { participants: true } } },
    });
    await prisma.chatParticipant.create({
      data: { userId, chatRoomId: room.id },
    });
    res.status(201).json(mapChannel(room));
  } catch (e) {
    console.error('[channels] create error:', e);
    res.status(500).json({ message: 'Create channel failed' });
  }
});

// GET /api/channels/:id/invite-link — получить ссылку-приглашение (только владелец)
router.get('/:id/invite-link', async (req, res) => {
  try {
    const channelId = req.params.id;
    const userId = req.user.userId;

    const room = await prisma.chatRoom.findFirst({
      where: { id: channelId, type: 'CHANNEL' },
      include: { channelInvites: true },
    });
    if (!room) return res.status(404).json({ message: 'Channel not found' });
    if (room.ownerId !== userId) return res.status(403).json({ message: 'Only channel owner can get invite link' });

    let invite = room.channelInvites[0];
    if (!invite) {
      const token = crypto.randomBytes(INVITE_TOKEN_BYTES).toString('base64url');
      invite = await prisma.channelInvite.create({
        data: { token, chatRoomId: channelId },
      });
    }
    const base = INVITE_BASE_URL.replace(/\/$/, '');
    const inviteUrl = INVITE_BASE_URL.includes('invite=') ? `${base}${invite.token}` : `${base}?invite=${invite.token}`;
    res.json({ inviteToken: invite.token, inviteUrl });
  } catch (e) {
    console.error('[channels] invite-link error:', e);
    res.status(500).json({ message: 'Error getting invite link' });
  }
});

// POST /api/channels/join — вступить по инвайт-токену
router.post('/join', async (req, res) => {
  try {
    const userId = req.user.userId;
    const { inviteToken } = req.body;
    if (!inviteToken) return res.status(400).json({ message: 'inviteToken required' });

    const invite = await prisma.channelInvite.findUnique({
      where: { token: inviteToken },
      include: { chatRoom: true },
    });
    if (!invite) return res.status(404).json({ message: 'Invalid or expired invite' });
    if (invite.chatRoom.type !== 'CHANNEL') return res.status(400).json({ message: 'Not a channel invite' });
    if (invite.expiresAt && invite.expiresAt < new Date()) return res.status(410).json({ message: 'Invite expired' });

    await prisma.chatParticipant.upsert({
      where: { userId_chatRoomId: { userId, chatRoomId: invite.chatRoomId } },
      create: { userId, chatRoomId: invite.chatRoomId },
      update: {},
    });
    const room = await prisma.chatRoom.findUnique({
      where: { id: invite.chatRoomId },
      include: { _count: { select: { participants: true } } },
    });
    res.json(mapChannel(room));
  } catch (e) {
    console.error('[channels] join error:', e);
    res.status(500).json({ message: 'Join failed' });
  }
});

// GET /api/channels/:id/posts — посты канала
router.get('/:id/posts', async (req, res) => {
  try {
    const channelId = req.params.id;
    const limit = Math.min(parseInt(req.query.limit, 10) || 50, 100);

    const room = await prisma.chatRoom.findFirst({
      where: { id: channelId, type: 'CHANNEL' },
    });
    if (!room) return res.status(404).json({ message: 'Channel not found' });

    const messages = await prisma.message.findMany({
      where: { chatRoomId: channelId },
      orderBy: { createdAt: 'desc' },
      take: limit,
      include: { sender: { select: { id: true, username: true } } },
    });
    const posts = messages.map((m) => ({
      id: m.id,
      content: m.content,
      authorId: m.senderId,
      senderId: m.senderId,
      username: m.sender?.username,
      createdAt: m.createdAt,
    }));
    res.json(posts);
  } catch (e) {
    console.error('[channels] posts error:', e);
    res.status(500).json({ message: 'Error fetching channel posts' });
  }
});

// POST /api/channels/:id/subscribe — подписаться на канал (закрытый — только по инвайту)
router.post('/:id/subscribe', async (req, res) => {
  try {
    const channelId = req.params.id;
    const userId = req.user.userId;

    const room = await prisma.chatRoom.findFirst({
      where: { id: channelId, type: 'CHANNEL' },
    });
    if (!room) return res.status(404).json({ message: 'Channel not found' });
    if (room.isPrivate) {
      return res.status(403).json({ message: 'Private channel: use invite link to join' });
    }

    await prisma.chatParticipant.upsert({
      where: { userId_chatRoomId: { userId, chatRoomId: channelId } },
      create: { userId, chatRoomId: channelId },
      update: {},
    });
    res.status(200).json({ subscribed: true });
  } catch (e) {
    console.error('[channels] subscribe error:', e);
    res.status(500).json({ message: 'Subscribe failed' });
  }
});

// POST /api/channels/:id/unsubscribe
router.post('/:id/unsubscribe', async (req, res) => {
  try {
    const channelId = req.params.id;
    const userId = req.user.userId;

    await prisma.chatParticipant.deleteMany({
      where: { userId, chatRoomId: channelId },
    });
    res.status(200).json({ unsubscribed: true });
  } catch (e) {
    console.error('[channels] unsubscribe error:', e);
    res.status(500).json({ message: 'Unsubscribe failed' });
  }
});

module.exports = router;
