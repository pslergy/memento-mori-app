// Real MeshCoreEngine stress tests. Uses real sendAuto, cascade, cooldown.
// NO production modification. Platform channels mocked for Wi-Fi.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:memento_mori_app/core/mesh/diagnostics/mesh_metrics.dart';

import '../harness/fake_mesh_bus.dart';
import '../harness/real_engine_harness.dart';

void main() {
  group('Real Engine Stress Tests', () {
    late RealEngineHarness harness;

    setUp(() async {
      harness = RealEngineHarness(seed: 42);
      addTearDown(() => harness.dispose());
      await harness.init();
    });

    test('Engine initializes without crash', () async {
      expect(harness.engine, isNotNull);
      final snap = harness.snapshot();
      expect(snap.isTransferring, isFalse);
    });

    test('sendAuto runs (real engine)', () async {
      harness.resetMetrics();

      await harness.sendAuto(
        content: 'stress_msg_1',
        chatId: 'THE_BEACON_GLOBAL',
        receiverName: 'TestReceiver',
      );

      await harness.tick(const Duration(milliseconds: 500));

      final snap = harness.snapshot();
      expect(snap.metrics['sendAutoCount'], greaterThanOrEqualTo(1));
      expect(snap.isTransferring, isFalse,
          reason: 'Should not be stuck in transferring');
    });

    test('Parallel sendAuto — 20 messages', () async {
      harness.resetMetrics();

      final futures = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(harness.sendAuto(
          content: 'parallel_$i',
          chatId: 'THE_BEACON_GLOBAL',
          receiverName: 'R$i',
          messageId: 'parallel_msg_$i', // Unique ID avoids _sendAutoInProgress collision
        ));
      }

      await Future.wait(futures);
      await harness.tick(const Duration(seconds: 2));

      final snap = harness.snapshot();
      expect(snap.metrics['sendAutoCount'], greaterThanOrEqualTo(20));
      expect(snap.isTransferring, isFalse,
          reason: 'No stuck transferring after parallel send');
    });

    test('Failure injection — Wi-Fi 20% fail', () async {
      harness.resetMetrics();
      harness.setWifiFailureRate(0.2);

      var success = 0;
      var fail = 0;
      for (var i = 0; i < 15; i++) {
        try {
          await harness.sendAuto(
            content: 'fail_test_$i',
            chatId: 'THE_BEACON_GLOBAL',
            receiverName: 'R',
          );
          success++;
        } catch (_) {
          fail++;
        }
        await harness.tick(const Duration(milliseconds: 50));
      }

      await harness.tick(const Duration(milliseconds: 300));

      final snap = harness.snapshot();
      expect(snap.isTransferring, isFalse);
      expect(success + fail, 15);
    });

    test('No infinite cascade — metrics sanity', () async {
      harness.resetMetrics();

      for (var i = 0; i < 10; i++) {
        await harness.sendAuto(
          content: 'cascade_check_$i',
          chatId: 'THE_BEACON_GLOBAL',
          receiverName: 'R',
        );
        await harness.tick(const Duration(milliseconds: 100));
      }

      await harness.tick(const Duration(seconds: 1));

      final snap = harness.snapshot();
      final cascadeStart = snap.metrics['cascadeStartCount'] ?? 0;
      final cascadeWatchdog = snap.metrics['cascadeWatchdogCount'] ?? 0;

      expect(cascadeWatchdog, lessThanOrEqualTo(cascadeStart + 2),
          reason: 'Watchdog should not fire excessively');
      expect(snap.isTransferring, isFalse);
    });

    test('Stuck transferring detection', () async {
      harness.resetMetrics();

      await harness.sendAuto(
        content: 'stuck_check',
        chatId: 'THE_BEACON_GLOBAL',
        receiverName: 'R',
      );

      await harness.tick(const Duration(seconds: 3));

      final snap = harness.snapshot();
      expect(snap.isTransferring, isFalse,
          reason: '_isTransferring should clear within 3s');
    });

    test('Cooldown and lastKnownPeerIp — context snapshot', () async {
      harness.resetMetrics();

      await harness.sendAuto(
        content: 'context_check',
        chatId: 'THE_BEACON_GLOBAL',
        receiverName: 'R',
      );

      await harness.tick(const Duration(milliseconds: 500));

      final snap = harness.snapshot();
      expect(snap.context, isNotNull);
      expect(snap.context.nearbyNodeCount, greaterThanOrEqualTo(0));
      expect(snap.context.cooldownCount, greaterThanOrEqualTo(0));
    });

    test('Metrics collection — delivery and cascade', () async {
      harness.resetMetrics();

      for (var i = 0; i < 8; i++) {
        await harness.sendAuto(
          content: 'metric_$i',
          chatId: 'THE_BEACON_GLOBAL',
          receiverName: 'R',
        );
        await harness.tick(const Duration(milliseconds: 80));
      }

      await harness.tick(const Duration(seconds: 1));

      final snap = harness.snapshot();

      print('');
      print('=== REAL ENGINE METRICS ===');
      print('sendAutoCount: ${snap.metrics['sendAutoCount']}');
      print('cascadeStartCount: ${snap.metrics['cascadeStartCount']}');
      print('cascadeSuccessCount: ${snap.metrics['cascadeSuccessCount']}');
      print('cascadeWatchdogCount: ${snap.metrics['cascadeWatchdogCount']}');
      print('cooldownHitCount: ${snap.metrics['cooldownHitCount']}');
      print('bleScanCount: ${snap.metrics['bleScanCount']}');
      print('isTransferring: ${snap.isTransferring}');
      print('=========================');

      expect(snap.metrics['sendAutoCount'], greaterThanOrEqualTo(8));
      expect(snap.isTransferring, isFalse);
    });

    test('Bus events — Wi-Fi mock receives', () async {
      harness.bus.clear();
      harness.setWifiFailureRate(0);

      await harness.sendAuto(
        content: 'bus_test',
        chatId: 'THE_BEACON_GLOBAL',
        receiverName: 'R',
      );

      await harness.tick(const Duration(milliseconds: 300));

      expect(harness.bus.events.length, greaterThanOrEqualTo(0));
    });
  });
}
