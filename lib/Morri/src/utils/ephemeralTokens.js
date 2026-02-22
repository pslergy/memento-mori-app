// 🛡️ ANTICENSORSHIP: ephemeral token store for mesh anonymity
// PERSISTED in PostgreSQL — survives server restart. TTL 1 hour.
const crypto = require('crypto');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();
const TTL_MS = 60 * 60 * 1000;

async function cleanup() {
  await prisma.ephemeralToken.deleteMany({
    where: { expiresAt: { lt: new Date() } },
  });
}

/**
 * Create ephemeral token for userId. Persists to DB.
 * @param {string} userId - User ID to bind token to
 * @returns {Promise<{ token: string, expiresAt: number }>}
 */
async function create(userId) {
  await cleanup();
  const token = 'eph_' + crypto.randomBytes(12).toString('hex');
  const expiresAt = new Date(Date.now() + TTL_MS);

  await prisma.ephemeralToken.create({
    data: { token, userId, expiresAt },
  });

  return { token, expiresAt: expiresAt.getTime() };
}

/**
 * Resolve ephemeral token to userId. Deletes if expired.
 * @param {string} token - eph_xxx token
 * @returns {Promise<string|null>} userId or null
 */
async function resolve(token) {
  if (!token || typeof token !== 'string' || !token.startsWith('eph_')) {
    return null;
  }

  const entry = await prisma.ephemeralToken.findUnique({
    where: { token },
  });

  if (!entry || entry.expiresAt < new Date()) {
    if (entry) {
      await prisma.ephemeralToken.delete({ where: { token } });
    }
    return null;
  }

  return entry.userId;
}

module.exports = { create, resolve, cleanup };
