// Test harness — sendAuto flow simulation. Verifies delivery and channel fallback.
// Uses VirtualNode + fakes. No production modification.

import 'package:flutter_test/flutter_test.dart';

import '../harness/fake_router_service.dart';
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

  group('sendAuto simulation', () {
    test('sendMessage delivers via BLE when nodes connected', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectBle(a, b);

      await a.sendMessage('hello');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
      final hasHello = b.receivedMessages.any((m) {
        if (m['payload'] != null) {
          return String.fromCharCodes(
                  (m['payload'] as List).map((e) => e as int).toList())
              .contains('hello');
        }
        if (m['message'] != null) {
          return (m['message'] as String).contains('hello');
        }
        return false;
      });
      expect(hasHello, isTrue);
    });

    test('sendMessage delivers via Wi-Fi when connected', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectWifi(a, b);

      await a.sendMessage('hello');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
      expect(
        b.receivedMessages.any((m) =>
            m['message'] != null && (m['message'] as String).contains('hello')),
        isTrue,
      );
    });

    test('respects channel fallback: router skips peer delivery', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectBle(a, b);
      a.routerService.enableCloud();

      await a.sendMessage('hello');
      await harness.tick(const Duration(milliseconds: 50));

      // With cloud available, sendMessage returns early — no BLE delivery
      expect(b.receivedMessages.length, 0);
    });

    test('falls back to BLE when Wi-Fi not connected', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectBle(a, b);
      a.routerService.disableCloud();

      await a.sendMessage('msg');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
    });
  });
}
