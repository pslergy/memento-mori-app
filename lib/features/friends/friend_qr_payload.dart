import 'dart:convert';

/// Payload encoded in [AddFriendScreen] QR (`type: FRIEND_QR`).
class FriendQrPayload {
  FriendQrPayload({
    required this.userId,
    this.username,
    this.timestampMs,
  });

  final String userId;
  final String? username;
  final int? timestampMs;
}

/// Parses JSON from scanned QR. Returns null if not our format.
FriendQrPayload? parseFriendQrPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    final dynamic decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    if (map['type'] != 'FRIEND_QR') return null;
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;
    final username = map['username'];
    final ts = map['timestamp'];
    return FriendQrPayload(
      userId: id,
      username: username is String ? username : null,
      timestampMs: ts is int ? ts : (ts is num ? ts.toInt() : null),
    );
  } catch (_) {
    return null;
  }
}

/// Reject very old QR codes (optional replay / stale UI).
bool isFriendQrFresh(
  FriendQrPayload p, {
  Duration maxAge = const Duration(days: 7),
}) {
  final ts = p.timestampMs;
  if (ts == null) return true;
  final created = DateTime.fromMillisecondsSinceEpoch(ts);
  return DateTime.now().difference(created) <= maxAge;
}
