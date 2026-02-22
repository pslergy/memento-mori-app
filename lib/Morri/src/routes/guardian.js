const express = require('express'); // Предполагаем, что express используется
const router = express.Router();

/**
 * Словарь "красных флагов" с системой очков риска.
 * Структура:
 * - keywords: объект, где ключ - код языка (ISO 639-1).
 * - [lang]: объект с категориями риска.
 * - [category]: массив объектов, где:
 *   - phrase: подозрительная фраза или слово.
 *   - score: количество очков риска (чем выше, тем опаснее).
 */
const dictionary = {
    version: 2, // Обновили версию из-за новой структуры
    keywords: {
        // Русский (ru)
        ru: {
            finance: [
                { phrase: "номер карты", score: 8 },
                { phrase: "переведи на карту", score: 8 },
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "срок действия", score: 7 },
                { phrase: "код из смс", score: 10 },
                { phrase: "быстрый заработок", score: 6 },
                { phrase: "инвестиционная платформа", score: 6 },
                { phrase: "выигрыш", score: 5 },
                { phrase: "лотерея", score: 5 },
                { phrase: "оплата вперед", score: 4 },
                { phrase: "предоплата", score: 3 },
                { phrase: "залог", score: 3 }
            ],
            urgency: [
                { phrase: "только сейчас", score: 4 },
                { phrase: "срочно нужны", score: 5 },
                { phrase: "последний шанс", score: 4 },
                { phrase: "не упусти", score: 3 }
            ],
            security: [
                { phrase: "ваш аккаунт заблокирован", score: 9 },
                { phrase: "служба безопасности", score: 7 },
                { phrase: "перейдите по ссылке", score: 6 },
                { phrase: "обновите данные", score: 7 },
                { phrase: "скачать приложение", score: 5 }
            ],
            suspiciousLinks: [ // Более точные правила для ссылок
                { phrase: "bit.ly", score: 4 },
                { phrase: "goo.gl", score: 4 },
                { phrase: "t.co", score: 3 },
                { phrase: "cutt.ly", score: 4 }
            ]
        },
        // Английский (en)
        en: {
            finance: [
                { phrase: "card number", score: 8 },
                { phrase: "transfer money to card", score: 8 },
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "expiration date", score: 7 },
                { phrase: "code from sms", score: 10 },
                { phrase: "quick profit", score: 6 },
                { phrase: "investment platform", score: 6 },
                { phrase: "you won", score: 5 },
                { phrase: "lottery", score: 5 },
                { phrase: "upfront payment", score: 4 },
                { phrase: "prepayment", score: 3 },
                { phrase: "deposit", score: 3 }
            ],
            urgency: [
                { phrase: "only now", score: 4 },
                { phrase: "urgent need", score: 5 },
                { phrase: "last chance", score: 4 },
                { phrase: "don't miss", score: 3 }
            ],
            security: [
                { phrase: "your account is blocked", score: 9 },
                { phrase: "security service", score: 7 },
                { phrase: "click the link", score: 6 },
                { phrase: "update your details", score: 7 },
                { phrase: "download the app", score: 5 }
            ],
            suspiciousLinks: [
                { phrase: "bit.ly", score: 4 },
                { phrase: "goo.gl", score: 4 },
                { phrase: "t.co", score: 3 },
                { phrase: "cutt.ly", score: 4 }
            ]
        },
        // Французский (fr)
        fr: {
            finance: [
                { phrase: "numéro de carte", score: 8 },
                { phrase: "virement sur la carte", score: 8 },
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "date d'expiration", score: 7 },
                { phrase: "code du sms", score: 10 },
                { phrase: "profit rapide", score: 6 },
                { phrase: "plateforme d'investissement", score: 6 },
                { phrase: "vous avez gagné", score: 5 },
                { phrase: "loterie", score: 5 },
                { phrase: "paiement d'avance", score: 4 },
                { phrase: "acompte", score: 3 }
            ],
            urgency: [
                { phrase: "seulement maintenant", score: 4 },
                { phrase: "besoin urgent", score: 5 },
                { phrase: "dernière chance", score: 4 }
            ],
            security: [
                { phrase: "votre compte est bloqué", score: 9 },
                { phrase: "service de sécurité", score: 7 },
                { phrase: "cliquez sur le lien", score: 6 },
                { phrase: "téléchargez l'application", score: 5 }
            ]
        },
        // Испанский (es)
        es: {
            finance: [
                { phrase: "número de tarjeta", score: 8 },
                { phrase: "transfiere a la tarjeta", score: 8 },
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "fecha de caducidad", score: 7 },
                { phrase: "código del sms", score: 10 },
                { phrase: "ganancia rápida", score: 6 },
                { phrase: "plataforma de inversión", score: 6 },
                { phrase: "has ganado", score: 5 },
                { phrase: "lotería", score: 5 },
                { phrase: "pago por adelantado", score: 4 },
                { phrase: "anticipo", score: 3 }
            ],
            urgency: [
                { phrase: "solo por hoy", score: 4 },
                { phrase: "necesito urgente", score: 5 },
                { phrase: "última oportunidad", score: 4 }
            ],
            security: [
                { phrase: "su cuenta ha sido bloqueada", score: 9 },
                { phrase: "servicio de seguridad", score: 7 },
                { phrase: "haga clic en el enlace", score: 6 },
                { phrase: "descargue la aplicación", score: 5 }
            ]
        },
        // Китайский (упрощенный) (zh)
        zh: {
            finance: [
                { phrase: "银行卡号", score: 8 }, // Bank card number
                { phrase: "转账", score: 8 },     // Transfer money
                { phrase: "验证码", score: 10 },  // Verification code (often from SMS)
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "有效期", score: 7 },  // Expiration date
                { phrase: "快速赚钱", score: 6 }, // Quick money-making
                { phrase: "投资平台", score: 6 }, // Investment platform
                { phrase: "中奖", score: 5 },     // You won a prize
                { phrase: "彩票", score: 5 },     // Lottery
                { phrase: "预付款", score: 4 },   // Prepayment
                { phrase: "定金", score: 3 }      // Deposit
            ],
            urgency: [
                { phrase: "就现在", score: 4 },     // Only now
                { phrase: "紧急", score: 5 },       // Urgent
                { phrase: "最后机会", score: 4 }   // Last chance
            ],
            security: [
                { phrase: "账户被冻结", score: 9 }, // Account is frozen/blocked
                { phrase: "安全中心", score: 7 },   // Security center
                { phrase: "点击链接", score: 6 },   // Click the link
                { phrase: "下载APP", score: 5 }   // Download APP
            ]
        },
        // Корейский (ko)
        ko: {
            finance: [
                { phrase: "카드 번호", score: 8 }, // Card number
                { phrase: "계좌 이체", score: 8 },  // Bank transfer
                { phrase: "인증 번호", score: 10 }, // Verification code
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "유효 기간", score: 7 }, // Expiration date
                { phrase: "빠른 수익", score: 6 },  // Quick profit
                { phrase: "투자 플랫폼", score: 6 },// Investment platform
                { phrase: "당첨", score: 5 },      // Won a prize
                { phrase: "복권", score: 5 },      // Lottery
                { phrase: "선불", score: 4 },      // Prepayment
                { phrase: "보증금", score: 3 }     // Deposit
            ],
            urgency: [
                { phrase: "지금만", score: 4 },    // Only now
                { phrase: "긴급", score: 5 },      // Urgent
                { phrase: "마지막 기회", score: 4 }// Last chance
            ],
            security: [
                { phrase: "계정이 잠겼습니다", score: 9 }, // Your account is locked
                { phrase: "보안팀", score: 7 },     // Security team
                { phrase: "링크를 클릭하세요", score: 6 }, // Click the link
                { phrase: "앱을 다운로드하세요", score: 5 } // Download the app
            ]
        },
        // Хинди (hi)
        hi: {
            finance: [
                { phrase: "कार्ड नंबर", score: 8 }, // Card number
                { phrase: "पैसे भेजो", score: 8 },   // Send money
                { phrase: "ओटीपी", score: 10 },      // OTP (One-Time Password)
                { phrase: "cvc", score: 10 },
                { phrase: "cvv", score: 10 },
                { phrase: "समाप्ति तिथि", score: 7 }, // Expiration date
                { phrase: "जल्दी कमाई", score: 6 },  // Quick earning
                { phrase: "निवेश मंच", score: 6 },   // Investment platform
                { phrase: "आप जीत गए", score: 5 },  // You won
                { phrase: "लॉटरी", score: 5 },     // Lottery
                { phrase: "अग्रिम भुगतान", score: 4 } // Advance payment
            ],
            urgency: [
                { phrase: "सिर्फ अभी", score: 4 }, // Only now
                { phrase: "तत्काल", score: 5 },    // Urgent
                { phrase: "आखिरी मौका", score: 4 } // Last chance
            ],
            security: [
                { phrase: "आपका खाता ब्लॉक हो गया है", score: 9 }, // Your account is blocked
                { phrase: "सुरक्षा विभाग", score: 7 }, // Security department
                { phrase: "लिंक पर क्लिक करें", score: 6 }, // Click on the link
                { phrase: "ऐप डाउनलोड करें", score: 5 } // Download the app
            ]
        }
    }
};

// GET /api/guardian/dictionary
router.get('/dictionary', (req, res) => {
    res.json(dictionary);
});

module.exports = router;