import 'dart:convert';
import 'package:uuid/uuid.dart';

class MeshPacket {
  final String id;
  final String type; // 'REQ' (Request), 'RES' (Response)
  final Map<String, dynamic> payload;
  final String? senderIp; // IP отправителя для обратного ответа

  MeshPacket({
    required this.id,
    required this.type,
    required this.payload,
    this.senderIp,
  });

  // 🔥 ТОТ САМЫЙ МЕТОД: Превращает Map из JSON в объект MeshPacket
  factory MeshPacket.fromMap(Map<String, dynamic> map, {String? ip}) {
    return MeshPacket(
      id: map['id'] ?? map['h'] ?? const Uuid().v4(),
      type: map['type'] ?? 'REQ',
      // Берем payload, если он есть, иначе считаем всю мапу полезной нагрузкой
      payload: Map<String, dynamic>.from(map['payload'] ?? map),
      senderIp: ip,
    );
  }

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
        'karma': 0, // Карма отправителя (подтянется из профиля)
      },
    );
  }

  // Создать ответ (от Моста к Призраку)
  static MeshPacket createResponse(String requestId, int statusCode, dynamic body) {
    return MeshPacket(
      id: requestId,
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

  // Для обратной совместимости, если где-то используется старый метод
  factory MeshPacket.fromJson(String source) {
    final map = jsonDecode(source);
    return MeshPacket.fromMap(map);
  }
}

