// src/routes/user.js
const express = require('express');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
const prisma = new PrismaClient();

// GET /api/users/me - Профиль
router.get('/me', authMiddleware, async (req, res) => {
    try {
        const userId = req.user.userId;
        const user = await prisma.user.findUnique({
            where: { id: userId },
            select: {
                id: true,
                username: true,
                email: true,
                countryCode: true,
                createdAt: true,
                deathDate: true,
                dateOfBirth: true // Не забудь добавить это поле в Prisma Schema!
            },
        });

        if (!user) return res.status(404).json({ message: "User not found." });
        res.json(user);
    } catch (error) {
        console.error("Get profile error:", error);
        res.status(500).json({ message: "Server error." });
    }
});

// GET /api/users/check-username
router.get('/check-username', async (req, res) => {
    const { username } = req.query;
    if (!username || username.length < 3) {
        return res.status(400).json({ available: false, message: "Username too short." });
    }
    try {
        const existingUser = await prisma.user.findUnique({ where: { username: String(username) } });
        res.json({ available: !existingUser });
    } catch (error) {
        res.status(500).json({ available: false });
    }
});

// --- 🔥 DELETE /api/users/nuke - ПРОТОКОЛ САМОУНИЧТОЖЕНИЯ ---
router.delete('/nuke', authMiddleware, async (req, res) => {
    const userId = req.user.userId;
    console.log(`☢️ [NUKE] PROTOCOL INITIATED BY USER ${userId}`);

    try {
        // Выполняем удаление в одной транзакции, чтобы стереть ВСЁ или ничего
        await prisma.$transaction([
            // 1. Удаляем сообщения
            prisma.message.deleteMany({ where: { senderId: userId } }),
            
            // 2. Удаляем участие в чатах
            prisma.chatParticipant.deleteMany({ where: { userId: userId } }),
            
            // 3. Удаляем дружбу
            // Твоя схема использует userA_id и userB_id, так что этот код правильный:
            prisma.friendship.deleteMany({ 
                where: { OR: [{ userA_id: userId }, { userB_id: userId }] } 
            }),

            // 4. Удаляем жалобы (Где юзер был репортером или на него жаловались)
            prisma.report.deleteMany({
                where: { OR: [{ reporterUserId: userId }, { reportedUserId: userId }] }
            }),
            
            // 5. Удаляем самого пользователя
            prisma.user.delete({ where: { id: userId } })
        ]);

        console.log(`☢️ [NUKE] USER ${userId} ELIMINATED SUCCESSFULLY.`);
        res.status(200).json({ message: "Account and data permanently deleted." });
    } catch (error) {
        console.error("[NUKE] Failed:", error);
        res.status(500).json({ message: "Nuke failed via API. Manual intervention required." });
    }
});

module.exports = router;