const express = require('express');
const router = express.Router();
const verifyToken = require('../middleware/authMiddleware');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

// In-memory хранилище для аггрегации (в продакшене лучше Redis)
const sectorAggregator = new Map(); 

router.post('/signal', verifyToken, async (req, res) => {
    const { sectorId } = req.body;
    const userId = req.user.userId;

    // 1. Идемпотентность и Spam-Guard
    // Проверяем время последнего сигнала от этого юзера
    const lastSignal = sectorAggregator.get(`${sectorId}_${userId}`);
    if (lastSignal && Date.now() - lastSignal < 300000) { // 5 минут кулдаун
        return res.status(429).json({ message: "Cooldown active" });
    }

    // 2. Регистрация сигнала в секторе
    sectorAggregator.set(`${sectorId}_${userId}`, Date.now());

    // 3. Подсчет уникальных сигналов в секторе
    const uniqueSignals = Array.from(sectorAggregator.keys())
        .filter(key => key.startsWith(sectorId)).length;

    // 4. Если порог (например, 5 человек) превышен — создаем HOT ZONE
    if (uniqueSignals >= 5) {
        await prisma.emergencyZone.upsert({
            where: { id: sectorId },
            update: { count: uniqueSignals, isActive: true },
            create: { id: sectorId, count: uniqueSignals }
        });
        
        // Вещаем всем через WebSocket (wss определен в server.js)
        global.broadcastEmergency(sectorId, uniqueSignals);
    }

    res.status(202).send();
});

module.exports = router;