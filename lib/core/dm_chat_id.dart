import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'room_id_normalizer.dart';

/// Убирает префикс `GHOST_` и приводит id к виду, согласованному с [RoomIdNormalizer.normalizePeerId],
/// чтобы `canonicalDirectChatId` совпадал между устройствами при разных строковых представлениях одного пира.
String meshStableIdForDm(String id) {
  var s = id.trim();
  if (s.toUpperCase().startsWith('GHOST_')) {
    s = s.substring(6);
  }
  return RoomIdNormalizer.normalizePeerId(s);
}

/// Нормализация `dm_*` для сравнения и ключа (hex в нижнем регистре).
String normalizeDmChatId(String chatId) {
  final t = chatId.trim();
  if (t.length < 4) return t;
  if (!t.toLowerCase().startsWith('dm_')) return t;
  return 'dm_${t.substring(3).toLowerCase()}';
}

/// Входящий `dm_*` относится к личке с другом [peerUserId] при текущем [myUserId]
/// (несколько вариантов сырой строки / mesh-stable, как у отправителя и у нас в friends).
bool incomingDmMatchesMyChatWithPeer(
  String incomingDm,
  String myUserId,
  String peerUserId,
) {
  final d = normalizeDmChatId(incomingDm);
  if (!d.startsWith('dm_')) return false;
  void tryPair(String a, String b, Set<String> out) {
    if (a.isEmpty || b.isEmpty) return;
    try {
      out.add(normalizeDmChatId(canonicalDirectChatId(a, b)));
    } catch (_) {}
  }

  final candidates = <String>{};
  tryPair(myUserId, peerUserId, candidates);
  tryPair(meshStableIdForDm(myUserId), meshStableIdForDm(peerUserId), candidates);
  tryPair(myUserId, meshStableIdForDm(peerUserId), candidates);
  tryPair(meshStableIdForDm(myUserId), peerUserId, candidates);
  return candidates.contains(d);
}

/// Детерминированный id лички для пары user id (совпадает у обоих концов).
/// Тот же алгоритм, что [RoomService._createDirectRoomId] (sha256 от sorted pair, 16 hex).
String canonicalDirectChatId(String userIdA, String userIdB) {
  if (userIdA.isEmpty || userIdB.isEmpty) {
    throw ArgumentError('canonicalDirectChatId: empty user id');
  }
  final sorted = [userIdA, userIdB]..sort();
  final combined = '${sorted[0]}_${sorted[1]}';
  final hash = sha256.convert(utf8.encode(combined));
  return 'dm_${hash.toString().substring(0, 16)}';
}

/// Проверка: [chatId] соответствует паре (мой id, peer).
bool directChatIdMatchesPeer(String chatId, String myUserId, String peerUserId) {
  if (!chatId.startsWith('dm_')) return false;
  try {
    final c = canonicalDirectChatId(
      meshStableIdForDm(myUserId),
      meshStableIdForDm(peerUserId),
    );
    return normalizeDmChatId(chatId) == normalizeDmChatId(c);
  } catch (_) {
    return false;
  }
}

/// Один канонический `dm_*` для пары (я ↔ собеседник) — тот же алгоритм, что [RoomService._createDirectRoomId].
String canonicalDmForMeshPair(String myUserId, String peerUserId) {
  if (myUserId.isEmpty || peerUserId.isEmpty) {
    throw ArgumentError('canonicalDmForMeshPair: empty user id');
  }
  return canonicalDirectChatId(
    meshStableIdForDm(myUserId),
    meshStableIdForDm(peerUserId),
  );
}

/// Хранение и UI: личка всегда под одним id, даже если на wire другой `dm_*` для той же пары.
String dmStorageChatIdFromWireAndSender({
  required String wireChatId,
  required String senderId,
  required String myUserId,
}) {
  final w = wireChatId.trim();
  if (!w.toLowerCase().startsWith('dm_')) return w;
  if (myUserId.isEmpty || senderId.isEmpty) return normalizeDmChatId(w);
  final me = myUserId.trim();
  final sid = senderId.trim();
  if (sid == me) return normalizeDmChatId(w);
  return canonicalDmForMeshPair(me, sid);
}

/// Все нормализованные `dm_*` для пары участников — те же четыре комбинации, что в
/// [incomingDmMatchesMyChatWithPeer] (сырой id / mesh-stable).
Set<String> dmAllPairKeyChatIds(String userA, String userB) {
  final out = <String>{};
  void tryPair(String a, String b) {
    if (a.isEmpty || b.isEmpty) return;
    try {
      out.add(normalizeDmChatId(canonicalDirectChatId(a, b)));
    } catch (_) {}
  }

  final a1 = userA.trim();
  final b1 = userB.trim();
  if (a1.isEmpty || b1.isEmpty) return out;
  tryPair(a1, b1);
  tryPair(meshStableIdForDm(a1), meshStableIdForDm(b1));
  tryPair(a1, meshStableIdForDm(b1));
  tryPair(meshStableIdForDm(a1), b1);
  return out;
}

/// Сначала [wireChatId] (как в БД / на wire), затем остальные варианты пары без дублей.
List<String> dmOrderedDecryptCandidatesForPair({
  required String wireChatId,
  required String userA,
  required String userB,
}) {
  final wireNorm = normalizeDmChatId(wireChatId.trim());
  if (!wireNorm.startsWith('dm_')) return [wireChatId.trim()];
  final set = dmAllPairKeyChatIds(userA, userB);
  final ordered = <String>[];
  void add(String s) {
    final n = normalizeDmChatId(s);
    if (n.startsWith('dm_') && !ordered.contains(n)) ordered.add(n);
  }

  add(wireNorm);
  for (final c in set) {
    add(c);
  }
  return ordered;
}

/// Кандидаты ключа для расшифровки сообщения в личке: комната + все варианты пары (я ↔ отправитель).
/// Для исходящих ([messageSenderId] == [myUserId]) нужен [dmPeerWhenFromMe] из `chat_rooms.participants`.
List<String> dmDecryptChatIdsForMessage({
  required String roomChatId,
  required String myUserId,
  required String messageSenderId,
  String? dmPeerWhenFromMe,
}) {
  final room = roomChatId.trim();
  if (!room.toLowerCase().startsWith('dm_')) return [room];
  final me = myUserId.trim();
  final sid = messageSenderId.trim();
  if (me.isEmpty) return [normalizeDmChatId(room)];
  if (sid.isEmpty) return [normalizeDmChatId(room)];
  if (sid == me) {
    final peer = dmPeerWhenFromMe?.trim() ?? '';
    if (peer.isEmpty) return [normalizeDmChatId(room)];
    return dmOrderedDecryptCandidatesForPair(
      wireChatId: room,
      userA: me,
      userB: peer,
    );
  }
  return dmOrderedDecryptCandidatesForPair(
    wireChatId: room,
    userA: me,
    userB: sid,
  );
}

/// Порядок: сначала wire, затем все варианты пары (как у отправителя при другом представлении id).
List<String> dmDecryptChatIdCandidates({
  required String wireChatId,
  required String myUserId,
  required String senderId,
}) {
  return dmDecryptChatIdsForMessage(
    roomChatId: wireChatId,
    myUserId: myUserId,
    messageSenderId: senderId,
    dmPeerWhenFromMe: null,
  );
}

/// Все варианты `dm_*` для расшифровки: [messageSenderId] на wire + те же 4 комбинации пары для
/// [additionalPeerRepresentations], если они не сводятся к тому же [meshStableIdForDm], что и отправитель.
/// Нужно, когда в `chat_rooms` пир записан как короткий id, а в пакете — полный `GHOST_*` (или наоборот).
List<String> dmDecryptChatIdCandidatesMerged({
  required String wireChatId,
  required String myUserId,
  required String messageSenderId,
  Iterable<String>? additionalPeerRepresentations,
}) {
  final seen = <String>{};
  final out = <String>[];
  void addList(List<String> ids) {
    for (final id in ids) {
      final n = normalizeDmChatId(id);
      if (n.startsWith('dm_') && seen.add(n)) {
        out.add(n);
      }
    }
  }

  addList(dmDecryptChatIdCandidates(
    wireChatId: wireChatId,
    myUserId: myUserId,
    senderId: messageSenderId,
  ));
  if (additionalPeerRepresentations == null) return out;
  final senderStable = meshStableIdForDm(messageSenderId);
  for (final alt in additionalPeerRepresentations) {
    final a = alt.trim();
    if (a.isEmpty) continue;
    if (meshStableIdForDm(a) == senderStable) continue;
    addList(dmDecryptChatIdCandidates(
      wireChatId: wireChatId,
      myUserId: myUserId,
      senderId: a,
    ));
  }
  return out;
}
