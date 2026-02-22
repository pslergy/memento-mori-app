// src/routes/friends.js
const express = require('express');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth'); // Мы создадим его на след. шаге

const router = express.Router();
const prisma = new PrismaClient();

// Защищаем все роуты в этом файле
router.use(authMiddleware);

// GET /api/friends/search?query=... - Поиск пользователей
router.get('/search', async (req, res) => {
    const { query } = req.query;
    const userId = req.user.userId; // ID текущего пользователя из middleware

    // Проверка длины запроса
    if (!query || query.length < 3) {
        return res.json([]);
    }

    try {
        const users = await prisma.user.findMany({
            where: {
                // 1. Поиск по имени (без учета регистра)
                username: { 
                    contains: String(query), 
                    mode: 'insensitive' 
                },
                // 2. Исключаем самого себя
                id: { 
                    not: userId 
                },
                // 3. Исключаем пользователей "в тени"
                isShadow: false 
            },
            // Возвращаем только безопасные поля
            select: { 
                id: true, 
                username: true 
            }, 
        });
        
        res.json(users);
    } catch (error) {
        console.error("Search error:", error);
        res.status(500).json({ message: "Server error" });
    }
});

// POST /api/friends/add - Отправить заявку в друзья
router.post('/add', async (req, res) => {
    const { friendId } = req.body;
    const userId = req.user.userId;

    try {
        // Проверка: не являемся ли мы уже друзьями или нет ли уже заявки?
        const existing = await prisma.friendship.findFirst({
            where: {
                OR: [
                    { userA_id: userId, userB_id: friendId },
                    { userA_id: friendId, userB_id: userId }
                ]
            }
        });

        if (existing) {
            return res.status(400).json({ message: "Link already exists or pending" });
        }

        const newFriendship = await prisma.friendship.create({
            data: {
                userA_id: userId,
                userB_id: friendId,
                status: 'PENDING',
                requestedById: userId,
            }
        });
        res.status(201).json(newFriendship);
    } catch (error) {
        res.status(400).json({ message: "Failed to create friendship link" });
    }
});


// GET /api/friends - Получить список друзей
router.get('/', async (req, res) => {
    const userId = req.user.userId;

    try {
        const friendships = await prisma.friendship.findMany({
            where: {
                status: 'ACCEPTED',
                OR: [{ userA_id: userId }, { userB_id: userId }],
            },
            include: { // Включаем данные о друзьях
                userA: { select: { id: true, username: true, deathDate: true } },
                userB: { select: { id: true, username: true, deathDate: true } },
            }
        });

        // Форматируем результат, чтобы было удобно
        const friends = friendships.map(f => {
            const friend = f.userA_id === userId ? f.userB : f.userA;
            return friend;
        });

        res.json(friends);
    } catch (error) {
        res.status(500).json({ message: "Server error" });
    }
});

router.get('/requests', async (req, res) => {
    const userId = req.user.userId;
    try {
        const requests = await prisma.friendship.findMany({
            where: {
                userB_id: userId, // Заявки, адресованные мне
                status: 'PENDING',
            },
            include: {
                userA: { // Включаем инфо о том, кто отправил заявку
                    select: { id: true, username: true }
                }
            }
        });
        res.json(requests);
    } catch (error) {
        res.status(500).json({ message: "Server error" });
    }
});

// --- PUT /api/friends/requests/:requestId/accept - Принять заявку ---
router.put('/requests/:requestId/accept', async (req, res) => {
    const { requestId } = req.params;
    const userId = req.user.userId;
    try {
        const friendship = await prisma.friendship.update({
            where: {
                // Убеждаемся, что мы можем принять только адресованную нам заявку
                userA_id_userB_id: { userA_id: requestId, userB_id: userId }
            },
            data: {
                status: 'ACCEPTED'
            }
        });
        res.json(friendship);
    } catch (error) {
        // Если заявка не найдена или уже не PENDING, будет ошибка
        res.status(404).json({ message: "Request not found or already handled." });
    }
});

// --- DELETE /api/friends/requests/:requestId/reject - Отклонить заявку ---
router.delete('/requests/:requestId/reject', async (req, res) => {
    const { requestId } = req.params;
    const userId = req.user.userId;
    try {
        await prisma.friendship.delete({
            where: {
                 userA_id_userB_id: { userA_id: requestId, userB_id: userId }
            }
        });
        res.status(204).send(); // 204 No Content - успешное удаление
    } catch (error) {
        res.status(404).json({ message: "Request not found." });
    }
});

// --- DELETE /api/friends/:friendId - Удалить из друзей (разорвать принятую дружбу) ---
router.delete('/:friendId', async (req, res) => {
    const { friendId } = req.params;
    const userId = req.user.userId;

    if (!friendId || friendId === userId) {
        return res.status(400).json({ message: "Invalid friend id" });
    }

    try {
        const friendship = await prisma.friendship.findFirst({
            where: {
                status: 'ACCEPTED',
                OR: [
                    { userA_id: userId, userB_id: friendId },
                    { userA_id: friendId, userB_id: userId },
                ],
            },
        });

        if (!friendship) {
            return res.status(404).json({ message: "Friendship not found or not accepted." });
        }

        await prisma.friendship.delete({
            where: {
                userA_id_userB_id: {
                    userA_id: friendship.userA_id,
                    userB_id: friendship.userB_id,
                },
            },
        });
        res.status(204).send();
    } catch (error) {
        console.error("Remove friend error:", error);
        res.status(500).json({ message: "Server error" });
    }
});

module.exports = router;