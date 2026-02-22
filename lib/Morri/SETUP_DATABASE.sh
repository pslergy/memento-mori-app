#!/bin/bash

# Скрипт для установки и настройки PostgreSQL для Memento Mori

echo "🚀 Memento Mori Database Setup"
echo "================================"

# Проверка, запущен ли скрипт от root или с sudo
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Пожалуйста, запустите скрипт с sudo: sudo bash SETUP_DATABASE.sh"
    exit 1
fi

# 1. Установка PostgreSQL
echo ""
echo "📦 Установка PostgreSQL..."
apt update
apt install -y postgresql postgresql-contrib

# 2. Запуск PostgreSQL
echo ""
echo "🔄 Запуск PostgreSQL..."
systemctl start postgresql
systemctl enable postgresql

# 3. Проверка статуса
echo ""
echo "✅ Проверка статуса PostgreSQL..."
systemctl status postgresql --no-pager | head -5

# 4. Создание базы данных
echo ""
echo "🗄️  Создание базы данных..."
sudo -u postgres psql <<EOF
-- Создание базы данных
CREATE DATABASE memento_mori;

-- Создание пользователя
CREATE USER memento_user WITH PASSWORD 'memento_secure_pass_2024';

-- Выдача прав
GRANT ALL PRIVILEGES ON DATABASE memento_mori TO memento_user;

-- Подключение к базе и выдача прав на схему
\c memento_mori
GRANT ALL ON SCHEMA public TO memento_user;

\q
EOF

echo ""
echo "✅ База данных создана!"
echo ""
echo "📝 Обновите DATABASE_URL в .env файле:"
echo "DATABASE_URL=\"postgresql://memento_user:memento_secure_pass_2024@localhost:5432/memento_mori\""
echo ""
echo "🔐 Или используйте пользователя postgres (если знаете пароль):"
echo "DATABASE_URL=\"postgresql://postgres:YOUR_POSTGRES_PASSWORD@localhost:5432/memento_mori\""
echo ""
echo "📋 Следующий шаг: npx prisma migrate deploy"
