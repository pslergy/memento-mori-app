#!/bin/bash

# Скрипт для проверки подключения к базе данных

echo "🔍 Проверка подключения к базе данных..."
echo "=========================================="

# Проверка наличия .env файла
if [ ! -f .env ]; then
    echo "❌ Файл .env не найден!"
    echo "📝 Создайте .env файл с DATABASE_URL"
    exit 1
fi

# Загрузка переменных из .env
source .env

if [ -z "$DATABASE_URL" ]; then
    echo "❌ DATABASE_URL не установлен в .env файле!"
    exit 1
fi

echo "✅ DATABASE_URL найден"
echo ""

# Извлечение данных из DATABASE_URL
# Формат: postgresql://user:password@host:port/database
DB_USER=$(echo $DATABASE_URL | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
DB_PASS=$(echo $DATABASE_URL | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
DB_HOST=$(echo $DATABASE_URL | sed -n 's/.*@\([^:]*\):.*/\1/p')
DB_PORT=$(echo $DATABASE_URL | sed -n 's/.*:\([0-9]*\)\/.*/\1/p')
DB_NAME=$(echo $DATABASE_URL | sed -n 's/.*\/\([^?]*\).*/\1/p')

echo "📊 Параметры подключения:"
echo "   User: $DB_USER"
echo "   Host: $DB_HOST"
echo "   Port: $DB_PORT"
echo "   Database: $DB_NAME"
echo ""

# Проверка подключения через psql
echo "🔌 Тестирование подключения..."
export PGPASSWORD="$DB_PASS"

if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ Подключение успешно!"
    echo ""
    echo "📋 Информация о базе данных:"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "\dt" 2>/dev/null || echo "   (Таблицы еще не созданы - нужно применить миграции)"
else
    echo "❌ Ошибка подключения!"
    echo ""
    echo "🔧 Возможные причины:"
    echo "   1. Неверные учетные данные в DATABASE_URL"
    echo "   2. PostgreSQL не запущен: sudo systemctl start postgresql"
    echo "   3. База данных не создана"
    echo "   4. Пользователь не имеет прав доступа"
    exit 1
fi

unset PGPASSWORD
