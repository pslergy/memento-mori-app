// lib/core/predictive_discovery_service.dart
//
// PredictiveDiscoveryService — BLE READ-ONLY consumer.
//
// IMPORTANT: MUST NOT change BLE scanning behavior.
// ONLY consumes existing RSSI + PeerCache data.
//
// Features:
// - Track lastSeen timestamps, RSSI trends.
// - Predict likely reconnect candidates.
// - Provide hints to Wi-Fi connection attempts.
//
// WHY: Helps Wi-Fi layer decide when/whom to connect without touching BLE.

import 'peer_cache_service.dart';

/// Hint for Wi-Fi connection attempt.
class WifiConnectionHint {
  final String peerId;
  final double priority;
  final String reason;

  const WifiConnectionHint({
    required this.peerId,
    required this.priority,
    required this.reason,
  });
}

/// RSSI trend (simple: improving, stable, degrading).
enum RssiTrend {
  improving,
  stable,
  degrading,
}

/// Per-peer predictive data (from PeerCache + optional RSSI).
class PredictivePeerData {
  final String peerId;
  final DateTime lastSeen;
  final double? successRate;
  final int? lastRssi;
  final RssiTrend? rssiTrend;

  const PredictivePeerData({
    required this.peerId,
    required this.lastSeen,
    this.successRate,
    this.lastRssi,
    this.rssiTrend,
  });
}

/// Predictive discovery — read-only consumer of PeerCache and RSSI.
class PredictiveDiscoveryService {
  static final PredictiveDiscoveryService _instance =
      PredictiveDiscoveryService._internal();
  factory PredictiveDiscoveryService() => _instance;
  PredictiveDiscoveryService._internal();

  final PeerCacheService _peerCache = PeerCacheService();

  /// Last RSSI per peer (updated by callers, NOT by BLE — we only consume).
  final Map<String, _RssiSample> _rssiSamples = {};
  static const int _maxRssiSamples = 5;

  /// Update RSSI for a peer (call from Wi-Fi/BLE integration when RSSI is observed).
  /// Does NOT touch BLE. Caller provides RSSI from existing scan result.
  void recordRssi(String peerId, int rssi) {
    final samples = _rssiSamples.putIfAbsent(peerId, () => _RssiSample());
    samples.add(rssi);
  }

  /// Get predicted reconnect candidates (for Wi-Fi hints).
  /// Uses PeerCache + RSSI history. Does NOT change any BLE behavior.
  List<WifiConnectionHint> getReconnectHints({
    required List<String> candidatePeerIds,
    int? minRssi = -90,
  }) {
    final hints = <WifiConnectionHint>[];

    for (final peerId in candidatePeerIds) {
      final metrics = _peerCache.getPeer(peerId);
      final samples = _rssiSamples[peerId];

      double priority = 0.5; // base
      String reason = 'unknown';

      if (metrics != null) {
        priority += metrics.successRate * 0.3;
        final age = DateTime.now().difference(metrics.lastSeen);
        if (age.inMinutes < 5) priority += 0.2;
        else if (age.inMinutes < 15) priority += 0.1;
        reason = 'cache_success=${metrics.successRate.toStringAsFixed(2)}';
      }

      if (samples != null && samples.latest != null) {
        final rssi = samples.latest!;
        if (rssi >= minRssi!) {
          if (rssi > -70) priority += 0.3;
          else if (rssi > -85) priority += 0.15;
          reason += ' rssi=$rssi';
        } else {
          priority -= 0.2; // too weak
        }
      }

      hints.add(WifiConnectionHint(
        peerId: peerId,
        priority: priority.clamp(0.0, 1.0),
        reason: reason,
      ));
    }

    hints.sort((a, b) => b.priority.compareTo(a.priority));
    return hints;
  }

  /// Get predictive data for a peer (for scoring).
  PredictivePeerData? getPredictiveData(String peerId) {
    final metrics = _peerCache.getPeer(peerId);
    final samples = _rssiSamples[peerId];

    RssiTrend? trend;
    if (samples != null && samples.hasTrend) {
      trend = samples.trend;
    }

    return PredictivePeerData(
      peerId: peerId,
      lastSeen: metrics?.lastSeen ?? DateTime.now(),
      successRate: metrics?.successRate,
      lastRssi: samples?.latest,
      rssiTrend: trend,
    );
  }

  /// Cleanup old RSSI samples (call periodically).
  void cleanup() {
    final now = DateTime.now();
    _rssiSamples.removeWhere((_, s) => s.isEmpty || s.age(now).inMinutes > 30);
  }
}

class _RssiSample {
  final List<int> _values = [];
  final List<DateTime> _times = [];

  void add(int rssi) {
    _values.add(rssi);
    _times.add(DateTime.now());
    if (_values.length > PredictiveDiscoveryService._maxRssiSamples) {
      _values.removeAt(0);
      _times.removeAt(0);
    }
  }

  int? get latest => _values.isEmpty ? null : _values.last;

  bool get isEmpty => _values.isEmpty;

  bool get hasTrend => _values.length >= 2;

  RssiTrend? get trend {
    if (!hasTrend) return null;
    final first = _values.first;
    final last = _values.last;
    if (last > first) return RssiTrend.improving;
    if (last < first) return RssiTrend.degrading;
    return RssiTrend.stable;
  }

  Duration age(DateTime now) {
    if (_times.isEmpty) return const Duration(hours: 1);
    return now.difference(_times.last);
  }
}
