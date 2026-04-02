import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Event protocol for rooms
/// Truth about room state is stored in events, not in participants
/// 
/// 🔥 CRITICAL: event_id (UUID) + (room_id, event_id) unique key
/// Protection against duplicates during mesh retransmission and bridge retransmission

/// Event source (for diagnostics only)
enum EventOrigin {
  LOCAL,   // Created locally on this device
  MESH,    // Received via mesh network
  SERVER,  // Received from server
}

/// Event-протокол для комнат
class RoomEvent {
  final String id; // UUID - unique event identifier
  final String roomId;
  final String type; // JOIN_ROOM, LEAVE_ROOM, MESSAGE, EDIT
  final String userId;
  final DateTime timestamp;
  final Map<String, dynamic>? payload;
  final EventOrigin origin; // 📊 For diagnostics only: where event came from
  
  static const _uuid = Uuid();

  RoomEvent({
    required this.id,
    required this.roomId,
    required this.type,
    required this.userId,
    required this.timestamp,
    this.payload,
    this.origin = EventOrigin.LOCAL, // Default: local
  });

  factory RoomEvent.fromJson(Map<String, dynamic> json) {
    EventOrigin origin = EventOrigin.LOCAL;
    if (json['origin'] != null) {
      final originStr = json['origin'] as String;
      origin = EventOrigin.values.firstWhere(
        (e) => e.name == originStr,
        orElse: () => EventOrigin.LOCAL,
      );
    }
    
    return RoomEvent(
      id: json['id'] as String,
      roomId: json['roomId'] as String,
      type: json['type'] as String,
      userId: json['userId'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      payload: json['payload'] != null 
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : null,
      origin: origin,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'roomId': roomId,
      'type': type,
      'userId': userId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'payload': payload,
      'origin': origin.name, // 📊 For diagnostics
    };
  }

  String serialize() => jsonEncode(toJson());

  factory RoomEvent.joinRoom({
    required String roomId,
    required String userId,
    DateTime? timestamp,
    String? eventId, // Optional for server synchronization
    EventOrigin origin = EventOrigin.LOCAL,
  }) {
    return RoomEvent(
      id: eventId ?? _uuid.v4(), // UUID for uniqueness
      roomId: roomId,
      type: 'JOIN_ROOM',
      userId: userId,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
    );
  }

  factory RoomEvent.leaveRoom({
    required String roomId,
    required String userId,
    DateTime? timestamp,
    String? eventId, // Optional for server synchronization
    EventOrigin origin = EventOrigin.LOCAL,
  }) {
    return RoomEvent(
      id: eventId ?? _uuid.v4(), // UUID for uniqueness
      roomId: roomId,
      type: 'LEAVE_ROOM',
      userId: userId,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
    );
  }

  factory RoomEvent.message({
    required String roomId,
    required String userId,
    required String messageId,
    DateTime? timestamp,
    String? eventId, // Optional for server synchronization
    EventOrigin origin = EventOrigin.LOCAL,
  }) {
    return RoomEvent(
      id: eventId ?? _uuid.v4(), // UUID for uniqueness
      roomId: roomId,
      type: 'MESSAGE',
      userId: userId,
      timestamp: timestamp ?? DateTime.now(),
      payload: {'messageId': messageId},
      origin: origin,
    );
  }

  factory RoomEvent.edit({
    required String roomId,
    required String userId,
    required String targetMessageId,
    required String newContent,
    DateTime? timestamp,
    String? eventId, // Optional for server synchronization
    EventOrigin origin = EventOrigin.LOCAL,
  }) {
    return RoomEvent(
      id: eventId ?? _uuid.v4(), // UUID for uniqueness
      roomId: roomId,
      type: 'EDIT',
      userId: userId,
      timestamp: timestamp ?? DateTime.now(),
      payload: {
        'targetMessageId': targetMessageId,
        'newContent': newContent,
      },
      origin: origin,
    );
  }
}

/// Rebuilds participant list from events
class RoomParticipantsRebuilder {
  /// Rebuilds participants from JOIN/LEAVE events
  static List<String> rebuildFromEvents(List<RoomEvent> events) {
    final Set<String> participants = {};
    
    // Sort events by time
    final sortedEvents = List<RoomEvent>.from(events)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    for (final event in sortedEvents) {
      if (event.type == 'JOIN_ROOM') {
        participants.add(event.userId);
      } else if (event.type == 'LEAVE_ROOM') {
        participants.remove(event.userId);
      }
    }
    
    return participants.toList()..sort();
  }
}
