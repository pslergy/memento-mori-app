// Test harness — cascade flow simulation. Wi-Fi → BLE fallback.
// Uses VirtualNode + fakes. No production modification.

import 'package:flutter_test/flutter_test.dart';

import '../harness/mesh_test_harness.dart';
import '../harness/virtual_node.dart';

void main() {
  late MeshTestHarness harness;

  setUp(() {
    harness = MeshTestHarness();
  });

  tearDown(() {
    harness.dispose();
  });

  group('cascade simulation', () {
    test('direct Wi-Fi send fails when disconnected, BLE fallback works', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      a.routerService.disableCloud();
      // No Wi-Fi connection
      harness.connectBle(a, b);

      await a.sendMessage('cascade_msg');
      await harness.tick(const Duration(milliseconds: 50));

      // BLE fallback should deliver
      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
    });

    test('Wi-Fi preferred when connected', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectWifi(a, b);
      harness.connectBle(a, b);
      a.routerService.disableCloud();

      await a.sendMessage('wifi_first');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
      // First channel (Wi-Fi) should succeed
      expect(
        b.wifiService.receivedMessages.any((m) =>
            m['message'] != null && (m['message'] as String).contains('wifi_first')),
        isTrue,
      );
    });

    test('cascade triggers when direct send fails', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      a.routerService.disableCloud();
      harness.connectBle(a, b);

      await a.sendMessage('fallback');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.bleService.receivedMessages.length, greaterThanOrEqualTo(1));
    });
  });
}
