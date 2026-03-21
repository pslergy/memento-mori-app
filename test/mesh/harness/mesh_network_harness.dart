// Multi-node mesh network harness for REAL MeshCoreEngine stress tests.
// Simulates distributed mesh: one real engine + virtual nodes, all transports via FakeMeshBus.
// NO production logic modification.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:memento_mori_app/core/decoy/app_mode.dart';
import 'package:memento_mori_app/core/decoy/vault_interface.dart';
import 'package:memento_mori_app/core/encryption_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_core_engine.dart';
import 'package:memento_mori_app/core/mesh/diagnostics/mesh_metrics.dart';
import 'fake_mesh_bus.dart';
import 'fake_test_vault.dart';
import 'mesh_topology_generator.dart';

/// Node in the mesh. Engine node has real MeshCoreEngine; virtual nodes are relay endpoints.
class MeshNode {
  final String nodeId;
  final String virtualIp;
  final MeshCoreEngine? engine;
  final bool isEngine;

  MeshNode({
    required this.nodeId,
    required this.virtualIp,
    this.engine,
  }) : isEngine = engine != null;
}

/// Harness for multi-node mesh stress tests.
/// Uses ONE real MeshCoreEngine (singleton limitation) + virtual relay nodes.
/// All Wi-Fi routed through FakeMeshBus. Cloud/Router forced offline.
class MeshNetworkHarness {
  final FakeMeshBus bus;
  final int? seed;

  final List<MeshNode> _nodes = [];
  final Map<String, MeshNode> _nodeMap = {};
  String? _engineNodeId;
  MethodChannel? _wifiChannel;
  bool _initialized = false;
  bool _cloudForcedOffline = true;

  MeshNetworkHarness({int? seed})
      : bus = FakeMeshBus(seed: seed),
        seed = seed;

  List<MeshNode> get nodes => List.unmodifiable(_nodes);
  Map<String, MeshNode> get nodeMap => Map.unmodifiable(_nodeMap);
  String? get engineNodeId => _engineNodeId;
  MeshCoreEngine? get engine =>
      _engineNodeId != null ? _nodeMap[_engineNodeId]?.engine : null;

  /// Initialize harness with topology. Call before use.
  Future<void> init({
    required int nodeCount,
    MeshTopologyType topologyType = MeshTopologyType.random,
    bool forceCloudOffline = true,
  }) async {
    if (_initialized) return;

    TestWidgetsFlutterBinding.ensureInitialized();
    _cloudForcedOffline = forceCloudOffline;

    _initSqfliteForTests();
    _mockPlatformChannels();

    await locator.reset();
    locator.registerLazySingleton<VaultInterface>(() => FakeTestVault());
    ensureCoreLocator(AppMode.REAL);
    setupSessionLocator(AppMode.REAL);

    if (!locator.isRegistered<EncryptionService>()) {
      throw StateError(
          'MeshNetworkHarness: EncryptionService not registered');
    }

    _buildTopology(nodeCount, topologyType);
    _mockWifiChannel();
    _injectEnginePeers();
    _simulateP2pConnected();

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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    const soundChannel = MethodChannel('sound_generator');
    messenger.setMockMethodCallHandler(soundChannel, (MethodCall call) async {
      if (call.method == 'init') return true;
      return null;
    });

    const sonarChannel = MethodChannel('memento/sonar');
    messenger.setMockMethodCallHandler(sonarChannel, (MethodCall call) async =>
        null);

    // Router/Cloud: force offline when _cloudForcedOffline
    if (_cloudForcedOffline) {
      const routerChannel = MethodChannel('memento/router');
      messenger.setMockMethodCallHandler(routerChannel, (MethodCall call) async {
        throw PlatformException(code: 'OFFLINE', message: 'Forced offline');
      });
    }
  }

  void _buildTopology(int nodeCount, MeshTopologyType topologyType) {
    final gen = MeshTopologyGenerator(seed: seed);
    final graph = gen.generate(nodeCount, topologyType);

    _nodes.clear();
    _nodeMap.clear();
    bus.clear();

    for (var i = 0; i < nodeCount; i++) {
      final nodeId = 'node_$i';
      final ip = '192.168.49.${i + 1}';
      bus.registerNode(nodeId, ip: ip);

      MeshCoreEngine? eng;
      if (i == 0) {
        eng = locator<MeshCoreEngine>();
        _engineNodeId = nodeId;
      }

      final node = MeshNode(nodeId: nodeId, virtualIp: ip, engine: eng);
      _nodes.add(node);
      _nodeMap[nodeId] = node;
    }

    for (final edge in graph.edges) {
      bus.connect(edge.from, edge.to);
    }

    // Delivery handlers for virtual nodes (receive only, no relay to avoid loops)
    for (final node in _nodes) {
      if (!node.isEngine) {
        bus.setDeliveryHandler(node.nodeId, (from, to, payload) async {
          _logPath('$from → $to');
          return false; // No relay
        });
      }
    }

    // Engine node: deliver to processIncomingPacket
    if (_engineNodeId != null && engine != null) {
      bus.setDeliveryHandler(_engineNodeId!, (from, to, payload) async {
        _logPath('$from → $to (engine)');
        if (payload is String) {
          try {
            final data = jsonDecode(payload) as Map<String, dynamic>?;
            if (data != null) {
              final incoming = {
                'message': payload,
                'senderIp': _nodeMap[from]?.virtualIp ?? from,
              };
              engine!.processIncomingPacket(incoming);
            }
          } catch (_) {}
        }
        return false; // No relay from engine in this sim
      });
    }
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
          final fromId = _engineNodeId ?? 'engine';
          final toId = bus.resolveHostToNodeId(host) ?? host;
          try {
            await bus.sendWifi(fromId, toId, message);
            return null;
          } catch (e) {
            throw PlatformException(code: 'SEND_FAILED', message: '$e');
          }
        default:
          return null;
      }
    });
  }

  void _injectEnginePeers() {
    if (engine == null) return;
    final neighbors = bus.neighborsOf(_engineNodeId!);
    final raw = <Map<String, dynamic>>[];
    for (final nid in neighbors) {
      final node = _nodeMap[nid];
      if (node != null) {
        raw.add({'metadata': node.virtualIp, 'address': node.virtualIp, 'name': 'Node_$nid'});
      }
    }
    engine!.handleNativePeers(raw);
  }

  void _simulateP2pConnected() {
    if (engine == null) return;
    final neighbors = bus.neighborsOf(_engineNodeId!);
    final first = neighbors.isNotEmpty ? neighbors.first : null;
    if (first != null) {
      final ip = _nodeMap[first]?.virtualIp ?? '192.168.49.2';
      engine!.onNetworkConnected(false, ip);
    }
  }

  void _logPath(String path) {
    // Debug: print('  [PATH] $path');
  }

  void setBleFailureRate(double rate) => bus.setBleFailureRate(rate);
  void setWifiFailureRate(double rate) => bus.setWifiFailureRate(rate);
  void setNodeDeathRate(double rate) => bus.setNodeDeathRate(rate);

  Future<void> sendAuto({
    required String content,
    String? chatId,
    required String receiverName,
    String? messageId,
  }) async {
    if (engine == null) throw StateError('No engine node');
    await engine!.sendAuto(
      content: content,
      chatId: chatId ?? 'THE_BEACON_GLOBAL',
      receiverName: receiverName,
      messageId: messageId,
    );
  }

  Future<void> tick([Duration duration = Duration.zero]) async {
    await Future.delayed(duration);
    await Future.delayed(Duration.zero);
  }

  MeshNetworkMetrics collectMetrics() => MeshNetworkMetrics(
        sendAutoCount: MeshMetrics.instance.sendAutoCount,
        cascadeStartCount: MeshMetrics.instance.cascadeStartCount,
        cascadeSuccessCount: MeshMetrics.instance.cascadeSuccessCount,
        cascadeWatchdogCount: MeshMetrics.instance.cascadeWatchdogCount,
        cooldownHitCount: MeshMetrics.instance.cooldownHitCount,
        bleScanCount: MeshMetrics.instance.bleScanCount,
        wifiSentCount: bus.wifiSentCount,
        wifiFailCount: bus.wifiFailCount,
        bleSentCount: bus.bleSentCount,
        bleFailCount: bus.bleFailCount,
        isTransferring: engine?.isTransferring ?? false,
      );

  void resetMetrics() => MeshMetrics.instance.reset();

  void dispose() {
    bus.clear();
    // Do NOT remove the mock - next test's init will overwrite with new bus.
    // Removing causes MissingPluginException for in-flight async sends.
  }
}

class MeshNetworkMetrics {
  final int sendAutoCount;
  final int cascadeStartCount;
  final int cascadeSuccessCount;
  final int cascadeWatchdogCount;
  final int cooldownHitCount;
  final int bleScanCount;
  final int wifiSentCount;
  final int wifiFailCount;
  final int bleSentCount;
  final int bleFailCount;
  final bool isTransferring;

  MeshNetworkMetrics({
    required this.sendAutoCount,
    required this.cascadeStartCount,
    required this.cascadeSuccessCount,
    required this.cascadeWatchdogCount,
    required this.cooldownHitCount,
    required this.bleScanCount,
    required this.wifiSentCount,
    required this.wifiFailCount,
    required this.bleSentCount,
    required this.bleFailCount,
    required this.isTransferring,
  });

  double get deliveryRate {
    final total = wifiSentCount + wifiFailCount;
    return total > 0 ? wifiSentCount / total : 0;
  }
}
