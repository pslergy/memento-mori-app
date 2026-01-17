import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../features/chat/conversation_screen.dart';
import 'MeshOrchestrator.dart';
import 'api_service.dart';
import 'background_service.dart';
import 'encryption_service.dart';
import 'gossip_manager.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_protocol.dart';
import 'models/ad_packet.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'network_monitor.dart';
import 'websocket_service.dart';
import 'bluetooth_service.dart';


enum MeshState {
  idle,
  advertising,
  scanning,
  connecting,
  transferring,
  hibernating,
}

enum MeshPacketType {
  PROXY_REQUEST,  // Призрак просит Мост выполнить запрос
  PROXY_RESPONSE, // Мост возвращает ответ Призраку
}

class MeshService with ChangeNotifier {
  static final MeshService _instance = MeshService._internal();
  factory MeshService() => _instance;
  MeshService._internal();
  GossipManager get _gossipManager => locator<GossipManager>();

  final BluetoothMeshService _btService = BluetoothMeshService();
  final ApiService _apiService = ApiService();
  final LocalDatabaseService _db = locator<LocalDatabaseService>();
  final math.Random _rng = math.Random(); // Добавь эту строку
  ApiService get apiService => _apiService;
  // Состояние обнаруженных узлов (Радар)
  final Map<String, SignalNode> _nearbyNodes = {};
  final Map<String, int> _lastSeenTimestamps = {};

  MeshState _state = MeshState.idle;
  final _stateLock = Object();
  // 🔒 Защита от параллельных сканов
  final Object _scanLock = Object();

  // 🔁 Таймер периодического сканирования
  Timer? _scanTimer;


  bool _isBtScanning = false;
  LocalDatabaseService get db => _db;

  // Геттеры для UI
  List<SignalNode> get nearbyNodes => _nearbyNodes.values.toList();
  bool get isP2pConnected => _isP2pConnected;
  bool get isHost => _isHost;

  // Потоки данных

  StreamSubscription<List<ScanResult>>? _scanSub;


  final StreamController<String> _linkRequestController = StreamController.broadcast();
  Stream<String> get linkRequestStream => _linkRequestController.stream;

  final StreamController<List<SignalNode>> _discoveryController = StreamController.broadcast();
  Stream<List<SignalNode>> get discoveryStream => _discoveryController.stream;

  final StreamController<Map<String, dynamic>> _messageController = StreamController.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<String> _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  StreamController<Map<String, dynamic>> get messageController => _messageController;

  Timer? _cleanupTimer;
  bool _isP2pConnected = false;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final String _baseUrl = 'https://89.125.131.63:3000/api';

  bool autoMesh = true;
  bool autoBT = true;
  bool _isMeshEnabled = true; // Главный тумблер всей системы связи
  bool _isPowerSaving = true;

  // Состояние "Магнита"
  int _myDistanceToBridge = 99; // 0 = инет есть, 1 = вижу инет, 99 = изоляция
  bool _isSearchingUplink = false;
  bool get isSearchingUplink => _isSearchingUplink;

  bool get isMeshEnabled => _isMeshEnabled;
  bool get isPowerSaving => _isPowerSaving;

  StreamSubscription? _accelSub;

  StreamSubscription? _accelerometerSub;
  Timer? _adaptiveTimer;
  bool _isMoving = false;

  bool _isGpsEnabled = true;
  bool get isGpsEnabled => _isGpsEnabled;
  bool _isTacticalQuietMode = false;



  final Battery _battery = Battery();

  Future<Map<String, dynamic>> getBatteryStatus() async {
    return {
      'level': await _battery.batteryLevel,
      'isCharging': (await _battery.batteryState) == BatteryState.charging,
    };
  }

  // --- СИСТЕМА ОБНАРУЖЕНИЯ И ОЧИСТКИ ---

  Future<void> initBackgroundProtocols() async {
    _log("⚙️ Activating Autonomous Link...");

    // 🔥 РЕШЕНИЕ ОШИБКИ И СТАБИЛИЗАЦИЯ ТЕХНО
    try {
      await WakelockPlus.enable();
    } catch (e) {
      _log("⚠️ Wakelock not supported");
    }

    await BackgroundService.start();

    if (autoMesh) startDiscovery(SignalType.mesh);
    if (autoBT) startDiscovery(SignalType.bluetooth);

    // Запуск автоматической очистки пропавших узлов (раз в 15 сек)
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _performCleanup());
  }

  Future<void> activateGroosaProtocol() async {
    _log("🚀 ACTIVATING GROOSA: Engaging all L0/L2 layers...");

    // 1. Включаем L0 (Звук)
    await locator<UltrasonicService>().startListening();

    // 2. Включаем L2 BLE (Прием + Передача)
    // Мы запускаем скан, а внутри _scanBluetooth уже есть startAdvertising
    _scanBluetooth();

    // 3. Включаем L2 Wi-Fi (P2P Discovery)
    await NativeMeshService.startDiscovery();

    // 4. Запускаем фоновый сервис, чтобы Android не убил "Спящего Агента"
    await NativeMeshService.startBackgroundMesh();

    _log("✅ GROOSA ACTIVE: Node is now a fully functional Relay.");
    notifyListeners();
  }

  void addLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    print("[Mesh Log] $msg");

    // Добавляем в поток для терминала
    _statusController.add("$timestamp > $msg");

    // Уведомляем UI (через Provider), что состояние обновилось
    notifyListeners();
  }



  void _performCleanup() {
    final now = DateTime.now().millisecondsSinceEpoch;
    bool changed = false;

    // Если нода не подавала сигнал более 45 секунд — удаляем
    _lastSeenTimestamps.removeWhere((id, timestamp) {
      if (now - timestamp > 45000) {
        _nearbyNodes.remove(id);
        changed = true;
        return true;
      }
      return false;
    });

    if (changed) {
      _discoveryController.add(nearbyNodes);
      notifyListeners();
    }
  }

  Future<void> _incrementKarma(int amount) async {
    try {
      final db = await LocalDatabaseService().database;
      // Используем одинарные кавычки для 'karma'
      await db.rawUpdate(
          "UPDATE system_stats SET value = value + ? WHERE key = 'karma'",
          [amount]
      );
    } catch (e) {
      print("⚠️ Karma sync deferred.");
    }
  }

  void toggleTacticalQuietMode(bool value) {
    _isTacticalQuietMode = value;
    _log("🤫 Tactical Quiet Mode: ${value ? 'ACTIVE' : 'OFF'}");
    // Если включен - уменьшаем мощность передатчика или частоту маяков
  }

  /// Умный лимит трафика для Моста


  Future<void> handleProxyWithFairUse(MeshPacket packet) async {
    // 1. Проверяем Карму отправителя (она должна быть в пакете)
    final int peerKarma = packet.payload['karma'] ?? 0;

    // 2. Если Карма низкая (< 5), ставим искусственную задержку
    // Это защищает Мост от DDoS и стимулирует людей помогать другим
    if (peerKarma < 5) {
      _log("⏳ Low Karma node detected. Throttling request...");
      await Future.delayed(const Duration(seconds: 5));
    }

    // 3. Выполняем проксирование
    _handleProxyRequest(packet); // Передаем объект дальше
  }

  // Центральный метод регистрации найденной ноды
  void _registerNode(SignalNode node) {
    _nearbyNodes[node.id] = node;
    _lastSeenTimestamps[node.id] = DateTime.now().millisecondsSinceEpoch;

    _discoveryController.add(nearbyNodes);
    notifyListeners(); // Обновляет экран "The Chain"
  }

  void handleNativePeers(List<dynamic> raw) {
    for (var item in raw) {
      // Ключевое исправление: проверяем все возможные ключи адреса
      final String address = item['metadata'] ?? item['id'] ?? item['address'] ?? "";

      if (address.isEmpty) continue; // Не добавляем "битые" ноды

      final node = SignalNode(
          id: address,
          name: item['name'] ?? 'P2P Node',
          type: SignalType.mesh,
          metadata: address // Сохраняем MAC-адрес здесь
      );
      _registerNode(node);
    }
  }

  void broadcastEmergencyHeartbeat() async {
    final deathDateStr = await Vault.read('user_deathDate');
    final deathDate = DateTime.parse(deathDateStr!);
    final remaining = deathDate.difference(DateTime.now()).inDays;

    // Если осталось менее 1000 дней — Сонар кричит "Low Essence"
    if (remaining < 1000) {
      locator<UltrasonicService>().transmitFrame("LOW_ESSENCE:${remaining}");
      _log("🔊 Critical Heartbeat emitted via Sonar.");
    }
  }

  void handleIncomingLinkRequest(String senderId) {
    _log("🤝 Incoming link request from Nomad #$senderId");
    // Посылаем ID отправителя в UI-стрим
    _linkRequestController.add(senderId);
  }

  // --- УМНАЯ ОТПРАВКА (Cloud <-> Mesh) ---

  /// Умная тактическая отправка (Cloud + Mesh + Sonar)
  /// Умная тактическая отправка (Cloud + Mesh + Bluetooth + Sonar)
  /// Оптимизирована для предотвращения коллизий и перегрузки стека.
  Future<void> sendAuto({
    required String content,
    String? chatId,
    required String receiverName,
  }) async {
    final currentRole = NetworkMonitor().currentRole;
    final encryption = locator<EncryptionService>();
    final api = locator<ApiService>();
    final sonar = locator<UltrasonicService>();

    // 1. УНИФИКАЦИЯ ID: Гарантируем работу через системный Маяк
    final String targetId = (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL" || chatId == null)
        ? "THE_BEACON_GLOBAL"
        : chatId;

    _log("🚀 Initiating Multi-Channel Uplink for: $targetId");

    // 2. КРИПТОГРАФИЯ: Готовим зашифрованный пакет (E2EE)
    final key = await encryption.getChatKey(targetId);
    final encryptedContent = await encryption.encrypt(content, key);
    final String tempId = "temp_${DateTime.now().millisecondsSinceEpoch}";

    final offlinePacket = jsonEncode({
      'type': 'OFFLINE_MSG',
      'chatId': targetId,
      'content': encryptedContent,
      'isEncrypted': true,
      'senderId': api.currentUserId.isNotEmpty ? api.currentUserId : "GHOST_NODE",
      'senderUsername': "Nomad",
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'clientTempId': tempId,
      'ttl': 5, // Начальный TTL для Gossip-паутины
    });

    // ==========================================
    // 🌐 КАНАЛ 1: CLOUD (Uplink via Bridge)
    // ==========================================
    if (currentRole == MeshRole.BRIDGE) {
      try {
        await WebSocketService().ensureConnected();
        await WebSocketService().send({
          "type": "message",
          "chatId": targetId,
          "content": content, // Внутренний метод WebSocket сам зашифрует
          "clientTempId": tempId,
        });
        _log("☁️ Cloud: Signal delivered to Command Center.");
      } catch (e) {
        _log("⚠️ Cloud: Relay failed, relying on Mesh.");
      }
    }

    // ==========================================
    // 👻 КАНАЛ 2: MESH (Wi-Fi Direct) - HIGH SPEED
    // ==========================================
    // Мы шлем через TCP только если физический линк установлен И маршрут "прогрет"
    if (_isP2pConnected && isRouteReady) {
      _log("📡 Mesh: Route is stable. Emitting TCP bursts...");
      // Используем sendTcpBurst (он внутри делает 3 попытки)
      await sendTcpBurst(offlinePacket);
    } else if (_isP2pConnected && !isRouteReady) {
      _log("⏳ Mesh: Link detected but route warming up. Skipping TCP.");
    }

    // ==========================================
    // 🦷 КАНАЛ 3: BLUETOOTH (Queue Mode)
    // ==========================================
    // Используем твою новую ОЧЕРЕДЬ, чтобы не "взорвать" Bluetooth чип
    final bluetoothNodes = _nearbyNodes.values.where((n) => n.type == SignalType.bluetooth).toList();

    if (bluetoothNodes.isNotEmpty) {
      _log("🦷 BT: Injecting packet into Serial Queue for ${bluetoothNodes.length} nodes.");
      for (var node in bluetoothNodes) {
        // Мы используем sendMessage, которую ты реализовал с очередью и ретраями
        _btService.sendMessage(BluetoothDevice.fromId(node.id), offlinePacket);
      }
    }

    // ==========================================
    // 🔊 КАНАЛ 4: SONAR (Acoustic Backup)
    // ==========================================
    bool isEmergency = content.toUpperCase().contains("SOS") || targetId == "THE_BEACON_GLOBAL";

    // Эскалация до Сонара только для SOS или очень коротких сообщений (до 64 символов)
    if (isEmergency || content.length < 64) {
      _log("🔊 Sonar: Escalating to Acoustic Link...");
      unawaited(sonar.transmitFrame(content));
    }

    // 3. ИНКУБАЦИЯ: Сохраняем в Outbox (Для Gossip-паутины)
    // Если мы GHOST или линк нестабилен, сообщение должно "жить" в БД
    final db = LocalDatabaseService();
    final myMsg = ChatMessage(
        id: tempId,
        content: content,
        senderId: api.currentUserId,
        createdAt: DateTime.now(),
        status: (currentRole == MeshRole.BRIDGE) ? "SENT" : "PENDING_RELAY"
    );

    await db.saveMessage(myMsg, targetId);

    if (currentRole == MeshRole.GHOST) {
      await db.addToOutbox(myMsg, targetId);
      _log("🦠 Virus: Signal incubated in Outbox.");
    }
  }






  /// Метод активного поиска интернета через узлы
  Future<void> seekInternetUplink() async {
    if (_isSearchingUplink) return;
    _isSearchingUplink = true;
    notifyListeners();

    _log("📡 [Uplink-Seeker] Probing neighbors for internet access...");

    // 1. Сначала проверяем себя (вдруг инет уже есть)
    await NetworkMonitor().checkNow();
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      _log("✅ Internet found on this device.");
      _isSearchingUplink = false;
      notifyListeners();
      return;
    }

    // 2. Рассылаем запрос "Кто видит мост?"
    final probe = jsonEncode({
      'type': 'MAGNET_QUERY',
      'senderId': _apiService.currentUserId,
    });

    for (var node in _nearbyNodes.values) {
      NativeMeshService.sendTcp(probe, host: node.metadata);
    }

    // 3. Таймаут поиска (30 секунд)
    Timer(const Duration(seconds: 30), () {
      _isSearchingUplink = false;
      notifyListeners();
      _log("⌛ Uplink probe cycle completed.");
    });
  }

  // --- СЕТЕВАЯ ЛОГИКА ---

  Future<void> startDiscovery(SignalType type) async {
    if (!_isMeshEnabled) return;

    // 🔥 ПРОВЕРКА GPS ДЛЯ BLUETOOTH
    if (type == SignalType.bluetooth || type == SignalType.mesh) {
      bool gpsStatus = await Geolocator.isLocationServiceEnabled();
      if (_isGpsEnabled != gpsStatus) {
        _isGpsEnabled = gpsStatus;
        notifyListeners(); // Уведомляем UI, чтобы показать ошибку
      }

      if (!gpsStatus) {
        _log("❌ Scan blocked: GPS is OFF. Please enable Location.");
        return;
      }
    }

    _log("📡 Scanning: ${type.name.toUpperCase()}");
    if (type == SignalType.mesh) NativeMeshService.startDiscovery();
    if (type == SignalType.bluetooth) _scanBluetooth();
  }

  // Добавь проверку в метод инициализации, чтобы сразу знать статус
  Future<void> checkHardwareStatus() async {
    _isGpsEnabled = await Geolocator.isLocationServiceEnabled();
    notifyListeners();
  }


  // 🔥 ТЕПЕРЬ ЭТО FUTURE, чтобы BackgroundService мог его "ждать"
  Future<void> stopDiscovery() async {
    await NativeMeshService.stopDiscovery();
    await FlutterBluePlus.stopScan();

    await _scanSub?.cancel();
    _scanSub = null;

    _log("🛑 Scanners paused.");
  }

  void _scanCloud() async {
    try {
      final branches = await _apiService.getTrendingBranches();
      for (var b in branches) {
        _registerNode(SignalNode(
            id: b['id'],
            name: b['name'] ?? 'Frequency',
            type: SignalType.cloud,
            isGroup: true,
            metadata: 'STABLE'
        ));
      }
    } catch (e) {
      _log("❌ Cloud frequency scan failed.");
    }
  }

  // Добавь это поле в начало класса MeshService для контроля повторных попыток
  final Map<String, DateTime> _linkCooldowns = {};

  // Карта кулдаунов, чтобы не спамить одну и ту же ноду каждые 2 секунды


  // Карта кулдаунов (MAC-адрес -> время последней попытки)







  Future<void> _scanBluetooth() async {
    if (!_isMeshEnabled || _isBtScanning) return;
    _isBtScanning = true;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _log("❌ Bluetooth Scan blocked: GPS is OFF");
        _isBtScanning = false;
        return;
      }

      final orchestrator = locator<TacticalMeshOrchestrator>();
      final db = locator<LocalDatabaseService>();
      final int pendingCount = await db.getOutboxCount();

      // 1. ПОДГОТОВКА ТАКТИЧЕСКОГО МАЯКА (Advertising)
      final String myShortId = _apiService.currentUserId.isNotEmpty
          ? _apiService.currentUserId.substring(0, 4)
          : "GHST";
      final String myTacticalName = "M_${orchestrator.myHops}_${pendingCount > 0 ? '1' : '0'}_$myShortId";

      _log("🦷 Pulsing Tactical Beacon: $myTacticalName");

      // Сбрасываем старую рекламу перед новой
      await _btService.stopAdvertising();
      await Future.delayed(const Duration(milliseconds: 200));
      await _btService.startAdvertising(myTacticalName);

      // 2. ОЧИСТКА СЛУШАТЕЛЕЙ
      await _scanSub?.cancel();
      _scanSub = null;
      await FlutterBluePlus.stopScan();

      // 3. ОБРАБОТКА ЭФИРА (Discovery & Hop Protocol)
      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          // Фильтр по нашему Service UUID
          if (!r.advertisementData.serviceUuids.contains(Guid(_btService.SERVICE_UUID))) continue;

          final String advName = r.advertisementData.localName;
          final String mac = r.device.remoteId.str;

          int peerHops = 99;
          bool peerHasData = false;
          String peerId = mac.substring(mac.length - 4);

          // Разбор тактического имени соседа
          if (advName.startsWith("M_")) {
            final parts = advName.split("_");
            if (parts.length >= 4) {
              peerHops = int.tryParse(parts[1]) ?? 99;
              peerHasData = parts[2] == "1";
              peerId = parts[3];
            }
          }

          // --- ШАГ А: ОБНОВЛЕНИЕ ГРАДИЕНТА (Zero-Connect) ---
          // Мы узнаем о близости выхода мгновенно из пакета рекламы
          orchestrator.processRoutingPulse(RoutingPulse(
            nodeId: peerId,
            hopsToInternet: peerHops,
            batteryLevel: 1.0,
            queuePressure: peerHasData ? 1 : 0,
          ));

          _registerNode(SignalNode(
              id: mac,
              name: "Nomad_$peerId",
              type: SignalType.bluetooth,
              metadata: mac,
              bridgeDistance: peerHops
          ));

          // --- ШАГ Б: ПРИНЯТИЕ РЕШЕНИЯ ОБ ЭСКАЛАЦИИ ---
          final lastAttempt = _linkCooldowns[mac];
          final bool isInCooldown = lastAttempt != null &&
              DateTime.now().difference(lastAttempt).inSeconds < 45;

          if (isInCooldown || _btService.state == BleAdvertiseState.connecting) continue;

          // Условие для перехвата данных (Я - Мост, у соседа есть данные)
          bool shouldPull = (orchestrator.myHops == 0 && peerHasData);

          // Условие для сброса данных (У меня есть данные, сосед ближе к инету)
          bool shouldPush = (pendingCount > 0 && peerHops < orchestrator.myHops);

          if (shouldPull || shouldPush) {
            // 🔥 АТОМНЫЙ ЗАМОК: Предотвращаем GATT-шторм
            _linkCooldowns[mac] = DateTime.now();

            // 🔥 ПОЛНАЯ ТИШИНА: Выключаем всё радио перед коннектом
            await _scanSub?.cancel();
            _scanSub = null;
            await FlutterBluePlus.stopScan();
            await _btService.stopAdvertising();
            await Future.delayed(const Duration(milliseconds: 1000));

            if (shouldPull) {
              _log("🧲 [Bridge] Magnet pull: Snatching data from $peerId");
              // Для приема маленьких пульсов используем BLE
              await _btService.quickLinkAndPing(r.device, orchestrator.generatePulse().toBytes());
            } else {
              _log("🚀 [Escalation] Cascade Offload: Moving data to $peerId via Wi-Fi Direct");

              // ПЕРЕХОДИМ НА WI-FI DIRECT ДЛЯ НАДЕЖНОЙ ПЕРЕДАЧИ
              // Твой нативный метод connect использует MAC-адрес
              await NativeMeshService.connect(mac);

              // Логика отправки пакета из Outbox находится в методе onNetworkConnected
              // Он сработает автоматически, как только Android поднимет P2P-группу
            }
            break;
          }
        }
      });

      // 4. ЗАПУСК СКАНЕРА
      await FlutterBluePlus.startScan(
        withServices: [Guid(_btService.SERVICE_UUID)],
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );

    } catch (e) {
      _log("❌ BT Burst Error: $e");
    } finally {
      // Авто-завершение цикла через 15 сек
      Future.delayed(const Duration(seconds: 15), () async {
        await _btService.stopAdvertising();
        _isBtScanning = false;
        _log("💤 [BT] Burst cycle completed.");
      });
    }
  }


  // --- ОБРАБОТКА ПАКЕТОВ ---


  String get lastKnownPeerIp => _lastKnownPeerIp;

  // 🔥 ИСПРАВЛЕННЫЙ МЕТОД ОБРАБОТКИ ПАКЕТОВ



  /// Логика: Распаковка -> Дедупликация -> Peer Lock -> Маршрутизация.
  void processIncomingPacket(dynamic rawData) async {
    _log("🧬 [Mesh-Kernel] New pulse incoming. Analyzing...");

    final db = LocalDatabaseService();
    // Извлекаем менеджер Gossip через локатор для ретрансляции
    final gossip = locator<GossipManager>();

    try {
      String jsonString = "";
      String? senderIp;

      // --- 1. РАСПАКОВКА И ЗАХВАТ IP (Критично для Tecno/Huawei) ---
      // Native-слой присылает Map с контентом сообщения и IP адресом отправителя.
      if (rawData is Map) {
        jsonString = rawData['message']?.toString() ?? "";
        senderIp = rawData['senderIp']?.toString();
      } else {
        jsonString = rawData.toString();
      }

      if (jsonString.isEmpty) {
        _log("⚠️ [Mesh] Empty payload received. Aborting.");
        return;
      }

      // --- 2. ПАРСИНГ JSON ---
      final Map<String, dynamic> data = jsonDecode(jsonString);

      // --- 3. GOSSIP ДЕДУПЛИКАЦИЯ (Anti-Entropy Layer) ---
      // Генерируем или извлекаем уникальный хеш пакета.
      final String packetHash = data['h'] ?? "pulse_${data['timestamp']}_${data['senderId']}";

      // Проверка через БД: если мы уже видели этот сигнал, мы его не обрабатываем и не пересылаем.
      if (await db.isPacketSeen(packetHash)) {
        _log("♻️ [Gossip] Duplicate pulse ($packetHash). Dropping to save battery.");
        return;
      }

      // --- 4. МАРШРУТИЗАЦИЯ ОБРАТНОГО ПУТИ (Peer Lock) ---
      // Фиксируем IP отправителя. В Wi-Fi Direct IP могут меняться,
      // поэтому мы всегда запоминаем адрес последнего входящего пакета.
      if (senderIp != null && senderIp.isNotEmpty && senderIp != "127.0.0.1") {
        if (_lastKnownPeerIp != senderIp) {
          _lastKnownPeerIp = senderIp;
          _log("📍 [Mesh] Peer Locked -> $_lastKnownPeerIp");
          notifyListeners(); // UI должен обновить статус "горячего" соединения
        }
      }

      // Извлекаем тактические метаданные
      final String packetType = data['type'] ?? 'UNKNOWN';
      final String senderId = data['senderId'] ?? 'Unknown';
      // Нормализуем ID чата для стабильной фильтрации на разных устройствах
      final String incomingChatId = (data['chatId'] ?? "").toString().trim().toUpperCase();

      // --- 5. ТАКТИЧЕСКИЙ РОУТИНГ ПО ТИПАМ ПАКЕТОВ ---
      switch (packetType) {

        case 'MAGNET_QUERY':
          _log("❓ Node $senderId is looking for internet. Answering status...");
          broadcastMagnetStatus(); // Отвечаем нашей дистанцией до моста
          break;

        case 'MAGNET_PULSE':
          final pulse = RoutingPulse.fromJson(data); // Используем наш класс
          locator<TacticalMeshOrchestrator>().processRoutingPulse(pulse); // Скармливаем мозгу

          if (pulse.hopsToInternet < 5) {
            HapticFeedback.heavyImpact();
          }
          notifyListeners();
          break;

        case 'PING':
          _log("👋 Handshake pulse from $senderId");
          // Если мы клиент, отвечаем синхронизацией рекламных пакетов
          if (!_isHost && senderIp != null) syncGossip(senderIp);
          break;

        case 'OFFLINE_MSG':
        case 'MSG_FRAG':
          _log("📥 Signal detected for room: $incomingChatId");

          final String myId = _apiService.currentUserId;

          // 🔥 ГИБКАЯ ФИЛЬТРАЦИЯ (Решение для Huawei/Xiaomi)
          // Пакет считается валидным для нашего UI, если:
          // 1. Он адресован лично нам.
          // 2. Он в глобальном канале (содержит GLOBAL или BEACON).
          // 3. Или у него просто есть chatId (ConversationScreen сам разберется).
          bool isForMe = data['recipientId'] == myId;
          bool isGlobal = incomingChatId.contains("GLOBAL") || incomingChatId.contains("BEACON");

          if (isForMe || isGlobal || incomingChatId.isNotEmpty) {
            _log("🚀 [Mesh] Valid signal recognized. Relaying to UI stream.");
            data['senderIp'] = senderIp; // Прокидываем IP для контекста
            _messageController.add(data); // Отправляем в стрим для ConversationScreen
          }

          // 🦠 GOSSIP PROPAGATION:
          // Даже если сообщение не нам, мы передаем его в GossipManager.
          // Менеджер решит: склеить фрагменты (Meaning Units) или переслать пакет соседям.
          await gossip.processEnvelope(data);
          break;

        case 'GOSSIP_SYNC':
          _log("🔄 Gossip Sync: Merging tactical ad-pool metadata.");
          final List? adsRaw = data['payload']?['ads'];
          if (adsRaw != null) {
            for (var adJson in adsRaw) {
              try {
                await db.saveAd(AdPacket.fromJson(adJson));
              } catch (e) { continue; }
            }
          }
          break;

        case 'REQ':
          if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
            _log("🌉 [Bridge] Validating REQ from $senderId...");

            // 🔥 СОЗДАЕМ ТИПИЗИРОВАННЫЙ ПАКЕТ
            final reqPacket = MeshPacket.fromMap(data, ip: senderIp);

            // Вызываем метод с ОДНИМ аргументом (как он и ожидает)
            handleProxyWithFairUse(reqPacket);
          } else {
            _log("💾 [Relay] Caching REQ to infected outbox.");
            _infectDevice(data);
          }
          break;



        case 'RES':
        // Ответ от облака (через прокси-мост) пробрасываем в локальные слушатели
          _log("🎯 [Ghost] Proxy response arrived. Injecting to UI.");
          _messageController.add(data);
          break;

        default:
          _log("❓ Unknown frequency: $packetType. Monitoring continues.");
      }
    } catch (e) {
      _log("❌ [Mesh-Critical] Crash during pulse processing: $e");
    }
  }



  /// Рассылка статуса близости к интернету
  void broadcastMagnetStatus() async {
    final currentRole = NetworkMonitor().currentRole;
    _myDistanceToBridge = (currentRole == MeshRole.BRIDGE) ? 0 : 99;

    // Если мы не мост, но видим мост среди соседей
    if (_myDistanceToBridge != 0) {
      int minDist = 98;
      for (var node in _nearbyNodes.values) {
        if (node.bridgeDistance < minDist) minDist = node.bridgeDistance;
      }
      _myDistanceToBridge = minDist + 1;
    }

    final pulse = jsonEncode({
      'type': 'MAGNET_PULSE',
      'senderId': _apiService.currentUserId,
      'dist': _myDistanceToBridge,
    });

    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh) {
        NativeMeshService.sendTcp(pulse, host: node.metadata);
      }
    }
  }




  /// Метод "Заражения" (Viral Infection Protocol)
  /// Сохраняет пакет в Outbox для дальнейшей ретрансляции при обнаружении BRIDGE-ноды
  Future<void> _infectDevice(Map<String, dynamic> packet) async {
    final String packetId = "pulse_${packet['timestamp']}_${packet['senderId']}";

    // Если мы уже инкубировали этот пульс - выходим
    if (_lastSeenTimestamps.containsKey(packetId)) return;
    _lastSeenTimestamps[packetId] = DateTime.now().millisecondsSinceEpoch;
    try {
      final db = LocalDatabaseService();
      // Используем timestamp как часть ID, чтобы он был уникальным
      final String packetId = "pulse_${packet['timestamp'] ?? DateTime.now().millisecondsSinceEpoch}";

      final relayMsg = ChatMessage(
        id: packetId,
        content: packet['content'] ?? jsonEncode(packet),
        senderId: packet['senderId'] ?? "GHOST_NODE",
        createdAt: DateTime.now(),
        status: "MESH_RELAY",
      );
      await _incrementKarma(1);
      await db.addToOutbox(relayMsg, packet['chatId'] ?? "TRANSIT_ZONE");
      _log("🦠 [Viral] Packet ${packetId} incubated.");
    } catch (e) {
      _log("⚠️ Infection failed: $e");
    }
  }



  /// МЕТОД "ЗАРАЖЕНИЯ" (Gossip Infection)
  /// Каждая нода, получив этот пакет, сохраняет его и пытается передать дальше
  Future<void> infectNeighbors(Map<String, dynamic> packet) async {
    final String packetId = packet['h'] ?? "pulse_${DateTime.now().millisecondsSinceEpoch}";

    // 1. Проверка на дубликат (чтобы не гонять пакеты по кругу)
    if (_lastSeenTimestamps.containsKey(packetId)) return;
    _lastSeenTimestamps[packetId] = DateTime.now().millisecondsSinceEpoch;

    _log("🦠 Virus Protocol: Infecting peers with packet $packetId");

    // 2. Сохраняем в Outbox (если вдруг мы сами станем BRIDGE)
    final db = LocalDatabaseService();
    final msg = ChatMessage(
        id: packetId,
        content: packet['data'], // Зашифрованные данные
        senderId: packet['senderId'] ?? 'GHOST',
        createdAt: DateTime.now(),
        status: 'MESH_RELAY'
    );
    await db.saveMessage(msg, packet['chatId'] ?? 'GLOBAL');

    // 3. Рассылаем всем Wi-Fi нодам в радиусе
    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh) {
        // Шлем по захваченному ранее IP или по IP группы
        String target = (node.id == _lastKnownPeerIp) ? _lastKnownPeerIp : "192.168.49.1";
        NativeMeshService.sendTcp(jsonEncode(packet), host: target);
      }
    }
  }



  /// Вирусная рассылка (Gossip Protocol)
  /// Шлет сообщение всем, кто в зоне доступа. Каждый получатель становится ретранслятором.
  Future<void> viralBroadcast(Map<String, dynamic> packet) async {
    final String packetId = packet['clientTempId'] ?? "ghost_${DateTime.now().millisecondsSinceEpoch}";

    // 1. Проверяем, не пересылали ли мы это уже (защита от циклов)
    if (_lastSeenTimestamps.containsKey(packetId)) return;
    _lastSeenTimestamps[packetId] = DateTime.now().millisecondsSinceEpoch;

    _log("🦠 [Viral] Infecting neighbors with packet: ${packetId.substring(0,8)}");

    // 2. Рассылаем всем Wi-Fi нодам
    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh) {
        // Мы используем IP, который захватили ранее (lastKnownPeerIp)
        NativeMeshService.sendTcp(jsonEncode(packet), host: _lastKnownPeerIp);
      }
    }

    // 3. Если мы нашли интернет (мы - Мост), сразу выстреливаем в облако
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      locator<ApiService>().syncOutbox();
    }
  }

  /// Фоновое сохранение сообщения, если пользователь не в чате
  // --- 🔥 ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ ОБРАБОТКИ ---

  /// Автоматическое сохранение сообщения в локальную БД.
  /// Это гарантирует, что сигнал не будет потерян, даже если юзер не в чате.
  Future<void> _autoSaveOfflineMessage(Map<String, dynamic> data) async {
    final db = LocalDatabaseService();

    try {
      // 1. Генерируем уникальный ключ для дедупликации на основе контента и времени.
      // Если придет такой же пакет - SQLite его просто проигнорирует (ConflictAlgorithm.replace)
      final String timestamp = (data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch).toString();
      final String meshId = "mesh_${data['senderId']}_$timestamp";

      // 2. Создаем объект сообщения
      // Важно: в оффлайне мы не можем расшифровать его здесь без контекста чата,
      // поэтому сохраняем зашифрованный контент. ConversationScreen расшифрует его при открытии.
      final msg = ChatMessage(
        id: meshId,
        content: data['content'] ?? "", // Зашифрованный AES-пакет
        senderId: data['senderId'] ?? "Unknown",
        senderUsername: data['senderUsername'] ?? "Nomad",
        createdAt: DateTime.fromMillisecondsSinceEpoch(int.tryParse(timestamp) ?? DateTime.now().millisecondsSinceEpoch),
        status: "MESH_LINK",
      );

      final String targetChatId = data['chatId'] ?? "THE_BEACON_GLOBAL";

      // 3. Сохраняем в SQLite
      await db.saveMessage(msg, targetChatId);

      _log("💾 [Storage] Offline packet cached for chat: $targetChatId");
    } catch (e) {
      _log("❌ [Storage-Error] Failed to auto-save mesh packet: $e");
    }
  }


  Future<void> dispatchMessage(ChatMessage msg) async {
    final orchestrator = locator<TacticalMeshOrchestrator>();

    // 1. Если я мост — сразу в облако через твой ApiService
    if (orchestrator.myHops == 0) {
      _log("🌉 I am BRIDGE. Sending directly to Cloud.");
      // Используем твой метод синхронизации
      await locator<ApiService>().syncOutbox();
      return;
    }

    // 2. Ищем лучший путь (используем таблицу из оркестратора)
    // Для этого в оркестраторе сделай геттер для таблицы или метод поиска лучшего соседа
    final bestNextHop = locator<TacticalMeshOrchestrator>().getBestUplink();

    if (bestNextHop != null) {
      _log("🚀 Routing packet to ${bestNextHop.nodeId}");

      // ТВОЙ РЕАЛЬНЫЙ МЕТОД:
      final packet = jsonEncode(msg.toJson());
      // В твоем коде это NativeMeshService.sendTcp
      await NativeMeshService.sendTcp(packet, host: bestNextHop.nodeId);
    } else {
      _log("📦 No uplink. Caching in local SQLite.");
      // ТВОЙ РЕАЛЬНЫЙ МЕТОД:
      await locator<LocalDatabaseService>().saveMessage(msg, msg.id);
      await locator<LocalDatabaseService>().addToOutbox(msg, msg.id);
    }
  }

  // В методе processIncomingPacket (MeshService)
  void handleDataPacket(Map<String, dynamic> data, String fromIp) async {
    final orchestrator = locator<TacticalMeshOrchestrator>();
    final String packetId = data['id'] ?? data['h'];
    final String type = data['type'];

    if (type == 'REQ') {
      // Мы — транзитный узел. Запоминаем, откуда пришел запрос, чтобы вернуть ответ.
      orchestrator.reversePath.savePath(packetId, data['senderId']);

      // Пересылаем пакет дальше по градиенту (к интернету)
      orchestrator.dispatchMessage(ChatMessage.fromJson(data));
    }

    else if (type == 'RES') {
      // Это ответ от сервера! Ищем, кому его вернуть в меш-сети.
      String? originalSenderId = orchestrator.reversePath.findNextHop(packetId);

      if (originalSenderId != null) {
        _log("🎯 Found reverse path for $packetId -> $originalSenderId");
        // Шлем ответ конкретному соседу
        await NativeMeshService.sendTcp(jsonEncode(data), host: originalSenderId);
      } else {
        _log("💨 Reverse path expired or not found for $packetId");
        // Если путь потерян — используем Limited Flooding как фолбек
        infectNeighbors(data);
      }
    }
  }

  // --- 🛰️ ПРОКСИ-ЛОГИКА (Для интервью) ---

  /// Центральный метод проксирования запросов от "Призраков" в Интернет
  void _handleProxyRequest(MeshPacket packet) async {
    final String method = packet.payload['method'];
    final String endpoint = packet.payload['endpoint'];
    final dynamic rawBody = packet.payload['body'];
    final String? targetIp = packet.senderIp; // 🔥 Берем IP из пакета

    // 1. Создаем защищенный HTTP-клиент
    final ioc = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    final client = IOClient(ioc);

    final String ghostId = packet.payload['senderId'] ?? "Unknown";
    _log("🌉 [Bridge] Proxying REQ for Node: ${ghostId.substring(0, 8)} -> $endpoint");

    try {
      // 2. ФОРМИРОВАНИЕ "СПОНСОРСКИХ" ЗАГОЛОВКОВ (DPI Deception)
      final String? myRealToken = await Vault.read('auth_token');

      final Map<String, String> proxyHeaders = {
        'Content-Type': 'application/json',
        'Host': 'update.microsoft.com', // Маскировка под трафик Microsoft
        if (myRealToken != null && myRealToken != 'GHOST_MODE_ACTIVE')
          'Authorization': 'Bearer $myRealToken',

        'X-Memento-Ghost-ID': ghostId,
        'X-Proxy-Node': _apiService.currentUserId, // Кто помогает (для Кармы)
      };

      // 3. ВЫПОЛНЕНИЕ ЗАПРОСА
      final String fullUrl = endpoint.startsWith('http')
          ? endpoint
          : (_baseUrl + (endpoint.startsWith('/api') ? endpoint.replaceFirst('/api', '') : endpoint));

      http.Response response;
      final encodedBody = (rawBody != null && rawBody is! String) ? jsonEncode(rawBody) : rawBody;

      if (method == 'POST') {
        response = await client.post(Uri.parse(fullUrl), headers: proxyHeaders, body: encodedBody);
      } else {
        response = await client.get(Uri.parse(fullUrl), headers: proxyHeaders);
      }

      _log("☁️ [Server] Response: ${response.statusCode}");

      // 4. УПАКОВКА ОТВЕТА
      final resPacket = MeshPacket.createResponse(packet.id, response.statusCode, response.body);
      final String serializedRes = resPacket.serialize();

      // 5. 🔥 ТАКТИКА "ОБРАТНЫЙ ВСПЛЕСК" (Return Burst)
      // Шлем 3 раза, так как Huawei соседа мог "уснуть", пока мы ждали интернет
      if (_lastKnownPeerIp.isNotEmpty) {
        for (int i = 0; i < 3; i++) {
          await NativeMeshService.sendTcp(serializedRes, host: _lastKnownPeerIp);
          await Future.delayed(const Duration(milliseconds: 200));
        }
        _log("✅ [Bridge] Result delivered back to $_lastKnownPeerIp");
      }

    } catch (e) {
      _log("❌ [Bridge] Relay Failure: $e");
      // Шлем ошибку 503, чтобы "Призрак" не ждал вечно
      final errPacket = MeshPacket.createResponse(packet.id, 503, jsonEncode({'error': 'Mesh Bridge Timeout'}));
      if (_lastKnownPeerIp.isNotEmpty) {
        await NativeMeshService.sendTcp(errPacket.serialize(), host: _lastKnownPeerIp);
      }
    } finally {
      client.close();
    }
  }

  // --- 🔄 СИНХРОНИЗАЦИЯ GOSSIP ---

  Future<void> syncGossip(String peerIp) async {
    final db = LocalDatabaseService();
    final myAds = await db.getActiveAds();

    if (myAds.isEmpty) return;

    final gossipPacket = jsonEncode({
      'type': 'GOSSIP_SYNC',
      'payload': {
        'ads': myAds.map((e) => e.toJson()).toList(),
      }
    });

    // Шлем соседу наши рекламные пакеты
    await NativeMeshService.sendTcp(gossipPacket, host: peerIp);
    _log("🔄 [Gossip] Synced ${myAds.length} ads with $peerIp");
  }

  Future<void> sendTcpBurst(String message) async {
    String targetIp;

    if (!_isHost) {
      // Я - КЛИЕНТ. Шлю всегда Хосту.
      targetIp = "192.168.49.1";
      _log("📡 Route: Client -> Host ($targetIp)");
    } else {
      // Я - ХОСТ. Шлю КЛИЕНТУ на его реальный IP.
      if (_lastKnownPeerIp.isEmpty || _lastKnownPeerIp == "192.168.49.1") {
        _log("⚠️ Error: I am Host, but Peer IP is not captured yet.");
        return;
      }
      targetIp = _lastKnownPeerIp;
      _log("📡 Route: Host -> Client ($targetIp)");
    }

    // Тот самый Burst (3 попытки)
    for (int i = 0; i < 3; i++) {
      await NativeMeshService.sendTcp(message, host: targetIp);
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  // --- ДОПОЛНИТЕЛЬНЫЕ МЕТОДЫ СВЯЗИ ---

  /// Отправляет HTTP-запрос через Mesh-цепочку (для режима GHOST)
  Future<dynamic> sendThroughMesh(String endpoint, String method, Map<String, String> headers, dynamic body) async {
    if (!_isP2pConnected) throw Exception("Mesh Link Offline.");

    // Создаем пакет запроса
    final packet = MeshPacket.createRequest(method, endpoint, headers, body);

    // Создаем "ожидатель" ответа
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[packet.id] = completer;

    _log("👻 [Ghost] Injecting packet ${packet.id.substring(0,8)} into Mesh...");

    // В Wi-Fi Direct "Призрак" всегда шлет пакет "Хосту" (Мосту) на стандартный IP
    String targetIp = "192.168.49.1";

    try {
      await NativeMeshService.sendTcp(packet.serialize(), host: targetIp);
    } catch (e) {
      _pendingRequests.remove(packet.id);
      throw Exception("Failed to transmit packet: $e");
    }

    // Ждем 20 секунд. Если Мост не ответит — выдаем таймаут
    return completer.future.timeout(const Duration(seconds: 20));
  }

  /// Тактический запрос на вступление в группу
  Future<Map<String, dynamic>> joinGroupRequest(String groupId) async {
    _log("🛰️ Tactical Join Request: $groupId");
    // Вызываем оригинальный метод из API Service
    return await _apiService.joinGroupRequest(groupId);
  }




  // lib/core/mesh_service.dart



  // --- ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ ---

  Future<bool> _isHardwareReady() async {
    if (!Platform.isAndroid) return true;
    await [Permission.location, Permission.bluetoothScan, Permission.bluetoothConnect].request();

    if (!(await Geolocator.isLocationServiceEnabled())) {
      await Geolocator.openLocationSettings();
      return false;
    }
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      if (Platform.isAndroid) await FlutterBluePlus.turnOn();
    }
    return true;
  }


  void _addLog(String msg) => _log(msg);

  String _lastConnectedHost = "192.168.49.1";

  bool _isHost = false;
  String _lastKnownPeerIp = "192.168.49.1";
  bool _isRouteReady = false;
  bool get isRouteReady => _isRouteReady;

  void onNetworkConnected(bool isHost, String hostAddress) async {
    _isP2pConnected = true;
    _isHost = isHost;

    _log("🌐 [MESH-LINK] Connected to group. Sending payload...");

    final db = locator<LocalDatabaseService>();
    final pending = await db.getPendingFromOutbox();

    if (pending.isNotEmpty) {
      final msg = pending.first;
      final packet = jsonEncode({
        'type': 'OFFLINE_MSG',
        'chatId': msg['chatRoomId'],
        'content': msg['content'],
        'senderId': _apiService.currentUserId,
        'h': msg['id'],
      });

      // 🔥 ТЕПЕРЬ МЫ ШЛЕМ НА IP, А НЕ НА MAC!
      // Если я клиент - шлю Хосту (192.168.49.1)
      // Если я хост - шлю клиенту (hostAddress)
      String targetIp = isHost ? hostAddress : "192.168.49.1";

      await NativeMeshService.sendTcp(packet, host: targetIp);
      _log("🚀 [DATA] Signal offloaded via Wi-Fi Direct to $targetIp");
    }
  }

  void logSonarEvent(String msg, {bool isError = false}) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final prefix = isError ? "❌ [SONAR-ERR]" : "🔊 [SONAR]";
    final fullLog = "$timestamp $prefix $msg";

    print(fullLog);
    _statusController.add(fullLog); // Отправляем в терминал на экране
    notifyListeners();
  }

  // Универсальный логгер с выводом в терминал UI
  void _log(String msg) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final fullMsg = "[$timestamp] $msg";
    print(fullMsg);
    _statusController.add(fullMsg); // Пробрасываем в терминал на экране
  }

  void _sendInitialHandshake() async {
    await Future.delayed(const Duration(seconds: 1)); // Даем сокету прогрузиться
    _log("👋 Sending Handshake to reveal my IP to Host...");

    final ping = jsonEncode({
      'type': 'PING',
      'senderId': _apiService.currentUserId.isNotEmpty ? _apiService.currentUserId : "GHOST_PREP",
      'senderUsername': "Nomad",
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Шлем Хосту. Как только он получит это, его `processIncomingPacket`
    // залочит наш IP и он сможет нам отвечать.
    await NativeMeshService.sendTcp(ping, host: "192.168.49.1");
  }

  void _sendPingPulse() async {
    await Future.delayed(const Duration(seconds: 1)); // Даем сокету проснуться
    _log("👋 Sending Handshake Ping to Host...");

    final ping = jsonEncode({
      'type': 'PING',
      'senderId': _apiService.currentUserId,
    });

    // Шлем Хосту на стандартный адрес
    NativeMeshService.sendTcp(ping, host: "192.168.49.1");
  }


  void onNetworkDisconnected() {
    _isP2pConnected = false;
    notifyListeners();
    _log("🔌 Link severed.");
  }

  void stopAll() async {
    _log("⚙️ Shutting down Link systems...");

    // 1. Сначала останавливаем сканеры
    stopDiscovery();
    _accelSub?.cancel();
    _adaptiveTimer?.cancel();
    _cleanupTimer?.cancel();

    // 2. БЕЗОПАСНАЯ ОСТАНОВКА ВЕЩАНИЯ (SONAR / BEACON)
    try {
      // Проверяем статус перед тем как дергать натив
      bool isAdvertising = await FlutterBlePeripheral().isAdvertising;
      if (isAdvertising) {
        await FlutterBlePeripheral().stop();
        _log("🦷 BT Peripheral stopped.");
      }
    } catch (e) {
      // Даже если натив выдаст "Reply already submitted",
      // мы это поймаем и приложение не вылетит
      print("⚠️ BT Safe Stop: $e");
    }

    _nearbyNodes.clear();
    notifyListeners();
    _log("🛑 Full System Hibernate.");
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _statusController.close();
    _discoveryController.close();
    _messageController.close();
    super.dispose();
  }


// --- 🔥 УПРАВЛЕНИЕ МОДУЛЯМИ ---

// Метод включения/выключения всей системы связи
void toggleMesh(bool value) {
  _isMeshEnabled = value;
  if (!_isMeshEnabled) {
    stopAll(); // Выключаем всё принудительно
  } else {
    initBackgroundProtocols(); // Запускаем заново
  }
  notifyListeners();
}

// Метод переключения режима энергосбережения
void togglePowerSaving(bool value) {
  _isPowerSaving = value;
  _setupAdaptiveScanning(); // Перенастраиваем логику
  notifyListeners();
}

// --- 🧠 ЛОГИКА АДАПТИВНОГО СКАНА ---

void _setupAdaptiveScanning() {
  _accelerometerSub?.cancel();
  _adaptiveTimer?.cancel();

  if (!_isMeshEnabled) return;

  if (!_isPowerSaving) {
    // Если энергосбережение ВЫКЛЮЧЕНО — сканируем постоянно на полной мощности
    _startConstantDiscovery();
    return;
  }

  // Если включено — подписываемся на датчик движения
  _accelerometerSub = accelerometerEventStream().listen((event) {
    // Вычисляем вектор движения
    double gForce = event.x.abs() + event.y.abs() + event.z.abs();

    // Если gForce > 12, значит телефон не в покое (его несут или он в машине)
    if (gForce > 12.0 && !_isMoving) {
      _isMoving = true;
      _log("🏃 Movement detected. Increasing scan frequency.");
      _triggerFastScan();
    } else if (gForce <= 10.5 && _isMoving) {
      _isMoving = false;
      _log("💤 Device still. Entering hibernation.");
      _triggerSlowScan();
    }
  });
}

// Постоянный скан (Максимальный расход)
void _startConstantDiscovery() {
  startDiscovery(SignalType.mesh);
  startDiscovery(SignalType.bluetooth);
}

// Быстрый скан (при движении) — раз в 30 секунд
void _triggerFastScan() {
  _adaptiveTimer?.cancel();
  _adaptiveTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
    if (!_isMeshEnabled) return;
    _log("📡 Fast Scan Pulse...");
    startDiscovery(SignalType.mesh);
    await Future.delayed(const Duration(seconds: 10));
    NativeMeshService.stopDiscovery(); // Кратковременный импульс
  });
}


// Медленный скан (в покое) — раз в 5 минут
void _triggerSlowScan() {
  _adaptiveTimer?.cancel();
  // Экономим Tecno: сканируем очень редко, когда он лежит
  _adaptiveTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
    if (!_isMeshEnabled) return;
    _log("🔋 Hibernation Pulse Scan...");
    startDiscovery(SignalType.mesh);
  });
}
  void _startSonar() {
    final sonar = UltrasonicService();
    sonar.transmitBeacon(); // 🔊 ультразвуковой маяк
    _addLog("🔊 SONAR: Ultrasonic beacon emitted.");
  } }
