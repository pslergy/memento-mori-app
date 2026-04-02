import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'models/uplink_candidate.dart';

/// Wi-Fi Direct Self-Healing + Anti-Chaos layer.
///
/// BLE IS NOT MODIFIED. All logic is isolated to Wi-Fi orchestration.
///
/// Features:
/// - Anti-chaos: split-brain prevention, ping-pong reconnect, network storm
/// - Self-healing GO election with recovery
/// - Predictive discovery (BLE RSSI → Wi-Fi triggers)
/// - Stability scoring for peers
enum WifiDirectState {
  idle,
  discovering,
  connecting,
  connected,
  goActive,
  recovery,
}

/// Per-peer connection history for anti-chaos
class _ConnectionHistoryEntry {
  final List<DateTime> attempts = [];
  DateTime? lastSuccess;
  DateTime? lastFailure;
  int consecutiveFailures = 0;

  void recordAttempt() {
    attempts.add(DateTime.now());
    _pruneOld();
  }

  void recordSuccess() {
    lastSuccess = DateTime.now();
    consecutiveFailures = 0;
  }

  void recordFailure() {
    lastFailure = DateTime.now();
    consecutiveFailures++;
  }

  void _pruneOld() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    attempts.removeWhere((t) => t.isBefore(cutoff));
  }

  bool get isPingPongCooldown {
    _pruneOld();
    if (attempts.length < 3) return false;
    final window = DateTime.now().subtract(const Duration(seconds: 60));
    final recent = attempts.where((t) => t.isAfter(window)).length;
    return recent >= 3;
  }

  Duration get exponentialBackoff {
    final base = const Duration(seconds: 15);
    final mult = math.pow(2, consecutiveFailures.clamp(0, 5)).toInt();
    return Duration(seconds: (base.inSeconds * mult).clamp(15, 120));
  }
}

/// Stability score for a peer (uptime + transfers - disconnects - failures)
class PeerStabilityScore {
  int uptimeSeconds = 0;
  int successfulTransfers = 0;
  int disconnects = 0;
  int failures = 0;

  int get score => uptimeSeconds + successfulTransfers - disconnects * 2 - failures * 3;
}

class WifiDirectSelfHealing {
  static final WifiDirectSelfHealing _instance = WifiDirectSelfHealing._internal();
  factory WifiDirectSelfHealing() => _instance;
  WifiDirectSelfHealing._internal();

  WifiDirectState _state = WifiDirectState.idle;
  WifiDirectState get state => _state;

  /// Had connection recently (for recovery trigger)
  bool _hadConnectionRecently = false;

  /// Anti-chaos: connection history per peer
  final Map<String, _ConnectionHistoryEntry> _connectionHistory = {};

  /// Anti-chaos: global rate limits
  final List<DateTime> _connectAttempts = [];
  final List<DateTime> _discoveryCycles = [];
  static const int maxConnectionsPerMinute = 4;
  static const int maxDiscoveryCyclesPerMinute = 3;

  /// GO creation cooldown after failure
  DateTime? _goCreateCooldownUntil;
  static const int goCreateCooldownSec = 45;

  /// Stability scores per peer
  final Map<String, PeerStabilityScore> _stabilityScores = {};

  /// Top 3 GO candidates (for multi-GO relay)
  List<UplinkCandidate> _goCandidates = [];
  static const int maxGoCandidates = 3;

  /// Max 1 active Wi-Fi connection
  String? _activeWifiPeerId;

  /// [STABILITY] Same-peer reconnect block: do not reconnect to peer within X sec of disconnect.
  final Map<String, DateTime> _lastDisconnectTimePerPeer = {};
  static const int _samePeerReconnectBlockSec = 10;

  void setState(WifiDirectState s) {
    _state = s;
  }

  void onConnected({required bool isHost, String? peerId}) {
    _state = isHost ? WifiDirectState.goActive : WifiDirectState.connected;
    _hadConnectionRecently = true;
    if (peerId != null) {
      _connectionHistory[peerId]?.recordSuccess();
      _stabilityScores.putIfAbsent(peerId, () => PeerStabilityScore());
      _stabilityScores[peerId]!.successfulTransfers++;
      _activeWifiPeerId = peerId;
    }
  }

  void onDisconnected({String? peerId}) {
    _state = WifiDirectState.idle;
    if (peerId != null) {
      // Record disconnect for stability score (not connection failure - that's onConnectionFailed)
      _stabilityScores.putIfAbsent(peerId, () => PeerStabilityScore());
      _stabilityScores[peerId]!.disconnects++;
      // [STABILITY] Block same-peer reconnect for X sec to prevent ping-pong
      _lastDisconnectTimePerPeer[peerId] = DateTime.now();
      _activeWifiPeerId = null;
    } else {
      _activeWifiPeerId = null;
    }
  }

  void onConnectionFailed({String? peerId}) {
    _state = WifiDirectState.idle;
    if (peerId != null) {
      _connectionHistory.putIfAbsent(peerId, () => _ConnectionHistoryEntry());
      _connectionHistory[peerId]!.recordFailure();
      _stabilityScores.putIfAbsent(peerId, () => PeerStabilityScore());
      _stabilityScores[peerId]!.failures++;
    }
  }

  void onGoCreateFailed() {
    _goCreateCooldownUntil = DateTime.now().add(const Duration(seconds: goCreateCooldownSec));
  }

  /// Recovery trigger: _isP2pConnected == false AND hadConnectionRecently
  bool get shouldEnterRecovery => !_hadConnectionRecently ? false : true;

  void clearHadConnectionRecently() {
    _hadConnectionRecently = false;
  }

  void markHadConnectionRecently() {
    _hadConnectionRecently = true;
  }

  /// Check if we can attempt connect (anti-chaos: ping-pong, rate limit)
  Future<({bool allowed, String? reason})> canAttemptConnect(String peerId) async {
    final now = DateTime.now();

    if (_activeWifiPeerId != null && _activeWifiPeerId != peerId) {
      return (allowed: false, reason: 'already_connected_to_other');
    }

    // [STABILITY] Same-peer reconnect block: prevent ping-pong within X sec
    final lastDisc = _lastDisconnectTimePerPeer[peerId];
    if (lastDisc != null) {
      final elapsed = now.difference(lastDisc);
      if (elapsed.inSeconds < _samePeerReconnectBlockSec) {
        return (allowed: false, reason: 'same_peer_reconnect_block_${_samePeerReconnectBlockSec - elapsed.inSeconds}s');
      }
    }

    final hist = _connectionHistory[peerId];
    if (hist != null && hist.isPingPongCooldown) {
      final backoff = hist.exponentialBackoff;
      return (allowed: false, reason: 'ping_pong_cooldown_${backoff.inSeconds}s');
    }

    _connectAttempts.removeWhere((t) => t.isBefore(now.subtract(const Duration(minutes: 1))));
    if (_connectAttempts.length >= maxConnectionsPerMinute) {
      return (allowed: false, reason: 'rate_limit_connections');
    }

    return (allowed: true, reason: null);
  }

  void recordConnectAttempt(String peerId) {
    _connectionHistory.putIfAbsent(peerId, () => _ConnectionHistoryEntry());
    _connectionHistory[peerId]!.recordAttempt();
    _connectAttempts.add(DateTime.now());
  }

  /// Check if we can start discovery (anti-chaos: rate limit)
  bool canStartDiscovery() {
    final now = DateTime.now();
    _discoveryCycles.removeWhere((t) => t.isBefore(now.subtract(const Duration(minutes: 1))));
    return _discoveryCycles.length < maxDiscoveryCyclesPerMinute;
  }

  void recordDiscoveryCycle() {
    _discoveryCycles.add(DateTime.now());
  }

  /// Jitter for connect attempts (0-3s)
  Duration getConnectJitter() {
    return Duration(milliseconds: math.Random().nextInt(3000));
  }

  /// Recovery: random delay 1-5s for re-election
  Duration getRecoveryJitter() {
    return Duration(seconds: 1 + math.Random().nextInt(4));
  }

  bool get isGoCreateCooldown =>
      _goCreateCooldownUntil != null && DateTime.now().isBefore(_goCreateCooldownUntil!);

  /// GO selection: best candidate from BLE RSSI, internet, battery, stability
  UplinkCandidate? selectBestGoCandidate({
    required List<UplinkCandidate> candidates,
    int? rssi,
    bool hasInternet = false,
  }) {
    if (candidates.isEmpty) return null;

    final scored = candidates.map((c) {
      var score = c.priority.toDouble();
      if (rssi != null) {
        if (rssi > -70) score += 50;
        else if (rssi > -85) score += 20;
      }
      if (hasInternet) score += 30;
      final stab = _stabilityScores[c.id]?.score ?? 0;
      score += stab * 0.1;
      return (candidate: c, score: score);
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.isNotEmpty ? scored.first.candidate : null;
  }

  void updateGoCandidates(List<UplinkCandidate> candidates) {
    _goCandidates = candidates.take(maxGoCandidates).toList();
  }

  UplinkCandidate? get bestGoCandidate => _goCandidates.isNotEmpty ? _goCandidates.first : null;

  int getStabilityScore(String peerId) =>
      _stabilityScores[peerId]?.score ?? 0;

  /// Unique groupId for multi-GO: hash(nodeId + timestamp)
  String computeGroupId(String nodeId) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final bytes = utf8.encode('$nodeId-$ts');
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  /// Predictive discovery: BLE RSSI → Wi-Fi trigger
  /// HIGH (>-70): immediate
  /// MEDIUM (-85 to -70): 3-5s delay
  /// LOW (<=-85): skip
  static ({bool shouldTrigger, Duration? delay}) evaluateRssiForWifi(int? rssi) {
    if (rssi == null) return (shouldTrigger: true, delay: null);
    if (rssi > -70) return (shouldTrigger: true, delay: Duration.zero);
    if (rssi > -85) return (shouldTrigger: true, delay: Duration(seconds: 3 + math.Random().nextInt(2)));
    return (shouldTrigger: false, delay: null);
  }
}
