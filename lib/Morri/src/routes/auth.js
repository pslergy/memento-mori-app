// src/routes/auth.js
const express = require('express');
const router = express.Router(); // Сначала создаем router
const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const authController = require('../controllers/authController');
const { sendPasswordResetEmail } = require('../services/mailService');
const verifyToken = require('../middleware/authMiddleware');
const rateLimit = require('express-rate-limit');
const { registrationAbuseGuard, recordSuccess } = require('../middleware/registrationAbuseGuard');

const prisma = new PrismaClient();
const ephemeralTokens = require('../utils/ephemeralTokens');

const recoveryLimiter = rateLimit({
    windowMs: 60 * 60 * 1000, // 1 час
    max: 3, // максимум 3 запроса с одного IP
    message: { message: "Too many recovery attempts. Try again in an hour." },
    standardHeaders: true,
    legacyHeaders: false,
});

// =============================================================================
// 🛡️ СИСТЕМНЫЕ МАРШРУТЫ
// =============================================================================

// Пинг для проверки связи (Используется NetworkMonitor во Flutter)
router.get('/ping', (req, res) => {
    res.status(200).send('PONG');
});

// POST /api/auth/ghost-sync - Выдать JWT призраку, уже известному серверу (по ghostId/id)
router.post('/ghost-sync', async (req, res) => {
    const { id: ghostId, username } = req.body || {};
    if (!ghostId) return res.status(400).json({ message: "id is required" });
    try {
        const user = await prisma.user.findFirst({
            where: { OR: [{ id: ghostId }, { ghostId: ghostId }] }
        });
        if (!user) return res.status(404).json({ message: "Ghost not registered. Use legalize first." });
        const token = jwt.sign({ userId: user.id }, process.env.JWT_SECRET, { expiresIn: '30d' });
        res.json({ token, user: { id: user.id, username: user.username } });
    } catch (e) {
        console.error("ghost-sync error:", e);
        res.status(500).json({ message: "Ghost sync failed" });
    }
});

// =============================================================================
// 🔐 АВТОРИЗАЦИЯ И РЕГИСТРАЦИЯ
// =============================================================================

// 1. Генерация фразы для старых пользователей (требует токен!)
router.post('/generate-recovery', verifyToken, authController.generateRecoveryForOldUser);

router.post('/recover', recoveryLimiter, authController.recoverAccount);

// 2. Регистрация (С генерацией 12 слов) + adaptive friction anti-abuse
router.post('/register', registrationAbuseGuard, authController.register);

// 🛡️ ANTICENSORSHIP: ephemeral token for mesh senderId (anonymous over-the-air)
router.post('/ephemeral-token', verifyToken, async (req, res) => {
  try {
    const { token, expiresAt } = await ephemeralTokens.create(req.user.userId);
    res.json({ ephemeralToken: token, expiresAt });
  } catch (e) {
    res.status(500).json({ message: "Ephemeral token generation failed" });
  }
});

// 3. Логин
router.post('/login', async (req, res) => {
    try {
        const { email, password } = req.body;

        // Поиск пользователя
        const user = await prisma.user.findUnique({ where: { email } });
        if (!user) {
            // Задержка для защиты от тайминг-атак (brute force)
            await new Promise(resolve => setTimeout(resolve, 500)); 
            return res.status(401).json({ message: "Invalid credentials" });
        }

        // Проверка пароля
        // ВНИМАНИЕ: Если в prisma.schema поле называется passwordHash, используем его
        const isMatch = await bcrypt.compare(password, user.passwordHash); 
        
        if (!isMatch) {
            await new Promise(resolve => setTimeout(resolve, 500));
            return res.status(401).json({ message: "Invalid credentials" });
        }

        // Создаем JWT токен
        const token = jwt.sign(
            { userId: user.id }, 
            process.env.JWT_SECRET, 
            { expiresIn: '30d' } // Долгий токен для удобства
        );

        // Отправляем данные пользователя
        res.json({
            token,
            user: { 
                id: user.id, 
                username: user.username, 
                deathDate: user.deathDate,
                dateOfBirth: user.dateOfBirth
            },
            // Флаг: если фразы нет, фронтенд должен её запросить
            requiresRecoverySetup: !user.recoveryMnemonicHash 
        });

    } catch (error) {
        console.error("Login error:", error);
        res.status(500).json({ message: "Server error" });
    }
});

// =============================================================================
// 🚑 ВОССТАНОВЛЕНИЕ ДОСТУПА
// =============================================================================

// 4. Восстановление по мнемонике (12 слов)
router.post('/recover', authController.recoverAccount);

// 5. Сброс пароля через Email (Классический способ)
router.post('/forgot-password', async (req, res) => {
    try {
        const { email, language } = req.body;
        const user = await prisma.user.findUnique({ where: { email } });

        if (!user) {
            return res.status(200).json({ message: "If account exists, reset link sent." });
        }
        
        const resetToken = crypto.randomBytes(32).toString('hex');
        // Здесь можно добавить сохранение токена в БД и отправку письма
        // await sendPasswordResetEmail(user.email, resetToken, language);

        res.status(200).json({ message: "If account exists, reset link sent." });
    } catch (e) {
        res.status(500).json({ message: "Error processing request" });
    }
});


/**
 * POST /api/auth/legalize
 * Переводит оффлайн-личность (Ghost) в гражданина Облака.
 * Контракт: Prisma User не имеет поля status; используем ghostId, countryCode, gender, dateOfBirth, deathDate.
 */
router.post('/legalize', registrationAbuseGuard, async (req, res) => {
    const { ghostId, email, pass, desiredUsername, password } = req.body;

    try {
        // 1. ПРОВЕРКА: Не занят ли ник кем-то другим (кроме нас самих)
        const existingUser = await prisma.user.findFirst({
            where: { 
                username: desiredUsername,
                NOT: { id: ghostId } // Если это не мы сами пытаемся обновиться
            }
        });

        if (existingUser) {
            // Возвращаем 409 Conflict - Flutter поймает это и попросит сменить ник
            return res.status(409).json({ 
                error: "NICKNAME_TAKEN", 
                message: "This callsign is already reserved by another unit." 
            });
        }

        // 2. АТОМАРНАЯ ЛЕГАЛИЗАЦИЯ (Identity Upsert)
        // Мы используем ghostId как первичный ключ, чтобы сохранить всю историю сообщений, 
        // которые уже успели прилететь на сервер от BRIDGE-нод с этим ID.
        const passwordHash = await bcrypt.hash(password, 10);
        
        const user = await prisma.user.upsert({
            where: { id: ghostId },
            update: {
                email,
                username: desiredUsername,
                passwordHash,
                ghostId: ghostId
            },
            create: {
                id: ghostId,
                email,
                username: desiredUsername,
                passwordHash,
                ghostId: ghostId,
                countryCode: 'XX',
                gender: 'OTHER',
                dateOfBirth: new Date('2000-01-01'),
                deathDate: new Date('2070-01-01')
            }
        });

        const token = jwt.sign({ userId: user.id }, process.env.JWT_SECRET, { expiresIn: '30d' });

        if (req.registrationGuardMeta) recordSuccess(req.registrationGuardMeta);
        console.log(`🧬 [Identity] Ghost ${ghostId.substring(0,8)} legalized as ${user.username}`);
        res.json({ status: 'verified', token, user });

    } catch (e) {
        console.error("Legalization Error:", e);
        res.status(500).json({ error: "GRID_FAULT", message: "Internal server error during legalization" });
    }
});
module.exports = router;