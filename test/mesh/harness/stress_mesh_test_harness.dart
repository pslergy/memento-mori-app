// Stress test harness — creates nodes with failure-injecting fakes.
// Extends MeshTestHarness behavior. Test utilities only.

import 'dart:math' as math;

import 'fake_database.dart';
import 'fake_router_service.dart';
import 'fake_ultrasonic_service.dart';
import 'stress_fake_bluetooth_service.dart';
import 'stress_fake_wifi_service.dart';
import 'virtual_node.dart';

/// Harness for mesh stress testing. Creates nodes with failure-injecting transports.
class StressMeshTestHarness {
  final Map<String, VirtualNode> _nodes = {};
  final List<StressFakeBluetoothService> _bleServices = [];
  final List<StressFakeWifiService> _wifiServices = [];
  final math.Random _random;

  StressMeshTestHarness({int? seed}) : _random = math.Random(seed);

  /// Create a virtual node with stress fakes.
  VirtualNode createNode(String id) {
    final ble = StressFakeBluetoothService(nodeId: id, random: _random);
    final wifi = StressFakeWifiService(nodeId: id, random: _random);
    wifi.setMyIp('192.168.49.${_nodes.length + 2}');
    final sonar = FakeUltrasonicService(nodeId: id);
    final router = FakeRouterService();
    final db = FakeDatabase();

    _bleServices.add(ble);
    _wifiServices.add(wifi);

    final node = VirtualNode(
      id: id,
      bleService: ble,
      wifiService: wifi,
      sonarService: sonar,
      routerService: router,
      database: db,
    );
    _nodes[id] = node;
    return node;
  }

  /// Connect two nodes via BLE.
  void connectBle(VirtualNode nodeA, VirtualNode nodeB) {
    nodeA.bleService.connectTo(nodeB.bleService);
  }

  /// Connect two nodes via Wi-Fi.
  void connectWifi(VirtualNode nodeA, VirtualNode nodeB) {
    final ipA = nodeA.wifiService.myIp;
    final ipB = nodeB.wifiService.myIp;
    nodeA.wifiService.registerPeer(ipB, nodeB.wifiService);
    nodeB.wifiService.registerPeer(ipA, nodeA.wifiService);
    nodeA.wifiService.connectTo(ipB, nodeB.wifiService);
  }

  /// Disconnect two nodes.
  void disconnect(VirtualNode nodeA, VirtualNode nodeB) {
    nodeA.bleService.disconnectFrom(nodeB.bleService);
    nodeA.wifiService.disconnect();
    nodeB.wifiService.disconnect();
  }

  /// Set BLE failure rate for a node (0.0–1.0).
  void setBleFailureRate(VirtualNode node, double rate) {
    (node.bleService as StressFakeBluetoothService).setFailureRate(rate);
  }

  /// Set Wi-Fi failure rate for a node (0.0–1.0).
  void setWifiFailureRate(VirtualNode node, double rate) {
    (node.wifiService as StressFakeWifiService).setFailureRate(rate);
  }

  /// Set Wi-Fi disconnected for all nodes (disconnect all).
  void disconnectAllWifi() {
    for (final n in _nodes.values) {
      n.wifiService.disconnect();
    }
  }

  /// Disable Wi-Fi for a node (simulate no Wi-Fi).
  void disableWifiFor(VirtualNode node) {
    node.wifiService.disconnect();
  }

  /// Simulate time advancement.
  Future<void> tick([Duration duration = Duration.zero]) async {
    await Future<void>.delayed(duration);
    await Future<void>.delayed(Duration.zero);
  }

  VirtualNode? getNode(String id) => _nodes[id];
  Iterable<VirtualNode> get nodes => _nodes.values;
  math.Random get random => _random;

  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
    _bleServices.clear();
    _wifiServices.clear();
  }
}
