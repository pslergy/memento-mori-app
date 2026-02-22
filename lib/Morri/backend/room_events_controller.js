/**
 * Room Events Controller
 * Room events handling with duplicate protection.
 * DTN: Append-only; query only by roomId and user participation. No bridge/chain filter. No delivery inference.
 */

const { RoomEvent, Room } = require('../models');
const { Op } = require('sequelize');

/**
 * Create room event
 * POST /api/rooms/:roomId/events
 * DTN: Append-only. Idempotent by (roomId, id). Do not infer delivery or recipient presence.
 */
async function createRoomEvent(req, res) {
  const { roomId } = req.params;
  const { id, type, userId, timestamp, payload, origin = 'SERVER' } = req.body;
  
  // Validation
  if (!id || !type || !userId || !timestamp) {
    return res.status(400).json({ 
      error: 'Missing required fields: id, type, userId, timestamp' 
    });
  }
  
  // UUID format check
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(id)) {
    return res.status(400).json({ error: 'Invalid event ID format (must be UUID v4)' });
  }
  
  // Room access check
  const hasAccess = await checkRoomAccess(req.user.id, roomId);
  if (!hasAccess) {
    return res.status(403).json({ error: 'Access denied to this room' });
  }
  
  try {
    // Uniqueness check (idempotent)
    const existing = await RoomEvent.findOne({
      where: { 
        roomId, 
        id 
      }
    });
    
    if (existing) {
      // Event already exists - normal (mesh may deliver twice)
      return res.status(200).json({
        success: true,
        event: {
          id: existing.id,
          roomId: existing.roomId,
          type: existing.type,
          userId: existing.userId,
          timestamp: existing.timestamp,
          payload: existing.payload ? JSON.parse(existing.payload) : null,
          origin: existing.eventOrigin || 'LOCAL' // 📊 For diagnostics
        },
        duplicate: true
      });
    }
    
    // Создание нового события
    const event = await RoomEvent.create({
      id,
      roomId,
      type,
      userId,
      timestamp,
      payload: payload ? JSON.stringify(payload) : null,
      eventOrigin: origin // 📊 For diagnostics
    });
    
    res.status(201).json({
      success: true,
      event: {
        id: event.id,
        roomId: event.roomId,
        type: event.type,
        userId: event.userId,
        timestamp: event.timestamp,
        payload: event.payload ? JSON.parse(event.payload) : null,
        origin: event.eventOrigin || origin // 📊 For diagnostics
      }
    });
  } catch (error) {
    // Обработка ошибок уникальности (может произойти при race condition)
    if (error.name === 'SequelizeUniqueConstraintError') {
      const existing = await RoomEvent.findOne({
        where: { roomId, id }
      });
      return res.status(200).json({
        success: true,
        event: {
          id: existing.id,
          roomId: existing.roomId,
          type: existing.type,
          userId: existing.userId,
          timestamp: existing.timestamp,
          payload: existing.payload ? JSON.parse(existing.payload) : null,
          origin: existing.eventOrigin || 'LOCAL' // 📊 For diagnostics
        },
        duplicate: true
      });
    }
    
    console.error('Error creating room event:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Get room events
 * GET /api/rooms/:roomId/events
 * DTN: Query only by roomId and user participation. No bridge or chain filter. Events may be returned repeatedly.
 */
async function getRoomEvents(req, res) {
  const { roomId } = req.params;
  const { since, limit = 100, type } = req.query;
  
  // Access check (identity/participation only; no bridge/chain)
  const hasAccess = await checkRoomAccess(req.user.id, roomId);
  if (!hasAccess) {
    return res.status(403).json({ error: 'Access denied to this room' });
  }
  
  try {
    const where = { roomId };
    
    if (since) {
      where.timestamp = { [Op.gt]: parseInt(since) };
    }
    
    if (type) {
      where.type = type;
    }
    
    const events = await RoomEvent.findAll({
      where,
      order: [['timestamp', 'ASC']],
      limit: Math.min(parseInt(limit), 1000) // Max 1000
    });
    
    res.json({
      events: events.map(e => ({
        id: e.id,
        roomId: e.roomId,
        type: e.type,
        userId: e.userId,
        timestamp: e.timestamp,
        payload: e.payload ? JSON.parse(e.payload) : null,
        origin: e.eventOrigin || 'LOCAL' // 📊 For diagnostics
      })),
      total: events.length,
      hasMore: events.length === parseInt(limit)
    });
  } catch (error) {
    console.error('Error fetching room events:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Sync room events (batch)
 * POST /api/rooms/:roomId/events/sync
 */
async function syncRoomEvents(req, res) {
  const { roomId } = req.params;
  const { events = [], lastKnownTimestamp = 0 } = req.body;
  
  // Проверка доступа
  const hasAccess = await checkRoomAccess(req.user.id, roomId);
  if (!hasAccess) {
    return res.status(403).json({ error: 'Access denied to this room' });
  }
  
  let synced = 0;
  let duplicates = 0;
  
  // Save events from client (idempotent)
  for (const eventData of events) {
    try {
      const [event, created] = await RoomEvent.findOrCreate({
        where: { 
          roomId, 
          id: eventData.id 
        },
        defaults: {
          id: eventData.id,
          roomId,
          type: eventData.type,
          userId: eventData.userId,
          timestamp: eventData.timestamp,
          payload: eventData.payload ? JSON.stringify(eventData.payload) : null,
          eventOrigin: eventData.origin || 'MESH' // 📊 События от клиента обычно через mesh
        }
      });
      
      if (created) {
        synced++;
      } else {
        duplicates++;
      }
    } catch (error) {
      // Ignore uniqueness errors (duplicates)
      if (error.name === 'SequelizeUniqueConstraintError') {
        duplicates++;
      } else {
        console.error('Error syncing event:', error);
      }
    }
  }
  
  // Get events missing on client
  let missing = [];
  try {
    const missingEvents = await RoomEvent.findAll({
      where: {
        roomId,
        timestamp: { [Op.gt]: parseInt(lastKnownTimestamp) }
      },
      order: [['timestamp', 'ASC']],
      limit: 1000
    });
    
    missing = missingEvents.map(e => ({
      id: e.id,
      roomId: e.roomId,
      type: e.type,
      userId: e.userId,
      timestamp: e.timestamp,
      payload: e.payload ? JSON.parse(e.payload) : null,
      origin: e.eventOrigin || 'SERVER' // 📊 События с сервера
    }));
  } catch (error) {
    console.error('Error fetching missing events:', error);
  }
  
  res.json({
    synced,
    duplicates,
    missing
  });
}

/**
 * Get room participants (rebuilt from events)
 * GET /api/rooms/:roomId/participants
 */
async function getRoomParticipants(req, res) {
  const { roomId } = req.params;
  
  // Проверка доступа
  const hasAccess = await checkRoomAccess(req.user.id, roomId);
  if (!hasAccess) {
    return res.status(403).json({ error: 'Access denied to this room' });
  }
  
  try {
    // Получаем все события JOIN/LEAVE для комнаты
    const events = await RoomEvent.findAll({
      where: {
        roomId,
        type: { [Op.in]: ['JOIN_ROOM', 'LEAVE_ROOM'] }
      },
      order: [['timestamp', 'ASC']]
    });
    
    // Rebuild participants
    const participantsMap = new Map();
    
    for (const event of events) {
      if (event.type === 'JOIN_ROOM') {
        participantsMap.set(event.userId, {
          userId: event.userId,
          joinedAt: event.timestamp
        });
      } else if (event.type === 'LEAVE_ROOM') {
        participantsMap.delete(event.userId);
      }
    }
    
    // Convert to array and get username for each participant
    const participants = [];
    for (const [userId, data] of participantsMap.entries()) {
      const user = await User.findByPk(userId);
      participants.push({
        userId,
        username: user?.username || 'Unknown',
        joinedAt: data.joinedAt
      });
    }
    
    res.json({ participants });
  } catch (error) {
    console.error('Error fetching room participants:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Check user access to room
 */
async function checkRoomAccess(userId, roomId) {
  try {
    const room = await Room.findByPk(roomId);
    if (!room) return false;
    
    // Check if user is participant
    const events = await RoomEvent.findAll({
      where: {
        roomId,
        userId,
        type: 'JOIN_ROOM'
      }
    });
    
    // If JOIN_ROOM exists - check there was no LEAVE_ROOM after it
    if (events.length > 0) {
      const lastJoin = events[events.length - 1];
      const leaveAfter = await RoomEvent.findOne({
        where: {
          roomId,
          userId,
          type: 'LEAVE_ROOM',
          timestamp: { [Op.gt]: lastJoin.timestamp }
        }
      });
      
      return !leaveAfter; // No LEAVE after last JOIN - access granted
    }
    
    return false;
  } catch (error) {
    console.error('Error checking room access:', error);
    return false;
  }
}

module.exports = {
  createRoomEvent,
  getRoomEvents,
  syncRoomEvents,
  getRoomParticipants
};
