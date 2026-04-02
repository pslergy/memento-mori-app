// Test harness — BLE discovery simulation. Node discovers another, cascade may trigger.
// Uses VirtualNode + fakes. No production modification.

import 'package:flutter_test/flutter_test.dart';

import '../harness/fake_bluetooth_service.dart';
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

  group('BLE discovery simulation', () {
    test('node discovers another node after connectBle', () {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');

      expect(a.bleService.discoverDevices(), isEmpty);

      harness.connectBle(a, b);

      expect(a.bleService.discoverDevices(), contains(b.id));
      expect(b.bleService.discoverDevices(), contains(a.id));
    });

    test('cascade may trigger when BRIDGE discovered', () async {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectBle(a, b);
      a.routerService.disableCloud();

      await a.sendMessage('discovery_msg');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1));
    });

    test('disconnect removes from discovery', () {
      final a = harness.createNode('node_a');
      final b = harness.createNode('node_b');
      harness.connectBle(a, b);

      expect(a.bleService.discoverDevices(), contains(b.id));

      harness.disconnect(a, b);

      expect(a.bleService.discoverDevices(), isEmpty);
      expect(b.bleService.discoverDevices(), isEmpty);
    });
  });
}
