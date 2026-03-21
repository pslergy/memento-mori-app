// Test harness — VirtualNode holds simulated mesh state and fake services.
// Uses fakes for transport. Does NOT wrap real MeshCoreEngine (no production modification).
// For integration tests with real MeshCoreEngine, use locator in test setup.

import 'dart:async';

import 'fake_bluetooth_service.dart';
import 'fake_database.dart';
import 'fake_router_service.dart';
import 'fake_ultrasonic_service.dart';
import 'fake_wifi_service.dart';

/// Virtual node for mesh simulation. Uses injected fake services.
/// receivedMessages captures delivered payloads for assertion.
class VirtualNode {
  final String id;
  final FakeBluetoothService bleService;
  final FakeWifiService wifiService;
  final FakeUltrasonicService sonarService;
  final FakeRouterService routerService;
  final FakeDatabase database;

  final List<Map<String, dynamic>> receivedMessages = [];
  StreamSubscription? _bleSub;
  StreamSubscription? _wifiSub;

  VirtualNode({
    required this.id,
    required this.bleService,
    required this.wifiService,
    required this.sonarService,
    required this.routerService,
    required this.database,
  }) {
    _bleSub = bleService.receivedStream.listen((m) => receivedMessages.add(m));
    _wifiSub = wifiService.receivedStream.listen((m) => receivedMessages.add(m));
  }

  /// Simulate sendAuto-like delivery: try router, then wifi, then ble, then sonar.
  Future<void> sendMessage(String content, {String? targetId}) async {
    final packet = {
      'type': 'OFFLINE_MSG',
      'content': content,
      'senderId': id,
      'targetId': targetId ?? 'THE_BEACON_GLOBAL',
    };
    final encoded = '${packet['type']}|${packet['content']}|${packet['senderId']}';

    // Channel order: Router → Wi-Fi → BLE → Sonar
    if (routerService.cloudAvailable) return;
    if (wifiService.isConnected && wifiService.connectedPeerIp != null) {
      await wifiService.sendTcp(encoded, host: wifiService.connectedPeerIp);
      return;
    }
    final blePeers = bleService.discoverDevices();
    if (blePeers.isNotEmpty) {
      await bleService.sendMessage(blePeers.first, encoded.codeUnits);
      return;
    }
    sonarService.transmitFrame(
        'DATA:${content.length > 64 ? content.substring(0, 64) : content}');
  }

  void dispose() {
    _bleSub?.cancel();
    _wifiSub?.cancel();
    bleService.dispose();
    wifiService.dispose();
    sonarService.dispose();
  }
}
