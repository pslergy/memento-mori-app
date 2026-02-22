// src/routes/reports.js
const express = require('express');
const { PrismaClient } = require('@prisma/client');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
const prisma = new PrismaClient();
router.use(authMiddleware);

// POST /api/reports - Отправить жалобу
router.post('/', async (req, res) => {
    const { reason, description, reportedUserId, messageId } = req.body;
    const reporterUserId = req.user.userId;

    if (!reason || !reportedUserId) {
        return res.status(400).json({ message: "Reason and reported user ID are required." });
    }

    try {
        const newReport = await prisma.report.create({
            data: {
                reason,
                description,
                reportedUserId,
                reporterUserId,
                messageId,
            }
        });
        console.log(`✅ New report created by ${reporterUserId} against ${reportedUserId}. Reason: ${reason}`);
        res.status(201).json(newReport);
    } catch (error) {
        console.error('Create Report Error:', error);
        res.status(500).json({ message: "Could not create report." });
    }
});

module.exports = router;