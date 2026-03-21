// Test harness — Fake BLE service. Simulates device discovery, send/receive.
// DO NOT import production mesh_core_engine. Isolated for testing.

import 'dart:async';

/// Minimal fake for BLE transport simulation.
/// Simulates device discovery, send/receive, manual connection between nodes.
class FakeBluetoothService {
  final String nodeId;
  final Map<String, FakeBluetoothService> _connectedPeers = {};
  final List<Map<String, dynamic>> _receivedMessages = [];
  final StreamController<Map<String, dynamic>> _receiveController =
      StreamController<Map<String, dynamic>>.broadcast();

  FakeBluetoothService({required this.nodeId});

  Stream<Map<String, dynamic>> get receivedStream => _receiveController.stream;
  List<Map<String, dynamic>> get receivedMessages =>
      List.unmodifiable(_receivedMessages);

  /// Simulate discovered devices (for discovery flow tests).
  List<String> getDiscoveredDeviceIds() => _connectedPeers.keys.toList();

  /// Connect this node to another (simulates BLE pairing).
  void connectTo(FakeBluetoothService other) {
    _connectedPeers[other.nodeId] = other;
    other._connectedPeers[nodeId] = this;
  }

  /// Disconnect from peer.
  void disconnectFrom(FakeBluetoothService other) {
    _connectedPeers.remove(other.nodeId);
    other._connectedPeers.remove(nodeId);
  }

  /// Simulate sending a message over BLE. Delivers to connected peers.
  Future<void> sendMessage(String targetId, List<int> payload) async {
    final peer = _connectedPeers[targetId];
    if (peer == null) return;
    final map = {'from': nodeId, 'payload': payload};
    peer._deliver(map);
  }

  void _deliver(Map<String, dynamic> msg) {
    _receivedMessages.add(msg);
    _receiveController.add(msg);
  }

  /// Simulate discovery result — returns list of connected peer ids.
  List<String> discoverDevices() => _connectedPeers.keys.toList();

  void dispose() {
    _receiveController.close();
  }
}
