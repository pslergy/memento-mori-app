import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/reverse_path_registry.dart';
import '../features/chat/conversation_screen.dart';
import 'api_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'bluetooth_service.dart';
import 'encryption_service.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'ultrasonic_service.dart';
import 'network_monitor.dart';
import 'gossip_manager.dart';
import 'local_db_service.dart';
import 'router/router_discovery_service.dart';
import 'router/router_connection_service.dart';
import 'repeater_service.dart';
import 'ghost_transfer_manager.dart';
import 'message_sync_service.dart';
import 'network_phase_context.dart';
import 'connection_phase.dart';
import 'ios_edge_beacon_service.dart';
import 'ios_ble_transport.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

enum NodeRole { GHOST, RELAY, BRIDGE }

class RouteInfo {
  final String nodeId;
  int hopsToInternet;
  double batteryLevel;
  DateTime lastSeen;
  int queuePressure; // Загруженность соседа
  /// TTL self-healing: optional bridge token and transport type.
  final String? bridgeToken;
  final String? connectionType; // 'ble' | 'wifi'

  RouteInfo({
    required this.nodeId,
    this.hopsToInternet = 255,
    this.batteryLevel = 1.0,
    required this.lastSeen,
    this.queuePressure = 0,
    this.bridgeToken,
    this.connectionType,
  });

  // Метрика "Качества" узла. Чем ниже, тем лучше узел как ретранслятор.
  double get score =>
      (hopsToInternet * 10) + (1 - batteryLevel) * 5 + (queuePressure * 0.5);
}

class RoutingPulse {
  final String nodeId;
  final int hopsToInternet;
  final double batteryLevel;
  final int queuePressure;

  RoutingPulse({
    required this.nodeId,
    required this.hopsToInternet,
    required this.batteryLevel,
    required this.queuePressure,
  });

  // 🔥 ФИКС: Фабрика для парсинга JSON (используется в MeshService / Wi-Fi)
  factory RoutingPulse.fromJson(Map<String, dynamic> json) {
    return RoutingPulse(
      nodeId: json['nodeId']?.toString() ?? 'unknown',
      hopsToInternet: json['hops'] ?? 255,
      batteryLevel: (json['batt'] ?? 1.0).toDouble(),
      queuePressure: json['press'] ?? 0,
    );
  }

  // 🔥 ФИКС: Фабрика для парсинга байтов (используется в Bluetooth)
  factory RoutingPulse.fromBytes(Uint8List bytes, String remoteId) {
    if (bytes.length < 3) {
      return RoutingPulse(
          nodeId: remoteId,
          hopsToInternet: 255,
          batteryLevel: 0,
          queuePressure: 0);
    }
    return RoutingPulse(
      nodeId: remoteId,
      hopsToInternet: bytes[0],
      batteryLevel: bytes[1] / 100.0,
      queuePressure: bytes[2],
    );
  }

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'hops': hopsToInternet,
        'batt': batteryLevel,
        'press': queuePressure,
      };
}

// Расширение для упаковки в байты (для BLE)
extension RoutingPulseBytes on RoutingPulse {
  Uint8List toBytes() {
    final data = Uint8List(4);
    data[0] = hopsToInternet.clamp(0, 255);
    data[1] = (batteryLevel * 100).toInt().clamp(0, 100);
    data[2] = queuePressure.clamp(0, 255);
    data[3] = math.Random().nextInt(255);
    return data;
  }
}

extension MeshNetworkStarter on TacticalMeshOrchestrator {
  /// 🔥 Полный старт Mesh-сети
  Future<void> startMeshNetwork({BuildContext? context}) async {
    if (!locator.isRegistered<NetworkPhaseContext>()) {
      _log("⚠️ [Mesh] NetworkPhaseContext not registered — skip start");
      return;
    }

    // iOS only: EDGE BEACON — scan-only, no Gossip/Wi-Fi/BLE advertise/cascade/Sonar.
    // Role is fixed IOS_EDGE_BEACON in NetworkMonitor. No timers added to cascade logic.
    if (Platform.isIOS) {
      _log("🍎 [iOS] EDGE BEACON mode — scan + BLE Central transport to Android");
      unawaited(IosEdgeBeaconService().start());
      unawaited(IosBleTransport().start());
      return;
    }

    _log("🚀 Initializing full Mesh network...");
    final phaseCtx = locator<NetworkPhaseContext>();
    phaseCtx.transitionTo(NetworkPhase.localDiscovery);

    // 1️⃣ Старт эпидемического цикла (Gossip)
    _gossip.startEpidemicCycle();
    _log("🦠 Epidemic cycle started");

    // 2️⃣ Старт Wi-Fi Direct / P2P
    _mesh.startDiscovery(SignalType.wifiDirect);
    _log("📡 Wi-Fi Direct discovery started");

    // 2.5️⃣ 🔥 АВТОМАТИЧЕСКОЕ СОЗДАНИЕ WI-FI DIRECT ГРУППЫ (для BRIDGE)
    // Запускаем асинхронно, чтобы не блокировать остальную инициализацию
    unawaited(_autoCreateWifiDirectGroupIfNeeded());

    // 3️⃣ Старт BLE (Control Plane)
    _startBLE();

    // 4️⃣ Sonar (Acoustic Plane) — проверка разрешения
    Future<void> sonarInit() async {
      if (!phaseCtx.allowsSonar) {
        _log("[Sonar][SKIP] init skipped (phase=${phaseCtx.phase})");
        return;
      }
      if (_sonar.isTransmitting) return;

      bool micGranted = await _requestMicrophonePermission(context);
      if (!micGranted) {
        _log("⚠️ Microphone permission denied. Sonar will remain off.");
        return;
      }

      try {
        await _startSonar();
        _log("🔊 Sonar initialized successfully");
      } catch (e) {
        _log("❌ Sonar failed to start: $e");
      }
    }

    // Запускаем Sonar после небольшого джиттера (чтобы BLE и Wi-Fi успели подняться)
    Future.delayed(
        Duration(milliseconds: 1000 + _rng.nextInt(2000)), sonarInit);

    // 5️⃣ Start biological heartbeat
    startBiologicalHeartbeat();
    _log("💓 Biological heartbeat active");

    // 6️⃣ 🔥 Start message sync service (BRIDGE only)
    // Периодически проверяет новые сообщения и отправляет их подключенным устройствам
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      _messageSync.start();
      _log("🔄 Message sync service started (BRIDGE mode)");
    }

    // 6️⃣ Старт отслеживания батареи
    _listenBattery();

    // 7️⃣ 🔥 REPEATER/REPAIR SERVICE - автоматическая ретрансляция и восстановление
    _startRepeaterService();

    // 8️⃣ 🔥 GHOST TRANSFER MANAGER - оптимизированная очередь передачи
    _startGhostTransferManager();

    // 9️⃣ 🔄 Ghost advertising watchdog: если Ghost активен, но advertising остановлен — перезапуск
    _ghostWatchdogTimer?.cancel();
    _ghostWatchdogTimer = Timer.periodic(const Duration(seconds: 15),
        (_) => unawaited(_checkGhostAdvertising()));
    _log("👻 [GHOST] Watchdog started (check every 15s)");
  }

  /// 🔥 Запуск Ghost Transfer Manager
  void _startGhostTransferManager() {
    try {
      final transferManager = locator<GhostTransferManager>();

      if (!transferManager.isRunning) {
        transferManager.start();

        // Загружаем сообщения из outbox
        unawaited(transferManager.loadFromOutbox());

        _log("👻 [TRANSFER-MGR] Ghost Transfer Manager started");
        _log(
            "   📋 Max parallel transfers: ${GhostTransferManager.MAX_PARALLEL_TRANSFERS}");
        _log(
            "   📋 Max queue per BRIDGE: ${GhostTransferManager.MAX_QUEUE_PER_BRIDGE}");
      } else {
        _log("ℹ️ [TRANSFER-MGR] Already running");
      }
    } catch (e) {
      _log("⚠️ [TRANSFER-MGR] Failed to start: $e");
    }
  }

  /// 🔥 Запуск Repeater/Repair Service
  void _startRepeaterService() {
    try {
      final repeater = locator<RepeaterService>();

      if (!repeater.isRunning) {
        repeater.start();
        _log("🔄 [REPEATER] Service started");
        _log(
            "   📋 Max connections: ${RepeaterService.MAX_CONCURRENT_CONNECTIONS}");
        _log(
            "   📋 Repair interval: ${RepeaterService.REPAIR_INTERVAL_SECONDS}s");
      } else {
        _log("ℹ️ [REPEATER] Service already running");
      }
    } catch (e) {
      _log("⚠️ [REPEATER] Failed to start: $e");
    }
  }

  /// 🔹 Запрос разрешения на микрофон (Just-in-time)
  Future<bool> _requestMicrophonePermission(BuildContext? context) async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    _log("📢 Requesting microphone permission...");

    // Показать системный диалог
    final result = await Permission.microphone.request();
    if (result.isGranted) return true;

    // Можно показать SnackBar или диалог для объяснения
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Microphone permission is required for acoustic offline messaging.",
          ),
        ),
      );
    }
    return false;
  }

  /// 🔹 BLE стартер (Control Plane)
  Future<void> _startBLE() async {
    final int pending = await locator<LocalDatabaseService>().getOutboxCount();
    final String myId = await getCurrentUserIdSafe();

    // Безопасное извлечение короткого ID (максимум 4 символа)
    String shortId = myId.isNotEmpty && myId.length >= 4
        ? myId.substring(0, 4)
        : (myId.isNotEmpty ? myId : "GHST");

    // Формат: M_Hops_HasData_ID (максимум ~20 символов для BLE)
    final isRelay = _mesh.isRelayMode;
    String tacticalName = isRelay
        ? "M_255_1_RELAY_$shortId"
        : "M_${_myHopsToInternet}_${pending > 0 ? '1' : '0'}_$shortId";

    final isGhost = NetworkMonitor().currentRole == MeshRole.GHOST;

    if (isGhost) {
      // 🟢 GHOST (или RELAY): Рекламируем и при необходимости сканируем
      _log(
          "📡 [ADV] BLE Pulse: '$tacticalName' (length: ${tacticalName.length})${isRelay ? ' [RELAY]' : ''}");
      await _bt.startAdvertising(tacticalName);
      _log("📡 [GHOST] Advertising started");

      // 🔥 Когда нечего отправлять (pending=0) и не RELAY — только реклама, без скана.
      // Так соседние устройства почти всегда видны тому, кто отправляет (ищет получателя/ретранслятор).
      // На Android во время скана реклама часто недоступна → без скана мы видимы 100% времени.
      if (pending == 0 && !isRelay) {
        _log(
            "📡 [GHOST] No pending — advertising only, staying visible for others (no scan)");
        return;
      }

      // 🔥 КРИТИЧНО: Синхронизация - GHOST сканирует ПОСЛЕ обновления advertising на BRIDGE
      // BRIDGE последовательность: GATT (500ms) → Token (0ms) → Advertising (500ms) → Стабилизация (2000ms)
      // Итого: минимум 3 секунды для полной инициализации BRIDGE
      // GHOST ждет 2 секунды перед сканированием, чтобы BRIDGE успел обновить advertising с токеном
      _log(
          "⏳ [GHOST] Waiting 2s before scan to allow BRIDGE initialization (GATT + Token + Advertising)...");
      _log(
          "   💡 BRIDGE needs time to: 1) Start GATT server, 2) Generate token, 3) Update advertising");
      await Future.delayed(const Duration(milliseconds: 2000));

      // 🔥 ШАГ 2.1: Сканировать не менее 3-5 секунд, сохранять все scanResult
      // Для GHOST с сообщениями - сканируем дольше (30 секунд), RELAY - 8 секунд
      final scanDuration = pending > 0
          ? const Duration(seconds: 30)
          : const Duration(seconds: 8);
      final minScanDuration =
          const Duration(seconds: 5); // Минимум 5 секунд для надежности
      final actualScanDuration =
          scanDuration.inSeconds > minScanDuration.inSeconds
              ? scanDuration
              : minScanDuration;

      _log(
          "🔍 [GHOST] Starting scan for ${actualScanDuration.inSeconds}s (role: GHOST, pending: $pending)");
      _log(
          "   📋 Will save all scanResult, even if localName == EMPTY (checking manufacturerData)");

      try {
        _mesh.startDiscovery(SignalType.bluetooth);
        _log(
            "✅ [GHOST] Discovery started, waiting ${actualScanDuration.inSeconds}s...");
        await Future.delayed(actualScanDuration);
        _log("⏰ [GHOST] Scan duration completed");
      } catch (e) {
        _log("❌ [GHOST] Scan error: $e");
      } finally {
        await _bt.stopAdvertising(keepGattServer: true);
        _log("🛑 [GHOST] Advertising stopped (GATT kept for re-connect)");
        if (isGhost) {
          final againRelay = _mesh.isRelayMode;
          final nameAfter =
              againRelay
                  ? "M_255_1_RELAY_$shortId"
                  : "M_${_myHopsToInternet}_${pending > 0 ? '1' : '0'}_$shortId";
          await _bt.startAdvertising(nameAfter);
          _log("📡 [GHOST] Advertising restarted after scan${againRelay ? ' [RELAY]' : ''}");
        }
      }
    } else {
      // 🟣 BRIDGE: НЕ рекламируем здесь!
      // 🔥 FIX: emitInternetMagnetWave() вызовет startAdvertising() с правильным токеном
      // Если вызвать startAdvertising() здесь с коротким именем (M_0_0_df78),
      // то manufacturerData будет без токена, и GHOST не сможет подключиться!
      _log(
          "🌉 [BRIDGE] Skipping _startBLE() advertising - will be handled by emitInternetMagnetWave()");
      _log(
          "   💡 emitInternetMagnetWave() will call startAdvertising() with proper BRIDGE_TOKEN");
      _log(
          "   💡 This prevents race condition between short name (M_0_0_df78) and full name (M_0_0_BRIDGE_TOKEN)");

      // BRIDGE advertising управляется ТОЛЬКО через emitInternetMagnetWave()
      // Это гарантирует, что токен ВСЕГДА присутствует в manufacturerData
    }
  }

  /// 🔥 АВТОМАТИЧЕСКОЕ СОЗДАНИЕ WI-FI DIRECT ГРУППЫ ДЛЯ BRIDGE
  /// Создает группу автоматически если устройство является BRIDGE
  Future<void> _autoCreateWifiDirectGroupIfNeeded() async {
    final currentRole = NetworkMonitor().currentRole;

    if (currentRole != MeshRole.BRIDGE) {
      _log("ℹ️ [WiFi-Direct] Not BRIDGE, skipping group creation");
      return;
    }
    if (!locator.isRegistered<NetworkPhaseContext>()) return;
    final phaseCtx = locator<NetworkPhaseContext>();
    if (!phaseCtx.allowsWifiDirectGroupCreate) {
      _log(
          "[WiFi-Direct][SKIP] group create skipped (phase=${phaseCtx.phase})");
      return;
    }
    phaseCtx.onWifiLinkSetupStarted();
    _log("🚀 [WiFi-Direct] BRIDGE detected, creating Wi-Fi Direct group...");

    try {
      // Небольшая задержка для стабилизации
      await Future.delayed(const Duration(milliseconds: 500));

      final groupInfo = await NativeMeshService.ensureWifiDirectGroupExists();

      if (groupInfo != null) {
        _log("✅ [WiFi-Direct] Group ready for clients:");
        _log("   📋 SSID: ${groupInfo.networkName}");
        _log(
            "   📋 Passphrase: ${groupInfo.passphrase?.substring(0, (groupInfo.passphrase?.length ?? 0) > 4 ? 4 : (groupInfo.passphrase?.length ?? 0))}...");
        _log("   📋 Owner: ${groupInfo.isGroupOwner ? 'Us' : 'Other device'}");
        _log("   📋 Clients: ${groupInfo.clientCount}");

        // Уведомляем MeshService о созданной группе
        _mesh.onWifiDirectGroupCreated(
          networkName: groupInfo.networkName,
          passphrase: groupInfo.passphrase,
          isGroupOwner: groupInfo.isGroupOwner,
        );
        phaseCtx.onWifiLinkSetupEnded();
      } else {
        phaseCtx.onWifiLinkSetupEnded();
        _log("⚠️ [WiFi-Direct] Failed to create group (fallback: BLE GATT)");
        _log("   💡 GHOST devices will use BLE GATT to connect");
      }
    } catch (e) {
      phaseCtx.onWifiLinkSetupEnded();
      _log("❌ [WiFi-Direct] Group creation error: $e");
      _log("   💡 Fallback: BLE GATT will be used instead of Wi-Fi Direct");
    }
  }
}

class TacticalMeshOrchestrator {
  static final TacticalMeshOrchestrator _instance =
      TacticalMeshOrchestrator._internal();
  factory TacticalMeshOrchestrator() => _instance;
  TacticalMeshOrchestrator._internal();

  final MeshService _mesh = locator<MeshService>();
  final BluetoothMeshService _bt = locator<BluetoothMeshService>();
  final UltrasonicService _sonar = locator<UltrasonicService>();
  final GossipManager _gossip = locator<GossipManager>();
  final ReversePathRegistry reversePath = ReversePathRegistry();
  final MessageSyncService _messageSync = MessageSyncService();

  final Map<String, RouteInfo> _routingTable = {};
  int _myHopsToInternet = 255;

  /// TTL self-healing: remove peers not seen within this period (configurable).
  static const int nodeTimeoutSeconds = 20;
  static Duration get _nodeTimeout => Duration(seconds: nodeTimeoutSeconds);

  Timer? _routingCleanupTimer;

  int get myHops => _myHopsToInternet;

  NodeRole _role = NodeRole.GHOST;
  NodeRole get role => _role;

  double _batteryAvg = 100.0;
  int _messagePressure = 0;

  bool _isRadioAwake = false;
  bool _bleActive = false;
  bool get isBLEActive => _bleActive;
  bool get isSonarActive => _sonar.isTransmitting;

  final _rng = math.Random();
  final List<Future<void> Function()> _burstQueue = [];
  Timer? _heartbeatTimer;

  /// 🔄 Cyclic check: if Ghost active but advertising stopped — restart (every 15s).
  Timer? _ghostWatchdogTimer;

  RouteInfo? getBestUplink() {
    var candidates = _routingTable.values
        .where((r) => r.hopsToInternet < _myHopsToInternet)
        .where((r) => DateTime.now().difference(r.lastSeen) < _nodeTimeout)
        .toList();

    if (candidates.isEmpty) return null;

    // СОРТИРОВКА (Твой вопрос: что делать при равных хопах?)
    candidates.sort((a, b) {
      // 1. Сначала смотрим на хопы (базовый градиент)
      int hopComp = a.hopsToInternet.compareTo(b.hopsToInternet);
      if (hopComp != 0) return hopComp;

      // 2. Если хопы равны — выбираем узел с меньшим давлением очереди (Queue Pressure)
      int pressComp = a.queuePressure.compareTo(b.queuePressure);
      if (pressComp != 0) return pressComp;

      // 3. Если и это равно — берем того, у кого больше батарея
      return b.batteryLevel.compareTo(a.batteryLevel);
    });

    return candidates.first;
  }

  void _log(String m) => print("🧠 [Orchestrator] $m");

  /// 🔄 Ghost watchdog: if Ghost active but advertising stopped — restart (do not block UI).
  Future<void> _checkGhostAdvertising() async {
    if (NetworkMonitor().currentRole != MeshRole.GHOST) return;
    if (!locator.isRegistered<MeshService>() ||
        !locator.isRegistered<BluetoothMeshService>()) return;
    final bt = locator<BluetoothMeshService>();
    final mesh = locator<MeshService>();
    if (bt.state == BleAdvertiseState.advertising ||
        bt.state == BleAdvertiseState.connecting) return;
    if (mesh.isTransferring || mesh.isP2pConnected) return;
    try {
      final pending = await locator<LocalDatabaseService>().getOutboxCount();
      final myId = await getCurrentUserIdSafe();
      final shortId = myId.isNotEmpty && myId.length >= 4
          ? myId.substring(0, 4)
          : (myId.isNotEmpty ? myId : "GHST");
      final tacticalName =
          "M_${_myHopsToInternet}_${pending > 0 ? '1' : '0'}_$shortId";
      await bt.startAdvertising(tacticalName);
      _log("📡 [GHOST] Advertising restarted by watchdog");
    } catch (e) {
      _log("⚠️ [GHOST] Watchdog restart advertising failed: $e");
    }
  }

  /// TTL self-healing: remove expired peers and recalculate routes. Called every 5s.
  void _runRoutingCleanup() {
    final now = DateTime.now();
    final toRemove = <String>[];
    for (final e in _routingTable.entries) {
      if (now.difference(e.value.lastSeen) > _nodeTimeout) {
        toRemove.add(e.key);
      }
    }
    for (final nodeId in toRemove) {
      _routingTable.remove(nodeId);
      _log("[ROUTING] Node expired: $nodeId");
    }
    if (toRemove.isNotEmpty) {
      _routeRecalculation();
    }
  }

  /// Recalculate shortest hop paths and optionally start discovery if upstream lost (only when phase == idle).
  void _routeRecalculation() {
    _updateMyGradient();
    _log("[ROUTING] Recalculated topology");
    final best = getBestUplink();
    if (best != null) return;
    if (!locator.isRegistered<ConnectionPhaseController>()) return;
    if (locator<ConnectionPhaseController>().current != ConnectionPhase.idle) return;
    _mesh.startDiscovery(SignalType.bluetooth);
    _log("[ROUTING] Upstream lost → discovery");
  }

  // ====================== PUBLIC ======================
  void start() {
    _listenBattery();
    _routingCleanupTimer?.cancel();
    _routingCleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) => _runRoutingCleanup());
    // Добавляем Jitter: каждый телефон просыпается в свое время
    final jitter = Duration(milliseconds: _rng.nextInt(5000));
    Future.delayed(Duration(seconds: 2 + _rng.nextInt(10)),
        () => _startBiologicalHeartbeat());
    _log(
        "🧭 [System] Heartbeat initialized with jitter: ${jitter.inMilliseconds}ms");
  }

  // ====================== HEARTBEAT ======================
  void _startBiologicalHeartbeat() {
    _heartbeatTimer?.cancel();

    int nextTick = 20 + _rng.nextInt(20);
    _heartbeatTimer = Timer(Duration(seconds: nextTick), () async {
      await _executeBurstWindow();
      _startBiologicalHeartbeat();
    });
  }

  RoutingPulse generatePulse() {
    return RoutingPulse(
      nodeId: _mesh.apiService.currentUserId.isNotEmpty
          ? _mesh.apiService.currentUserId
          : "GHOST_${_rng.nextInt(9999)}",
      hopsToInternet: _myHopsToInternet,
      batteryLevel: _batteryAvg / 100.0,
      queuePressure: _messagePressure,
    );
  }

// Не забудь добавить Extension (если еще не добавил),
// чтобы превращать пульс в байты для BLE

  void processRoutingPulse(RoutingPulse pulse, {String? connectionType, String? bridgeToken}) {
    _routingTable[pulse.nodeId] = RouteInfo(
      nodeId: pulse.nodeId,
      hopsToInternet: pulse.hopsToInternet,
      batteryLevel: pulse.batteryLevel,
      lastSeen: DateTime.now(),
      queuePressure: pulse.queuePressure,
      bridgeToken: bridgeToken,
      connectionType: connectionType,
    );
    _updateMyGradient();
  }

  /// TTL self-healing: update lastSeen (and optionally connectionType) when a packet is received from this peer.
  void touchPeer(String nodeId, {String? connectionType}) {
    final r = _routingTable[nodeId];
    if (r == null) return;
    _routingTable[nodeId] = RouteInfo(
      nodeId: r.nodeId,
      hopsToInternet: r.hopsToInternet,
      batteryLevel: r.batteryLevel,
      lastSeen: DateTime.now(),
      queuePressure: r.queuePressure,
      bridgeToken: r.bridgeToken,
      connectionType: connectionType ?? r.connectionType,
    );
  }

  Future<void> dispatchMessage(ChatMessage msg) async {
    final db = locator<LocalDatabaseService>();

    // 1. ПРОВЕРКА РОЛИ: Если я BRIDGE и есть ApiService — сразу в облако
    if (_myHopsToInternet == 0 && locator.isRegistered<ApiService>()) {
      _log("🌉 I am BRIDGE. Delivering to Command Center...");
      await locator<ApiService>().syncOutbox();
      return;
    }

    // 2. ТАКТИЧЕСКИЙ РОУТИНГ: Ищем лучший аплинк (ближе к инету)
    final bestNextHop = getBestUplink();

    if (bestNextHop != null) {
      _log(
          "🚀 [Routing] Uplink found: ${bestNextHop.nodeId} (Hops: ${bestNextHop.hopsToInternet})");

      try {
        // Превращаем сообщение в пакет для передачи
        final packetMap = <String, dynamic>{
          'type': 'OFFLINE_MSG',
          'chatId': msg.id, // или твой ChatRoomId
          'content': msg.content,
          'senderId': msg.senderId,
          'timestamp': msg.createdAt.millisecondsSinceEpoch,
          'h': msg.id.hashCode.toString(), // Компактный хеш
          'ttl': 5, // Начальный TTL
        };
        await locator<EncryptionService>().addIdentityLayerIfAvailable(packetMap);
        final packet = jsonEncode(packetMap);

        // Передаем через Native-слой (Wi-Fi Direct)
        // В качестве host используем IP соседа, который ты сохранил в метаданных ноды
        await NativeMeshService.sendTcp(packet, host: bestNextHop.nodeId);

        _log("✅ Signal successfully relayed to next hop.");
      } catch (e) {
        _log("⚠️ Transmission failed: $e. Falling back to Cache.");
        await db.addToOutbox(msg, "GRID_SYNC");
      }
    } else {
      // 3. ИЗОЛЯЦИЯ: Если выхода нет, кладем в инкубатор (Outbox)
      _log("📦 No uplink available. Message incubated in Outbox.");
      await db.saveMessage(msg, "TRANSIT"); // Помечаем как транзитное
      await db.addToOutbox(msg, "TRANSIT");
    }
  }

// Вспомогательный логгер для оркестратора

  void _updateMyGradient() {
    // Если я сам вижу интернет (BRIDGE)
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      if (_myHopsToInternet != 0) {
        _myHopsToInternet = 0;
        _log("⚡ I am the MAGNET (Hops: 0)");
      }
      return;
    }

    // Ищем лучший аплинк в таблице
    int minHopsNearby = 254;
    for (var route in _routingTable.values) {
      if (DateTime.now().difference(route.lastSeen) >= _nodeTimeout) continue;

      if (route.hopsToInternet < minHopsNearby) {
        minHopsNearby = route.hopsToInternet;
      }
    }

    // Мои хопы = хопы лучшего соседа + 1
    int calculatedHops = minHopsNearby + 1;

    if (calculatedHops < _myHopsToInternet) {
      _myHopsToInternet = calculatedHops;
      _log("🧲 Internet Magnet detected! My Hops: $_myHopsToInternet");
      HapticFeedback.lightImpact(); // Вибрация: "Почуял инет"
    }
  }

  // ====================== BURST WINDOW ======================
  Future<void> _executeBurstWindow() async {
    final mesh = locator<MeshService>();

    // 🛡️ ГЛОБАЛЬНЫЙ ЗАМОК: Если мы в процессе коннекта Wi-Fi или данные уже летят - МОЛЧИМ.
    if (mesh.isTransferring ||
        mesh.isP2pConnected ||
        _bt.state == BleAdvertiseState.connecting) {
      _log("🛡️ [Orchestrator] Data Plane active. Aborting background pulse.");
      return;
    }

    // 🛡️ ГВАРД: Полная тишина при активном соединении
    if (_bt.state == BleAdvertiseState.connecting ||
        mesh.isTransferring ||
        mesh.isP2pConnected) {
      _log("🛡️ [Silence] Critical Data Task in progress. Burst aborted.");
      return;
    }

    _log("💓 Burst Wake: Score calculation...");
    _messagePressure = await locator<LocalDatabaseService>().getOutboxCount();

    // 1. Инициализируем список задач ПЕРЕД использованием
    List<Future<void> Function()> tasks = [];

    // Задача: Router Discovery (приоритет 1)
    final routerDiscovery = RouterDiscoveryService();
    final routerConnection = RouterConnectionService();
    if (routerConnection.connectedRouter == null) {
      tasks.add(() async {
        final ts = DateTime.now().toIso8601String();
        _log("[ROUTER-DIAG] Router activation attempt no existing router ts=$ts");
        final bestRouter = await routerDiscovery.findBestRouter();
        if (bestRouter != null && bestRouter.isTrusted) {
          _log(
              "🛰️ [Router] Found best router: ${bestRouter.ssid}, attempting connection...");
          _log("[ROUTER-DIAG] connectToRouter ssid=${bestRouter.ssid} ts=$ts");
          await routerConnection.connectToRouter(bestRouter);
          routerConnection.startConnectionMonitoring();
        }
      });
    } else {
      final ts = DateTime.now().toIso8601String();
      _log("[ROUTER-DIAG] Router activation skip existing router ssid=${routerConnection.connectedRouter?.ssid} ts=$ts");
    }

    // Задача: BLE Beacon
    tasks.add(() async => await _startBLE());

    // Задача: Acoustic Discovery
    if (_batteryAvg > 20) {
      tasks.add(() async => await _startSonar());
    }

    // Задача: Internet Propagation (Magnet Pulse)
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      // 🔥 ШАГ 1.1: Генерация токена за 1-2 секунды до старта BLE advertising
      // Вызываем emitInternetMagnetWave() ПЕРВЫМ, чтобы токен был готов до advertising
      // 1. Сначала генерируем токен и обновляем advertising
      tasks.add(() async {
        _mesh.emitInternetMagnetWave();
      });
      // 2. Затем обрабатываем очередь сообщений от GHOST
      tasks.add(() async => await _processBridgeQueue());
    } else if (_messagePressure > 0) {
      // 🔥 FIX: Для GHOST с pending сообщениями запускаем BLE сканирование
      // seekInternetUplink() вызывает _scanBluetooth(), который теперь проверяет outbox после завершения
      tasks.add(() async => await _mesh.seekInternetUplink());
    }

    // 🔥 ХАОТИЧЕСКИЙ РОУТИНГ
    tasks.shuffle(_rng);

    // 2. Исполнение очереди
    for (var task in tasks) {
      // ПРОВЕРКА ПРЯМО ПЕРЕД ЗАПУСКОМ КАЖДОГО МОДУЛЯ
      final mesh = locator<MeshService>();
      if (_bt.state != BleAdvertiseState.idle || mesh.isTransferring) {
        _log(
            "🚨 [Critical Interruption] Radio is occupied by Data Link. Aborting window.");
        break;
      }

      await task();

      // Длинная пауза между задачами
      await Future.delayed(Duration(milliseconds: 4000 + _rng.nextInt(2000)));
    }

    _log("💤 Hibernation initiated.");
  }

  void updateHops(int newHops, String viaNodeId) {
    if (newHops < _myHopsToInternet) {
      _myHopsToInternet = newHops;
      _log("🧭 Gradient optimized: $_myHopsToInternet hops via $viaNodeId");

      // Форсируем пересчет путей в БД
      _optimizeRoutingPaths(viaNodeId);
    }
  }

  Future<void> _optimizeRoutingPaths([String? preferredUplinkId]) async {
    final db = locator<LocalDatabaseService>();
    final database = await db.database;

    if (preferredUplinkId != null) {
      await database.update('outbox',
          {'preferred_uplink': preferredUplinkId, 'routing_state': 'ROUTING'},
          where: "routing_state = 'PENDING'");
      _log("🧭 Outbox redirected to $preferredUplinkId");
    }
  }

  // ====================== BRIDGE QUEUE PROCESSING ======================
  /// Обрабатывает очередь сообщений от GHOST устройств
  Future<void> _processBridgeQueue() async {
    if (NetworkMonitor().currentRole != MeshRole.BRIDGE) return;

    try {
      final queued = await NativeMeshService.getQueuedMessages();
      if (queued.isEmpty) {
        _log("📦 [Bridge] Queue is empty");
        return;
      }

      _log("📦 [Bridge] Processing ${queued.length} queued messages...");

      if (!locator.isRegistered<ApiService>()) return;
      final api = locator<ApiService>();
      final db = locator<LocalDatabaseService>();

      // Группируем по batch_id для обработки
      final Map<String, List<Map<String, dynamic>>> batches = {};
      for (var msg in queued) {
        final batchId = msg['batchId']?.toString() ?? 'unknown';
        if (!batches.containsKey(batchId)) {
          batches[batchId] = [];
        }
        batches[batchId]!.add(msg);
      }

      // Собираем (batchId, messageIds) для сигнала DELIVERED_TO_CLOUD после sync
      final List<MapEntry<String, List<String>>> batchesWithIds = [];

      // Обрабатываем каждый batch
      for (var entry in batches.entries) {
        final batchId = entry.key;
        final messages = entry.value;
        final List<String> messageIds = [];

        _log(
            "📤 [BRIDGE] Processing batch $batchId (${messages.length} messages)");

        // Парсим и сохраняем сообщения
        for (var msgData in messages) {
          String messageId = 'unknown';
          try {
            final messageJson =
                jsonDecode(msgData['message']?.toString() ?? '{}');
            final chatId =
                messageJson['chatId']?.toString() ?? 'THE_BEACON_GLOBAL';
            final content = messageJson['content']?.toString() ?? '';
            final senderId = messageJson['senderId']?.toString() ?? 'UNKNOWN';
            final timestamp = messageJson['timestamp'] ??
                DateTime.now().millisecondsSinceEpoch;
            messageId =
                (messageJson['h'] ?? messageJson['id'] ?? 'unknown').toString();
            if (messageId != 'unknown') messageIds.add(messageId);

            _log("   📥 [BRIDGE] Processing message from queue:");
            _log(
                "      📋 Message ID: ${messageId.length > 8 ? messageId.substring(0, 8) : messageId}...");
            _log(
                "      📋 Sender: ${senderId.length > 8 ? senderId.substring(0, 8) : senderId}...");
            _log("      📋 Chat ID: $chatId");
            _log("      📋 Content length: ${content.length} bytes");

            // Сохраняем в локальную БД (контент от GHOST может быть уже зашифрован)
            final chatMessage = ChatMessage(
              id: messageJson['id']?.toString() ??
                  'msg_${DateTime.now().millisecondsSinceEpoch}',
              content: content,
              senderId: senderId,
              createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp as int),
              status: 'MESH_RELAY',
            );

            _log("      💾 Saving message to local database...");

            await db.saveMessage(chatMessage, chatId,
                contentAlreadyEncrypted: messageJson['isEncrypted'] == true);
            _log("      ✅ Message saved to local database (chat: $chatId)");
          } catch (e) {
            _log("      ❌ [BRIDGE] Failed to process message: $e");
            _log(
                "      📋 Message ID: ${messageId.length > 8 ? messageId.substring(0, 8) : messageId}...");
          }
        }

        if (messageIds.isNotEmpty) {
          batchesWithIds.add(MapEntry(batchId, messageIds));
        }
      }

      // Отправляем в облако через syncOutbox
      _log("📤 [BRIDGE] Syncing processed messages to cloud...");
      await api.syncOutbox();
      _log("✅ [BRIDGE] Queue processed and synced to cloud successfully");

      // Сигнал DELIVERED_TO_CLOUD: другие узлы снимут эти сообщения с ретрансляции
      for (final batchEntry in batchesWithIds) {
        await _mesh.broadcastDeliveredToCloud(batchEntry.value, batchEntry.key);
      }
    } catch (e) {
      _log("❌ [Bridge] Queue processing error: $e");
    }
  }

  // ====================== SONAR TASK ======================
  Future<void> _startSonar() async {
    if (_bleActive || _bt.isGattConnecting || _bt.isInBleConnectWindow) {
      _log(
          "⏳ Skipping Sonar, BLE connect window active (QUIET_PRE_CONNECT/CONNECTING/DISCOVERING) to avoid HAL_LOCKED.");
      return;
    }
    if (_sonar.isTransmitting) return;

    _log("🔊 Starting Sonar FFT Sweep...");
    try {
      await _sonar.transmitBeacon();
    } catch (e) {
      _log("⚠️ Sonar task failed: $e");
    }
  }

  void startBiologicalHeartbeat() {
    _heartbeatTimer?.cancel();
    // 🔥 MAC RANDOMIZATION FIX: Увеличено с 30s до 60s
    // Каждый heartbeat вызывает emitInternetMagnetWave() который ротирует токен
    // Ротация токена вызывает перезапуск advertising, что на Android меняет MAC
    // 60s даёт GHOST больше времени для connect после обнаружения BRIDGE
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 60), (timer) async {
      // 🔥 SELF-GROWING NETWORK: Автоматическое продвижение GHOST → BRIDGE
      await _evaluateAutoPromotion();

      // 1. Рассылаем пульс (градиент маршрутизации)
      await _broadcastRoutingPulse();

      // 2. Обновляем давление очереди (сколько сообщений ждёт uplink)
      final pending = await LocalDatabaseService().getPendingFromOutbox();
      _messagePressure = pending.length;

      // 3. Если этот узел стал BRIDGE — объявляем себя магнитом и зовём соседей
      if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
        _mesh.emitInternetMagnetWave();
      }
      // 4. Если мы GHOST и в Outbox есть сообщения — активно ищем аплинк через соседей
      else if (_messagePressure > 0) {
        await _mesh.seekInternetUplink();
      }
    });
  }

  Future<void> _broadcastRoutingPulse() async {
    final nodeId = await getCurrentUserIdSafe();
    final pulse = RoutingPulse(
      nodeId: nodeId,
      hopsToInternet: _myHopsToInternet,
      batteryLevel: 0.8, // Сюда подставь реальный заряд батареи
      queuePressure: 0, // Сюда - размер таблицы Outbox
    );

    // Шлем этот пульс всем соседям через BLE (50 байт как ты и хотел)
    // locator<BluetoothMeshService>().broadcastPulse(pulse);
    _log("💓 Heartbeat: My hops = $_myHopsToInternet");
  }

  // ====================== HIBERNATION ======================
  Future<void> _hibernate() async {
    _isRadioAwake = false;
    _log("💤 [Stealth] Radio hibernation initiated.");
  }

  // ====================== ROLE MANAGEMENT ======================
  void _promoteToBridge() {
    if (_role == NodeRole.BRIDGE) return;
    _role = NodeRole.BRIDGE;
    _myHopsToInternet = 0; // BRIDGE имеет 0 hops до интернета
    _log("🚀 Elevated to BRIDGE. Acting as Internet Gateway.");
  }

  void _stepDown() {
    if (_role == NodeRole.GHOST) return;
    _role = NodeRole.GHOST;
    _myHopsToInternet = 255; // GHOST не имеет прямого доступа к интернету
    _log("👻 Stepping down to GHOST.");
  }

  // 🔥 SELF-GROWING NETWORK: Автоматическое продвижение GHOST → BRIDGE
  /// Оценивает, должен ли узел автоматически стать BRIDGE
  /// Вызывается в heartbeat цикле для саморастущей сети
  Future<void> _evaluateAutoPromotion() async {
    final networkMonitor = NetworkMonitor();
    final currentRole = networkMonitor.currentRole;

    // Если мы GHOST, но видим интернет через роутер - автоматически становимся BRIDGE
    if (currentRole == MeshRole.GHOST) {
      final routerService = RouterConnectionService();
      final connectedRouter = routerService.connectedRouter;

      if (connectedRouter != null && connectedRouter.hasInternet) {
        final ts = DateTime.now().toIso8601String();
        _log("[ROUTER-DIAG] Router activation auto-promoted BRIDGE ssid=${connectedRouter.ssid} hasInternet=true localIp=${connectedRouter.ipAddress} ts=$ts");
        // 🔥 SELF-GROWING: Автоматическое продвижение
        _promoteToBridge();
        _mesh.emitInternetMagnetWave(); // Метод void, вызываем напрямую
        _log("🚀 [SELF-GROWING] Auto-promoted to BRIDGE (router has internet)");

        // Запускаем message sync service для BRIDGE
        try {
          _messageSync.start();
          _log(
              "🔄 [SELF-GROWING] Message sync service started (auto-promoted BRIDGE)");
        } catch (e) {
          _log(
              "⚠️ [SELF-GROWING] Message sync service already running or error: $e");
        }
      }
    }

    // Если мы BRIDGE, но потеряли интернет - автоматически становимся GHOST
    if (currentRole == MeshRole.BRIDGE) {
      // NetworkMonitor уже проверяет интернет, но мы можем добавить дополнительную проверку
      final routerService = RouterConnectionService();
      final connectedRouter = routerService.connectedRouter;

      // Если роутер отключен и нет прямого интернета - становимся GHOST
      if (connectedRouter == null || !connectedRouter.hasInternet) {
        final ts = DateTime.now().toIso8601String();
        _log("[ROUTER-DIAG] Router stepDown check connectedRouter=${connectedRouter != null} hasInternet=${connectedRouter?.hasInternet} ts=$ts");
        // Проверяем прямой интернет через NetworkMonitor
        await networkMonitor.checkNow();
        if (networkMonitor.currentRole == MeshRole.GHOST) {
          _stepDown();
          _log("[ROUTER-DIAG] Router stepDown applied reason=internet_lost ts=$ts");
          _log("👻 [SELF-GROWING] Auto-stepped down to GHOST (internet lost)");

          // Останавливаем message sync service
          try {
            _messageSync.stop();
            _log(
                "🛑 [SELF-GROWING] Message sync service stopped (stepped down to GHOST)");
          } catch (e) {
            _log(
                "⚠️ [SELF-GROWING] Message sync service stop error (may not be running): $e");
          }
        }
      }
    }
  }

  // ====================== ENVIRONMENT EVALUATION ======================
  Future<int> _evaluateEnvironment() async {
    int score = 0;

    final pending = await LocalDatabaseService().getPendingFromOutbox();
    _messagePressure = pending.length;

    if (_batteryAvg > 80) score += 2;
    if (_batteryAvg < 20) score -= 4;

    if (_mesh.nearbyNodes.length > 2) score += 2;

    if (_messagePressure > 10) score += 2;

    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) score += 5;

    return score;
  }

  // ====================== INTERNET NODE SEARCH ======================
  SignalNode? _findNodeWithInternet() {
    for (var node in _mesh.nearbyNodes) {
      // Считаем, что cloud-узел имеет интернет
      if (node.type == SignalType.cloud) return node;
    }
    return null;
  }

  // ====================== SIGNAL DISPATCH ======================
  Future<void> dispatchSignal(String content, {int priority = 1}) async {
    if (priority == 0) {
      _log("🚨 [CRITICAL] SOS Signal! Bypassing Duty Cycle...");
      await _executeBurstWindow();
    }

    _mesh.sendAuto(
        content: content,
        receiverName: "Broadcast",
        chatId: "THE_BEACON_GLOBAL");

    if (_messagePressure > 15 && _batteryAvg > 40) {
      _mesh.seekInternetUplink();
    }
  }

  // ====================== BATTERY MONITOR ======================
  void _listenBattery() {
    Battery().onBatteryStateChanged.listen((state) async {
      final level = await Battery().batteryLevel;
      _batteryAvg = (_batteryAvg * 0.9) + (level * 0.1);
    });
  }
}

// ====================== Модель Node ======================
class MeshNode {
  final String name;
  final bool hasInternet;
  MeshNode({required this.name, this.hasInternet = false});
}
