// src/services/cleanerService.js
const cron = require('node-cron');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

// Запускаем задачу каждую минуту
cron.schedule('* * * * *', async () => {
    try {
        const now = new Date();
        
        // Удаляем сообщения, где время истечения (expiresAt) меньше текущего времени
        const result = await prisma.message.deleteMany({
            where: {
                expiresAt: {
                    lt: now // "less than" now
                }
            }
        });

        if (result.count > 0) {
            console.log(`🗑️ [CLEANER] Permanently deleted ${result.count} expired messages.`);
        }
    } catch (error) {
        console.error('⚠️ [CLEANER] Error:', error);
    }
});

module.exports = {}; // Просто, чтобы файл можно было подключить