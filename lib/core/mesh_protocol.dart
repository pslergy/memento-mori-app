// lib/core/mesh_protocol.dart
import 'dart:convert';
import 'package:uuid/uuid.dart';

enum MeshPacketType {
  PROXY_REQUEST,  // Призрак просит Мост выполнить запрос
  PROXY_RESPONSE, // Мост возвращает ответ Призраку
}

class MeshPacket {
  final String id;
  final String type; // 'REQ' or 'RES'
  final Map<String, dynamic> payload;

  MeshPacket({
    required this.id,
    required this.type,
    required this.payload,
  });

  // Создать запрос (от Призрака к Мосту)
  static MeshPacket createRequest(String method, String endpoint, Map<String, String> headers, dynamic body) {
    return MeshPacket(
      id: const Uuid().v4(),
      type: 'REQ',
      payload: {
        'method': method,
        'endpoint': endpoint,
        'headers': headers,
        'body': body,
      },
    );
  }

  // Создать ответ (от Моста к Призраку)
  static MeshPacket createResponse(String requestId, int statusCode, dynamic body) {
    return MeshPacket(
      id: requestId, // Используем ID запроса, чтобы связать их
      type: 'RES',
      payload: {
        'statusCode': statusCode,
        'body': body,
      },
    );
  }

  String serialize() => jsonEncode({
    'id': id,
    'type': type,
    'payload': payload,
  });

  factory MeshPacket.fromJson(String source) {
    final map = jsonDecode(source);
    return MeshPacket(
      id: map['id'],
      type: map['type'],
      payload: Map<String, dynamic>.from(map['payload']),
    );
  }
}