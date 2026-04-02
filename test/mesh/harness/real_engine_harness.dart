// Real MeshCoreEngine stress test harness.
// Uses real engine with locator overrides and platform channel mocks.
// NO production logic modification.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:memento_mori_app/core/decoy/app_mode.dart';
import 'package:memento_mori_app/core/decoy/vault_interface.dart';
import 'package:memento_mori_app/core/encryption_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_core_engine.dart';

import 'fake_test_vault.dart';
import 'package:memento_mori_app/core/mesh/diagnostics/mesh_metrics.dart';

import 'fake_mesh_bus.dart';

/// Harness for real MeshCoreEngine stress tests.
/// Overrides locator services where possible; mocks platform channels.
///
/// LIMITATION: MeshCoreEngine creates BluetoothMeshService internally.
/// BLE cannot be replaced without production changes. Wi-Fi uses
/// NativeMeshService (platform channel) — we mock it.
class RealEngineHarness {
  final FakeMeshBus bus;
  final int? seed;
  late final math.Random _random;

  RealEngineHarness({int? seed})
      : bus = FakeMeshBus(seed: seed),
        seed = seed,
        _random = math.Random(seed);

  MeshCoreEngine? _engine;
  MethodChannel? _wifiChannel;
  bool _initialized = false;

  MeshCoreEngine get engine {
    if (_engine == null) {
      _engine = locator<MeshCoreEngine>();
    }
    return _engine!;
  }

  /// Initialize locator and platform mocks. Call before first engine access.
  /// Uses ensureCoreLocator + setupSessionLocator to avoid double-reset race.
  Future<void> init() async {
    if (_initialized) return;

    TestWidgetsFlutterBinding.ensureInitialized();

    _initSqfliteForTests();
    _mockPlatformChannels();

    await locator.reset();

    locator.registerLazySingleton<VaultInterface>(() => FakeTestVault());
    ensureCoreLocator(AppMode.REAL);
    setupSessionLocator(AppMode.REAL);

    if (!locator.isRegistered<EncryptionService>()) {
      throw StateError(
          'RealEngineHarness: EncryptionService not registered after setup');
    }

    _mockWifiChannel();

    _initialized = true;
  }

  static bool _sqfliteInitialized = false;

  void _initSqfliteForTests() {
    if (_sqfliteInitialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _sqfliteInitialized = true;
  }

  void _mockPlatformChannels() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // sound_generator — init returns bool, others return void
    const soundChannel = MethodChannel('sound_generator');
    messenger.setMockMethodCallHandler(soundChannel, (MethodCall call) async {
      switch (call.method) {
        case 'init':
          return true; // SoundGenerator.init expects bool
        case 'setWaveform':
        case 'setWaveType':
        case 'setVolume':
        case 'setFrequency':
        case 'play':
        case 'stop':
          return null;
        default:
          return null;
      }
    });

    // memento/sonar — stopListening, startListening
    const sonarChannel = MethodChannel('memento/sonar');
    messenger.setMockMethodCallHandler(sonarChannel, (MethodCall call) async {
      switch (call.method) {
        case 'stopListening':
        case 'startListening':
          return null;
        default:
          return null;
      }
    });
  }

  void _mockWifiChannel() {
    _wifiChannel = const MethodChannel('memento/wifi_direct');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_wifiChannel!, (MethodCall call) async {
      switch (call.method) {
        case 'sendTcp':
          final args = call.arguments as Map<dynamic, dynamic>;
          final host = args['host'] as String? ?? '';
          final message = args['message'] as String? ?? '';
          try {
            await bus.sendWifi('engine', host, message);
            return null;
          } catch (e) {
            throw PlatformException(code: 'SEND_FAILED', message: '$e');
          }
        case 'startDiscovery':
        case 'stopDiscovery':
        case 'connect':
        case 'createGroup':
        case 'removeGroup':
        case 'getGroupInfo':
        case 'ensureGroupExists':
        case 'isGroupOwner':
        case 'startMeshService':
        case 'stopMeshService':
        case 'checkP2pState':
        case 'checkDiscoveryState':
        case 'requestP2pActivation':
        case 'forceReset':
        case 'canStartTcpServer':
        case 'startTemporaryTcpServer':
        case 'resetTcpServerCrashFlag':
          return null;
        default:
          return null;
      }
    });
  }

  /// Set BLE failure rate for bus (when BLE is routed through bus).
  void setBleFailureRate(double rate) => bus.setBleFailureRate(rate);

  /// Set Wi-Fi failure rate.
  void setWifiFailureRate(double rate) => bus.setWifiFailureRate(rate);

  /// Set latency ranges (ms).
  void setBleLatency(int minMs, int maxMs) => bus.setBleLatency(minMs, maxMs);
  void setWifiLatency(int minMs, int maxMs) =>
      bus.setWifiLatency(minMs, maxMs);

  /// Run real sendAuto.
  Future<void> sendAuto({
    required String content,
    String? chatId,
    required String receiverName,
    String? messageId,
  }) async {
    await engine.sendAuto(
      content: content,
      chatId: chatId,
      receiverName: receiverName,
      messageId: messageId,
    );
  }

  /// Advance time and flush microtasks.
  Future<void> tick([Duration duration = Duration.zero]) async {
    await Future<void>.delayed(duration);
    await Future<void>.delayed(Duration.zero);
  }

  /// Snapshot of engine state for assertions.
  EngineStateSnapshot snapshot() => EngineStateSnapshot(
        isTransferring: engine.isTransferring,
        nearbyNodeCount: engine.nearbyNodes.length,
        context: engine.getContextSnapshot(),
        metrics: _metricsSnapshot(),
      );

  Map<String, int> _metricsSnapshot() => {
        'sendAutoCount': MeshMetrics.instance.sendAutoCount,
        'cascadeStartCount': MeshMetrics.instance.cascadeStartCount,
        'cascadeSuccessCount': MeshMetrics.instance.cascadeSuccessCount,
        'cascadeWatchdogCount': MeshMetrics.instance.cascadeWatchdogCount,
        'cooldownHitCount': MeshMetrics.instance.cooldownHitCount,
        'bleScanCount': MeshMetrics.instance.bleScanCount,
      };

  /// Reset metrics for fresh run.
  void resetMetrics() => MeshMetrics.instance.reset();

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_wifiChannel!, null);
    bus.clear();
  }
}

class EngineStateSnapshot {
  final bool isTransferring;
  final int nearbyNodeCount;
  final dynamic context;
  final Map<String, int> metrics;

  EngineStateSnapshot({
    required this.isTransferring,
    required this.nearbyNodeCount,
    required this.context,
    required this.metrics,
  });
}
