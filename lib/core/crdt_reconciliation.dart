// CRDT replicated log: causal sync strictly above transport.
//
// Operates only after OUTBOX phase completes. Does not start connections, modify
// cooldown/Mesh Health/encryption/framing, or block transport. Abort on disconnect;
// call resetSessionForPeer(peerAddress) so next session runs HEAD_EXCHANGE again.
//
// Protocol: HEAD_EXCHANGE → diff → REQUEST_RANGE → LOG_ENTRIES.
// Chain validation, fork detection, additive merge only. No history replacement.

import 'dart:convert';

import 'local_db_service.dart';
import 'locator.dart';

/// HEADS: per chat, author_id → highest_valid_sequence (main chain).
typedef HeadsMap = Map<String, Map<String, int>>;

/// Callback to send a payload to a peer (IP or BLE MAC). Uses existing encrypted channel.
typedef SendToPeer = Future<void> Function(String peerAddress, String payloadJson);

/// CRDT anti-entropy: causal sync, deterministic merge, no overwrites, no central authority.
class CrdtReconciliation {
  CrdtReconciliation({
    required SendToPeer sendToPeer,
    void Function(String message)? log,
    void Function(String peerAddress)? onDiffZero,
    void Function(String peerAddress)? onDiffNonZero,
  })  : _sendToPeer = sendToPeer,
        _log = log ?? ((String _msg) {}),
        _onDiffZero = onDiffZero,
        _onDiffNonZero = onDiffNonZero;

  final SendToPeer _sendToPeer;
  final void Function(String message) _log;
  final void Function(String peerAddress)? _onDiffZero;
  final void Function(String peerAddress)? _onDiffNonZero;

  final Set<String> _syncSentForPeer = {};

  void resetSessionForPeer(String peerAddress) {
    _syncSentForPeer.remove(peerAddress);
  }

  /// Build HEADS: chatId → (authorId → maxSeq).
  Future<HeadsMap> buildHeads() async {
    return locator<LocalDatabaseService>().getHeads();
  }

  /// Start CRDT_SYNC phase (once per session, after OUTBOX completes).
  Future<void> startDigestExchange(String peerAddress) async {
    if (_syncSentForPeer.contains(peerAddress)) {
      _log('[BEACON-SYNC] CRDT already sent for this peer this session — skip (next meeting will retry)');
      return;
    }
    _syncSentForPeer.add(peerAddress);
    try {
      final heads = await buildHeads();
      final beaconChats = heads.keys.where((k) => k == 'THE_BEACON_GLOBAL' || k == 'GLOBAL').toList();
      _log('[BEACON-SYNC] Starting chat sync with peer (HEADS for ${heads.length} chat(s), Beacon: $beaconChats)');
      final payload = {
        'type': 'HEAD_EXCHANGE',
        'heads': _headsToWire(heads),
      };
      await _sendToPeer(peerAddress, jsonEncode(payload));
      _log('[CRDT] Heads exchanged');
      _log('[BEACON-SYNC] HEAD_EXCHANGE sent — waiting for peer response (REQUEST_RANGE / LOG_ENTRIES)');
    } catch (e) {
      _syncSentForPeer.remove(peerAddress);
      _log('[CRDT] Head exchange send failed: $e');
      _log('[BEACON-SYNC] Chat sync failed: could not send HEADS ($e)');
    }
  }

  static Map<String, dynamic> _headsToWire(HeadsMap heads) {
    final m = <String, dynamic>{};
    for (final e in heads.entries) {
      m[e.key] = e.value;
    }
    return m;
  }

  static HeadsMap _wireToHeads(Map<String, dynamic>? wire) {
    if (wire == null) return {};
    final HeadsMap out = {};
    for (final e in wire.entries) {
      final chatId = e.key;
      final authors = e.value;
      if (authors is! Map<String, dynamic>) continue;
      final authorMap = <String, int>{};
      for (final a in authors.entries) {
        final v = a.value;
        final seq = v is int ? v : int.tryParse(v.toString());
        if (seq != null) authorMap[a.key.toString()] = seq;
      }
      if (authorMap.isNotEmpty) out[chatId] = authorMap;
    }
    return out;
  }

  /// On HEAD_EXCHANGE: diff, send our HEADS back. If diff=0, notify and skip REQUEST_RANGE/LOG_ENTRIES.
  Future<void> onHeadExchangeReceived(Map<String, dynamic> data, String peerAddress) async {
    final peerHeads = _wireToHeads(data['heads'] as Map<String, dynamic>?);
    final db = locator<LocalDatabaseService>();
    final localHeads = await db.getHeads();

    bool hasRequest = false;
    bool hasSend = false;
    for (final chatEntry in peerHeads.entries) {
      final peerAuthors = chatEntry.value;
      final localAuthors = localHeads[chatEntry.key] ?? {};
      for (final authorEntry in peerAuthors.entries) {
        final peerSeq = authorEntry.value;
        final localSeq = localAuthors[authorEntry.key] ?? 0;
        if (peerSeq > localSeq) hasRequest = true;
      }
      for (final authorEntry in localAuthors.entries) {
        final localSeq = authorEntry.value;
        final peerSeq = peerAuthors[authorEntry.key] ?? 0;
        if (localSeq > peerSeq && peerSeq >= 0) hasSend = true;
      }
    }

    try {
      await _sendToPeer(peerAddress, jsonEncode({
        'type': 'HEAD_EXCHANGE',
        'heads': _headsToWire(localHeads),
      }));
    } catch (_) {}

    if (!hasRequest && !hasSend) {
      _log('[CRDT] Diff=0 — no exchange needed');
      _log('[BEACON-SYNC] Chat already in sync with peer (no missing ranges either side)');
      _onDiffZero?.call(peerAddress);
      return;
    }
    _log('[BEACON-SYNC] Diff found: will request missing from peer and/or send our missing');
    _onDiffNonZero?.call(peerAddress);

    for (final chatEntry in peerHeads.entries) {
      final chatId = chatEntry.key;
      final peerAuthors = chatEntry.value;
      final localAuthors = localHeads[chatId] ?? {};

      for (final authorEntry in peerAuthors.entries) {
        final authorId = authorEntry.key;
        final peerSeq = authorEntry.value;
        final localSeq = localAuthors[authorId] ?? 0;
        if (peerSeq > localSeq) {
          final fromSeq = localSeq + 1;
          await _sendToPeer(peerAddress, jsonEncode({
            'type': 'REQUEST_RANGE',
            'chatId': chatId,
            'authorId': authorId,
            'fromSeq': fromSeq,
            'toSeq': peerSeq,
          }));
          _log('[CRDT] Missing range requested: author $authorId seq $fromSeq→$peerSeq');
          _log('[BEACON-SYNC] Requesting chatId=$chatId author=$authorId seq $fromSeq→$peerSeq');
        }
      }

      for (final authorEntry in localAuthors.entries) {
        final authorId = authorEntry.key;
        final localSeq = authorEntry.value;
        final peerSeq = peerAuthors[authorId] ?? 0;
        if (localSeq > peerSeq && peerSeq >= 0) {
          final fromSeq = peerSeq + 1;
          final toSeq = localSeq;
          final entries = await db.getLogEntriesByAuthorRange(chatId, authorId, fromSeq, toSeq);
          if (entries.isEmpty) {
            _log('[BEACON-SYNC] No local entries for chatId=$chatId author=$authorId $fromSeq→$toSeq (skip send)');
            continue;
          }
          final wireEntries = entries.map((r) => _rowToLogEntry(r)).toList();
          await _sendToPeer(peerAddress, jsonEncode({
            'type': 'LOG_ENTRIES',
            'chatId': chatId,
            'entries': wireEntries,
          }));
          _log('[CRDT] Log entries sent: ${wireEntries.length}');
          _log('[BEACON-SYNC] Sent ${wireEntries.length} message(s) for chatId=$chatId to peer');
        }
      }
    }
  }

  Map<String, dynamic> _rowToLogEntry(Map<String, dynamic> r) {
    return {
      'id': r['id'],
      'author_id': r['senderId'],
      'sequence_number': r['sequence_number'],
      'previous_hash': r['previous_hash'],
      'vector_clock': r['vectorClock'] is String ? r['vectorClock'] : jsonEncode(r['vectorClock']),
      'timestamp': r['createdAt'],
      'encrypted_payload': r['content'],
      'senderUsername': r['senderUsername'],
    };
  }

  /// On REQUEST_RANGE: send LOG_ENTRIES for (chatId, authorId, fromSeq..toSeq).
  Future<void> onRequestRangeReceived(Map<String, dynamic> data, String peerAddress) async {
    final chatId = data['chatId']?.toString();
    final authorId = data['authorId']?.toString();
    final fromSeq = data['fromSeq'] is int ? data['fromSeq'] as int : int.tryParse(data['fromSeq'].toString());
    final toSeq = data['toSeq'] is int ? data['toSeq'] as int : int.tryParse(data['toSeq'].toString());
    if (chatId == null || chatId.isEmpty || authorId == null || authorId.isEmpty || fromSeq == null || toSeq == null || fromSeq > toSeq) {
      _log('[BEACON-SYNC] REQUEST_RANGE ignored: invalid params chatId=$chatId authorId=$authorId from=$fromSeq to=$toSeq');
      return;
    }
    final db = locator<LocalDatabaseService>();
    final entries = await db.getLogEntriesByAuthorRange(chatId, authorId, fromSeq, toSeq);
    if (entries.isEmpty) {
      _log('[BEACON-SYNC] REQUEST_RANGE: no local entries for $chatId author=$authorId $fromSeq→$toSeq (peer may use different chatId)');
      return;
    }
    _log('[BEACON-SYNC] Sending ${entries.length} entries for $chatId to peer (requested $fromSeq→$toSeq)');
    final wireEntries = entries.map((r) => _rowToLogEntry(r)).toList();
    await _sendToPeer(peerAddress, jsonEncode({
      'type': 'LOG_ENTRIES',
      'chatId': chatId,
      'entries': wireEntries,
    }));
    _log('[CRDT] Log entries sent: ${wireEntries.length}');
  }

  /// On LOG_ENTRIES: validate chain (previous_hash continuity), insert idempotently, detect fork.
  Future<void> onLogEntriesReceived(Map<String, dynamic> data, String peerAddress) async {
    final chatId = data['chatId']?.toString();
    final list = data['entries'];
    if (chatId == null || chatId.isEmpty || list is! List) {
      _log('[BEACON-SYNC] LOG_ENTRIES ignored: no chatId or entries');
      return;
    }
    _log('[BEACON-SYNC] Received ${list.length} entries for chatId=$chatId — merging into local chat');
    final db = locator<LocalDatabaseService>();
    int inserted = 0;
    bool forkDetected = false;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id']?.toString() ?? item['h']?.toString() ?? '';
      final authorId = item['author_id']?.toString() ?? item['senderId']?.toString() ?? '';
      final seqRaw = item['sequence_number'];
      final seq = seqRaw is int ? seqRaw : int.tryParse(seqRaw?.toString() ?? '');
      final prevHash = item['previous_hash']?.toString() ?? '';
      final vcRaw = item['vector_clock'];
      Map<String, int> vc = {};
      if (vcRaw != null) {
        if (vcRaw is String) {
          try {
            vc = Map<String, int>.from(jsonDecode(vcRaw));
          } catch (_) {}
        } else if (vcRaw is Map) {
          vc = Map<String, int>.from(vcRaw);
        }
      }
      final tsRaw = item['timestamp'];
      final ts = tsRaw is int ? tsRaw : int.tryParse(tsRaw?.toString() ?? '0') ?? 0;
      final payload = item['encrypted_payload']?.toString() ?? item['content']?.toString() ?? '';
      final senderUsername = item['senderUsername']?.toString();
      if (id.isEmpty || authorId.isEmpty || seq == null) continue;
      final result = await db.saveLogEntryFromSync(
        chatId: chatId,
        authorId: authorId,
        sequenceNumber: seq,
        previousHash: prevHash,
        vectorClock: vc,
        timestamp: ts,
        encryptedPayload: payload,
        id: id,
        senderUsername: senderUsername,
      );
      if (result.inserted) inserted++;
      if (result.wasFork) forkDetected = true;
    }
    _log('[CRDT] Log entries received: ${list.length}');
    if (inserted > 0) {
      _log('[CRDT] Chain validated');
      _log('[BEACON-SYNC] Chat updated: $inserted new message(s) for $chatId');
    }
    if (forkDetected) _log('[CRDT] Fork detected');
    if (list.isNotEmpty && inserted == 0 && !forkDetected) {
      _log('[CRDT] Chain validation failed');
      _log('[BEACON-SYNC] No new messages merged (duplicates or chain broken for $chatId)');
    }
    _log('[CRDT] Sync complete');
    _log('[BEACON-SYNC] Sync phase done for chatId=$chatId');
  }
}
