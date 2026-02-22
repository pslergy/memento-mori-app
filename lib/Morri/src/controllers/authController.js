const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
const bip39 = require('bip39');
const crypto = require('crypto');
const disposableDomains = require('disposable-email-domains');
const dns = require('dns').promises;
// Вспомогательная функция для хэширования мнемоники (чтобы код был чище)
const hashMnemonic = (phrase) => {
    return crypto.createHash('sha256').update(phrase.trim().toLowerCase()).digest('hex');
};

// Функция проверки реальности домена

async function isEmailReal(email) {
    if (!email || !email.includes('@')) return false;
    const domain = email.split('@')[1].toLowerCase();
    
    // 1. Проверка: не является ли домен одноразовым (disposable)
    if (disposableDomains.includes(domain)) {
        console.log(`[Registration] Blocked disposable domain: ${domain}`);
        return false;
    }

    // 2. Проверка: есть ли у домена MX-записи (почтовые сервера)
    try {
        const mxRecords = await dns.resolveMx(domain);
        return mxRecords && mxRecords.length > 0;
    } catch (e) {
        // Если MX записи не найдены или домен не существует
        return false;
    }
}

// 1. РЕГИСТРАЦИЯ
exports.register = async (req, res) => {
    try {
        const { username, email, password, dateOfBirth, lifestyle, countryCode, gender } = req.body;

        // --- ВАЛИДАЦИЯ EMAIL ---
        const isReal = await isEmailReal(email);
        if (!isReal) {
            return res.status(400).json({ 
                message: "Invalid email address. Please use a real provider (Gmail, Outlook, Mail.ru etc.)" 
            });
        }

        // Проверяем уникальность username и email
        const existingUser = await prisma.user.findFirst({
            where: {
                OR: [
                    { email: email.toLowerCase() },
                    { username: username }
                ]
            }
        });

        if (existingUser) {
            return res.status(400).json({ message: "User with this email or username already exists" });
        }

        // Генерация мнемоники и хэшей
        const mnemonic = bip39.generateMnemonic();
        const recoveryMnemonicHash = crypto.createHash('sha256').update(mnemonic.trim().toLowerCase()).digest('hex');
        const passwordHash = await bcrypt.hash(password, 12);

        // Расчет даты смерти
        const deathDate = new Date();
        deathDate.setFullYear(deathDate.getFullYear() + 50); 

        // Сохранение в БД
        const newUser = await prisma.user.create({
            data: {
                username,
                email: email.toLowerCase(),
                passwordHash,
                dateOfBirth: new Date(dateOfBirth),
                deathDate,
                recoveryMnemonicHash,
                lifestyle: lifestyle || {},
                countryCode: countryCode || "RU",
                gender: gender || "MALE" 
            }
        });

        // Создание токена
        const token = jwt.sign(
            { userId: newUser.id }, 
            process.env.JWT_SECRET, 
            { expiresIn: '30d' }
        );

        console.log(`[Registration] New user created: ${username}`);

        const { recordSuccess } = require('../middleware/registrationAbuseGuard');
        if (req.registrationGuardMeta) recordSuccess(req.registrationGuardMeta);

        // Возвращаем успех
        res.status(201).json({
            message: "User registered successfully",
            recoveryPhrase: mnemonic, // Показываем только один раз!
            token,
            user: { 
                id: newUser.id, 
                username: newUser.username,
                deathDate: newUser.deathDate,
                dateOfBirth: newUser.dateOfBirth
            }
        });

    } catch (error) {
        console.error("REGISTRATION ERROR:", error);
        res.status(500).json({ message: "Server error", details: error.message });
    }
};

// 2. ВОССТАНОВЛЕНИЕ АККАУНТА (по фразе)
exports.recoverAccount = async (req, res) => {
    try {
        const { email, recoveryPhrase, newPassword } = req.body;

        if (!email || !recoveryPhrase || !newPassword) {
            return res.status(400).json({ message: "All fields are required" });
        }

        const user = await prisma.user.findUnique({ where: { email } });
        if (!user || !user.recoveryMnemonicHash) {
            return res.status(404).json({ message: "Recovery not possible" });
        }

        // Проверяем хэш фразы (SHA-256)
        const incomingHash = hashMnemonic(recoveryPhrase);
        
        if (incomingHash !== user.recoveryMnemonicHash) {
            return res.status(401).json({ message: "Invalid recovery phrase" });
        }

        // Хэшируем новый пароль
        const newPasswordHash = await bcrypt.hash(newPassword, 12);

        await prisma.user.update({
            where: { id: user.id },
            data: { passwordHash: newPasswordHash } // Убедись, что в схеме именно passwordHash
        });

        console.log(`[Auth] Access restored for: ${email}`);
        res.status(200).json({ message: "Password updated successfully" });

    } catch (error) {
        console.error("RECOVERY ERROR:", error);
        res.status(500).json({ message: "Internal server error" });
    }
};

// 3. ГЕНЕРАЦИЯ ФРАЗЫ ДЛЯ СТАРЫХ ПОЛЬЗОВАТЕЛЕЙ
exports.generateRecoveryForOldUser = async (req, res) => {
    try {
        const userId = req.user.userId; // Берется из middleware verifyToken

        const user = await prisma.user.findUnique({ where: { id: userId } });
        
        if (!user) return res.status(404).json({ message: "User not found" });
        if (user.recoveryMnemonicHash) {
            return res.status(400).json({ message: "Recovery phrase already set." });
        }

        const mnemonic = bip39.generateMnemonic();
        const mnemonicHash = hashMnemonic(mnemonic); // Используем тот же SHA-256!

        await prisma.user.update({
            where: { id: userId },
            data: { recoveryMnemonicHash: mnemonicHash }
        });

        res.json({ recoveryPhrase: mnemonic });

    } catch (error) {
        console.error("GENERATION ERROR:", error);
        res.status(500).json({ message: "Error generating phrase" });
    }
};