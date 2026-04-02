import 'dart:typed_data';

class ReversePathRegistry {
  // 100k записей: Uint32 (4 байта) + String ID (~20-30 байт)
  // Займет примерно 3-4 МБ RAM.
  static const int maxEntries = 100000;
  final Uint32List _hashes = Uint32List(maxEntries);
  final List<String> _nextHopIds = List.filled(maxEntries, '');
  final Int32List _timestamps = Int32List(maxEntries);

  int _cursor = 0;

  void savePath(String packetId, String fromNodeId) {
    int hash = packetId.hashCode;
    _hashes[_cursor] = hash;
    _nextHopIds[_cursor] = fromNodeId;
    _timestamps[_cursor] = DateTime.now().millisecondsSinceEpoch;

    _cursor = (_cursor + 1) % maxEntries;
  }

  String? findNextHop(String packetId) {
    int targetHash = packetId.hashCode;
    int now = DateTime.now().millisecondsSinceEpoch;
    int fiveMinutes = 5 * 60 * 1000;

    // Ищем с конца буфера (самые свежие)
    for (int i = 1; i <= maxEntries; i++) {
      int idx = (_cursor - i) % maxEntries;
      if (idx < 0) idx += maxEntries;

      if (_hashes[idx] == targetHash) {
        // Проверяем TTL (5 минут)
        if (now - _timestamps[idx] < fiveMinutes) {
          return _nextHopIds[idx];
        }
        break; // Запись устарела
      }
    }
    return null;
  }
}