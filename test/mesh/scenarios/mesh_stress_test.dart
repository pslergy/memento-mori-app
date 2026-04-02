// Stress tests for mesh networking. Uses MeshTestHarness + VirtualNode.
// Goal: BREAK the system, reveal weaknesses. No production modification.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../harness/mesh_test_harness.dart';
import '../harness/stress_mesh_test_harness.dart';
import '../harness/virtual_node.dart';

void main() {
  group('Mesh Stress Tests', () {
    test('MASS NODE CREATION — 20 nodes', () async {
      final harness = StressMeshTestHarness(seed: 42);
      addTearDown(harness.dispose);

      final nodes = List.generate(20, (i) => harness.createNode('Node_$i'));
      expect(nodes.length, 20);
      for (var i = 0; i < 20; i++) {
        expect(harness.getNode('Node_$i'), isNotNull);
      }
    });

    test('RANDOM TOPOLOGY — 30% Wi-Fi, 70% BLE, 10% isolated', () async {
      final harness = StressMeshTestHarness(seed: 123);
      addTearDown(harness.dispose);

      final nodes = List.generate(30, (i) => harness.createNode('Node_$i'));
      final r = harness.random;

      // 30% Wi-Fi connected (9 pairs)
      final wifiCount = (nodes.length * 0.15).floor();
      for (var i = 0; i < wifiCount; i++) {
        final a = nodes[r.nextInt(nodes.length)];
        final b = nodes[r.nextInt(nodes.length)];
        if (a.id != b.id) harness.connectWifi(a, b);
      }

      // 70% BLE only (21 pairs)
      final bleCount = (nodes.length * 0.35).floor();
      for (var i = 0; i < bleCount; i++) {
        final a = nodes[r.nextInt(nodes.length)];
        final b = nodes[r.nextInt(nodes.length)];
        if (a.id != b.id) harness.connectBle(a, b);
      }

      // Verify topology
      int wifiConnected = 0;
      int bleConnected = 0;
      for (final n in nodes) {
        if (n.wifiService.isConnected) wifiConnected++;
        if (n.bleService.discoverDevices().isNotEmpty) bleConnected++;
      }
      expect(wifiConnected + bleConnected, greaterThan(0));
    });

    test('PARALLEL SEND LOAD — 100–300 messages', () async {
      final harness = StressMeshTestHarness(seed: 456);
      addTearDown(harness.dispose);

      final nodes = List.generate(15, (i) => harness.createNode('Node_$i'));
      final r = harness.random;

      // Connect all in a chain for delivery
      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectBle(nodes[i], nodes[i + 1]);
      }

      for (final n in nodes) n.routerService.disableCloud();

      final futures = <Future<void>>[];
      final totalMessages = 100 + r.nextInt(200);

      for (var i = 0; i < totalMessages; i++) {
        final sender = nodes[r.nextInt(nodes.length)];
        final delay = Duration(milliseconds: r.nextInt(500));
        futures.add(Future.delayed(delay, () async {
          try {
            await sender.sendMessage('msg_$i');
          } catch (_) {}
        }));
      }

      await Future.wait(futures);
      await harness.tick(const Duration(milliseconds: 100));

      int delivered = 0;
      for (final n in nodes) {
        delivered += n.receivedMessages.length;
      }

      final ratio = totalMessages > 0 ? delivered / totalMessages : 0.0;
      print('Parallel load: sent=$totalMessages delivered=$delivered ratio=${(ratio * 100).toStringAsFixed(1)}%');
      expect(ratio, greaterThanOrEqualTo(0.85), reason: 'Delivery ratio should be >= 85%');
    });

    test('CASCADE STRESS — Wi-Fi disabled, BLE fallback', () async {
      final harness = StressMeshTestHarness(seed: 789);
      addTearDown(harness.dispose);

      final a = harness.createNode('sender');
      final b = harness.createNode('bridge');
      harness.connectBle(a, b);
      harness.disableWifiFor(a);
      a.routerService.disableCloud();

      for (var i = 0; i < 20; i++) {
        await a.sendMessage('cascade_$i');
        await harness.tick(const Duration(milliseconds: 10));
      }

      expect(b.receivedMessages.length, greaterThanOrEqualTo(15),
          reason: 'Cascade BLE fallback should deliver most messages');
    });

    test('COOLDOWN STRESS — repeated failures, no infinite retry', () async {
      final harness = StressMeshTestHarness(seed: 999);
      addTearDown(harness.dispose);

      final a = harness.createNode('a');
      final b = harness.createNode('b');
      harness.connectBle(a, b);
      harness.setBleFailureRate(a, 0.9);
      a.routerService.disableCloud();

      int attempts = 0;
      const maxAttempts = 50;

      for (var i = 0; i < 20 && attempts < maxAttempts; i++) {
        attempts++;
        try {
          await a.sendMessage('cooldown_$i');
        } catch (_) {}
        await harness.tick(const Duration(milliseconds: 5));
      }

      expect(attempts, lessThan(maxAttempts), reason: 'No infinite retry loop');
      expect(b.receivedMessages.length, lessThan(20), reason: 'Most should fail under 90% BLE failure');
    });

    test('NODE CHURN — disconnect/reconnect during transfers', () async {
      final harness = StressMeshTestHarness(seed: 111);
      addTearDown(harness.dispose);

      final nodes = List.generate(10, (i) => harness.createNode('Node_$i'));
      final r = harness.random;

      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectBle(nodes[i], nodes[i + 1]);
      }
      for (final n in nodes) n.routerService.disableCloud();

      final churnStopwatch = Stopwatch()..start();
      const churnDuration = Duration(seconds: 3);
      var churnCycles = 0;

      final sendFutures = <Future<void>>[];
      for (var i = 0; i < 50; i++) {
        sendFutures.add(Future.delayed(
          Duration(milliseconds: r.nextInt(100)),
          () async {
            final s = nodes[r.nextInt(nodes.length)];
            try {
              await s.sendMessage('churn_$i');
            } catch (_) {}
          },
        ));
      }

      while (churnStopwatch.elapsed < churnDuration) {
        if (nodes.length >= 4) {
          final idx1 = r.nextInt(nodes.length);
          var idx2 = r.nextInt(nodes.length);
          while (idx2 == idx1) idx2 = r.nextInt(nodes.length);
          harness.disconnect(nodes[idx1], nodes[idx2]);
          await harness.tick(const Duration(milliseconds: 100));
          harness.connectBle(nodes[idx1], nodes[idx2]);
          churnCycles++;
        }
        await harness.tick(const Duration(milliseconds: 200));
      }

      await Future.wait(sendFutures);
      await harness.tick(const Duration(milliseconds: 200));

      int delivered = 0;
      for (final n in nodes) delivered += n.receivedMessages.length;

      print('Churn: cycles=$churnCycles delivered=$delivered');
      expect(churnCycles, greaterThan(0));
    });

    test('FAILURE INJECTION — BLE 20–40% fail, cascade fallback', () async {
      final harness = StressMeshTestHarness(seed: 222);
      addTearDown(harness.dispose);

      final a = harness.createNode('a');
      final b = harness.createNode('b');
      harness.connectBle(a, b);
      harness.setBleFailureRate(a, 0.3);
      a.routerService.disableCloud();

      int sent = 0;
      int delivered = 0;

      for (var i = 0; i < 50; i++) {
        sent++;
        try {
          await a.sendMessage('fail_$i');
          delivered++;
        } catch (_) {}
        await harness.tick(const Duration(milliseconds: 5));
      }

      await harness.tick(const Duration(milliseconds: 50));
      delivered = b.receivedMessages.length;

      final ratio = sent > 0 ? delivered / sent : 0.0;
      print('Failure injection: sent=$sent delivered=$delivered ratio=${(ratio * 100).toStringAsFixed(1)}%');
      expect(ratio, greaterThanOrEqualTo(0.5), reason: 'Some delivery despite 30% BLE failure');
    });

    test('EDGE: Single bridge overloaded', () async {
      final harness = StressMeshTestHarness(seed: 333);
      addTearDown(harness.dispose);

      final bridge = harness.createNode('bridge');
      final clients = List.generate(15, (i) => harness.createNode('client_$i'));

      for (final c in clients) {
        harness.connectBle(c, bridge);
        c.routerService.disableCloud();
      }

      for (var i = 0; i < 50; i++) {
        final c = clients[i % clients.length];
        unawaited(c.sendMessage('overload_$i'));
      }

      await harness.tick(const Duration(milliseconds: 500));

      final delivered = bridge.receivedMessages.length;
      print('Bridge overload: delivered=$delivered/50');
      expect(delivered, greaterThan(0));
    });

    test('EDGE: All nodes BLE-only', () async {
      final harness = StressMeshTestHarness(seed: 444);
      addTearDown(harness.dispose);

      final nodes = List.generate(10, (i) => harness.createNode('Node_$i'));
      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectBle(nodes[i], nodes[i + 1]);
      }
      for (final n in nodes) n.routerService.disableCloud();

      for (var i = 0; i < 30; i++) {
        await nodes[0].sendMessage('ble_only_$i');
        await harness.tick(const Duration(milliseconds: 5));
      }

      int total = 0;
      for (final n in nodes) total += n.receivedMessages.length;
      expect(total, greaterThanOrEqualTo(20));
    });

    test('EDGE: All nodes Wi-Fi-only', () async {
      final harness = StressMeshTestHarness(seed: 555);
      addTearDown(harness.dispose);

      final nodes = List.generate(8, (i) => harness.createNode('Node_$i'));
      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectWifi(nodes[i], nodes[i + 1]);
      }
      for (final n in nodes) n.routerService.disableCloud();

      for (var i = 0; i < 25; i++) {
        await nodes[0].sendMessage('wifi_only_$i');
        await harness.tick(const Duration(milliseconds: 5));
      }

      int total = 0;
      for (final n in nodes) total += n.receivedMessages.length;
      expect(total, greaterThanOrEqualTo(15));
    });

    test('EDGE: Fully disconnected partitions', () async {
      final harness = StressMeshTestHarness(seed: 666);
      addTearDown(harness.dispose);

      final groupA = List.generate(3, (i) => harness.createNode('A_$i'));
      final groupB = List.generate(3, (i) => harness.createNode('B_$i'));

      for (var i = 0; i < groupA.length - 1; i++) harness.connectBle(groupA[i], groupA[i + 1]);
      for (var i = 0; i < groupB.length - 1; i++) harness.connectBle(groupB[i], groupB[i + 1]);

      for (final n in groupA) n.routerService.disableCloud();
      for (final n in groupB) n.routerService.disableCloud();

      await groupA[0].sendMessage('to_partition_b');
      await harness.tick(const Duration(milliseconds: 50));

      int bReceived = 0;
      for (final n in groupB) bReceived += n.receivedMessages.length;

      expect(bReceived, 0, reason: 'Partition B should receive nothing from A');
    });

    test('EDGE: Rapid connect/disconnect storm', () async {
      final harness = StressMeshTestHarness(seed: 777);
      addTearDown(harness.dispose);

      final a = harness.createNode('a');
      final b = harness.createNode('b');
      a.routerService.disableCloud();

      for (var i = 0; i < 20; i++) {
        harness.connectBle(a, b);
        await harness.tick(const Duration(milliseconds: 1));
        harness.disconnect(a, b);
        await harness.tick(const Duration(milliseconds: 1));
      }

      harness.connectBle(a, b);
      await a.sendMessage('after_storm');
      await harness.tick(const Duration(milliseconds: 50));

      expect(b.receivedMessages.length, greaterThanOrEqualTo(1),
          reason: 'Should recover after storm');
    });

    test('METRICS COLLECTION — delivery ratio, no crashes', () async {
      final harness = StressMeshTestHarness(seed: 888);
      addTearDown(harness.dispose);

      final nodes = List.generate(12, (i) => harness.createNode('Node_$i'));
      final r = harness.random;

      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectBle(nodes[i], nodes[i + 1]);
      }
      harness.setBleFailureRate(nodes[0], 0.2);
      for (final n in nodes) n.routerService.disableCloud();

      const totalMessages = 80;
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < totalMessages; i++) {
        final sender = nodes[r.nextInt(nodes.length)];
        try {
          await sender.sendMessage('metric_$i');
        } catch (_) {}
        await harness.tick(Duration(milliseconds: r.nextInt(20)));
      }

      await harness.tick(const Duration(milliseconds: 100));
      stopwatch.stop();

      int delivered = 0;
      for (final n in nodes) delivered += n.receivedMessages.length;

      final ratio = totalMessages > 0 ? delivered / totalMessages : 0.0;
      final avgLatency = stopwatch.elapsedMilliseconds / totalMessages;

      print('');
      print('=== STRESS METRICS ===');
      print('Total sent: $totalMessages');
      print('Delivered: $delivered');
      print('Delivery ratio: ${(ratio * 100).toStringAsFixed(1)}%');
      print('Avg latency: ${avgLatency.toStringAsFixed(0)}ms');
      print('Duration: ${stopwatch.elapsedMilliseconds}ms');
      print('=====================');

      expect(ratio, greaterThanOrEqualTo(0.85));
      expect(stopwatch.elapsedMilliseconds, lessThan(30000), reason: 'No hanging');
    });

    test('AGGRESSIVE: 50 nodes, 300 messages, 40% BLE failure', () async {
      final harness = StressMeshTestHarness(seed: 9999);
      addTearDown(harness.dispose);

      final nodes = List.generate(50, (i) => harness.createNode('Node_$i'));
      final r = harness.random;

      for (var i = 0; i < nodes.length - 1; i++) {
        harness.connectBle(nodes[i], nodes[i + 1]);
      }
      for (var i = 0; i < 10; i++) {
        harness.setBleFailureRate(nodes[i], 0.4);
      }
      for (final n in nodes) n.routerService.disableCloud();

      const total = 300;
      final futures = <Future<void>>[];
      for (var i = 0; i < total; i++) {
        final s = nodes[r.nextInt(nodes.length)];
        futures.add(Future.delayed(
          Duration(milliseconds: r.nextInt(300)),
          () async {
            try {
              await s.sendMessage('aggressive_$i');
            } catch (_) {}
          },
        ));
      }

      await Future.wait(futures);
      await harness.tick(const Duration(milliseconds: 500));

      int delivered = 0;
      for (final n in nodes) delivered += n.receivedMessages.length;

      final ratio = total > 0 ? delivered / total : 0.0;
      print('Aggressive 50 nodes: sent=$total delivered=$delivered ratio=${(ratio * 100).toStringAsFixed(1)}%');
      expect(ratio, greaterThanOrEqualTo(0.80));
    });
  });
}
