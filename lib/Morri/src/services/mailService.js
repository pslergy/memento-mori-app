// src/services/mailService.js
const nodemailer = require('nodemailer');

// Настройка "транспорта" - способа отправки. 
// В продакшене здесь будут данные от SendGrid, Mailgun или вашего SMTP.
// Для теста используем Ethereal.
async function createTestTransporter() {
    const testAccount = await nodemailer.createTestAccount();
    return nodemailer.createTransport({
        host: 'smtp.ethereal.email',
        port: 587,
        secure: false,
        auth: {
            user: testAccount.user,
            pass: testAccount.pass,
        },
    });
}

// Шаблоны писем
const emailTemplates = {
    'ru': {
        subject: 'Восстановление пароля для Memento Mori',
        text: (token) => `Привет! Для сброса пароля используйте этот токен: ${token}. Если это были не вы, просто проигнорируйте это письмо.`,
    },
    'en': {
        subject: 'Password Reset for Memento Mori',
        text: (token) => `Hello! To reset your password, use this token: ${token}. If you didn't request this, please ignore this email.`,
    },
    // TODO: Добавить шаблоны для de, fr, es, zh и т.д.
};

async function sendPasswordResetEmail(userEmail, token, language = 'en') {
    const transporter = await createTestTransporter();
    const template = emailTemplates[language] || emailTemplates['en']; // Если языка нет, используем английский

    const info = await transporter.sendMail({
        from: '"Memento Mori Support" <noreply@mementomori.app>',
        to: userEmail,
        subject: template.subject,
        text: template.text(token),
    });

    console.log('Message sent: %s', info.messageId);
    // Ссылку для предпросмотра письма можно найти в консоли!
    console.log('Preview URL: %s', nodemailer.getTestMessageUrl(info));
}

module.exports = { sendPasswordResetEmail };