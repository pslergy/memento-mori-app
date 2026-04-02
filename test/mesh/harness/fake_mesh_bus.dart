// Real engine stress test — in-memory transport bus.
// Routes BLE/Wi-Fi/Sonar between nodes. Supports multi-hop, topology, delivery callbacks.
// Test utilities only.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

/// Callback when a packet is delivered to a node. Return true to relay (for multi-hop).
typedef OnDeliver = Future<bool> Function(String fromId, String toId, dynamic payload);

/// In-memory bus for mesh transport simulation.
/// Captures sends, injects latency/failure, routes to endpoints.
/// Supports node map for delivery routing and broadcast sonar.
class FakeMeshBus {
  final math.Random _random;
  double _bleFailureRate = 0.0;
  double _wifiFailureRate = 0.0;
  double _nodeDeathRate = 0.0;
  int _bleLatencyMinMs = 20;
  int _bleLatencyMaxMs = 200;
  int _wifiLatencyMinMs = 5;
  int _wifiLatencyMaxMs = 50;
  int _sonarLatencyMinMs = 200;
  int _sonarLatencyMaxMs = 500;

  final List<BusEvent> _events = [];
  final Map<String, List<BusEvent>> _inboxByNode = {};
  final Map<String, OnDeliver> _deliveryHandlers = {};
  final Set<String> _deadNodes = {};
  final Map<String, Set<String>> _topology = {}; // nodeId -> Set of neighbor nodeIds

  /// IP -> nodeId mapping for Wi-Fi sendTcp(host: ip)
  final Map<String, String> _ipToNodeId = {};
  final Map<String, String> _nodeIdToIp = {};

  FakeMeshBus({int? seed}) : _random = math.Random(seed);

  List<BusEvent> get events => List.unmodifiable(_events);
  List<BusEvent> inboxFor(String nodeId) =>
      List.unmodifiable(_inboxByNode[nodeId] ?? []);

  void setBleFailureRate(double rate) => _bleFailureRate = rate.clamp(0.0, 1.0);
  void setWifiFailureRate(double rate) =>
      _wifiFailureRate = rate.clamp(0.0, 1.0);
  void setNodeDeathRate(double rate) => _nodeDeathRate = rate.clamp(0.0, 1.0);
  void setBleLatency(int minMs, int maxMs) {
    _bleLatencyMinMs = minMs;
    _bleLatencyMaxMs = maxMs;
  }
  void setWifiLatency(int minMs, int maxMs) {
    _wifiLatencyMinMs = minMs;
    _wifiLatencyMaxMs = maxMs;
  }
  void setSonarLatency(int minMs, int maxMs) {
    _sonarLatencyMinMs = minMs;
    _sonarLatencyMaxMs = maxMs;
  }

  /// Register a node. [ip] is used when sendTcp(host: ip) is called.
  void registerNode(String nodeId, {String? ip}) {
    _topology.putIfAbsent(nodeId, () => {});
    if (ip != null) {
      _ipToNodeId[ip] = nodeId;
      _nodeIdToIp[nodeId] = ip;
    }
  }

  /// Set connectivity: fromId can reach toId.
  void connect(String fromId, String toId) {
    _topology.putIfAbsent(fromId, () => {}).add(toId);
    _topology.putIfAbsent(toId, () => {}).add(fromId);
  }

  /// Set delivery handler for a node. Called when packet arrives. Return true to relay.
  void setDeliveryHandler(String nodeId, OnDeliver handler) {
    _deliveryHandlers[nodeId] = handler;
  }

  /// Mark node as dead (drops incoming packets).
  void killNode(String nodeId) => _deadNodes.add(nodeId);
  void reviveNode(String nodeId) => _deadNodes.remove(nodeId);
  bool isNodeDead(String nodeId) => _deadNodes.contains(nodeId);

  /// Resolve host (IP) to nodeId.
  String? resolveHostToNodeId(String host) => _ipToNodeId[host];

  /// Get neighbors for a node (for discovery simulation).
  Set<String> neighborsOf(String nodeId) =>
      Set.from(_topology[nodeId] ?? {});

  /// Simulate BLE send. Returns after latency; may throw on failure.
  Future<void> sendBle(String fromId, String toId, List<int> payload) async {
    if (_deadNodes.contains(fromId) || _deadNodes.contains(toId)) {
      _events.add(BusEvent.bleFail(fromId, toId));
      throw StateError('FakeMeshBus: Node dead');
    }
    if (_bleFailureRate > 0 && _random.nextDouble() < _bleFailureRate) {
      _events.add(BusEvent.bleFail(fromId, toId));
      throw StateError('FakeMeshBus: BLE send failed');
    }
    final latency = _bleLatencyMinMs +
        _random.nextInt((_bleLatencyMaxMs - _bleLatencyMinMs).clamp(1, 1000));
    await Future.delayed(Duration(milliseconds: latency));
    _events.add(BusEvent.bleSent(fromId, toId, payload.length));
    await _deliverToNode(fromId, toId, payload, isBle: true);
  }

  /// Simulate Wi-Fi/TCP send. [toId] can be nodeId; if [host] is provided, resolve host->nodeId.
  Future<void> sendWifi(String fromId, String toId, String message, {String? host}) async {
    final targetId = host != null ? (_ipToNodeId[host] ?? toId) : toId;
    if (_deadNodes.contains(fromId) || _deadNodes.contains(targetId)) {
      _events.add(BusEvent.wifiFail(fromId, targetId));
      throw StateError('FakeMeshBus: Node dead');
    }
    if (_wifiFailureRate > 0 && _random.nextDouble() < _wifiFailureRate) {
      _events.add(BusEvent.wifiFail(fromId, targetId));
      throw StateError('FakeMeshBus: Wi-Fi send failed');
    }
    final latency = _wifiLatencyMinMs +
        _random.nextInt((_wifiLatencyMaxMs - _wifiLatencyMinMs).clamp(1, 100));
    await Future.delayed(Duration(milliseconds: latency));
    _events.add(BusEvent.wifiSent(fromId, targetId, message.length));
    await _deliverToNode(fromId, targetId, message, isBle: false);
  }

  /// Simulate Sonar broadcast to nearby nodes.
  Future<void> broadcastSonar(String fromId, String payload) async {
    if (_deadNodes.contains(fromId)) return;
    final latency = _sonarLatencyMinMs +
        _random.nextInt((_sonarLatencyMaxMs - _sonarLatencyMinMs).clamp(1, 500));
    await Future.delayed(Duration(milliseconds: latency));
    _events.add(BusEvent.sonarSent(fromId, payload.length));
    final neighbors = neighborsOf(fromId);
    for (final toId in neighbors) {
      if (!_deadNodes.contains(toId)) {
        _inboxByNode.putIfAbsent(toId, () => []).add(
            BusEvent.sonarReceived(fromId, toId, payload));
      }
    }
  }

  Future<void> _deliverToNode(String fromId, String toId, dynamic payload, {required bool isBle}) async {
    if (_nodeDeathRate > 0 && _random.nextDouble() < _nodeDeathRate) return;
    _inboxByNode.putIfAbsent(toId, () => []);
    if (isBle) {
      final bytes = payload is List<int> ? payload : utf8.encode(payload.toString());
      _inboxByNode[toId]!.add(BusEvent.bleReceived(fromId, toId, bytes));
    } else {
      _inboxByNode[toId]!.add(BusEvent.wifiReceived(fromId, toId, payload is String ? payload : payload.toString()));
    }
    final handler = _deliveryHandlers[toId];
    if (handler != null) {
      try {
        final shouldRelay = await handler(fromId, toId, payload);
        if (shouldRelay && payload is String) {
          // Relay to neighbors (simplified: relay to all neighbors except sender)
          for (final nextId in neighborsOf(toId)) {
            if (nextId != fromId && !_deadNodes.contains(nextId)) {
              await sendWifi(toId, nextId, payload);
            }
          }
        }
      } catch (_) {}
    }
  }

  void clear() {
    _events.clear();
    _inboxByNode.clear();
    _deliveryHandlers.clear();
    _deadNodes.clear();
  }

  int get bleSentCount =>
      _events.where((e) => e.type == BusEventType.bleSent).length;
  int get bleFailCount =>
      _events.where((e) => e.type == BusEventType.bleFail).length;
  int get wifiSentCount =>
      _events.where((e) => e.type == BusEventType.wifiSent).length;
  int get wifiFailCount =>
      _events.where((e) => e.type == BusEventType.wifiFail).length;
}

enum BusEventType {
  bleSent,
  bleFail,
  bleReceived,
  wifiSent,
  wifiFail,
  wifiReceived,
  sonarSent,
  sonarReceived,
}

class BusEvent {
  final BusEventType type;
  final String from;
  final String to;
  final int size;

  BusEvent(this.type, this.from, this.to, this.size);

  factory BusEvent.bleSent(String from, String to, int size) =>
      BusEvent(BusEventType.bleSent, from, to, size);
  factory BusEvent.bleFail(String from, String to) =>
      BusEvent(BusEventType.bleFail, from, to, 0);
  factory BusEvent.bleReceived(String from, String to, List<int> payload) =>
      BusEvent(BusEventType.bleReceived, from, to, payload.length);
  factory BusEvent.wifiSent(String from, String to, int size) =>
      BusEvent(BusEventType.wifiSent, from, to, size);
  factory BusEvent.wifiFail(String from, String to) =>
      BusEvent(BusEventType.wifiFail, from, to, 0);
  factory BusEvent.wifiReceived(String from, String to, String message) =>
      BusEvent(BusEventType.wifiReceived, from, to, message.length);
  factory BusEvent.sonarSent(String from, int size) =>
      BusEvent(BusEventType.sonarSent, from, '', size);
  factory BusEvent.sonarReceived(String from, String to, String payload) =>
      BusEvent(BusEventType.sonarReceived, from, to, payload.length);
}
