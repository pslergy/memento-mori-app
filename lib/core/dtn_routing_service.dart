// lib/core/dtn_routing_service.dart
//
// DTN Routing Layer — Spray-and-Wait, Entropy Control, RSSI Drift, Anti-Chaos.
//
// ⚠️ CRITICAL: BLE transport is NOT modified. All logic is additive and layered
// above existing system. Only controls WHICH messages are selected for sending.

import 'dart:math' as math;
import 'local_db_service.dart';
import 'dtn_contact_service.dart';
import 'discovery_context_service.dart';
import 'locator.dart';
import 'models/uplink_candidate.dart';

// ─── Spray-and-Wait ────────────────────────────────────────────────────────

/// Default spray count (L). 4–8 depending on density; use 6 as baseline.
const int kSprayCountDefault = 6;
const int kSprayCountSparse = 8;
const int kSprayCountDense = 4;

/// Wait phase: only send when peer deliveryScore > this threshold.
const double kWaitPhaseDeliveryScoreThreshold = 0.5;

// ─── Entropy ────────────────────────────────────────────────────────────────

/// Per-message stats for entropy-based epidemic control.
class MessageStats {
  int seenCount = 0;
  final Set<String> uniquePeersSeen = {};
  DateTime? lastRelayTime;

  /// entropyScore = uniquePeersSeen / totalPeersObserved (clamped 0..1)
  double entropyScore(int totalPeersObserved) {
    if (totalPeersObserved <= 0) return 0;
    return (uniquePeersSeen.length / totalPeersObserved).clamp(0.0, 1.0);
  }
}

// ─── Anti-Chaos ─────────────────────────────────────────────────────────────

/// Max relays per message per minute.
const int kMaxRelaysPerMessagePerMinute = 5;

/// Max active messages in flight.
const int kMaxActiveMessages = 20;

/// Ping-pong: do not resend to same peer within this window.
const Duration kPingPongCooldown = Duration(seconds: 30);

/// Top-K: only top K nodes relay same message (suppress others).
const int kTopKRelayers = 5;

// ─── Bridge Cluster ─────────────────────────────────────────────────────────

/// Top N bridges in cluster.
const int kBridgeClusterSize = 3;

// ─── Delivery Safety Layer ──────────────────────────────────────────────────

/// Age threshold: message considered STUCK if older than this (not delivered).
const Duration kStuckThreshold = Duration(seconds: 90);

/// When stuck: relax anti-chaos relay limit (emergency rate).
const int kStuckMaxRelaysPerMinute = 15;

/// DtnRoutingService — routing decision layer.
///
/// Integrates: Spray-and-Wait, Entropy, RSSI drift, Anti-Chaos, Bridge cluster.
/// Does NOT modify BLE. Only influences message selection and send scheduling.
class DtnRoutingService {
  static final DtnRoutingService _instance = DtnRoutingService._internal();
  factory DtnRoutingService() => _instance;
  DtnRoutingService._internal();

  LocalDatabaseService get _db => locator<LocalDatabaseService>();
  DtnContactService get _dtn => locator<DtnContactService>();
  DiscoveryContextService get _discovery => locator<DiscoveryContextService>();

  /// Per-message stats for entropy (in-memory, pruned periodically).
  final Map<String, MessageStats> _messageStats = {};

  /// Anti-chaos: relays per message per minute.
  final Map<String, List<DateTime>> _relaysPerMessage = {};

  /// Anti-chaos: last send to peer (messageId -> peerId -> timestamp).
  final Map<String, Map<String, DateTime>> _lastSendToPeer = {};

  /// Anti-chaos: relay rank per message (who relayed, for top-K).
  final Map<String, List<String>> _relayerRank = {};

  void onMessageSeen(String messageId, String peerId) {
    final stats = _messageStats.putIfAbsent(messageId, () => MessageStats());
    stats.seenCount++;
    stats.uniquePeersSeen.add(peerId);
    stats.lastRelayTime = DateTime.now();
    _pruneMessageStats();
  }

  void onMessageRelayed(String messageId, String peerId) {
    onMessageSeen(messageId, peerId);
    _relaysPerMessage.putIfAbsent(messageId, () => []);
    _relaysPerMessage[messageId]!.add(DateTime.now());
    _lastSendToPeer.putIfAbsent(messageId, () => {});
    _lastSendToPeer[messageId]![peerId] = DateTime.now();
    _relayerRank.putIfAbsent(messageId, () => []);
    if (!_relayerRank[messageId]!.contains(peerId)) {
      _relayerRank[messageId]!.add(peerId);
    }
    _pruneAntiChaos();
  }

  void _pruneMessageStats() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 2));
    _messageStats.removeWhere((_, s) =>
        s.lastRelayTime != null && s.lastRelayTime!.isBefore(cutoff));
    if (_messageStats.length > 500) {
      final keys = _messageStats.keys.toList()
        ..sort((a, b) =>
            (_messageStats[b]!.lastRelayTime ?? DateTime(0))
                .compareTo(_messageStats[a]!.lastRelayTime ?? DateTime(0)));
      for (var i = 500; i < keys.length; i++) {
        _messageStats.remove(keys[i]);
      }
    }
  }

  void _pruneAntiChaos() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 2));
    for (final key in _relaysPerMessage.keys.toList()) {
      _relaysPerMessage[key]!.removeWhere((t) => t.isBefore(cutoff));
      if (_relaysPerMessage[key]!.isEmpty) _relaysPerMessage.remove(key);
    }
  }

  /// [DTN-SAFETY] Stuck message detection: not delivered and age > threshold.
  bool isStuck(Map<String, dynamic> entry) {
    final createdAt = entry['createdAt'];
    if (createdAt == null) return false;
    final ms = createdAt is int ? createdAt : (createdAt is num ? createdAt.toInt() : null);
    if (ms == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ms;
    return age >= kStuckThreshold.inMilliseconds;
  }

  /// [DTN-SAFETY] Anti-chaos bypass when stuck: relaxed limits.
  bool canRelayByAntiChaosWhenStuck(String messageId, String peerId) {
    final relays = _relaysPerMessage[messageId];
    if (relays != null) {
      final window = DateTime.now().subtract(const Duration(minutes: 1));
      final recent = relays.where((t) => t.isAfter(window)).length;
      if (recent >= kStuckMaxRelaysPerMinute) return false;
    }
    return true;
  }

  /// Spray count L based on peer density.
  int sprayCountForDensity(int peerCount) {
    if (peerCount >= 4) return kSprayCountDense;
    if (peerCount <= 1) return kSprayCountSparse;
    return kSprayCountDefault;
  }

  /// Spray-and-Wait: should we send this message to this peer?
  /// Returns (shouldSend, newCopiesRemaining for our record).
  /// [DTN-SAFETY] When stuck: wait phase escape — allow send even if deliveryScore < 0.5.
  Future<({bool shouldSend, int? newCopiesRemaining})> sprayAndWaitDecision(
    Map<String, dynamic> outboxEntry,
    String peerId, {
    int? peerCount,
    Map<String, int>? rssiByNode,
    bool isStuckMessage = false,
  }) async {
    final messageId = outboxEntry['id'] as String?;
    if (messageId == null) return (shouldSend: false, newCopiesRemaining: null);

    int copiesRemaining = outboxEntry['copiesRemaining'] as int? ?? -1;
    final sprayCount = outboxEntry['sprayCount'] as int? ?? kSprayCountDefault;

    if (copiesRemaining < 0) {
      copiesRemaining = sprayCount;
    }

    if (copiesRemaining > 1) {
      // Spray phase: send to new peer, give half
      final give = copiesRemaining ~/ 2;
      if (give > 0) {
        final newOurs = copiesRemaining - give;
        return (shouldSend: true, newCopiesRemaining: newOurs);
      }
    }

    if (copiesRemaining == 1) {
      // Wait phase: only send if peer.deliveryScore > threshold
      // [DTN-SAFETY] Stuck escape: bypass deliveryScore requirement
      if (isStuckMessage) {
        return (shouldSend: true, newCopiesRemaining: 1);
      }
      final score = _dtn.deliveryScore(peerId, currentRssi: rssiByNode?[peerId]);
      if (score >= kWaitPhaseDeliveryScoreThreshold) {
        return (shouldSend: true, newCopiesRemaining: 1);
      }
      return (shouldSend: false, newCopiesRemaining: null);
    }

    return (shouldSend: false, newCopiesRemaining: null);
  }

  /// Entropy-based relay probability: baseRate * (1 - entropyScore)
  /// [DTN-SAFETY] When stuck: entropy bypass — return 1.0 (always relay).
  double relayProbability(String messageId, double baseRate,
      {int totalPeersObserved = 1, bool isStuckMessage = false}) {
    if (isStuckMessage) return 1.0;
    final stats = _messageStats[messageId];
    if (stats == null) return baseRate;
    final denom = math.max(1, totalPeersObserved);
    final entropy = stats.entropyScore(denom);
    return (baseRate * (1 - entropy)).clamp(0.05, 1.0);
  }

  /// Anti-chaos: can we relay this message?
  bool canRelayByAntiChaos(String messageId, String peerId) {
    final relays = _relaysPerMessage[messageId];
    if (relays != null) {
      final window = DateTime.now().subtract(const Duration(minutes: 1));
      final recent = relays.where((t) => t.isAfter(window)).length;
      if (recent >= kMaxRelaysPerMessagePerMinute) return false;
    }

    final lastSend = _lastSendToPeer[messageId]?[peerId];
    if (lastSend != null &&
        DateTime.now().difference(lastSend) < kPingPongCooldown) {
      return false;
    }

    final rank = _relayerRank[messageId];
    if (rank != null && rank.length >= kTopKRelayers && !rank.contains(peerId)) {
      return false;
    }

    return true;
  }

  /// Combined send decision: spray-and-wait + entropy + anti-chaos.
  /// [DTN-SAFETY] Stuck messages bypass ALL filters and are ALWAYS included.
  /// Returns filtered list of outbox entries to send to peer, with updated copiesRemaining.
  Future<List<Map<String, dynamic>>> selectMessagesForPeer(
    String peerId, {
    int? peerCount,
    Map<String, int>? rssiByNode,
    double baseRelayRate = 0.8,
    int maxMessages = 10,
  }) async {
    final pending = await _db.getPendingFromOutboxSmart();
    if (pending.isEmpty) return [];

    final peerCountVal = peerCount ?? 1;
    final selected = <Map<String, dynamic>>[];
    final selectedIds = <String>{};
    int count = 0;

    // [DTN-SAFETY] Phase 1: Force-include stuck messages (bypass spray/entropy; relaxed anti-chaos)
    for (final entry in pending) {
      if (count >= maxMessages) break;

      final messageId = entry['id'] as String?;
      if (messageId == null) continue;
      if (selectedIds.contains(messageId)) continue;

      if (!isStuck(entry)) continue;

      // Relaxed anti-chaos cap only (15/min vs 5/min) — prevents storm
      if (!canRelayByAntiChaosWhenStuck(messageId, peerId)) continue;

      final copy = Map<String, dynamic>.from(entry);
      copy['copiesRemaining'] = copy['copiesRemaining'] ?? 1;
      selected.add(copy);
      selectedIds.add(messageId);
      count++;
      print("[DTN-SAFETY] message $messageId marked as STUCK — forcing relay");
    }

    // Phase 2: Normal DTN filtering for non-stuck messages
    for (final entry in pending) {
      if (count >= maxMessages) break;

      final messageId = entry['id'] as String?;
      if (messageId == null) continue;
      if (selectedIds.contains(messageId)) continue;

      final stuck = isStuck(entry);

      // Anti-chaos: use relaxed limits when stuck
      if (stuck) {
        if (!canRelayByAntiChaosWhenStuck(messageId, peerId)) continue;
      } else {
        if (!canRelayByAntiChaos(messageId, peerId)) continue;
      }

      // Entropy: bypass when stuck (prob=1.0)
      final prob = relayProbability(messageId, baseRelayRate,
          totalPeersObserved: math.max(1, peerCountVal),
          isStuckMessage: stuck);
      if (math.Random().nextDouble() > prob) continue;

      final decision = await sprayAndWaitDecision(
        entry,
        peerId,
        peerCount: peerCountVal,
        rssiByNode: rssiByNode,
        isStuckMessage: stuck,
      );

      if (decision.shouldSend) {
        final copy = Map<String, dynamic>.from(entry);
        if (decision.newCopiesRemaining != null) {
          copy['copiesRemaining'] = decision.newCopiesRemaining;
        }
        selected.add(copy);
        selectedIds.add(messageId);
        count++;
      }
    }

    if (selected.isEmpty && pending.isNotEmpty) {
      print("[DTN-OBS] selectMessagesForPeer returned empty for peer=$peerId pending=${pending.length} (filtered by entropy/anti-chaos/spray/wait)");
    }
    return selected;
  }

  /// Get spray/wait metadata for new outbox entry (when adding).
  Map<String, dynamic> sprayMetadataForNewMessage(int peerCount) {
    final L = sprayCountForDensity(peerCount);
    return {'sprayCount': L, 'copiesRemaining': L};
  }

  /// Bridge cluster: top N bridges for load distribution.
  List<UplinkCandidate> getBridgeCluster({bool hasInternet = false}) {
    final bridges = _discovery.validBridges;
    if (bridges.isEmpty) return [];

    final dtn = _dtn;
    final scored = bridges.map((c) {
      final s = dtn.bridgeScore(c, hasInternet: hasInternet);
      return (candidate: c, score: s);
    }).toList();
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(kBridgeClusterSize).map((e) => e.candidate).toList();
  }

  /// Select bridge from cluster (round-robin or least-loaded).
  UplinkCandidate? selectBridgeFromCluster({bool hasInternet = false}) {
    final cluster = getBridgeCluster(hasInternet: hasInternet);
    return cluster.isNotEmpty ? cluster.first : null;
  }

  /// RSSI drift: should we delay send? (peer approaching = delay)
  /// Called from scheduler; DtnContactService provides drift.
  bool shouldDelaySendByDrift(String peerId) {
    return _dtn.isPeerApproaching(peerId);
  }

  /// RSSI drift: should we send immediately? (peer leaving)
  bool shouldSendImmediatelyByDrift(String peerId) {
    return _dtn.isPeerLeaving(peerId);
  }
}
