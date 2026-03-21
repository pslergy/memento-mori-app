import 'models/uplink_candidate.dart';

/// DTN+ Contact-Aware Routing Service.
///
/// BLE IS NOT MODIFIED. All logic is additive — used for routing decisions only.
///
/// Features:
/// - Contact history per node (lastSeen, encounterCount, avgRSSI, successRate)
/// - Delivery probability score for relay selection
/// - Bridge scoring (internet, uptime, successRate)
/// - Time-based decay for old data
/// - Penalize unstable nodes
/// RSSI history for drift (movement prediction). Last N values.
const int kRssiHistorySize = 8;

class ContactHistoryEntry {
  DateTime lastSeen;
  int encounterCount;
  double avgRssi; // dBm, e.g. -70
  int successCount;
  int failureCount;
  int get totalTransfers => successCount + failureCount;
  double get successRate {
    final total = successCount + failureCount;
    return total == 0 ? 1.0 : successCount / total;
  }
  DateTime? firstSeenAt;
  int uptimeSeconds; // cumulative connected time

  /// [RSSI Drift] Last N RSSI values for drift (slope) computation.
  final List<int> rssiHistory = [];

  ContactHistoryEntry({
    required this.lastSeen,
    this.encounterCount = 1,
    this.avgRssi = -80,
    this.successCount = 0,
    this.failureCount = 0,
    this.firstSeenAt,
    this.uptimeSeconds = 0,
  });

  void recordEncounter({int? rssi}) {
    lastSeen = DateTime.now();
    encounterCount++;
    if (rssi != null) {
      avgRssi = (avgRssi * (encounterCount - 1) + rssi) / encounterCount;
      rssiHistory.add(rssi);
      if (rssiHistory.length > kRssiHistorySize) rssiHistory.removeAt(0);
    }
    firstSeenAt ??= lastSeen;
  }

  void recordSuccess() {
    successCount++;
    lastSeen = DateTime.now();
  }

  void recordFailure() {
    failureCount++;
    lastSeen = DateTime.now();
  }

  void addUptime(int seconds) {
    uptimeSeconds += seconds;
  }
}

/// Weights for deliveryScore (w1..w4)
class DtnWeights {
  static const double w1EncounterFrequency = 0.25;
  static const double w2SuccessRate = 0.35;
  static const double w3SignalStrength = 0.25;
  static const double w4Uptime = 0.15;
}

/// Decay: entries older than this are considered stale
const Duration _contactHistoryTtl = Duration(hours: 2);
const Duration _encounterWindow = Duration(minutes: 30);

class DtnContactService {
  static final DtnContactService _instance = DtnContactService._internal();
  factory DtnContactService() => _instance;
  DtnContactService._internal();

  final Map<String, ContactHistoryEntry> _contactHistory = {};
  final List<DateTime> _encounterTimestamps = [];

  /// Update on BLE discovery
  void onBleDiscovery(String nodeId, {int? rssi}) {
    final entry = _contactHistory.putIfAbsent(
      nodeId,
      () => ContactHistoryEntry(
        lastSeen: DateTime.now(),
        avgRssi: (rssi ?? -80).toDouble(),
      ),
    );
    entry.recordEncounter(rssi: rssi);
    _encounterTimestamps.add(DateTime.now());
    _pruneOld();
  }

  /// Update on Wi-Fi connection
  void onWifiConnected(String nodeId) {
    final entry = _contactHistory.putIfAbsent(
      nodeId,
      () => ContactHistoryEntry(lastSeen: DateTime.now()),
    );
    entry.recordEncounter();
    _pruneOld();
  }

  /// Update on successful message transfer
  void onTransferSuccess(String nodeId) {
    final entry = _contactHistory[nodeId];
    if (entry != null) {
      entry.recordSuccess();
    }
  }

  /// Update on failed transfer
  void onTransferFailure(String nodeId) {
    final entry = _contactHistory[nodeId];
    if (entry != null) {
      entry.recordFailure();
    }
  }

  /// Add uptime for a node (call when connection ends)
  void addUptime(String nodeId, int seconds) {
    final entry = _contactHistory[nodeId];
    if (entry != null) {
      entry.addUptime(seconds);
    }
  }

  void _pruneOld() {
    final cutoff = DateTime.now().subtract(_contactHistoryTtl);
    _contactHistory.removeWhere((_, e) => e.lastSeen.isBefore(cutoff));
    _encounterTimestamps.removeWhere((t) => t.isBefore(cutoff));
  }

  /// Encounter frequency (encounters per 30 min, normalized 0..1)
  double _encounterFrequency(String nodeId) {
    final entry = _contactHistory[nodeId];
    if (entry == null) return 0;
    final recent = entry.encounterCount; // simplified: use total, decay via age
    final ageSec = DateTime.now().difference(entry.lastSeen).inSeconds;
    if (ageSec > 1800) return 0; // stale
    final freq = recent / 10.0; // cap at 10 encounters = 1.0
    return freq.clamp(0.0, 1.0);
  }

  /// Delivery score for relay selection
  /// deliveryScore = w1*encounterFreq + w2*successRate + w3*signalStrength + w4*uptime
  double deliveryScore(String nodeId, {int? currentRssi}) {
    _pruneOld();
    final entry = _contactHistory[nodeId];
    if (entry == null) return 0.3; // unknown = low default

    final encFreq = _encounterFrequency(nodeId);
    final succRate = entry.successRate;
    final rssi = currentRssi ?? entry.avgRssi.round();
    // RSSI: -50=1, -70=0.7, -85=0.3, -100=0
    final signalStrength = ((rssi + 100) / 50).clamp(0.0, 1.0);
    final uptimeNorm = (entry.uptimeSeconds / 300).clamp(0.0, 1.0); // 5 min = 1

    var score = DtnWeights.w1EncounterFrequency * encFreq +
        DtnWeights.w2SuccessRate * succRate +
        DtnWeights.w3SignalStrength * signalStrength +
        DtnWeights.w4Uptime * uptimeNorm;

    // Penalize unstable (many failures)
    if (entry.totalTransfers >= 3 && entry.successRate < 0.5) {
      score *= 0.5;
    }
    return score.clamp(0.0, 1.0);
  }

  /// Bridge score: internet + uptime + successRate
  double bridgeScore(UplinkCandidate c, {bool hasInternet = false}) {
    final nodeId = c.id;
    final entry = _contactHistory[nodeId];
    var score = 0.5; // base
    if (hasInternet) score += 0.3;
    if (c.isBridge) score += 0.1;
    if (entry != null) {
      score += 0.2 * entry.successRate;
      score += 0.1 * (entry.uptimeSeconds / 300).clamp(0.0, 1.0);
      if (c.rssi != null && c.rssi! > -75) score += 0.1;
    }
    return score.clamp(0.0, 1.0);
  }

  /// Predictive GO/relay score (dynamic, with decay)
  double nodeScore(String nodeId,
      {int? rssi,
      double? batteryLevel,
      bool hasInternet = false,
      double? stabilityScore}) {
    _pruneOld();
    final entry = _contactHistory[nodeId];
    var score = deliveryScore(nodeId, currentRssi: rssi) * 0.4;
    if (hasInternet) score += 0.3;
    if (batteryLevel != null) score += 0.1 * batteryLevel;
    if (stabilityScore != null) score += 0.1 * (stabilityScore / 100);
    if (entry != null && entry.uptimeSeconds > 60) score += 0.1;
    // Decay: penalize old data
    if (entry != null) {
      final ageMin = DateTime.now().difference(entry.lastSeen).inMinutes;
      if (ageMin > 10) score *= 0.8;
      if (ageMin > 30) score *= 0.6;
    }
    return score.clamp(0.0, 1.0);
  }

  ContactHistoryEntry? getContact(String nodeId) => _contactHistory[nodeId];

  /// [RSSI Drift] Compute slope of RSSI over time (drift).
  /// Positive = signal improving (peer approaching), negative = leaving.
  double rssiDrift(String nodeId) {
    final entry = _contactHistory[nodeId];
    if (entry == null || entry.rssiHistory.length < 3) return 0;

    final n = entry.rssiHistory.length;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (var i = 0; i < n; i++) {
      final x = i.toDouble();
      final y = entry.rssiHistory[i].toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }
    final denom = n * sumX2 - sumX * sumX;
    if (denom.abs() < 1e-6) return 0;
    return (n * sumXY - sumX * sumY) / denom;
  }

  /// [RSSI Drift] Peer approaching (drift > threshold): delay send.
  static const double _driftThreshold = 0.5;
  bool isPeerApproaching(String nodeId) {
    return rssiDrift(nodeId) > _driftThreshold;
  }

  /// [RSSI Drift] Peer leaving (drift < -threshold): send immediately.
  bool isPeerLeaving(String nodeId) {
    return rssiDrift(nodeId) < -_driftThreshold;
  }

  /// Best relay target from candidates (by deliveryScore)
  String? selectBestRelayTarget(List<String> nodeIds, {Map<String, int>? rssiByNode}) {
    if (nodeIds.isEmpty) return null;
    String? best;
    double bestScore = 0;
    for (final id in nodeIds) {
      final s = deliveryScore(id, currentRssi: rssiByNode?[id]);
      if (s > bestScore) {
        bestScore = s;
        best = id;
      }
    }
    return best;
  }

  /// [DTN+] Adaptive TTL: dense network → lower TTL, sparse → higher
  /// Returns suggested TTL (default 5). Dense (4+ peers) → 3, sparse (0-1) → 7
  static int adaptiveTtl(int peerCount) {
    if (peerCount >= 4) return 3;
    if (peerCount >= 2) return 5;
    return 7; // sparse (forest scenario)
  }

  /// Best bridge from candidates (by bridgeScore: internet, uptime, successRate)
  UplinkCandidate? selectBestBridge(
    List<UplinkCandidate> candidates, {
    bool hasInternet = false,
  }) {
    if (candidates.isEmpty) return null;
    UplinkCandidate? best;
    double bestScore = 0;
    for (final c in candidates) {
      final s = bridgeScore(c, hasInternet: hasInternet);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    return best;
  }
}
