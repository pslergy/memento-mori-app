import 'dm_chat_id.dart';
import 'double_ratchet/dr_symmetric_engine.dart' show parseDmPeerId;

/// Нормализация id комнаты для истории DM: старый `dm_<hash>_<peer>` → [canonicalDirectChatId].
///
/// [GHOST_*] и прочие не‑DM id не меняются.
String migrateDmHistoryChatId({
  required String? storedChatId,
  required String myUserId,
  required String peerUserId,
}) {
  if (myUserId.isEmpty || peerUserId.isEmpty) {
    return storedChatId ?? '';
  }
  final canonical = canonicalDirectChatId(myUserId, peerUserId);
  if (storedChatId == null || storedChatId.isEmpty) return canonical;
  if (storedChatId == canonical) return storedChatId;
  if (storedChatId.startsWith('dm_')) {
    final p = parseDmPeerId(storedChatId);
    if (p == peerUserId) return canonical;
  }
  return storedChatId;
}
