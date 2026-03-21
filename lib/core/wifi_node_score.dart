// lib/core/wifi_node_score.dart
//
// WifiNodeScore — scoring for GO election and Wi-Fi connection priority.
//
// WHY: Multi-GO awareness (NOT full multi-GO). Prefer: higher battery,
// BRIDGE role, stable uptime. Used during GO election and candidate selection.
//
// Integrates with: GoElectionService, WifiDirectSelfHealing.PeerStabilityScore,
// PeerCacheService. Does NOT replace existing logic — extends it.

import 'dart:math' as math;

import 'wifi_direct_self_healing.dart';

/// Score components for a Wi-Fi node (GO candidate or connection target).
class WifiNodeScore {
  /// Uptime in seconds (how long peer has been stable).
  final int uptimeSeconds;

  /// Disconnect count (higher = less stable).
  final int disconnectCount;

  /// Battery level 0-100 (if known).
  final int? batteryLevel;

  /// Role weight: BRIDGE=100, CLIENT=50, GHOST=10.
  final int roleWeight;

  /// Success count from stability history.
  final int successCount;

  /// Failure count from stability history.
  final int failureCount;

  const WifiNodeScore({
    this.uptimeSeconds = 0,
    this.disconnectCount = 0,
    this.batteryLevel,
    this.roleWeight = 10,
    this.successCount = 0,
    this.failureCount = 0,
  });

  /// Compute composite score. Higher = better candidate.
  /// Formula: uptime*0.1 + roleWeight - disconnectCount*2 - failureCount*3 + batteryBonus.
  double get score {
    double s = uptimeSeconds * 0.1 + roleWeight - disconnectCount * 2 - failureCount * 3;
    if (batteryLevel != null) {
      if (batteryLevel! >= 80) s += 25;
      else if (batteryLevel! >= 50) s += 15;
      else if (batteryLevel! >= 20) s += 5;
      else s -= 10;
    }
    s += successCount * 0.5;
    return s.clamp(0.0, 200.0);
  }

  /// Build from PeerStabilityScore + role.
  factory WifiNodeScore.fromStability({
    required PeerStabilityScore stability,
    required String role,
    int? batteryLevel,
  }) {
    final roleWeight = role == 'BRIDGE' ? 100 : (role == 'CLIENT' ? 50 : 10);
    return WifiNodeScore(
      uptimeSeconds: stability.uptimeSeconds,
      disconnectCount: stability.disconnects,
      batteryLevel: batteryLevel,
      roleWeight: roleWeight,
      successCount: stability.successfulTransfers,
      failureCount: stability.failures,
    );
  }
}

/// Scorer for GO election — combines willingness, stability, role.
class WifiNodeScorer {
  /// Score a candidate for GO election.
  /// [stability] from WifiDirectSelfHealing.getStabilityScore / PeerStabilityScore.
  /// [role] BRIDGE | CLIENT | GHOST.
  /// [batteryLevel] 0-100 if known.
  static double scoreForGoElection({
    required int willingness,
    required int stabilityScore,
    required String role,
    int? batteryLevel,
  }) {
    double s = willingness.toDouble();
    s += stabilityScore * 0.1;
    if (role == 'BRIDGE') s += 30;
    else if (role == 'CLIENT') s += 10;
    if (batteryLevel != null && batteryLevel >= 50) s += 10;
    return s.clamp(0.0, 150.0);
  }

  /// Random jitter 1-3 seconds for createGroup/connect (anti-chaos).
  static Duration getCreateGroupJitter() {
    return Duration(seconds: 1 + math.Random().nextInt(2));
  }

  static Duration getConnectJitter() {
    return Duration(milliseconds: 1000 + math.Random().nextInt(2000));
  }
}
