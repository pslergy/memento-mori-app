// src/services/timerService.js

// Упрощенные данные для примера. В будущем можно вынести в отдельную таблицу или конфиг.
const lifeExpectancyData = {
    // Средняя продолжительность жизни по странам (условно)
    RU: { MALE: 68, FEMALE: 78 },
    US: { MALE: 76, FEMALE: 81 },
    JP: { MALE: 81, FEMALE: 87 },
    DEFAULT: { MALE: 70, FEMALE: 75 },
};

const lifestyleFactors = {
    sport: { REGULAR: 5, NEVER: -3, SOMETIMES: 0 },
    habits: { YES: -7, NO: 2 }, // Даем небольшой бонус за отсутствие привычек
    optimism: { YES: 2, NO: -1 },
    stress: { HIGH: -4, LOW: 2, MEDIUM: 0 },
    sleep: { POOR: -3, GOOD: 3, NORMAL: 0 },
    social: { RARELY: -2, OFTEN: 2, SOMETIMES: 0 },
    purpose: { YES: 3, NO: -1, UNSURE: 0 },
    // НОВЫЕ ФАКТОРЫ
    diet: { BALANCED: 4, FASTFOOD: -5, NORMAL: 0 },
    satisfaction: { YES: 2, HATE: -3, MOSTLY_NO: -1 },
};

function calculateDeathDate(userData) {
    const { dateOfBirth, countryCode, gender, lifestyle } = userData;
    
    // 1. База
    const countryData = lifeExpectancyData[countryCode.toUpperCase()] || lifeExpectancyData.DEFAULT;
    let baseLifespan = countryData[gender.toUpperCase()];

    // 2. Применяем корректировки динамически
    let adjustment = 0;
    for (const factor in lifestyle) {
        if (lifestyleFactors[factor] && lifestyleFactors[factor][lifestyle[factor]]) {
            adjustment += lifestyleFactors[factor][lifestyle[factor]];
        }
    }
    
    // 3. Фактор судьбы (сделаем его чуть более влиятельным)
    const fateFactor = (Math.random() * 6) - 3; // от -3 до +3 лет

    // 4. Итоговая продолжительность жизни
    const finalLifespan = baseLifespan + adjustment + fateFactor;
    
    // 5. Вычисление
    const birthDate = new Date(dateOfBirth);
    // Используем копию даты, чтобы избежать мутации оригинального объекта
    const deathDate = new Date(birthDate.getTime());
    deathDate.setFullYear(deathDate.getFullYear() + Math.floor(finalLifespan));
    
    // Добавляем случайность в месяцы/дни, но более предсказуемо
    const randomMonthOffset = Math.floor(Math.random() * 12);
    deathDate.setMonth(deathDate.getMonth() + randomMonthOffset);
    
    // Добавляем оставшуюся дробную часть года в виде дней
    const remainingDays = (finalLifespan % 1) * 365;
    deathDate.setDate(deathDate.getDate() + Math.floor(remainingDays));

    return deathDate;
}

module.exports = { calculateDeathDate };