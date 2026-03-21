/// Нормализация ID комнат (chatId / roomId) в ядре приложения.
///
/// Проблема: один телефон считает ID комнаты как GHOST_MAC1_MAC2,
/// другой — как MAC или BLE_shortMac; пакеты отфильтровываются (Screen Match Error).
/// Решение: единый канонический формат для построения и сравнения.
class RoomIdNormalizer {
  RoomIdNormalizer._();

  /// Специальные комнаты — не меняем.
  static const _globalIds = ['THE_BEACON_GLOBAL', 'GLOBAL', 'TRANSIT_ZONE', 'BEACON_NEARBY'];

  /// Чат «Кто рядом» — локальная mesh-комната без геолокации.
  static const String beaconNearbyId = 'BEACON_NEARBY';

  /// Приводит один "peer id" (MAC, BLE_xxx, hex) к каноническому виду,
  /// чтобы с разных устройств для одного и того же пира получалась одна строка.
  static String normalizePeerId(String id) {
    if (id.isEmpty) return id;
    String s = id.trim();
    if (s.startsWith('BLE_')) s = s.substring(4);
    s = s.toLowerCase();
    // Полный MAC (XX:XX:XX:XX:XX:XX) → берём последние 8 символов (short MAC),
    // чтобы BLE_D0:CF:CF и 52:54:70:D0:CF:CF давали один и тот же канонический id.
    if (s.contains(':') && s.length > 8) {
      final parts = s.split(':');
      if (parts.length >= 2) {
        final last = parts.sublist(parts.length - 2).join(':');
        if (last.length >= 5) s = last;
      }
    }
    return s;
  }

  /// Строит канонический ID комнаты для лички (DM) из двух peer id.
  /// Всегда формат GHOST_<part1>_<part2>, части отсортированы лексикографически.
  static String canonicalDmRoomId(String peerId1, String peerId2) {
    final a = normalizePeerId(peerId1);
    final b = normalizePeerId(peerId2);
    if (a.isEmpty && b.isEmpty) return 'GHOST_unknown_unknown';
    if (a.isEmpty) return 'GHOST_${b}_unknown';
    if (b.isEmpty) return 'GHOST_${a}_unknown';
    final list = [a, b]..sort();
    return 'GHOST_${list[0]}_${list[1]}';
  }

  /// Нормализует любой входящий chatId/roomId к каноническому виду для сравнения.
  /// Для лички (GHOST_*_*) пересобирает из двух частей; для глобальных — без изменений.
  static String normalizeRoomId(String? roomId) {
    if (roomId == null || roomId.isEmpty) return roomId ?? '';
    final s = roomId.trim();
    for (final g in _globalIds) {
      if (s.toUpperCase() == g.toUpperCase()) return g;
    }
    if (s.startsWith('THE_BEACON_') && s.length == 13) return s;
    if (!s.toUpperCase().startsWith('GHOST_')) {
      // Один id вместо GHOST_A_B — возвращаем нормализованный peer id.
      return normalizePeerId(s);
    }
    final parts = s.split('_');
    if (parts.length < 3) return s;
    // GHOST_<peer1>_<peer2> (peer1 может содержать _, напр. BLE_14:12:33)
    final p1 = normalizePeerId(parts.sublist(1, parts.length - 1).join('_'));
    final p2 = normalizePeerId(parts.last);
    final list = [p1, p2]..sort();
    return 'GHOST_${list[0]}_${list[1]}';
  }

  /// Проверяет, что packetChatId и screenChatId относятся к одной комнате.
  /// Использует нормализацию, чтобы GHOST_BLE_14:12:33_BLE_1A:CF:A5
  /// совпадал с GHOST_14:12:33_1A:CF:A5 и т.п.
  static bool roomIdsMatch(String? packetChatId, String? screenChatId) {
    if (packetChatId == null || screenChatId == null) return false;
    final p = packetChatId.trim();
    final s = screenChatId.trim();
    if (p.isEmpty || s.isEmpty) return false;
    for (final g in _globalIds) {
      if (p.toUpperCase() == g && s.toUpperCase() == g) return true;
    }
    if (p.startsWith('THE_BEACON_') && p.length == 13 && p == s) return true;
    final normPacket = normalizeRoomId(p);
    final normScreen = normalizeRoomId(s);
    return normPacket == normScreen;
  }
}
