// lib/core/wifi_self_healing_service.dart
//
// WifiSelfHealingService — self-healing Wi-Fi Direct layer.
//
// Responsibilities:
// - Detect Wi-Fi Direct failure: group dropped, TCP disconnect, GO gone.
// - Trigger recovery WITHOUT affecting BLE.
// - If GO dies → trigger re-election via GoElectionService.
// - Cooldowns: prevent rapid group recreation, ping-pong reconnect.
// - Respect ConnectionPhaseController.
// - Failure counters, exponential backoff.
//
// WHY: Transforms Wi-Fi from "unstable optional" to "self-healing high-bandwidth relay".
// BLE IS NOT MODIFIED.

import 'dart:async';

import 'locator.dart';
import 'mesh_network_state.dart';
import 'network_phase_context.dart';
import 'wifi_direct_self_healing.dart';

/// Failure type for backoff tuning.
enum WifiFailureType {
  groupDropped,
  tcpDisconnect,
  goGone,
  connectionFailed,
}

class WifiSelfHealingService {
  static final WifiSelfHealingService _instance =
      WifiSelfHealingService._internal();
  factory WifiSelfHealingService() => _instance;
  WifiSelfHealingService._internal();

  final WifiDirectSelfHealing _selfHealing = WifiDirectSelfHealing();

  /// Failure counters per type (for exponential backoff).
  final Map<WifiFailureType, int> _failureCounts = {};

  /// Last recovery attempt — prevent rapid retries.
  DateTime? _lastRecoveryAttemptAt;
  static const Duration _minRecoveryInterval = Duration(seconds: 20);

  /// Callback to trigger re-election / group create. Set by integration.
  void Function()? onRecoveryTrigger;

  /// Called when Wi-Fi group is dropped.
  void onGroupDropped() {
    _recordFailure(WifiFailureType.groupDropped);
    _selfHealing.onDisconnected(peerId: null);
    _maybeTriggerRecovery('group_dropped');
  }

  /// Called when TCP disconnect occurs.
  void onTcpDisconnect({String? peerId}) {
    _recordFailure(WifiFailureType.tcpDisconnect);
    _selfHealing.onDisconnected(peerId: peerId);
    _maybeTriggerRecovery('tcp_disconnect');
  }

  /// Called when GO device is gone (detected via discovery/state).
  void onGoGone() {
    _recordFailure(WifiFailureType.goGone);
    _selfHealing.clearHadConnectionRecently();
    _maybeTriggerRecovery('go_gone');
  }

  /// Called when connection attempt failed.
  void onConnectionFailed({String? peerId}) {
    _recordFailure(WifiFailureType.connectionFailed);
    _selfHealing.onConnectionFailed(peerId: peerId);
    // No immediate recovery — backoff handles retries.
  }

  /// Called when GO create failed.
  void onGoCreateFailed() {
    _selfHealing.onGoCreateFailed();
    _recordFailure(WifiFailureType.groupDropped);
  }

  /// Called when we had connection recently (for recovery trigger).
  void markHadConnectionRecently() {
    _selfHealing.markHadConnectionRecently();
  }

  /// Check if we should enter recovery (had connection, now lost).
  bool get shouldEnterRecovery => _selfHealing.shouldEnterRecovery;

  /// Exponential backoff delay based on failure count.
  Duration getRecoveryBackoff() {
    final totalFailures = _failureCounts.values.fold(0, (a, b) => a + b);
    final base = const Duration(seconds: 15);
    final mult = totalFailures.clamp(0, 5);
    final sec = (base.inSeconds * (1 << mult)).clamp(15, 120);
    return Duration(seconds: sec);
  }

  void _recordFailure(WifiFailureType type) {
    _failureCounts[type] = (_failureCounts[type] ?? 0) + 1;
  }

  void _maybeTriggerRecovery(String reason) {
    if (!_selfHealing.shouldEnterRecovery) return;

    final state = MeshNetworkState();
    if (state.isBleActive) return; // Do NOT disturb BLE.

    final phaseCtx = locator.isRegistered<NetworkPhaseContext>()
        ? locator<NetworkPhaseContext>()
        : null;
    if (phaseCtx != null && !phaseCtx.allowsWifiDirectGroupCreate) return;

    final now = DateTime.now();
    if (_lastRecoveryAttemptAt != null) {
      final elapsed = now.difference(_lastRecoveryAttemptAt!);
      if (elapsed < _minRecoveryInterval) return;
    }

    final backoff = getRecoveryBackoff();
    _lastRecoveryAttemptAt = now;

    // Schedule recovery with jitter.
    final jitter = _selfHealing.getRecoveryJitter();
    final delay = Duration(
      seconds: backoff.inSeconds + jitter.inSeconds,
    );

    Future.delayed(delay, () {
      _executeRecovery(reason);
    });
  }

  void _executeRecovery(String reason) {
    final state = MeshNetworkState();
    if (state.isBleActive) return;
    if (state.isWifiActive) return; // Already in Wi-Fi flow.

    if (_selfHealing.isGoCreateCooldown) return;

    _selfHealing.clearHadConnectionRecently();

    // Trigger re-election / group create via callback.
    final trigger = onRecoveryTrigger;
    if (trigger != null) {
      trigger();
    }
  }

  /// Reset failure counts (e.g. after successful connection).
  void resetFailureCounts() {
    _failureCounts.clear();
  }
}
