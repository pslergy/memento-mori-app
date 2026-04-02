// lib/core/transport_decision_engine.dart
//
// Real-Time Transport Selection Engine (RTSE).
//
// Dynamically decides WHICH transport to use, WHEN to switch, WHEN to avoid.
// BLE remains DEFAULT FALLBACK at all times.
//
// Uses ONLY existing data: ConnectionPhaseController, NetworkPhaseContext,
// PeerCacheService, MeshNetworkState, RSSI (read-only). No BLE scan changes.
//
// Design: Stability > Speed, Predictability > Reactivity, Avoid chaos > Max throughput.

import 'locator.dart';
import 'mesh_network_state.dart';
import 'network_phase.dart';
import 'network_phase_context.dart';
import 'peer_cache_service.dart';

/// Selected transport for a send attempt.
enum SelectedTransport {
  ble,
  wifiDirect,
  sonar,
}

/// Input context for transport decision.
class TransportDecisionContext {
  final int messageSizeBytes;
  final String? peerId;
  final bool isEmergency;
  final int? rssi; // From existing scan/discovery, read-only

  const TransportDecisionContext({
    required this.messageSizeBytes,
    this.peerId,
    this.isEmergency = false,
    this.rssi,
  });
}

/// Per-transport score components (for weighted decision).
class TransportScore {
  final double latency; // Lower = better
  final double bandwidth; // Higher = better
  final double stability; // 0-1, higher = more stable
  final double setupCost; // Lower = better

  const TransportScore({
    this.latency = 0,
    this.bandwidth = 0,
    this.stability = 1,
    this.setupCost = 0,
  });

  /// Composite score (higher = better). Weights tuned for stability.
  double get composite =>
      bandwidth * 0.2 + (1 - latency / 100) * 0.2 + stability * 0.5 - setupCost * 0.1;
}

/// Per-transport metrics (from PeerCache, read-only).
class TransportMetrics {
  final double successRate;
  final int failureCount;
  final Duration avgTransferTime;

  const TransportMetrics({
    this.successRate = 0.5,
    this.failureCount = 0,
    this.avgTransferTime = const Duration(seconds: 5),
  });
}

/// Lightweight failure tracking (does not modify BLE/PeerCache).
class _TransportFailureTracker {
  final Map<String, int> _wifiFailuresByPeer = {};
  final Map<String, DateTime> _wifiLastFailure = {};
  DateTime? _lastWifiFailureGlobal;
  static const int _maxFailuresTracked = 20;

  void recordWifiFailure(String? peerId) {
    _lastWifiFailureGlobal = DateTime.now();
    if (peerId != null) {
      _wifiFailuresByPeer[peerId] = (_wifiFailuresByPeer[peerId] ?? 0) + 1;
      _wifiLastFailure[peerId] = DateTime.now();
      if (_wifiFailuresByPeer.length > _maxFailuresTracked) {
        final oldest = _wifiLastFailure.entries
            .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
        _wifiFailuresByPeer.remove(oldest.key);
        _wifiLastFailure.remove(oldest.key);
      }
    }
  }

  int wifiFailureCount(String? peerId) => peerId != null
      ? (_wifiFailuresByPeer[peerId] ?? 0)
      : 0;

  bool isWifiInCooldown(Duration cooldown) {
    final last = _lastWifiFailureGlobal;
    if (last == null) return false;
    return DateTime.now().difference(last) < cooldown;
  }
}

/// Real-Time Transport Selection Engine.
class TransportDecisionEngine {
  static final TransportDecisionEngine _instance =
      TransportDecisionEngine._internal();
  factory TransportDecisionEngine() => _instance;
  TransportDecisionEngine._internal();

  final _failureTracker = _TransportFailureTracker();

  // --- Anti-chaos constants ---
  static const int _smallThresholdBytes = 512;
  static const int _largeThresholdBytes = 4096;
  static const Duration _stickinessSec = Duration(seconds: 15);
  static const Duration _wifiCooldownAfterFailure = Duration(seconds: 30);
  static const double _hysteresisThreshold = 0.15; // Min score diff to switch

  SelectedTransport? _lastSelectedTransport;
  DateTime? _lastSelectionTime;

  /// Record Wi-Fi failure (call from integration when Wi-Fi send fails).
  void recordWifiFailure(String? peerId) {
    _failureTracker.recordWifiFailure(peerId);
  }

  /// Select transport for given context.
  /// Returns preference; caller MUST fall back to BLE if chosen transport unavailable.
  SelectedTransport selectTransport(TransportDecisionContext ctx) {
    final state = MeshNetworkState();
    final phaseCtx = locator.isRegistered<NetworkPhaseContext>()
        ? locator<NetworkPhaseContext>()
        : null;

    // --- LOCKING: Do NOT switch if BLE or Wi-Fi transfer active ---
    if (state.isBleActive) {
      return SelectedTransport.ble;
    }
    if (state.isWifiActive) {
      return SelectedTransport.wifiDirect;
    }

    // --- Phase guard: Do NOT start Wi-Fi in localTransfer ---
    if (phaseCtx != null &&
        phaseCtx.phase == NetworkPhase.localTransfer) {
      return SelectedTransport.ble;
    }

    // --- Emergency / tiny: Sonar as additive (not replacement) ---
    if (ctx.isEmergency || ctx.messageSizeBytes < 64) {
      // Sonar is fallback/additive; primary still BLE or Wi-Fi
      // Don't return sonar as primary for normal flow
    }

    // --- Score each transport ---
    final bleScore = _scoreBle(ctx, state);
    final wifiScore = _scoreWifi(ctx, state);
    final sonarScore = _scoreSonar(ctx);

    // --- Stickiness: Don't switch for X seconds ---
    if (_lastSelectedTransport != null && _lastSelectionTime != null) {
      final elapsed = DateTime.now().difference(_lastSelectionTime!);
      if (elapsed < _stickinessSec) {
        final stickScore = _lastSelectedTransport == SelectedTransport.ble
            ? bleScore
            : (_lastSelectedTransport == SelectedTransport.wifiDirect
                ? wifiScore
                : sonarScore);
        final nextBest = _bestOf(bleScore, wifiScore, sonarScore);
        if ((nextBest - stickScore).abs() < _hysteresisThreshold) {
          return _lastSelectedTransport!;
        }
      }
    }

    // --- Hysteresis: Switch only if score diff > threshold ---
    final best = _bestTransport(bleScore, wifiScore, sonarScore);
    final bestScore = best == SelectedTransport.ble
        ? bleScore
        : (best == SelectedTransport.wifiDirect ? wifiScore : sonarScore);
    final prevScore = _lastSelectedTransport == SelectedTransport.ble
        ? bleScore
        : (_lastSelectedTransport == SelectedTransport.wifiDirect
            ? wifiScore
            : sonarScore);
    if (_lastSelectedTransport != null &&
        best != _lastSelectedTransport! &&
        (bestScore - prevScore).abs() < _hysteresisThreshold) {
      return _lastSelectedTransport!;
    }

    _lastSelectedTransport = best;
    _lastSelectionTime = DateTime.now();
    return best;
  }

  double _scoreBle(TransportDecisionContext ctx, MeshNetworkState state) {
    // BLE: stable, low latency setup, low bandwidth
    double s = 0.7; // Base stability
    if (ctx.messageSizeBytes < _smallThresholdBytes) s += 0.2;
    if (ctx.messageSizeBytes > _largeThresholdBytes) s -= 0.1;
    return s.clamp(0.0, 1.0);
  }

  double _scoreWifi(TransportDecisionContext ctx, MeshNetworkState state) {
    // Wi-Fi: high throughput, setup cost, instability risk
    if (!state.allowsWifiOps) return 0.0;

    // Cooldown: block Wi-Fi after recent failure
    if (_failureTracker.isWifiInCooldown(_wifiCooldownAfterFailure)) {
      return 0.0;
    }

    double s = 0.0;
    if (ctx.messageSizeBytes > _largeThresholdBytes) s += 0.3;
    if (ctx.rssi != null && ctx.rssi! > -70) s += 0.2;
    if (ctx.rssi != null && ctx.rssi! > -85) s += 0.1;

    // Peer instability: penalize
    if (ctx.peerId != null) {
      final failures = _failureTracker.wifiFailureCount(ctx.peerId);
      if (failures > 2) s -= 0.3;
      if (failures > 0) s -= 0.1;
    }

    // PeerCache success rate (read-only)
    if (ctx.peerId != null && locator.isRegistered<PeerCacheService>()) {
      final metrics = locator<PeerCacheService>().getPeer(ctx.peerId!);
      if (metrics != null) {
        final wifiStats = metrics.channelStats['wifiDirect'];
        if (wifiStats != null && wifiStats.successRate < 0.5) s -= 0.2;
      }
    }

    return s.clamp(0.0, 1.0);
  }

  double _scoreSonar(TransportDecisionContext ctx) {
    // Sonar: extreme fallback, very low bandwidth
    if (ctx.isEmergency) return 0.5;
    if (ctx.messageSizeBytes < 64) return 0.4;
    return 0.1;
  }

  double _bestOf(double b, double w, double s) {
    if (b >= w && b >= s) return b;
    if (w >= b && w >= s) return w;
    return s;
  }

  SelectedTransport _bestTransport(double ble, double wifi, double sonar) {
    // BLE is default fallback: tie goes to BLE
    if (wifi > ble && wifi > sonar) return SelectedTransport.wifiDirect;
    if (sonar > ble && sonar > wifi && sonar > 0.4) return SelectedTransport.sonar;
    return SelectedTransport.ble;
  }

  /// Check if Wi-Fi should be attempted (availability + not blocked).
  bool shouldAttemptWifi(TransportDecisionContext ctx) {
    final state = MeshNetworkState();
    if (!state.allowsWifiOps) return false;
    if (_failureTracker.isWifiInCooldown(_wifiCooldownAfterFailure)) return false;
    final wifiScore = _scoreWifi(ctx, state);
    return wifiScore > 0.1;
  }

  /// Check if BLE should be attempted (always true unless explicitly blocked).
  bool shouldAttemptBle(TransportDecisionContext ctx) => true;

  /// Check if Sonar should be attempted (emergency or tiny).
  bool shouldAttemptSonar(TransportDecisionContext ctx) =>
      ctx.isEmergency || ctx.messageSizeBytes < 64;
}
