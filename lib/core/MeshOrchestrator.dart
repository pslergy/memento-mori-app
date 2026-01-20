import 'dart:async';
import 'dart:convert';
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
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'ultrasonic_service.dart';
import 'network_monitor.dart';
import 'gossip_manager.dart';
import 'local_db_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum NodeRole { GHOST, RELAY, BRIDGE }


class RouteInfo {
  final String nodeId;
  int hopsToInternet;
  double batteryLevel;
  DateTime lastSeen;
  int queuePressure; // Загруженность соседа

  RouteInfo({
    required this.nodeId,
    this.hopsToInternet = 255,
    this.batteryLevel = 1.0,
    required this.lastSeen,
    this.queuePressure = 0,
  });

  // Метрика "Качества" узла. Чем ниже, тем лучше узел как ретранслятор.
  double get score => (hopsToInternet * 10) + (1 - batteryLevel) * 5 + (queuePressure * 0.5);
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
      return RoutingPulse(nodeId: remoteId, hopsToInternet: 255, batteryLevel: 0, queuePressure: 0);
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
    _log("🚀 Initializing full Mesh network...");

    // 1️⃣ Старт эпидемического цикла (Gossip)
    _gossip.startEpidemicCycle();
    _log("🦠 Epidemic cycle started");

    // 2️⃣ Старт Wi-Fi Direct / P2P
    _mesh.startDiscovery(SignalType.wifiDirect);
    _log("📡 Wi-Fi Direct discovery started");

    // 3️⃣ Старт BLE (Control Plane)
    _startBLE();

    // 4️⃣ Sonar (Acoustic Plane) — проверка разрешения
    Future<void> sonarInit() async {
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
    Future.delayed(Duration(milliseconds: 1000 + _rng.nextInt(2000)), sonarInit);

    // 5️⃣ Start biological heartbeat
    startBiologicalHeartbeat();
    _log("💓 Biological heartbeat active");

    // 6️⃣ Старт отслеживания батареи
    _listenBattery();
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
    String myId = _mesh.apiService.currentUserId;
    String shortId = myId.length > 4 ? myId.substring(0, 4) : "GHST";

    // Формат: M_Hops_HasData_ID
    String tacticalName = "M_${_myHopsToInternet}_${pending > 0 ? '1' : '0'}_$shortId";
    _log("📡 BLE Pulse: $tacticalName");

    await _bt.startAdvertising(tacticalName);
    // Скан на 8 секунд
    _mesh.startDiscovery(SignalType.bluetooth);
    await Future.delayed(const Duration(seconds: 8));
    await _bt.stopAdvertising();
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

  final Map<String, RouteInfo> _routingTable = {};
  int _myHopsToInternet = 255;

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

  RouteInfo? getBestUplink() {
    var candidates = _routingTable.values
        .where((r) => r.hopsToInternet < _myHopsToInternet)
        .where((r) => DateTime.now().difference(r.lastSeen).inMinutes < 2)
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


  // ====================== PUBLIC ======================
  void start() {
    _listenBattery();
    // Добавляем Jitter: каждый телефон просыпается в свое время
    final jitter = Duration(milliseconds: _rng.nextInt(5000));
    Future.delayed(Duration(seconds: 2 + _rng.nextInt(10)), () => _startBiologicalHeartbeat());
    _log("🧭 [System] Heartbeat initialized with jitter: ${jitter.inMilliseconds}ms");
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


  void processRoutingPulse(RoutingPulse pulse) {
    _routingTable[pulse.nodeId] = RouteInfo(
      nodeId: pulse.nodeId,
      hopsToInternet: pulse.hopsToInternet,
      batteryLevel: pulse.batteryLevel,
      lastSeen: DateTime.now(),
      queuePressure: pulse.queuePressure,
    );
    _updateMyGradient();
  }

  Future<void> dispatchMessage(ChatMessage msg) async {
    final api = locator<ApiService>();
    final db = locator<LocalDatabaseService>();

    // 1. ПРОВЕРКА РОЛИ: Если я BRIDGE — сразу в облако
    if (_myHopsToInternet == 0) {
      _log("🌉 I am BRIDGE. Delivering to Command Center...");

      // Используем твой механизм синхронизации
      await api.syncOutbox();
      return;
    }

    // 2. ТАКТИЧЕСКИЙ РОУТИНГ: Ищем лучший аплинк (ближе к инету)
    final bestNextHop = getBestUplink();

    if (bestNextHop != null) {
      _log("🚀 [Routing] Uplink found: ${bestNextHop.nodeId} (Hops: ${bestNextHop.hopsToInternet})");

      try {
        // Превращаем сообщение в пакет для передачи
        final packet = jsonEncode({
          'type': 'OFFLINE_MSG',
          'chatId': msg.id, // или твой ChatRoomId
          'content': msg.content,
          'senderId': msg.senderId,
          'timestamp': msg.createdAt.millisecondsSinceEpoch,
          'h': msg.id.hashCode.toString(), // Компактный хеш
          'ttl': 5, // Начальный TTL
        });

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
      // Aging: если соседа не видели > 2 минут, не верим ему
      if (DateTime.now().difference(route.lastSeen).inMinutes > 2) continue;

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
    if (mesh.isTransferring || mesh.isP2pConnected || _bt.state == BleAdvertiseState.connecting) {
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

    // Задача: BLE Beacon
    tasks.add(() async => await _startBLE());

    // Задача: Acoustic Discovery
    if (_batteryAvg > 20) {
      tasks.add(() async => await _startSonar());
    }

    // Задача: Internet Propagation (Magnet Pulse)
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      tasks.add(() async => _mesh.emitInternetMagnetWave());
    } else if (_messagePressure > 0) {
      tasks.add(() async => await _mesh.seekInternetUplink());
    }

    // 🔥 ХАОТИЧЕСКИЙ РОУТИНГ
    tasks.shuffle(_rng);

    // 2. Исполнение очереди
    for (var task in tasks) {
      // ПРОВЕРКА ПРЯМО ПЕРЕД ЗАПУСКОМ КАЖДОГО МОДУЛЯ
      final mesh = locator<MeshService>();
      if (_bt.state != BleAdvertiseState.idle || mesh.isTransferring) {
        _log("🚨 [Critical Interruption] Radio is occupied by Data Link. Aborting window.");
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
          {
            'preferred_uplink': preferredUplinkId,
            'routing_state': 'ROUTING'
          },
          where: "routing_state = 'PENDING'"
      );
      _log("🧭 Outbox redirected to $preferredUplinkId");
    }
  }



  // ====================== SONAR TASK ======================
  Future<void> _startSonar() async {
    if (_bleActive) {
      _log("⏳ Skipping Sonar, BLE is active to avoid HAL_LOCKED.");
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
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _broadcastRoutingPulse();
    });
  }

  void _broadcastRoutingPulse() {
    final pulse = RoutingPulse(
      nodeId: locator<ApiService>().currentUserId,
      hopsToInternet: _myHopsToInternet,
      batteryLevel: 0.8, // Сюда подставь реальный заряд батареи
      queuePressure: 0,   // Сюда - размер таблицы Outbox
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
    _log("🚀 Elevated to BRIDGE. Acting as Internet Gateway.");
  }

  void _stepDown() {
    if (_role == NodeRole.GHOST) return;
    _role = NodeRole.GHOST;
    _log("👻 Stepping down to GHOST.");
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
        content: content, receiverName: "Broadcast", chatId: "THE_BEACON_GLOBAL");

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
