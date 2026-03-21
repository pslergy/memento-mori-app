// Test harness — MeshTestHarness orchestrates virtual nodes and connections.
// Simulates BLE/Wi-Fi connections, tick for time advancement.
// DO NOT modify production mesh_core_engine.

import 'dart:async';

import 'fake_bluetooth_service.dart';
import 'fake_database.dart';
import 'fake_router_service.dart';
import 'fake_ultrasonic_service.dart';
import 'fake_wifi_service.dart';
import 'virtual_node.dart';

/// Harness for mesh protocol testing. Creates nodes, connects them, simulates time.
class MeshTestHarness {
  final Map<String, VirtualNode> _nodes = {};
  final List<FakeBluetoothService> _bleServices = [];
  final List<FakeWifiService> _wifiServices = [];

  /// Create a virtual node with id.
  VirtualNode createNode(String id) {
    final ble = FakeBluetoothService(nodeId: id);
    final wifi = FakeWifiService(nodeId: id);
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

  /// Connect two nodes via BLE (simulated).
  void connectBle(VirtualNode nodeA, VirtualNode nodeB) {
    nodeA.bleService.connectTo(nodeB.bleService);
  }

  /// Connect two nodes via Wi-Fi (simulated).
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

  /// Simulate time advancement. Flush microtasks.
  Future<void> tick([Duration duration = Duration.zero]) async {
    await Future<void>.delayed(duration);
    await Future<void>.delayed(Duration.zero);
  }

  /// Get node by id.
  VirtualNode? getNode(String id) => _nodes[id];

  /// All nodes.
  Iterable<VirtualNode> get nodes => _nodes.values;

  /// Cleanup.
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
    _bleServices.clear();
    _wifiServices.clear();
  }
}
