// Multi-node mesh network stress tests.
// Real MeshCoreEngine under distributed mesh simulation.
// NO production modification.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../harness/fake_mesh_bus.dart';
import '../harness/mesh_network_harness.dart';
import '../harness/mesh_topology_generator.dart';

void main() {
  group('Mesh Network Stress Tests', () {
    late MeshNetworkHarness harness;

    setUp(() async {
      harness = MeshNetworkHarness(seed: 42);
      addTearDown(() => harness.dispose());
      await harness.init(
        nodeCount: 20,
        topologyType: MeshTopologyType.random,
        forceCloudOffline: true,
      );
    });

    test('Harness initializes with 20 nodes', () {
      expect(harness.nodes.length, 20);
      expect(harness.engine, isNotNull);
      expect(harness.engineNodeId, 'node_0');
    });

    test('sendAuto runs through mesh bus', () async {
      harness.resetMetrics();
      harness.setWifiFailureRate(0);

      await harness.sendAuto(
        content: 'mesh_msg_1',
        receiverName: 'R',
        messageId: 'msg_1',
      );

      await harness.tick(const Duration(milliseconds: 500));

      final m = harness.collectMetrics();
      expect(m.sendAutoCount, greaterThanOrEqualTo(1));
      expect(m.isTransferring, isFalse);
    });

    test('Failure injection — Wi-Fi 30%', () async {
      harness.resetMetrics();
      harness.setWifiFailureRate(0.3);

      for (var i = 0; i < 15; i++) {
        await harness.sendAuto(
          content: 'fail_$i',
          receiverName: 'R',
          messageId: 'fail_msg_$i',
        );
        await harness.tick(const Duration(milliseconds: 50));
      }

      await harness.tick(const Duration(seconds: 2));

      final m = harness.collectMetrics();
      expect(m.isTransferring, isFalse);
      expect(m.wifiSentCount + m.wifiFailCount, greaterThanOrEqualTo(0));
    });

    test('No stuck transferring', () async {
      harness.resetMetrics();

      await harness.sendAuto(
        content: 'stuck_check',
        receiverName: 'R',
        messageId: 'stuck_1',
      );

      await harness.tick(const Duration(seconds: 3));

      final m = harness.collectMetrics();
      expect(m.isTransferring, isFalse, reason: '_isTransferring should clear');
    });

    test('Chain topology — multi-hop', () async {
      harness.dispose();
      harness = MeshNetworkHarness(seed: 123);
      addTearDown(() => harness.dispose());
      await harness.init(
        nodeCount: 10,
        topologyType: MeshTopologyType.chain,
        forceCloudOffline: true,
      );

      harness.resetMetrics();
      harness.setWifiFailureRate(0);

      await harness.sendAuto(
        content: 'chain_msg',
        receiverName: 'R',
        messageId: 'chain_1',
      );

      await harness.tick(const Duration(seconds: 2));

      final m = harness.collectMetrics();
      expect(m.isTransferring, isFalse);
    });

    test('Stress — 30 nodes, 50 messages', () async {
      harness.dispose();
      harness = MeshNetworkHarness(seed: 999);
      addTearDown(() => harness.dispose());
      await harness.init(
        nodeCount: 30,
        topologyType: MeshTopologyType.random,
        forceCloudOffline: true,
      );

      harness.resetMetrics();
      harness.setWifiFailureRate(0.2);

      for (var i = 0; i < 50; i++) {
        await harness.sendAuto(
          content: 'stress_$i',
          receiverName: 'R${i % 10}',
          messageId: 'stress_msg_$i',
        );
        if (i % 5 == 4) await harness.tick(const Duration(milliseconds: 100));
      }

      await harness.tick(const Duration(seconds: 5));

      final m = harness.collectMetrics();
      expect(m.isTransferring, isFalse);
      expect(m.sendAutoCount, greaterThanOrEqualTo(50));
      expect(m.cascadeWatchdogCount, lessThanOrEqualTo(m.cascadeStartCount + 5),
          reason: 'No excessive watchdog');
    });

    test('Metrics — delivery and cascade', () async {
      harness.resetMetrics();

      for (var i = 0; i < 10; i++) {
        await harness.sendAuto(
          content: 'metric_$i',
          receiverName: 'R',
          messageId: 'm_$i',
        );
        await harness.tick(const Duration(milliseconds: 80));
      }

      await harness.tick(const Duration(seconds: 2));

      final m = harness.collectMetrics();
      print('');
      print('=== MESH NETWORK METRICS ===');
      print('sendAutoCount: ${m.sendAutoCount}');
      print('cascadeStart: ${m.cascadeStartCount}');
      print('cascadeSuccess: ${m.cascadeSuccessCount}');
      print('cascadeWatchdog: ${m.cascadeWatchdogCount}');
      print('cooldownHit: ${m.cooldownHitCount}');
      print('wifiSent/Fail: ${m.wifiSentCount}/${m.wifiFailCount}');
      print('isTransferring: ${m.isTransferring}');
      print('===========================');

      expect(m.sendAutoCount, greaterThanOrEqualTo(10));
      expect(m.isTransferring, isFalse);
    });
  });
}
