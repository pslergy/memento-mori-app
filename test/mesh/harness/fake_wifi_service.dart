// Test harness — Fake Wi-Fi P2P service. Simulates P2P connection, TCP send.
// DO NOT import production mesh_core_engine. Isolated for testing.

import 'dart:async';

/// Minimal fake for Wi-Fi Direct / TCP transport simulation.
/// Simulates P2P connection, TCP send, direct IP messaging.
class FakeWifiService {
  final String nodeId;
  String? _connectedPeerIp;
  final Map<String, FakeWifiService> _ipToPeer = {};
  final List<Map<String, dynamic>> _receivedMessages = [];
  final StreamController<Map<String, dynamic>> _receiveController =
      StreamController<Map<String, dynamic>>.broadcast();

  FakeWifiService({required this.nodeId});

  Stream<Map<String, dynamic>> get receivedStream => _receiveController.stream;
  List<Map<String, dynamic>> get receivedMessages =>
      List.unmodifiable(_receivedMessages);
  String? get connectedPeerIp => _connectedPeerIp;
  bool get isConnected => _connectedPeerIp != null;

  String _myIp = '';

  /// Set this node's IP (for registration).
  void setMyIp(String ip) => _myIp = ip;
  String get myIp => _myIp;

  /// Register peer for IP-based messaging.
  void registerPeer(String ip, FakeWifiService peer) {
    _ipToPeer[ip] = peer;
  }

  /// Simulate P2P connection to peer. Call from harness: connectWifi(nodeA, nodeB).
  void connectTo(String peerIp, FakeWifiService peer) {
    _connectedPeerIp = peerIp;
    peer._connectedPeerIp = _myIp.isNotEmpty ? _myIp : '${nodeId}_ip';
  }

  /// Disconnect.
  void disconnect() {
    _connectedPeerIp = null;
  }

  /// Simulate TCP send.
  Future<void> sendTcp(String message, {String? host, int? port}) async {
    if (host == null) return;
    final peer = _ipToPeer[host];
    if (peer == null) return;
    peer._deliver({'from': nodeId, 'message': message, 'host': host});
  }

  void _deliver(Map<String, dynamic> msg) {
    _receivedMessages.add(msg);
    _receiveController.add(msg);
  }

  void dispose() {
    _receiveController.close();
  }
}
