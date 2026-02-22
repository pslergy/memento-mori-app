/**
 * Room Events Routes
 * Маршруты для работы с событиями комнат
 */

const express = require('express');
const router = express.Router();
const { authenticate } = require('../middleware/auth');
const {
  createRoomEvent,
  getRoomEvents,
  syncRoomEvents,
  getRoomParticipants
} = require('./room_events_controller');

// POST /api/rooms/:roomId/events
// Создание события комнаты
router.post('/:roomId/events', authenticate, createRoomEvent);

// GET /api/rooms/:roomId/events
// Получение событий комнаты
router.get('/:roomId/events', authenticate, getRoomEvents);

// POST /api/rooms/:roomId/events/sync
// Синхронизация событий (batch)
router.post('/:roomId/events/sync', authenticate, syncRoomEvents);

// GET /api/rooms/:roomId/participants
// Получение участников комнаты (пересобранных из событий)
router.get('/:roomId/participants', authenticate, getRoomParticipants);

module.exports = router;
