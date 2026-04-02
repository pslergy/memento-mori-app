import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:memento_mori_app/core/dm_chat_id.dart';
import 'package:memento_mori_app/core/safe_string_prefix.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/room_events.dart'
    show RoomEvent, EventOrigin, RoomParticipantsRebuilder;

/// Service for working with rooms (chats)
class RoomService {
  static final RoomService _instance = RoomService._internal();
  factory RoomService() => _instance;
  RoomService._internal();

  /// Всегда текущий профиль БД после смены REAL/DECOY ([locator.reset]).
  LocalDatabaseService get _db => LocalDatabaseService();

  ApiService? get _apiOrNull =>
      locator.isRegistered<ApiService>() ? locator<ApiService>() : null;

  /// Стабильный id лички для mesh/облака — те же нормализации, что [incomingDmMatchesMyChatWithPeer].
  String _createDirectRoomId(String userId1, String userId2) {
    return canonicalDirectChatId(
      meshStableIdForDm(userId1),
      meshStableIdForDm(userId2),
    );
  }

  /// Creates direct room (1-on-1)
  /// For user it looks like a regular chat
  Future<Map<String, dynamic>> createDirectRoom(String otherUserId) async {
    final api = _apiOrNull;
    if (api == null) throw Exception('User not authenticated');
    final currentUserId = api.currentUserId;
    if (currentUserId.isEmpty) {
      throw Exception('User not authenticated');
    }

    final roomId = _createDirectRoomId(currentUserId, otherUserId);

    // Get friend name from friends list
    final friends = await _db.getFriends();
    final friend = friends.firstWhere(
      (f) => f['id'] == otherUserId,
      orElse: () => {'username': 'Unknown'},
    );
    final friendName = friend['username'] ?? 'Unknown';

    // Check if room already exists
    final existingRooms = await _db.getAllChatRooms();
    final existingRoom = existingRooms.firstWhere(
      (r) => r['id'] == roomId,
      orElse: () => <String, dynamic>{},
    );

    if (existingRoom.isNotEmpty) {
      return existingRoom;
    }

    // Старая комната с другим dm_* (сырой id vs GHOST_ / BLE) — переносим на канонический roomId.
    Map<String, dynamic>? legacyDm;
    for (final r in existingRooms) {
      if (r['type'] != 'DIRECT' && r['room_type'] != 'DIRECT') continue;
      final rid = r['id']?.toString() ?? '';
      if (!rid.startsWith('dm_')) continue;
      List<dynamic> parts;
      try {
        parts = jsonDecode(r['participants'] ?? '[]') as List<dynamic>? ?? [];
      } catch (_) {
        continue;
      }
      final ps = parts.map((e) => e.toString()).toList();
      final bool hasFriend = ps.contains(otherUserId) ||
          ps.any((p) => meshStableIdForDm(p) == meshStableIdForDm(otherUserId));
      final bool hasMe = ps.contains(currentUserId) ||
          ps.any((p) => meshStableIdForDm(p) == meshStableIdForDm(currentUserId));
      if (hasFriend && hasMe) {
        legacyDm = Map<String, dynamic>.from(r);
        break;
      }
    }
    if (legacyDm != null && legacyDm['id'] != roomId) {
      final legId = legacyDm['id'] as String;
      final targetTaken =
          existingRooms.any((r) => r['id'] == roomId && r['id'] != legId);
      if (!targetTaken) {
        await _db.migrateDmChatRoomId(fromId: legId, toId: roomId);
        legacyDm['id'] = roomId;
        return legacyDm;
      }
    }

    // Create new room
    final room = {
      'id': roomId,
      'ownerId': currentUserId,
      'name': friendName, // For user, name = friend name
      'type': 'DIRECT',
      'room_type': 'DIRECT',
      'creator': currentUserId,
      'participants':
          jsonEncode([currentUserId, otherUserId]), // Cache, not truth
      'lastMessage': '',
      'lastActivity': DateTime.now().millisecondsSinceEpoch,
    };

    await _db.database.then((db) => db.insert(
          'chat_rooms',
          room,
          conflictAlgorithm: ConflictAlgorithm.replace,
        ));

    // 🔥 CRITICAL: Create JOIN_ROOM events for both participants
    // This is the truth about room state
    await _saveRoomEvent(RoomEvent.joinRoom(
      roomId: roomId,
      userId: currentUserId,
      origin: EventOrigin.LOCAL, // 📊 Created locally
    ));
    await _saveRoomEvent(RoomEvent.joinRoom(
      roomId: roomId,
      userId: otherUserId,
      origin: EventOrigin.LOCAL, // 📊 Assume other participant also locally
    ));

    return room;
  }

  /// Creates group room
  Future<Map<String, dynamic>> createGroupRoom({
    required String name,
    List<String>? participantIds,
  }) async {
    final api = _apiOrNull;
    if (api == null) throw Exception('User not authenticated');
    final currentUserId = api.currentUserId;
    if (currentUserId.isEmpty) {
      throw Exception('User not authenticated');
    }

    // Generate random UUID for group
    final roomId =
        'group_${DateTime.now().millisecondsSinceEpoch}_${safePrefix(currentUserId, 8)}';

    final participants = participantIds ?? [currentUserId];
    if (!participants.contains(currentUserId)) {
      participants.add(currentUserId);
    }

    final room = {
      'id': roomId,
      'ownerId': currentUserId,
      'name': name.isEmpty ? 'Group' : name,
      'type': 'GROUP',
      'room_type': 'GROUP',
      'creator': currentUserId,
      'participants': jsonEncode(participants), // Cache, not truth
      'lastMessage': '',
      'lastActivity': DateTime.now().millisecondsSinceEpoch,
    };

    await _db.database.then((db) => db.insert(
          'chat_rooms',
          room,
          conflictAlgorithm: ConflictAlgorithm.replace,
        ));

    // 🔥 CRITICAL: Create JOIN_ROOM events for all participants
    // This is the truth about room state
    for (final participantId in participants) {
      await _saveRoomEvent(RoomEvent.joinRoom(
        roomId: roomId,
        userId: participantId,
        origin: EventOrigin.LOCAL, // 📊 Created locally
      ));
    }

    return room;
  }

  /// Gets room by ID
  Future<Map<String, dynamic>?> getRoom(String roomId) async {
    final rooms = await _db.getAllChatRooms();
    try {
      return rooms.firstWhere((r) => r['id'] == roomId);
    } catch (e) {
      return null;
    }
  }

  /// Adds participant to group room
  /// Updates participants cache and creates JOIN_ROOM event
  Future<void> addParticipant(String roomId, String userId) async {
    final room = await getRoom(roomId);
    if (room == null) return;

    // 🔥 TRUTH: Create JOIN_ROOM event
    await _saveRoomEvent(RoomEvent.joinRoom(
      roomId: roomId,
      userId: userId,
      origin: EventOrigin.LOCAL, // 📊 Created locally
    ));

    // 🔄 CACHE: Update participants (best-effort)
    final participantsJson = room['participants'] as String? ?? '[]';
    final participants = List<String>.from(jsonDecode(participantsJson));

    if (!participants.contains(userId)) {
      participants.add(userId);
      await _db.database.then((db) => db.update(
            'chat_rooms',
            {'participants': jsonEncode(participants)},
            where: 'id = ?',
            whereArgs: [roomId],
          ));
    }
  }

  /// Removes participant from room
  /// Updates participants cache and creates LEAVE_ROOM event
  Future<void> removeParticipant(String roomId, String userId) async {
    // 🔥 TRUTH: Create LEAVE_ROOM event
    await _saveRoomEvent(RoomEvent.leaveRoom(
      roomId: roomId,
      userId: userId,
      origin: EventOrigin.LOCAL, // 📊 Created locally
    ));

    // 🔄 CACHE: Update participants (best-effort)
    final room = await getRoom(roomId);
    if (room != null) {
      final participantsJson = room['participants'] as String? ?? '[]';
      final participants = List<String>.from(jsonDecode(participantsJson));

      if (participants.contains(userId)) {
        participants.remove(userId);
        await _db.database.then((db) => db.update(
              'chat_rooms',
              {'participants': jsonEncode(participants)},
              where: 'id = ?',
              whereArgs: [roomId],
            ));
      }
    }
  }

  /// Rebuilds participants from events (truth)
  Future<List<String>> rebuildParticipants(String roomId) async {
    final events = await getRoomEvents(roomId);
    return RoomParticipantsRebuilder.rebuildFromEvents(events);
  }

  /// Saves room event
  Future<void> _saveRoomEvent(RoomEvent event) async {
    await _db.saveRoomEvent(event);
  }

  /// Gets all room events
  Future<List<RoomEvent>> getRoomEvents(String roomId) async {
    return await _db.getRoomEvents(roomId);
  }

  /// Creates MESSAGE event for room
  Future<void> recordMessageEvent(
      String roomId, String userId, String messageId,
      {EventOrigin origin = EventOrigin.LOCAL}) async {
    await _saveRoomEvent(RoomEvent.message(
      roomId: roomId,
      userId: userId,
      messageId: messageId,
      origin: origin, // 📊 Specify event source
    ));
  }

  /// Saves event from mesh network
  Future<bool> saveEventFromMesh(RoomEvent event) async {
    // Set origin = MESH for diagnostics
    final meshEvent = RoomEvent(
      id: event.id,
      roomId: event.roomId,
      type: event.type,
      userId: event.userId,
      timestamp: event.timestamp,
      payload: event.payload,
      origin: EventOrigin.MESH, // 📊 Event came via mesh
    );
    return await _db.saveRoomEvent(meshEvent);
  }

  /// Saves event from server
  Future<bool> saveEventFromServer(RoomEvent event) async {
    // Set origin = SERVER for diagnostics
    final serverEvent = RoomEvent(
      id: event.id,
      roomId: event.roomId,
      type: event.type,
      userId: event.userId,
      timestamp: event.timestamp,
      payload: event.payload,
      origin: EventOrigin.SERVER, // 📊 Event came from server
    );
    return await _db.saveRoomEvent(serverEvent);
  }
}
