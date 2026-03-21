// lib/core/wifi_arbitration_guard.dart
//
// WifiArbitrationGuard — prevents chaos: multiple GO creation, connection storms.
//
// WHY: Without guard, nearby nodes can all create groups simultaneously,
// causing split-brain and connection storms. Jitter + rules reduce collisions.
//
// Rules:
// - Do NOT create group if another GO detected recently.
// - Do NOT create group if RSSI indicates strong nearby peer (connect instead).
// - Add random jitter (1-3 sec) BEFORE createGroup and connect.
//
// BLE IS NOT MODIFIED. Only affects Wi-Fi orchestration.

import 'mesh_network_state.dart';
import 'wifi_direct_self_healing.dart';
import 'wifi_node_score.dart';

/// Result of arbitration check.
class WifiArbitrationResult {
  final bool allowed;
  final String? reason;

  const WifiArbitrationResult({required this.allowed, this.reason});
}

class WifiArbitrationGuard {
  static final WifiArbitrationGuard _instance = WifiArbitrationGuard._internal();
  factory WifiArbitrationGuard() => _instance;
  WifiArbitrationGuard._internal();

  /// Timestamp when we last detected another GO (from BLE scan / discovery).
  DateTime? _lastOtherGoDetectedAt;
  static const Duration _otherGoCooldown = Duration(seconds: 30);

  /// Max simultaneous Wi-Fi connect attempts (global).
  int _activeWifiAttempts = 0;
  static const int _maxSimultaneousWifiAttempts = 1;

  /// Check if we can create a Wi-Fi Direct group.
  /// WHY: Prevents multiple GO creation nearby.
  WifiArbitrationResult canCreateGroup({
    int? nearbyRssi,
    bool hasStrongNearbyPeer = false,
  }) {
    final state = MeshNetworkState();

    // Phase guard: do NOT create if BLE transfer active.
    if (state.isBleActive) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'ble_transfer_active',
      );
    }

    if (!state.allowsWifiOps) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'phase_disallows_wifi',
      );
    }

    // Another GO detected recently — wait to avoid split-brain.
    if (_lastOtherGoDetectedAt != null) {
      final elapsed = DateTime.now().difference(_lastOtherGoDetectedAt!);
      if (elapsed < _otherGoCooldown) {
        return WifiArbitrationResult(
          allowed: false,
          reason: 'other_go_recently_${_otherGoCooldown.inSeconds - elapsed.inSeconds}s',
        );
      }
    }

    // Strong nearby peer (RSSI > -70): prefer connecting, not creating.
    if (hasStrongNearbyPeer || (nearbyRssi != null && nearbyRssi > -70)) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'strong_nearby_peer_connect_instead',
      );
    }

    // Delegate to WifiDirectSelfHealing for GO create cooldown.
    if (WifiDirectSelfHealing().isGoCreateCooldown) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'go_create_cooldown',
      );
    }

    return const WifiArbitrationResult(allowed: true);
  }

  /// Check if we can attempt Wi-Fi connect to a peer.
  Future<WifiArbitrationResult> canAttemptConnect(String peerId) async {
    final state = MeshNetworkState();

    if (state.isBleActive) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'ble_transfer_active',
      );
    }

    if (!state.allowsWifiOps) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'phase_disallows_wifi',
      );
    }

    // Limit simultaneous attempts.
    if (_activeWifiAttempts >= _maxSimultaneousWifiAttempts) {
      return const WifiArbitrationResult(
        allowed: false,
        reason: 'max_simultaneous_wifi_attempts',
      );
    }

    // Delegate to WifiDirectSelfHealing for ping-pong, rate limit.
    final result = await WifiDirectSelfHealing().canAttemptConnect(peerId);
    if (!result.allowed) {
      return WifiArbitrationResult(
        allowed: false,
        reason: result.reason ?? 'self_healing_block',
      );
    }

    return const WifiArbitrationResult(allowed: true);
  }

  /// Record that another GO was detected (call from discovery).
  void recordOtherGoDetected() {
    _lastOtherGoDetectedAt = DateTime.now();
  }

  /// Call before starting a Wi-Fi connect attempt.
  void onConnectAttemptStarted() {
    _activeWifiAttempts++;
  }

  /// Call when Wi-Fi connect attempt finishes (success or failure).
  void onConnectAttemptFinished() {
    if (_activeWifiAttempts > 0) _activeWifiAttempts--;
  }

  /// Jitter before createGroup (1-3 sec). Reduces collision with other nodes.
  Duration getCreateGroupJitter() => WifiNodeScorer.getCreateGroupJitter();

  /// Jitter before connect (1-3 sec).
  Duration getConnectJitter() => WifiNodeScorer.getConnectJitter();
}
