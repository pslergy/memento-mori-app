// lib/core/mesh_network_state.dart
//
// Central observable state for the mesh network.
// READ-ONLY for most services — populated via explicit update calls.
//
// WHY: Single source of truth for network intelligence without global locks.
// Avoids chaos by making state observable, not mutable from many places.
//
// DO NOT: introduce global locks, break existing orchestration.

import 'connection_phase.dart';
import 'network_monitor.dart';
import 'network_phase.dart';

/// Snapshot of active peer info (minimal, for scoring/hints).
class ActivePeerInfo {
  final String peerId;
  final String transport; // 'BLE' | 'WIFI'
  final DateTime connectedAt;
  final int? rssi;

  const ActivePeerInfo({
    required this.peerId,
    required this.transport,
    required this.connectedAt,
    this.rssi,
  });
}

/// Transport usage counters (for intelligence, not for routing decisions).
class TransportUsage {
  final int bleConnections;
  final int wifiConnections;
  final int bleTransferCount;
  final int wifiTransferCount;

  const TransportUsage({
    this.bleConnections = 0,
    this.wifiConnections = 0,
    this.bleTransferCount = 0,
    this.wifiTransferCount = 0,
  });
}

/// Failure rates (rolling window, approximate).
class FailureRates {
  final double bleFailureRate;
  final double wifiFailureRate;
  final int bleRecentFailures;
  final int wifiRecentFailures;

  const FailureRates({
    this.bleFailureRate = 0.0,
    this.wifiFailureRate = 0.0,
    this.bleRecentFailures = 0,
    this.wifiRecentFailures = 0,
  });
}

/// Central mesh network state — observable, read-only for consumers.
///
/// Updated by MeshCoreEngine, WifiSelfHealingService, and integration points.
/// No circular dependencies: state flows one way.
class MeshNetworkState {
  static final MeshNetworkState _instance = MeshNetworkState._internal();
  factory MeshNetworkState() => _instance;
  MeshNetworkState._internal();

  final List<ActivePeerInfo> _activePeers = [];
  TransportUsage _transportUsage = const TransportUsage();
  FailureRates _failureRates = const FailureRates();
  ConnectionPhase _connectionPhase = ConnectionPhase.idle;
  NetworkPhase _networkPhase = NetworkPhase.boot;
  MeshRole _currentRole = MeshRole.GHOST;

  /// Active peers (copy to avoid external mutation).
  List<ActivePeerInfo> get activePeers => List.unmodifiable(_activePeers);

  TransportUsage get transportUsage => _transportUsage;

  FailureRates get failureRates => _failureRates;

  ConnectionPhase get connectionPhase => _connectionPhase;

  NetworkPhase get networkPhase => _networkPhase;

  MeshRole get currentRole => _currentRole;

  /// True when BLE or Wi-Fi transfer is active — do NOT start new Wi-Fi ops.
  bool get isTransferActive =>
      _connectionPhase == ConnectionPhase.transferring_ble ||
      _connectionPhase == ConnectionPhase.transferring_wifi;

  /// True when BLE is active — Wi-Fi must wait.
  bool get isBleActive =>
      _connectionPhase == ConnectionPhase.connecting_ble ||
      _connectionPhase == ConnectionPhase.transferring_ble;

  /// True when Wi-Fi is active.
  bool get isWifiActive =>
      _connectionPhase == ConnectionPhase.wifi_arbitration ||
      _connectionPhase == ConnectionPhase.wifi_pending_enable ||
      _connectionPhase == ConnectionPhase.connecting_wifi ||
      _connectionPhase == ConnectionPhase.transferring_wifi;

  /// True if Wi-Fi group create / connect is allowed by phase system.
  bool get allowsWifiOps =>
      _networkPhase != NetworkPhase.boot &&
      _networkPhase != NetworkPhase.localTransfer &&
      _networkPhase != NetworkPhase.localLinkSetup;

  // --- Update methods (called by integration points only) ---

  void updateConnectionPhase(ConnectionPhase phase) {
    _connectionPhase = phase;
  }

  void updateNetworkPhase(NetworkPhase phase) {
    _networkPhase = phase;
  }

  void updateCurrentRole(MeshRole role) {
    _currentRole = role;
  }

  void updateActivePeers(List<ActivePeerInfo> peers) {
    _activePeers.clear();
    _activePeers.addAll(peers);
  }

  void addActivePeer(ActivePeerInfo peer) {
    _activePeers.removeWhere((p) => p.peerId == peer.peerId);
    _activePeers.add(peer);
  }

  void removeActivePeer(String peerId) {
    _activePeers.removeWhere((p) => p.peerId == peerId);
  }

  void updateTransportUsage(TransportUsage usage) {
    _transportUsage = usage;
  }

  void updateFailureRates(FailureRates rates) {
    _failureRates = rates;
  }

  /// Check if a peer is currently connected via Wi-Fi.
  bool isPeerConnectedViaWifi(String peerId) {
    return _activePeers.any(
        (p) => p.peerId == peerId && p.transport.toUpperCase() == 'WIFI');
  }

  /// Count of active Wi-Fi connections (0 or 1 in current design).
  int get wifiConnectionCount =>
      _activePeers.where((p) => p.transport.toUpperCase() == 'WIFI').length;
}
