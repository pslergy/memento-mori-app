const express = require('express');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
const prisma = new PrismaClient();

// GET /api/ads - Получить список активных тактических объявлений
// Мы не ставим здесь authMiddleware, чтобы даже "Призраки" могли скачать рекламу
router.get('/', async (req, res) => {
    try {
        const ads = await prisma.ad.findMany({
            where: {
                expiresAt: {
                    gt: new Date() // Только те, что не протухли
                }
            },
            orderBy: { priority: 'desc' }, // Сначала самые важные
            take: 10
        });

        res.json(ads);
    } catch (error) {
        console.error("🚨 [Ad-Fetch Error]:", error);
        res.status(500).json({ message: "Error fetching tactical packets" });
    }
});

// POST /api/ads - Создать новое объявление (Только для тебя/админа)
router.post('/', authMiddleware, async (req, res) => {
    const { title, content, imageUrl, priority, durationDays } = req.body;
    
    try {
        const newAd = await prisma.ad.create({
            data: {
                title,
                content,
                imageUrl,
                priority: priority || 0,
                expiresAt: new Date(Date.now() + (durationDays || 7) * 24 * 60 * 60 * 1000)
            }
        });
        res.status(201).json(newAd);
    } catch (error) {
        res.status(500).json({ message: "Failed to create ad" });
    }
});

module.exports = router;