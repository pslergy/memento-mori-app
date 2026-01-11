import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../features/chat/conversation_screen.dart';
import 'api_service.dart';
import 'background_service.dart';
import 'encryption_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_protocol.dart';
import 'models/ad_packet.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'network_monitor.dart';
import 'websocket_service.dart';
import 'bluetooth_service.dart';

class MeshService with ChangeNotifier {
  static final MeshService _instance = MeshService._internal();
  factory MeshService() => _instance;
  MeshService._internal();

  final BluetoothMeshService _btService = BluetoothMeshService();
  final ApiService _apiService = ApiService();

  // Состояние обнаруженных узлов (Радар)
  final Map<String, SignalNode> _nearbyNodes = {};
  final Map<String, int> _lastSeenTimestamps = {};

  // Геттеры для UI
  List<SignalNode> get nearbyNodes => _nearbyNodes.values.toList();
  bool get isP2pConnected => _isP2pConnected;

  // Потоки данных



  final StreamController<List<SignalNode>> _discoveryController = StreamController.broadcast();
  Stream<List<SignalNode>> get discoveryStream => _discoveryController.stream;

  final StreamController<Map<String, dynamic>> _messageController = StreamController.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<String> _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  Timer? _cleanupTimer;
  bool _isP2pConnected = false;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final String _baseUrl = 'https://89.125.131.63:3000/api';

  bool autoMesh = true;
  bool autoBT = true;
  bool _isMeshEnabled = true; // Главный тумблер всей системы связи
  bool _isPowerSaving = true;

  bool get isMeshEnabled => _isMeshEnabled;
  bool get isPowerSaving => _isPowerSaving;

  StreamSubscription? _accelSub;

  StreamSubscription? _accelerometerSub;
  Timer? _adaptiveTimer;
  bool _isMoving = false;

  bool _isGpsEnabled = true;
  bool get isGpsEnabled => _isGpsEnabled;


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

  // --- УМНАЯ ОТПРАВКА (Cloud <-> Mesh) ---

  Future<void> sendAuto({
    required String content,
    String? chatId,
    required String receiverName,
  }) async {
    final currentRole = NetworkMonitor().currentRole;
    final encryption = locator<EncryptionService>();
    final api = locator<ApiService>();

    // 🔥 ГЛОБАЛЬНЫЙ ID: Если ID не передан, используем единую частоту Маяка
    final String targetId = chatId ?? "THE_BEACON_GLOBAL";

    // 1. ПОДГОТОВКА: Шифруем контент ключом конкретного чата
    final key = await encryption.getChatKey(targetId);
    final encryptedContent = await encryption.encrypt(content, key);

    // Генерируем временный ID для дедупликации
    final String tempId = "mesh_${DateTime.now().millisecondsSinceEpoch}";

    if (currentRole == MeshRole.BRIDGE) {
      // ==========================================
      // 🌐 КАНАЛ ОБЛАКА (Online)
      // ==========================================
      WebSocketService().send({
        "type": "message",
        "chatId": targetId,
        "content": content, // WebSocketService сам зашифрует внутри
        "clientTempId": tempId,
      });
      _log("🚀 Packet routed via Cloud Relay.");

    } else {
      // ==========================================
      // 👻 КАНАЛ MESH (Offline)
      // ==========================================
      _log("📡 Broadcasting encrypted pulse to Mesh frequencies...");

      // Формируем оффлайн-пакет
      final offlinePacket = jsonEncode({
        'type': 'OFFLINE_MSG',
        'chatId': targetId,
        'content': encryptedContent,
        'isEncrypted': true,
        'senderId': api.currentUserId.isNotEmpty ? api.currentUserId : "GHOST_NODE",
        'senderUsername': "Nomad",
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'clientTempId': tempId, // Передаем ID для защиты от дублей на приеме
      });

      // --- 1. ОТПРАВКА ПО WI-FI DIRECT (TCP Bursts) ---
      if (_isP2pConnected) {
        String targetIp;
        if (!_isHost) {
          targetIp = "192.168.49.1"; // Клиент шлет Хосту
        } else {
          // Хост шлет на захваченный IP клиента
          targetIp = _lastKnownPeerIp;
        }

        if (targetIp.isEmpty || targetIp == "127.0.0.1") {
          _log("⚠️ Target IP invalid. Waiting for Peer Pulse...");
          return;
        }

        _log("🚀 Sending via WiFi to $targetIp");
        for (int i = 0; i < 3; i++) {
          await NativeMeshService.sendTcp(offlinePacket, host: targetIp);
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      // --- 2. ОТПРАВКА ПО BLUETOOTH (BLE Push) ---
      // Ищем все обнаруженные Bluetooth-ноды и пытаемся "впрыснуть" данные
      final bluetoothNodes = _nearbyNodes.values.where((n) => n.type == SignalType.bluetooth).toList();

      for (var node in bluetoothNodes) {
        try {
          _log("🦷 Pulsing data to BT Node: ${node.name}");
          // Пытаемся передать через GATT характеристики
          await _btService.sendMessage(BluetoothDevice.fromId(node.id), offlinePacket);
          _log("✅ Pulse successful for ${node.name}");
        } catch (e) {
          _log("❌ BT Link failed for ${node.name}");
        }
      }
    }
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

  void _scanBluetooth() async {
    if (!_isMeshEnabled) return;

    // 1. Проверка GPS
    if (!await Geolocator.isLocationServiceEnabled()) {
      _log("❌ Bluetooth Scan blocked: GPS is OFF");
      return;
    }

    try {
      _log("🦷 Pulsing Bluetooth frequency...");

      // 2. Проверка и принудительное включение адаптера
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        _log("⚠️ BT Adapter is OFF. Forcing ON...");
        if (Platform.isAndroid) await FlutterBluePlus.turnOn();
        await Future.delayed(const Duration(seconds: 1));
      }

      // 3. Остановка старого скана перед новым (защита от краша)
      await FlutterBluePlus.stopScan();
      await Future.delayed(const Duration(milliseconds: 200));

      String myId = "Ghost";
      try {
        final me = await _apiService.getMe();
        myId = me['id'].toString().substring(0, 4);
      } catch (_) {}

      // 4. Вещание (Advertising)
      await _btService.startAdvertising("MEMENTO_NODE_$myId");

      // 5. Поиск (Scanning) с плавным стартом
      FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );

      // 6. Прослушка результатов
      _btService.scanForNodes().listen((result) {
        String name = result.advertisementData.localName.isNotEmpty
            ? result.advertisementData.localName
            : "Ghost Node";

        final node = SignalNode(
            id: result.device.remoteId.str,
            name: name,
            type: SignalType.bluetooth,
            metadata: result.device.remoteId.str
        );
        _registerNode(node);
      }, onError: (e) => _log("❌ BT Scan Stream Error: $e"));

    } catch (e) {
      _log("❌ BT Critical Failure: $e");
    }
  }

  // --- ОБРАБОТКА ПАКЕТОВ ---


  String get lastKnownPeerIp => _lastKnownPeerIp;

  // 🔥 ИСПРАВЛЕННЫЙ МЕТОД ОБРАБОТКИ ПАКЕТОВ
  /// Центральный хаб обработки входящих Mesh-пакетов
  void processIncomingPacket(dynamic rawData) async {
    final db = LocalDatabaseService();

    try {
      String jsonString = "";
      String? senderIp;

      // 1. РАСПАКОВКА И ЗАХВАТ IP
      if (rawData is Map) {
        jsonString = rawData['message']?.toString() ?? "";
        senderIp = rawData['senderIp']?.toString();
      } else {
        jsonString = rawData.toString();
      }

      if (jsonString.isEmpty) return;
      final Map<String, dynamic> data = jsonDecode(jsonString);
      final String packetType = data['type'] ?? 'UNKNOWN';
      final String senderId = data['senderId'] ?? 'Unknown';

      // 2. IDENTITY MAPPING (Критично для Tecno/Huawei)
      // Привязываем реальный ID пользователя к его текущему IP в P2P группе
      if (senderIp != null && senderIp.isNotEmpty) {
        _lastKnownPeerIp = senderIp;

        // Если мы в режиме Хоста, мы теперь знаем, по какому адресу отвечать этому пользователю
        _log("📍 [Mesh] Identity Locked: $senderId @ $senderIp");
      }

      // 3. ТАКТИЧЕСКИЙ РОУТИНГ
      switch (packetType) {

        case 'PING':
          _log("👋 Handshake pulse from $senderId");
          // Авто-ответ на пинг для установления двусторонней связи
          if (!_isHost) syncGossip(senderIp!);
          break;

        case 'OFFLINE_MSG':
        // Если пришло сообщение с UUID, а на радаре этот человек висел как MAC
          if (senderIp != null && senderId != 'Unknown') {
            _log("🧬 [Mesh] Correlating MAC-Node with UUID: $senderId");
            _lastKnownPeerIp = senderIp; // Запоминаем, что этот UUID сидит на этом IP
          }
          _messageController.add(data);
          break;

        case 'GOSSIP_SYNC':
          _log("🔄 Gossip Protocol: Syncing tactical ads.");
          final List? adsRaw = data['payload']?['ads'];
          if (adsRaw != null) {
            for (var adJson in adsRaw) {
              await db.saveAd(AdPacket.fromJson(adJson));
            }
          }
          break;

        case 'REQ':
          if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
            _handleProxyRequest(MeshPacket.fromJson(jsonString));
          }
          break;

        default:
          _log("❓ Unknown frequency: $packetType");
      }
    } catch (e) {
      _log("❌ [Mesh-Critical] Packet processing failed: $e");
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

  // --- 🛰️ ПРОКСИ-ЛОГИКА (Для интервью) ---

  void _handleProxyRequest(MeshPacket packet) async {
    final String method = packet.payload['method'];
    final String endpoint = packet.payload['endpoint'];
    final Map<String, String> headers = Map<String, String>.from(packet.payload['headers']);
    final dynamic rawBody = packet.payload['body'];

    // 1. Создаем защищенный клиент
    final ioc = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    final client = IOClient(ioc);

    _log("🌉 [Bridge] Proxying request to: $endpoint");

    try {
      // 2. Формируем полный URL.
      // Убеждаемся, что не дублируем /api, если он уже есть в endpoint
      final String fullUrl = endpoint.startsWith('http')
          ? endpoint
          : (_baseUrl + (endpoint.startsWith('/api') ? endpoint.replaceFirst('/api', '') : endpoint));

      http.Response response;
      final encodedBody = (rawBody != null && rawBody is! String) ? jsonEncode(rawBody) : rawBody;

      if (method == 'POST') {
        response = await client.post(Uri.parse(fullUrl), headers: headers, body: encodedBody);
      } else {
        response = await client.get(Uri.parse(fullUrl), headers: headers);
      }

      // 3. Упаковываем ответ сервера в Mesh-пакет
      final resPacket = MeshPacket.createResponse(packet.id, response.statusCode, response.body);

      // 4. Отправляем назад "Призраку" (Huawei) через Wi-Fi Direct
      // Мы используем _lastKnownPeerIp, который захватили при получении REQ пакета
      await NativeMeshService.sendTcp(resPacket.serialize(), host: _lastKnownPeerIp);

      _log("✅ [Bridge] Proxy result sent back to peer.");

    } catch (e) {
      _log("❌ [Bridge] Failed to relay packet: $e");
      // Шлем ошибку 500 назад, чтобы Huawei не висел в ожидании (timeout)
      final errPacket = MeshPacket.createResponse(packet.id, 500, jsonEncode({'error': 'Bridge failure'}));
      await NativeMeshService.sendTcp(errPacket.serialize(), host: _lastKnownPeerIp);
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

  void _log(String msg) {
    print("[Mesh] $msg");
    _statusController.add(msg);
  }
  void _addLog(String msg) => _log(msg);

  String _lastConnectedHost = "192.168.49.1";

  bool _isHost = false;
  String _lastKnownPeerIp = "192.168.49.1";

  void onNetworkConnected(bool isHost, String hostAddress) {
    _isP2pConnected = true;
    _isHost = isHost;

    if (_isHost) {
      // Я - Хост. Жду, когда клиент пришлет PING, чтобы узнать его IP
      _lastKnownPeerIp = "";
      _log("🛡️ ROLE: HOST. Waiting for Client handshake...");
    } else {
      // Я - Клиент. Я ТОЧНО знаю, что Хост на 192.168.49.1
      _lastKnownPeerIp = "192.168.49.1";
      _log("📡 ROLE: CLIENT. Host locked at $_lastKnownPeerIp");

      // 🔥 КРИТИЧЕСКИЙ ХОД: Сразу шлем Пинг, чтобы Хост узнал наш IP
      _sendPingPulse();
    }
    notifyListeners();
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
    sonar.transmit("BEACON_ACTIVE"); // Телефон "пропищит" свой статус в эфир
    _addLog("🔊 SONAR: Acoustic pulse emitted.");
  }}
