import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
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
import 'hardware_check_service.dart';
import 'router/router_connection_service.dart';
import 'router/router_bridge_protocol.dart';
import 'models/ad_packet.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'network_monitor.dart';
import 'websocket_service.dart';
import 'bluetooth_service.dart';
import 'message_status.dart';
import 'message_signing_service.dart';
import 'event_bus_service.dart';
import 'discovery_context_service.dart';
import 'models/uplink_candidate.dart';
import 'connection_stabilizer.dart';


// 🔥 МАСШТАБИРУЕМОСТЬ: Классы для оптимизации отправки
class PayloadRetryInfo {
  int gattAttempts = 0;
  int tcpAttempts = 0;
  int sonarAttempts = 0;
  DateTime? cycleStartTime;
  int? hopsToBridge;
  int? outboxSizeAtStart;
  
  bool get maxRetriesReached => gattAttempts >= 3 && tcpAttempts >= 2 && sonarAttempts >= 1;
  
  Duration? get cycleDuration => cycleStartTime != null 
      ? DateTime.now().difference(cycleStartTime!) 
      : null;
}

class TransportLatency {
  final List<Duration> successfulLatencies = [];
  final List<Duration> failedLatencies = [];
  int consecutiveFailures = 0;
  int consecutiveSuccesses = 0;
  
  Duration get averageSuccessLatency {
    if (successfulLatencies.isEmpty) return const Duration(seconds: 10);
    final total = successfulLatencies.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return Duration(milliseconds: total ~/ successfulLatencies.length);
  }
  
  Duration get adaptiveTimeout {
    if (consecutiveFailures >= 3) {
      return const Duration(seconds: 20); // Увеличиваем при множественных неудачах
    }
    if (successfulLatencies.isNotEmpty && averageSuccessLatency.inSeconds <= 5) {
      return const Duration(seconds: 10); // Стандартный для быстрых устройств
    }
    return const Duration(seconds: 15); // Увеличенный для медленных устройств
  }
  
  void recordSuccess(Duration latency) {
    successfulLatencies.add(latency);
    if (successfulLatencies.length > 10) successfulLatencies.removeAt(0); // Храним последние 10
    consecutiveSuccesses++;
    consecutiveFailures = 0;
  }
  
  void recordFailure() {
    failedLatencies.add(DateTime.now().difference(DateTime.now())); // Placeholder
    if (failedLatencies.length > 10) failedLatencies.removeAt(0);
    consecutiveFailures++;
    consecutiveSuccesses = 0;
  }
}

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
  MeshService._internal() {
    // Запускаем таймер очистки "мертвых" нод раз в 10 секунд
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pruneDeadNodes());
    
    // 🔒 Fix memory leaks: Periodic cleanup of cooldowns and timestamps
    _memoryCleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      final now = DateTime.now();
      // Clean up expired cooldowns (older than 1 hour)
      _linkCooldowns.removeWhere((_, time) => now.difference(time).inHours > 1);
      // Clean up expired IP locks (older than 10 minutes)
      _peerIpExpiry.removeWhere((_, expiry) => now.isAfter(expiry));
      // Clean up old timestamps (older than 1 hour)
      final oneHourAgoTimestamp = now.millisecondsSinceEpoch - (60 * 60 * 1000);
      _lastSeenTimestamps.removeWhere((_, timestamp) => timestamp < oneHourAgoTimestamp);
      
      // 🔥 УЛУЧШЕНИЕ: Очистка _sentPayloads по времени (старше 1 часа) для освобождения памяти
      // Храним timestamp вместе с transport для очистки по времени
      final oneHourAgo = now.subtract(const Duration(hours: 1));
      final sentPayloadsToRemove = <String>[];
      
      // Собираем ключи для удаления (если нет timestamp - считаем старыми)
      // Note: _sentPayloads хранит только transport, поэтому используем время из _payloadRetries
      for (final entry in _sentPayloads.entries) {
        final retryInfo = _payloadRetries[entry.key];
        if (retryInfo?.cycleStartTime != null) {
          if (retryInfo!.cycleStartTime!.isBefore(oneHourAgo)) {
            sentPayloadsToRemove.add(entry.key);
          }
        } else {
          // Если нет retryInfo - считаем старым (старше 1 часа по умолчанию)
          sentPayloadsToRemove.add(entry.key);
        }
      }
      
      // Удаляем старые записи
      for (final key in sentPayloadsToRemove) {
        _sentPayloads.remove(key);
      }
      
      if (sentPayloadsToRemove.isNotEmpty) {
        _log("🧹 [Memory] Cleaned up ${sentPayloadsToRemove.length} old _sentPayloads entries (older than 1 hour)");
      }
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Динамическая очистка _sentPayloads при превышении лимита (500-1000)
      if (_sentPayloads.length > 1000) {
        // Оставляем только последние 500 записей
        final entries = _sentPayloads.entries.toList();
        _sentPayloads.clear();
        _sentPayloads.addEntries(entries.skip(entries.length - 500));
        _log("🧹 [Memory] Cleaned up _sentPayloads (kept last 500 of ${entries.length})");
      }
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Очистка старых retry info (старше 1 часа)
      _payloadRetries.removeWhere((_, info) {
        if (info.cycleStartTime == null) return true;
        return now.difference(info.cycleStartTime!).inHours > 1;
      });
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Очистка старых transport latencies (старше 24 часов)
      // Оставляем только активные (использовались в последние 24 часа)
      _transportLatencies.removeWhere((_, latency) {
        // Если нет успешных попыток за последние 24 часа - удаляем
        return latency.successfulLatencies.isEmpty && latency.consecutiveFailures > 10;
      });
      
      _log("🧹 [Memory] Cleaned up expired cooldowns, IP locks, timestamps, _sentPayloads, retry info, and transport latencies");
    });
    
    // 🔥 СЛУШАТЕЛЬ SONAR: Обработка запросов пакетов через Sonar
    locator<UltrasonicService>().sonarMessages.listen((signal) {
      _handleSonarSignal(signal);
    });
  }
  
  /// Обработка сигналов Sonar (запросы пакетов)
  void _handleSonarSignal(String signal) {
    if (signal.startsWith("Q:")) {
      // Запрос пакета: Q:hashCode
      final queryHash = signal.substring(2);
      _log("🔊 [Sonar] Packet query received: $queryHash");
      // TODO: Найти пакет по хешу и ответить
    } else if (signal.startsWith("REQ:")) {
      // Запрос на получение пакета: REQ:packetId
      final packetId = signal.substring(4);
      _log("🔊 [Sonar] Packet request received: $packetId");
      // Отправляем пакет через доступные каналы
      unawaited(_sendPacketOnRequest(packetId));
    } else if (signal.startsWith("MSG:")) {
      // Уведомление о наличии пакета: MSG:hashCode
      final msgHash = signal.substring(4);
      _log("🔊 [Sonar] Packet notification: $msgHash");
      // TODO: Запросить пакет через BLE/Wi-Fi
    } else if (signal.startsWith("DATA:")) {
      // 🔥 КРИТИЧНО: Получены реальные данные через Sonar
      final dataPayload = signal.substring(5); // Убираем префикс "DATA:"
      _log("🔊 [Sonar] Real data received: ${dataPayload.length} bytes");
      // Обрабатываем асинхронно
      unawaited(_processSonarData(dataPayload));
    }
  }
  
  /// Асинхронная обработка данных из Sonar
  Future<void> _processSonarData(String dataPayload) async {
    try {
      final data = jsonDecode(dataPayload) as Map<String, dynamic>;
      // Обрабатываем как обычный пакет
      await processIncomingPacket(data);
      _log("✅ [Sonar] Data packet processed successfully");
    } catch (e) {
      _log("❌ [Sonar] Failed to process data packet: $e");
    }
  }
  
  /// Отправляет пакет по запросу через Sonar
  Future<void> _sendPacketOnRequest(String packetId) async {
    final pending = await _db.getPendingFromOutbox();
    final msg = pending.firstWhere((m) => m['id'] == packetId, orElse: () => {});
    
    if (msg.isEmpty) {
      _log("⚠️ [Sonar] Requested packet $packetId not found in outbox");
      return;
    }
    
    // Пытаемся отправить через доступные каналы
    final payload = jsonEncode({
      'type': 'OFFLINE_MSG',
      'content': msg['content'],
      'senderId': _apiService.currentUserId,
      'h': packetId,
      'ttl': 5,
    });
    
    // 1. Wi-Fi Direct
    if (_isP2pConnected) {
      await sendTcpBurst(payload);
      return;
    }
    
    // 2. BLE
    final bluetoothNodes = _nearbyNodes.values.where((n) => n.type == SignalType.bluetooth).toList();
    if (bluetoothNodes.isNotEmpty) {
      // TODO: Отправить через BLE GATT
      _log("🦷 [Sonar] Sending via BLE to ${bluetoothNodes.first.name}");
    }
  }
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

  bool _isTransferring = false;
  bool get isTransferring => _isTransferring;
  bool _isBtScanning = false;
  bool _p2pDiscoveryActive = false;
  Timer? _periodicDiscoveryTimer; // Таймер для периодического discovery
  LocalDatabaseService get db => _db;

  // Геттеры для UI
  List<SignalNode> get nearbyNodes => _nearbyNodes.values.toList();
  bool get isP2pConnected => _isP2pConnected;
  bool get isHost => _isHost;

  // Потоки данных

  StreamSubscription<List<ScanResult>>? _scanSub;


  // 🔄 Event Bus replaces StreamControllers
  final EventBusService _eventBus = EventBusService();
  
  // Legacy StreamControllers (for backward compatibility during migration)
  final StreamController<String> _linkRequestController = StreamController.broadcast();
  Stream<String> get linkRequestStream => _linkRequestController.stream;

  final StreamController<List<SignalNode>> _discoveryController = StreamController.broadcast();
  Stream<List<SignalNode>> get discoveryStream => _discoveryController.stream;

  final StreamController<Map<String, dynamic>> _messageController = StreamController.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<String> _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  StreamController<Map<String, dynamic>> get messageController => _messageController;

  // Хранение всех логов для копирования
  final List<String> _allLogs = [];
  static const int _maxLogs = 1000; // 🔒 Reduced from 10000 to 1000 to prevent memory leaks

  /// Получить все логи для копирования
  List<String> getAllLogs() => List.unmodifiable(_allLogs);

  /// Получить все логи как одну строку
  String getAllLogsAsString() => _allLogs.join('\n');

  Timer? _cleanupTimer;
  bool _isP2pConnected = false;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final String _baseUrl = 'https://89.125.131.63:3000/api';
  
  // 🔒 Fix memory leaks: Periodic cleanup timer for cooldowns and timestamps
  Timer? _memoryCleanupTimer;

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

  Future<void> checkMyPower() async {
    final caps = await NativeMeshService.getHardwareCapabilities();
    _log("🛠️ HARDWARE REPORT: $caps");
  }

  // --- СИСТЕМА ОБНАРУЖЕНИЯ И ОЧИСТКИ ---

  Future<void> initBackgroundProtocols() async {
    _log("⚙️ Activating Autonomous Link...");

    // 1. 🛡️ HARDWARE AUDIT: Опрашиваем способности чипа
    // Это первая строка, чтобы Оркестратор знал, какие ресурсы у него есть.
    final caps = await NativeMeshService.getHardwareCapabilities();
    _log("🛠️ HARDWARE REPORT: $caps");

    // 2. 🔥 СТАБИЛИЗАЦИЯ (Wakelock)
    try {
      await WakelockPlus.enable();
    } catch (e) {
      _log("⚠️ Wakelock not supported");
    }

    // 3. 🚀 BACKGROUND PERSISTENCE: Запуск "бессмертного" сервиса
    await BackgroundService.start();

    // 4. 🧭 ADAPTIVE DISCOVERY: Выбор протокола на основе железа
    if (autoMesh) {
      if (caps['hasAware'] == true) {
        // Если Nova 13 подтвердит NAN, мы будем использовать его
        _log("💎 [Elite Path] Wi-Fi Aware detected. Prioritizing Silent Mesh.");
        // Пока используем стандартный старт, но помечаем в логах успех
        _startPeriodicDiscovery();
      } else {
        _log("🚜 [Legacy Path] NAN not supported. Using standard Wi-Fi Direct.");
        _startPeriodicDiscovery();
      }
    }

    if (autoBT) {
      _log("🦷 Engaging Bluetooth Control Plane...");
      startDiscovery(SignalType.bluetooth);
    }

    // 5. 🧹 MAINTENANCE: Очистка "призраков"
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pruneDeadNodes());

    _log("✅ Grid Core is now autonomous.");
  }

  /// 🔄 Периодический discovery для экономии батареи
  /// Запускает discovery каждые 45 секунд на 15 секунд
  void _startPeriodicDiscovery() {
    _periodicDiscoveryTimer?.cancel();
    
    // Первый запуск сразу
    startDiscovery(SignalType.mesh);
    
    // Затем периодически: каждые 45 секунд запускаем discovery на 15 секунд
    _periodicDiscoveryTimer = Timer.periodic(const Duration(seconds: 45), (timer) async {
      if (!_isMeshEnabled) {
        timer.cancel();
        return;
      }
      
      _log("📡 [Periodic] Starting discovery cycle...");
      
      // 🔥 КРИТИЧНО: Проверяем, не активен ли уже discovery
      final isDiscoveryActive = await NativeMeshService.checkDiscoveryState();
      if (isDiscoveryActive || _p2pDiscoveryActive) {
        _log("ℹ️ [Periodic] Discovery already active, skipping this cycle");
        return; // Пропускаем этот цикл, если discovery уже активен
      }
      
      // Retry логика для фонового режима
      int retries = 0;
      const maxRetries = 2; // Уменьшаем до 2 попыток, чтобы не жрать батарею
      
      while (retries < maxRetries) {
        final success = await startDiscovery(SignalType.mesh);
        
        if (success || _p2pDiscoveryActive) {
          _log("✅ [Periodic] Discovery started successfully");
          break;
        }
        
        retries++;
        if (retries < maxRetries) {
          _log("⚠️ [Periodic] Discovery failed, retrying in ${retries * 2}s... (attempt $retries/$maxRetries)");
          await Future.delayed(Duration(seconds: retries * 2));
        } else {
          _log("❌ [Periodic] Discovery failed after $maxRetries attempts, will retry next cycle");
        }
      }
      
      // Останавливаем через 15 секунд
      Future.delayed(const Duration(seconds: 15), () async {
        if (_p2pDiscoveryActive) {
          await stopDiscovery();
          _log("💤 [Periodic] Discovery paused (battery saving)");
        }
      });
    });
    
    _log("🔄 Periodic discovery started: every 45s, active for 15s");
  }

  Future<void> activateGroosaProtocol() async {
    _log("🚀 ACTIVATING GROOSA: Engaging all L0/L2 layers...");

    try {
      // 1. Включаем L0 (Звук)
      _log("⏳ Step 1: Starting UltrasonicService...");
      await locator<UltrasonicService>().startListening();
      _log("✅ UltrasonicService started");
    } catch (e, stack) {
      _log("❌ CRASH in UltrasonicService.startListening: $e");
      print("Stack: $stack");
    }

    try {
      // 2. Включаем L2 BLE (Прием + Передача)
      // Мы запускаем скан, а внутри _scanBluetooth уже есть startAdvertising
      _log("⏳ Step 2: Starting Bluetooth scan...");
      _scanBluetooth();
      _log("✅ Bluetooth scan started");
    } catch (e, stack) {
      _log("❌ CRASH in _scanBluetooth: $e");
      print("Stack: $stack");
    }

    try {
      // 3. Включаем L2 Wi-Fi (P2P Discovery)
      _log("⏳ Step 3: Starting Wi-Fi Direct discovery...");
      await NativeMeshService.startDiscovery();
      _log("✅ Wi-Fi Direct discovery started");
    } catch (e, stack) {
      _log("❌ CRASH in NativeMeshService.startDiscovery: $e");
      print("Stack: $stack");
    }

    try {
      // 4. Запускаем фоновый сервис, чтобы Android не убил "Спящего Агента"
      _log("⏳ Step 4: Starting background mesh service...");
      await NativeMeshService.startBackgroundMesh();
      _log("✅ Background mesh service started");
    } catch (e, stack) {
      _log("❌ CRASH in NativeMeshService.startBackgroundMesh: $e");
      print("Stack: $stack");
    }

    _log("✅ GROOSA ACTIVE: Node is now a fully functional Relay.");
    notifyListeners();
  }

  void addLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    print("[Mesh Log] $msg");

    // Добавляем в поток для терминала
    // 🔄 Event Bus: Fire status event
    _eventBus.bus.fire(StatusEvent("$timestamp > $msg"));
    // Legacy StreamController (for backward compatibility)
    _statusController.add("$timestamp > $msg");

    // Уведомляем UI (через Provider), что состояние обновилось
    notifyListeners();
  }
  Timer? _transferGuardTimer;

  Future<void> connectToNode(String address) async {
    // Если уже идет процесс, не плодим запросы
    if (_isTransferring) {
      _log("⚠️ [Block] Connection already in progress. Wait for timeout.");
      return;
    }

    _isTransferring = true;
    _log("🧨 [NUCLEAR-ATTACK] Target: $address. Engaging P2P Stack...");
    notifyListeners();

    // 🛡️ ТАЙМЕР-СТРАЖ (Watchdog)
    // Если через 20 секунд линк не поднимется — принудительно разблокируем систему
    _transferGuardTimer?.cancel();
    _transferGuardTimer = Timer(const Duration(seconds: 20), () {
      if (_isTransferring && !_isP2pConnected) {
        _log("🚨 [WATCHDOG] Connection timed out. Resetting local state.");
        _isTransferring = false;
        notifyListeners();
      }
    });

    try {
      // 1. ПРИНУДИТЕЛЬНЫЙ СБРОС: Перед каждым коннектом на Huawei/Tecno
      // нужно вызвать forceReset, чтобы вывести чип из состояния BUSY (2)
      _log("☢️ Executing Pre-emptive Stack Reset...");
      await NativeMeshService.forceReset();
      await Future.delayed(const Duration(milliseconds: 1500));

      // 2. ПОПЫТКА КОННЕКТА
      _log("🔗 Engaging Native Connect for $address");
      await NativeMeshService.connect(address);

    } catch (e) {
      _log("❌ [Link Fault] $e");
      _isTransferring = false;
      _transferGuardTimer?.cancel();
      notifyListeners();
    }
  }



  Future<void> engageSuperiorLink(SignalNode node) async {
    final caps = await NativeMeshService.getHardwareCapabilities();

    if (caps['hasAware'] == true) {
      // 🚀 ВАРИАНТ А: Wi-Fi Aware (NAN)
      // Никаких окон! Полный стелс и авто-линк.
      _log("💎 [Ultra-Link] Hardware supports NAN. Activating Silent Bridge...");
      await NativeMeshService.startAwareSession(node.id);
    }
    else {
      // 🚜 ВАРИАНТ Б: Wi-Fi Direct
      // Фолбек для старых/дешевых устройств. Будет окно.
      _log("🚜 [Legacy-Link] NAN not supported. Falling back to Wi-Fi Direct...");
      await connectToNode(node.id);
    }
  }



// --- 🧹 AGING POLICY: ОЧИСТКА СПИСКА ---
  void _pruneDeadNodes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    bool changed = false;

    // Удаляем ноды, которых не видели более 45 секунд
    _lastSeenTimestamps.removeWhere((id, ts) {
      if (now - ts > 45000) {
        _nearbyNodes.remove(id);
        changed = true;
        return true;
      }
      return false;
    });

    if (changed) {
      _log("🧹 Pruned dead nodes. Active: ${_nearbyNodes.length}");
      notifyListeners();
    }
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
      // 🔄 Event Bus: Fire nodes discovered event
      _eventBus.bus.fire(NodesDiscoveredEvent(nearbyNodes));
      // Legacy StreamController (for backward compatibility)
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


  // 🔥 ОБНОВЛЯЕМ ЭТОТ МЕТОД: Он теперь "авто-киллер"
  void handleNativePeers(List<dynamic> raw) {
    for (var item in raw) {
      final String addr = item['metadata'] ?? item['address'] ?? "";
      final String name = item['name'] ?? "WiFi_Node";
      if (addr.isEmpty) continue;

      // Регистрируем в UI только Wi-Fi ноды
      _registerNode(SignalNode(id: addr, name: name, type: SignalType.mesh, metadata: addr));

      // Если мы в режиме "Охоты" - цепляемся за первую же Wi-Fi ноду
      if (_isEscalating && !_isP2pConnected && !_isTransferring) {
        _log("🏹 Hunt Success: Found Wi-Fi target. Executing Link...");
        connectToNode(addr);
      }
    }
  }


  // Внутри MeshService

  Future<void> _executeCascadeTransfer(ScanResult target, int peerHops) async {
    final String mac = target.device.remoteId.str;
    final db = locator<LocalDatabaseService>();
    final pending = await db.getPendingFromOutbox();
    if (pending.isEmpty) return;

    final msgData = pending.first;
    final String payload = jsonEncode({
      'type': 'OFFLINE_MSG',
      'content': msgData['content'],
      'senderId': _apiService.currentUserId,
      'h': msgData['id'],
      'ttl': 5,
    });

    _isTransferring = true;
    _log("⛓️ Starting Cascade: Wi-Fi -> BLE -> Sonar");

    // --- СТУПЕНЬ 1: WI-FI DIRECT (DATA PLANE) ---
    _log("📡 Stage 1: Attempting Wi-Fi Direct...");
    try {
      await NativeMeshService.connect(mac);

      // Ждем 10 секунд. Если onNetworkConnected не сработал - Wi-Fi мертв.
      await Future.delayed(const Duration(seconds: 10));
      if (_isP2pConnected) {
        _log("✅ Stage 1 Success: Wi-Fi Direct Linked.");
        return;
      }
    } catch (e) {
      _log("⚠️ Stage 1 Failed: Wi-Fi Busy.");
    }

    // --- СТУПЕНЬ 2: BLUETOOTH GATT (CONTROL PLANE) ---
    if (!_isP2pConnected) {
      _log("🦷 Stage 2: Wi-Fi failed. Attacking via Bluetooth GATT...");

      // Включаем "Хищника"
      bool bleSuccess = false;
      try {
        await _btService.sendMessage(target.device, payload);
        bleSuccess = true; // sendMessage внутри имеет свои ретраи
        _log("✅ Stage 2 Success: Delivered via BLE GATT.");
        return;
      } catch (e) {
        _log("⚠️ Stage 2 Failed: GATT 133 or Timeout.");
      }
    }

    // --- СТУПЕНЬ 3: SONAR (ACOUSTIC PLANE) ---
    if (!_isP2pConnected) {
      _log("🔊 Stage 3: Radio silence detected. Escalating to SONAR...");

      try {
        // Шлем только хеш и Short-ID, чтобы сосед понял, что у нас есть почта
        // Весь месседж в сонар не влезет, но это "пинок" для соседа
        await locator<UltrasonicService>().transmitFrame("REQ:${msgData['id']}");
        _log("✅ Stage 3 Success: Sonar Alert emitted.");
      } catch (e) {
        _log("❌ Stage 3 Failed: Audio HAL busy.");
      }
    }

    _isTransferring = false;
    notifyListeners();
  }

  int _failedRadioCycles = 0;

  void handleRadioSilence() {
    _failedRadioCycles++;

    if (_failedRadioCycles >= 3) {
      _log("🚨 TOTAL RADIO SILENCE DETECTED. Escalating to Acoustic Sovereignty...");
      // Увеличиваем частоту и громкость Сонара для пробития среды
      locator<UltrasonicService>().transmitBeacon();
      _failedRadioCycles = 0;
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
    // 🔄 Event Bus: Fire link request event
    _eventBus.bus.fire(LinkRequestEvent(senderId));
    // Legacy StreamController (for backward compatibility)
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
    String? messageId,
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
    final String tempId = messageId ?? "temp_${DateTime.now().millisecondsSinceEpoch}";

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

    bool messageDeliveredToNetwork = false;
    bool messageDeliveredToParticipants = false;
    final db = LocalDatabaseService();

    // ==========================================
    // 🛰️ КАНАЛ 0: ROUTER (Wi-Fi Router) - HIGHEST PRIORITY
    // ==========================================
    final routerConnection = RouterConnectionService();
    final connectedRouter = routerConnection.connectedRouter;
    if (connectedRouter != null && connectedRouter.hasInternet) {
      try {
        _log("🛰️ Router: Attempting transmission via ${connectedRouter.ssid}...");
        final routerProtocol = RouterBridgeProtocol();
        // Если мы BRIDGE через роутер - отправляем в облако
        if (currentRole == MeshRole.BRIDGE) {
          await WebSocketService().ensureConnected();
          await WebSocketService().send({
            "type": "message",
            "chatId": targetId,
            "content": content,
            "clientTempId": tempId,
          });
          _log("🛰️ Router: Signal delivered via router to Cloud.");
          messageDeliveredToNetwork = true;
          messageDeliveredToParticipants = true; // Cloud доставляет участникам
        } else {
          // Если мы GHOST через роутер - используем протокол роутера для передачи другим устройствам
          // TODO: Реализовать передачу через роутер для GHOST устройств
          _log("🛰️ Router: Router available but GHOST mode, using mesh fallback");
        }
      } catch (e) {
        _log("⚠️ Router: Transmission failed, falling back to mesh: $e");
      }
    }

    // ==========================================
    // 🌐 КАНАЛ 1: CLOUD (Uplink via Bridge)
    // ==========================================
    if (currentRole == MeshRole.BRIDGE && connectedRouter == null) {
      try {
        await WebSocketService().ensureConnected();
        await WebSocketService().send({
          "type": "message",
          "chatId": targetId,
          "content": content, // Внутренний метод WebSocket сам зашифрует
          "clientTempId": tempId,
        });
        _log("☁️ Cloud: Signal delivered to Command Center.");
        messageDeliveredToNetwork = true;
        messageDeliveredToParticipants = true; // Cloud доставляет участникам
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
      messageDeliveredToNetwork = true;
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
      messageDeliveredToNetwork = true;
    }

    // Обновляем статус сообщения
    if (messageId != null) {
      if (messageDeliveredToParticipants) {
        await db.updateMessageStatus(messageId, MessageStatus.deliveredToParticipants);
      } else if (messageDeliveredToNetwork) {
        await db.updateMessageStatus(messageId, MessageStatus.deliveredToNetwork);
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
    // Статус уже установлен в conversation_screen.dart, здесь только сохраняем если нужно
    if (messageId == null) {
      final myMsg = ChatMessage(
          id: tempId,
          content: content,
          senderId: api.currentUserId,
          createdAt: DateTime.now(),
          status: messageDeliveredToNetwork ? MessageStatus.deliveredToNetwork : MessageStatus.sending
      );

      await db.saveMessage(myMsg, targetId);

      if (currentRole == MeshRole.GHOST) {
        await db.addToOutbox(myMsg, targetId);
        _log("🦠 Virus: Signal incubated in Outbox.");
      }
    } else if (currentRole == MeshRole.GHOST && !messageDeliveredToNetwork) {
      // Если сообщение еще не доставлено и мы GHOST - добавляем в outbox
      final myMsg = ChatMessage(
          id: tempId,
          content: content,
          senderId: api.currentUserId,
          createdAt: DateTime.now(),
          status: MessageStatus.sending
      );
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

    // 1. Проверяем локальный статус (Self-check)
    await NetworkMonitor().checkNow();
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      _log("✅ Internet found on this device.");
      _isSearchingUplink = false;
      notifyListeners();
      return;
    }

    // 2. Подготовка поискового сигнала
    final probe = jsonEncode({
      'type': 'MAGNET_QUERY',
      'senderId': _apiService.currentUserId,
    });

    // 3. ТАКТИЧЕСКИЙ ПРОБРОС (Только по живым IP-каналам)
    // Мы шлем TCP только тем, у кого метаданные — это реальный IP, а не MAC
    for (var node in _nearbyNodes.values) {
      final String metadata = node.metadata;

      // Фильтр: Если в адресе есть ":" — это MAC-адрес Bluetooth, TCP туда слать НЕЛЬЗЯ.
      // Если это только цифры и точки — это IP Wi-Fi Direct.
      if (node.type == SignalType.mesh && !metadata.contains(":")) {
        _log("🔗 Probing Wi-Fi peer via TCP: $metadata");
        NativeMeshService.sendTcp(probe, host: metadata);
      }
    }

    // 4. ЭСКАЛАЦИЯ НА BLUETOOTH (Zero-Connect Growth)
    // Если мы ищем аплинк, нам нужно обновить "зрение" через Bluetooth
    _scanBluetooth();

    // 5. Таймаут поиска
    Timer(const Duration(seconds: 20), () {
      _isSearchingUplink = false;
      notifyListeners();
      _log("⌛ Uplink probe cycle completed.");
    });
  }

  // --- СЕТЕВАЯ ЛОГИКА ---

  Future<bool> startDiscovery(SignalType type) async {
    if (!_isMeshEnabled) return false;

    // 🔥 ПРОВЕРКА GPS ДЛЯ BLUETOOTH
    if (type == SignalType.bluetooth || type == SignalType.mesh) {
      bool gpsStatus = await Geolocator.isLocationServiceEnabled();
      if (_isGpsEnabled != gpsStatus) {
        _isGpsEnabled = gpsStatus;
        notifyListeners(); // Уведомляем UI, чтобы показать ошибку
      }

      if (!gpsStatus) {
        _log("❌ Scan blocked: GPS is OFF. Please enable Location.");
        return false;
      }
    }

    // 🔥 ПРОВЕРКА Wi-Fi Direct ДЛЯ MESH/WIFI_DIRECT
    if (type == SignalType.mesh || type == SignalType.wifiDirect) {
      final isP2pEnabled = await NativeMeshService.checkP2pState();
      if (!isP2pEnabled) {
        _log("⚠️ Wi-Fi Direct is DISABLED. Requesting activation...");
        await NativeMeshService.requestP2pActivation();
        _log("📱 Please enable Wi-Fi Direct in settings and try again.");
        return false;
      }
    }

    _log("📡 Scanning: ${type.name.toUpperCase()}");
    if (type == SignalType.mesh || type == SignalType.wifiDirect) {
      // Проверяем состояние Wi-Fi Direct перед запуском
      final isP2pEnabled = await NativeMeshService.checkP2pState();
      if (!isP2pEnabled) {
        _log("⚠️ Wi-Fi Direct is disabled, skipping discovery");
        return false;
      }
      
      // 🔥 КРИТИЧНО: Проверяем, не активен ли уже discovery
      final isDiscoveryActive = await NativeMeshService.checkDiscoveryState();
      if (isDiscoveryActive || _p2pDiscoveryActive) {
        _log("ℹ️ Discovery already active, skipping duplicate start");
        return true; // Возвращаем true, так как discovery уже работает
      }
      
      final success = await NativeMeshService.startDiscovery();
      if (success) {
        _p2pDiscoveryActive = true;
        _log("✅ Wi-Fi Direct discovery started");
        if (type == SignalType.bluetooth) _scanBluetooth();
        return true;
      } else {
        _log("❌ Failed to start Wi-Fi Direct discovery");
        _p2pDiscoveryActive = false;
        if (type == SignalType.bluetooth) _scanBluetooth();
        return false;
      }
    }
    if (type == SignalType.bluetooth) {
      _scanBluetooth();
      return true;
    }
    return true;
  }

  // Добавь проверку в метод инициализации, чтобы сразу знать статус
  Future<void> checkHardwareStatus() async {
    _isGpsEnabled = await Geolocator.isLocationServiceEnabled();
    notifyListeners();
  }


  // 🔥 ТЕПЕРЬ ЭТО FUTURE, чтобы BackgroundService мог его "ждать"
  Future<void> stopDiscovery() async {
    try {
      _log("🛑 Attempting to stop P2P discovery...");
      await NativeMeshService.stopDiscovery();
    } catch (e) {
      if (e.toString().contains("2")) {
        _log("☢️ [P2P-CRITICAL] Stack Deadlock detected (Error 2). Executing Force Reset...");
        // Вызываем ядерный сброс
        await NativeMeshService.forceReset();
      } else {
        _log("⚠️ Stop Discovery warning: $e");
      }
    } finally {
      await FlutterBluePlus.stopScan();
    }
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




  bool _isEscalating = false; // Флаг режима "Охоты по Wi-Fi"






  String? _targetIdToHunt;


  Future<void> _scanBluetooth() async {
    if (!_isMeshEnabled) {
      _log("⚠️ [BT-SCAN] Scan blocked: Mesh not enabled");
      return;
    }
    if (_isBtScanning) {
      _log("⚠️ [BT-SCAN] Scan already in progress, skipping");
      return;
    }
    
    _isBtScanning = true;
    final currentRole = NetworkMonitor().currentRole;
    _log("🔍 [BT-SCAN] Starting BLE scan (role: ${currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST'})");

    try {
      final orchestrator = locator<TacticalMeshOrchestrator>();
      final pendingCount = await _db.getOutboxCount();

      // 1. ВЕЩАНИЕ (Маяк)
      final String rawUserId = _apiService.currentUserId;
      // Безопасное извлечение короткого ID (максимум 4 символа, но не падаем если короче)
      final String myShortId = rawUserId.isNotEmpty && rawUserId.length >= 4 
          ? rawUserId.substring(0, 4) 
          : (rawUserId.isNotEmpty ? rawUserId : "GHST");
      
      // Формат: M_Hops_HasData_ID (максимум ~20 символов для BLE)
      final String myTacticalName = "M_${orchestrator.myHops}_${pendingCount > 0 ? '1' : '0'}_$myShortId";
      
      // 🔍 ЛОГИРОВАНИЕ для отладки
      _log("📡 [ADV] Setting tactical name: '$myTacticalName' (length: ${myTacticalName.length})");

      await _btService.stopAdvertising();
      await _btService.startAdvertising(myTacticalName);

      // 2. СКАНИРОВАНИЕ
      await _scanSub?.cancel();
      await FlutterBluePlus.stopScan();

      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        // 🔥 Discovery Context: Обновляем контекст, НЕ принимаем решения напрямую
        final discoveryContext = locator<DiscoveryContextService>();
        final isGhost = NetworkMonitor().currentRole == MeshRole.GHOST;
        int meshDevicesCount = 0;
        
        if (results.isNotEmpty) {
          _log("🔍 [BT-SCAN] Received ${results.length} scan result(s), updating discovery context...");
        }
        
        for (ScanResult r in results) {
          // 🔥 Discovery Context: Обновляем контекст из BLE scan
          // Это НЕ инициирует подключение, только обновляет контекст
          discoveryContext.updateFromBleScan(r);
          final String advName = r.advertisementData.localName ?? "";
          final String platformName = r.device.platformName;
          final String mac = r.device.remoteId.str;
          
          // 🔥 FIX: Если localName пустое, используем platformName как fallback
          final String effectiveName = advName.isEmpty ? platformName : advName;
          
          // 🔍 ДИАГНОСТИКА: Детальный лог RAW данных сканера
          _log("🔍 [DEBUG] RAW SCAN DATA:");
          _log("   MAC: $mac");
          _log("   localName: '${advName.isEmpty ? 'EMPTY' : advName}'");
          _log("   platformName: '${platformName.isEmpty ? 'EMPTY' : platformName}'");
          _log("   effectiveName: '${effectiveName.isEmpty ? 'EMPTY' : effectiveName}'");
          _log("   serviceUUIDs: ${r.advertisementData.serviceUuids}");
          _log("   manufacturerData: ${r.advertisementData.manufacturerData}");
          
          // 🔍 ФИЛЬТР: Только устройства мессенджера (по service UUID ИЛИ тактическому имени)
          // 🔥 УЛУЧШЕННАЯ ПРОВЕРКА: Проверяем наличие SERVICE_UUID в advertising data
          final bool hasServiceUuid = r.advertisementData.serviceUuids
              .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
          
          // 🔥 FIX: Проверяем manufacturerData для определения роли (fallback если имя пустое)
          final mfData = r.advertisementData.manufacturerData[0xFFFF];
          final bool isBridgeByMfData = mfData != null && 
              mfData.length >= 2 && 
              mfData[0] == 0x42 && 
              mfData[1] == 0x52; // "BR" = BRIDGE
          final bool isGhostByMfData = mfData != null && 
              mfData.length >= 2 && 
              mfData[0] == 0x47 && 
              mfData[1] == 0x48; // "GH" = GHOST
          
          // Дополнительная проверка: если имя начинается с "M_", считаем это mesh устройством
          // даже если SERVICE_UUID не найден (для обратной совместимости)
          final bool isMeshByName = effectiveName.startsWith("M_");
          
          if (!hasServiceUuid && !isMeshByName && !isBridgeByMfData && !isGhostByMfData) {
            continue; // Пропускаем устройства без нашего сервиса и без тактического имени
          }
          
          // Логируем детали для отладки
          if (!hasServiceUuid && isMeshByName) {
            _log("⚠️ [BT-SCAN] Mesh device found by name but without SERVICE_UUID: '$effectiveName'");
            _log("   Available UUIDs: ${r.advertisementData.serviceUuids.map((u) => u.toString()).join(', ')}");
          }
          final bool hasTacticalName = effectiveName.startsWith("M_");
          final bool isOurNode = hasServiceUuid || hasTacticalName || isBridgeByMfData || isGhostByMfData;
          
          // Пропускаем все устройства, которые не относятся к мессенджеру
          if (!isOurNode) continue;
          
          meshDevicesCount++;
          
          // 🧲 ЛОГИРОВАНИЕ только устройств мессенджера
          _log("🔍 [BT-SCAN] ✅ Mesh device: '$effectiveName' (MAC: ${mac.substring(mac.length - 8)})");
          
          // 🧲 ДЕТАЛЬНОЕ ЛОГИРОВАНИЕ для отладки BRIDGE обнаружения
          if (hasTacticalName) {
            _log("🔍 [BT-SCAN] ✅ Found tactical node: '$effectiveName' (MAC: ${mac.substring(mac.length - 8)})");
          }
          
          // Логируем найденное устройство для отладки
          if (hasTacticalName && !hasServiceUuid) {
            _log("🔍 [BT-SCAN] Found tactical node '$effectiveName' but service UUID missing (Huawei/Tecno quirk?)");
          }
          
          // 🔥 FIX: Если BRIDGE обнаружен через manufacturerData
          if (isBridgeByMfData) {
            _log("🧲 [Ghost] ⚡ BRIDGE detected via manufacturerData! (MAC: ${mac.substring(mac.length - 8)})");
          }

          int peerHops = 99;
          bool peerHasData = false;
          String peerId = mac.substring(mac.length - 4);
          String? bridgeToken;

          // 🔥 FIX: Используем effectiveName вместо advName
          if (effectiveName.startsWith("M_")) {
            final parts = effectiveName.split("_");
            if (parts.length >= 4) {
              peerHops = int.tryParse(parts[1]) ?? 99;
              peerHasData = parts[2] == "1";
              peerId = parts[3];
              
              // 🔥 КРИТИЧНО: Логируем все найденные устройства для диагностики
              if (peerHops == 0) {
                _log("🧲 [Ghost] ⚡ BRIDGE DETECTED! Hops=0, Name: '$effectiveName', MAC: ${mac.substring(mac.length - 8)}");
              }
              
              // 🧲 ОБРАБОТКА BRIDGE: Извлекаем зашифрованный токен из имени
              // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN или M_0_0_BRIDGE_ENCRYPTED_TOKEN
              // 🔒 SECURITY: Token is now HMAC-encrypted, not plaintext
              if (parts.length >= 5 && parts[3] == "BRIDGE") {
                final encryptedToken = parts[4]; // Encrypted token from advertising name
                final tokenPreview = encryptedToken.length > 8 ? encryptedToken.substring(0, 8) : encryptedToken;
                _log("🧲 [Ghost] BRIDGE detected in BLE advertising! Encrypted token: $tokenPreview..., Hops: $peerHops");
                
                // Если мы GHOST и есть зашифрованный токен - обрабатываем как MAGNET_WAVE
                // Note: We'll need the actual token from TCP connection, not from BLE
                // BLE only provides encrypted hint for discovery
                if (NetworkMonitor().currentRole == MeshRole.GHOST && encryptedToken.isNotEmpty) {
                  // 🔒 SECURITY: Encrypted token in BLE is just a hint for discovery
                  // Actual token verification happens during TCP connection
                  // 🔥 ШАГ 3: Токен валиден 30 секунд
                  final expiresAt = DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
                  _log("🧲 [Ghost] Processing MAGNET_WAVE hint from BLE advertising (encrypted: $tokenPreview...)");
                  // Note: We can't decrypt token from BLE alone - need full MAGNET_WAVE packet via TCP
                  // This is just for discovery - actual connection uses TCP with full signed packet
                }
              } else if (peerHops == 0) {
                // 🔥 КРИТИЧНО: BRIDGE может рекламировать без токена в имени (старый формат или до emitInternetMagnetWave)
                // Но hops=0 означает BRIDGE - обрабатываем немедленно
                _log("🧲 [Ghost] ⚡ BRIDGE DETECTED (hops=0)! Name: '$effectiveName', MAC: ${mac.substring(mac.length - 8)}");
                
                // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверяем token ПЕРЕД вызовом Cascade
                String? extractedToken;
                if (effectiveName.startsWith("M_")) {
                  final parts = effectiveName.split("_");
                  if (parts.length >= 5 && parts[3] == "BRIDGE") {
                    extractedToken = parts[4];
                  }
                }
                
                // Проверяем manufacturerData для token (fallback для Huawei)
                if (extractedToken == null) {
                  final mfData = r.advertisementData.manufacturerData[0xFFFF];
                  if (mfData != null && mfData.length > 2 && mfData[0] == 0x42 && mfData[1] == 0x52) {
                    try {
                      final tokenBytes = mfData.sublist(2);
                      extractedToken = utf8.decode(tokenBytes);
                    } catch (e) {
                      // Не удалось декодировать token
                    }
                  }
                }
                
                if (extractedToken == null) {
                  // 🔥 ШАГ 2.2: Токен не найден - fallback на Sonar
                  _log("🚫 [ARCHITECTURE] BRIDGE without token — Cascade FORBIDDEN");
                  _log("   📋 Effective name: '$effectiveName'");
                  _log("   📋 Platform name: '$platformName'");
                  _log("   📋 MAC: ${mac.substring(mac.length - 8)}");
                  _log("   ⚠️ Token not found in advertising - possible reasons:");
                  _log("      1. BRIDGE hasn't updated advertising yet (timing issue)");
                  _log("      2. Token expired (>30s old)");
                  _log("      3. BLE stack delay on BRIDGE device (Huawei/Android)");
                  
                  // 🔥 ШАГ 4.1: Повторное сканирование через 1-2 секунды, если токен не найден
                  _pendingBridgeConnections[mac] = DateTime.now();
                  Future.delayed(const Duration(seconds: 2), () async {
                    _log("🔄 [GHOST] Retry scan for BRIDGE token (MAC: ${mac.substring(mac.length - 8)})...");
                    try {
                      await startDiscovery(SignalType.bluetooth);
                      await Future.delayed(const Duration(seconds: 5)); // Сканируем 5 секунд
                      await stopDiscovery();
                      
                      // 🔥 ШАГ 4.2: После получения токена - сразу инициировать подключение
                      // Проверяем, появился ли токен в DiscoveryContext
                      final discoveryContext = locator<DiscoveryContextService>();
                      final updatedCandidate = discoveryContext.getCandidateByMac(mac);
                      if (updatedCandidate != null && updatedCandidate.bridgeToken != null) {
                        _log("✅ [GHOST] Token found after retry scan - initiating connection...");
                        _pendingBridgeConnections.remove(mac);
                        // Инициируем подключение через Cascade
                        final lastScanResults = await FlutterBluePlus.lastScanResults;
                        for (final result in lastScanResults) {
                          if (result.device.remoteId.str == mac) {
                            unawaited(_executeCascadeRelay(result, 0));
                            break;
                          }
                        }
                      } else {
                        _log("⚠️ [GHOST] Token still not found after retry scan");
                      }
                    } catch (e) {
                      _log("⚠️ [GHOST] Retry scan failed: $e");
                    }
                  });
                  
                  _log("   Escalating directly to Sonar (no BLE GATT, no TCP)");
                  
                  // Помечаем BRIDGE как запрещенный для GATT
                  final discoveryContext = locator<DiscoveryContextService>();
                  final candidate = discoveryContext.getCandidateByMac(mac);
                  if (candidate != null) {
                    discoveryContext.markBridgeAsGattForbidden(candidate.id);
                  }
                  
                  // Сразу переходим к Sonar
                  if (pendingCount > 0) {
                    var pending = <Map<String, dynamic>>[];
                    try {
                      pending = await _db.getPendingFromOutbox();
                      if (pending.isNotEmpty) {
                        final msgId = pending.first['id'] as String;
                        // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
                        if (_sentPayloads.containsKey(msgId)) {
                          _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
                          return;
                        }
                        
                        final messageData = jsonEncode({
                          'type': 'OFFLINE_MSG',
                          'content': pending.first['content'],
                          'senderId': _apiService.currentUserId,
                          'h': msgId,
                          'ttl': 5,
                        });
                        final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
                        await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
                        
                        // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
                        _sentPayloads[msgId] = 'SONAR';
                        await _db.removeFromOutbox(msgId);
                        _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (SONAR), removed from outbox");
                        _log("✅ Sonar Packet Emitted (BRIDGE without token). Cycle CLOSED.");
                      }
                    } catch (e) {
                      final msgId = pending.isNotEmpty ? pending.first['id'] as String : 'unknown';
                      _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
                      _log("❌ Sonar failed: $e");
                    }
                  }
                  return; // Прерываем - не запускаем Cascade
                }
                
                // Запускаем каскадное подключение для BRIDGE с token
                if (pendingCount > 0 && !_linkCooldowns.containsKey(mac) && !_isTransferring) {
                  _linkCooldowns[mac] = DateTime.now();
                  _log("🧲 [Ghost] Initiating connection to BRIDGE (hops=0, token: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}...) with $pendingCount pending messages...");
                  unawaited(_executeCascadeRelay(r, peerHops));
                } else if (pendingCount == 0) {
                  _log("ℹ️ [Ghost] BRIDGE detected but no pending messages to upload");
                }
              }
            }
          } else if (isBridgeByMfData) {
            // 🔥 FALLBACK: Если имя пустое, но manufacturerData указывает на BRIDGE
            peerHops = 0;
            _log("🧲 [Ghost] ⚡ BRIDGE detected via manufacturerData fallback! (MAC: ${mac.substring(mac.length - 8)})");
            
            // Запускаем каскадное подключение для BRIDGE
            if (pendingCount > 0 && !_linkCooldowns.containsKey(mac) && !_isTransferring) {
              _linkCooldowns[mac] = DateTime.now();
              _log("🧲 [Ghost] Initiating connection to BRIDGE (via manufacturerData) with $pendingCount pending messages...");
              unawaited(_executeCascadeRelay(r, peerHops));
            }
          } else if (isGhostByMfData) {
            // 🔥 FALLBACK: Если имя пустое, но manufacturerData указывает на GHOST
            // Используем hops из Orchestrator (если есть сосед с меньшими hops)
            peerHops = 99; // По умолчанию
            _log("🧲 [Ghost] GHOST detected via manufacturerData fallback! (MAC: ${mac.substring(mac.length - 8)})");
          }

          // ТИХОЕ ОБНОВЛЕНИЕ ГРАДИЕНТА (БЕЗ UI)
          orchestrator.processRoutingPulse(RoutingPulse(
            nodeId: peerId, hopsToInternet: peerHops, batteryLevel: 1.0, queuePressure: peerHasData ? 1 : 0,
          ));

          // 🔥 КРИТИЧНО: GHOST должен подключаться к BRIDGE (hops=0) независимо от своих hops
          // Если мы GHOST и нашли BRIDGE (hops=0) - подключаемся немедленно
          final isBridge = peerHops == 0;
          final shouldConnect = isBridge || (pendingCount > 0 && peerHops < orchestrator.myHops);
          
          if (shouldConnect) {
            if (!_linkCooldowns.containsKey(mac) && !_isTransferring) {
              _linkCooldowns[mac] = DateTime.now();
              if (isBridge) {
                _log("🧲 [Ghost] BRIDGE detected (hops=0)! Initiating connection immediately...");
              }
              _executeCascadeRelay(r, peerHops); // Вызываем наш каскад
              break;
            }
          }
        }
        
        // Логируем итоговое количество найденных устройств мессенджера
        if (meshDevicesCount > 0) {
          _log("🔍 [BT-SCAN] Summary: Found $meshDevicesCount mesh device(s)");
        }
        
        // 🔥 КРИТИЧНО: После сканирования проверяем, есть ли BRIDGE для forced send
        if (NetworkMonitor().currentRole == MeshRole.GHOST && pendingCount > 0) {
          await _checkForBridgeAndForceSend();
        }
      });

      // 🧲 Для GHOST - сканируем с фильтром SERVICE_UUID (оптимизация для 100k+ пользователей)
      // 🔥 ИСПРАВЛЕНИЕ: GHOST сканирует БЕЗ фильтра SERVICE_UUID, чтобы видеть BRIDGE по тактическому имени
      // BRIDGE может не рекламировать SERVICE_UUID, если GATT server не запустился
      final isGhost = NetworkMonitor().currentRole == MeshRole.GHOST;
      final scanDuration = isGhost ? const Duration(seconds: 30) : const Duration(seconds: 10);
      
      // Только BRIDGE использует фильтр SERVICE_UUID (для поиска других BRIDGE)
      // GHOST сканирует БЕЗ фильтра, чтобы видеть BRIDGE по тактическому имени
      final useFilter = !isGhost;
      
      _log("🔍 [BT-SCAN] Configuring scan: duration=${scanDuration.inSeconds}s, role=${isGhost ? 'GHOST' : 'BRIDGE'}, filter=${useFilter ? 'SERVICE_UUID' : 'NONE (check tactical names)'}");
      
      try {
        if (useFilter) {
          // BRIDGE сканирует с фильтром SERVICE_UUID для поиска других BRIDGE или GHOST с GATT server
          await FlutterBluePlus.startScan(
            withServices: [Guid(_btService.SERVICE_UUID)],
            timeout: scanDuration,
          );
          _log("✅ [BT-SCAN] BLE scan started successfully (SERVICE_UUID filter)");
        } else {
          // GHOST сканирует БЕЗ фильтра, чтобы видеть BRIDGE по тактическому имени
          await FlutterBluePlus.startScan(
            timeout: scanDuration,
          );
          _log("✅ [BT-SCAN] BLE scan started successfully (no filter)");
        }
      } catch (e) {
        _log("❌ [BT-SCAN] Failed to start scan: $e");
        _isBtScanning = false;
        return;
      }

    } catch (e) { 
      _log("❌ [BT-SCAN] BT Radar Error: $e");
      _isBtScanning = false;
    }
    finally { 
      Future.delayed(const Duration(seconds: 10), () {
        _isBtScanning = false;
        _log("🔍 [BT-SCAN] Scan session ended");
      });
    }
  }

  // ============================================================
  // ⛓️ КАСКАДНЫЙ ПРОТОКОЛ (WiFi -> BLE -> Sonar)
  // ============================================================

  // 🔥 Улучшение: Счётчики попыток для агрессивного fallback на TCP
  final Map<String, int> _bleGattAttempts = {}; // MAC -> количество неудачных попыток BLE GATT
  final Map<String, DateTime> _pendingConnections = {}; // MAC -> время добавления в очередь
  
  // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Трекинг отправленных payload в текущем цикле
  // Ключ: messageId, Значение: транспорт (BLE/TCP/SONAR)
  // Очищается периодически (каждые 10 минут) для предотвращения утечек памяти
  final Map<String, String> _sentPayloads = {}; // messageId -> transport
  
  // 🔥 МАСШТАБИРУЕМОСТЬ: Ограничение активных payload (10-20 на узел)
  static const int _maxActivePayloads = 15; // Максимальное количество одновременно активных payload
  final Set<String> _activePayloads = {}; // messageId -> активные payload в обработке
  
  // 🔥 МАСШТАБИРУЕМОСТЬ: Retry strategy с ограничением попыток
  final Map<String, PayloadRetryInfo> _payloadRetries = {}; // messageId -> информация о попытках
  
  // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивные таймауты на основе предыдущих успехов/неудач
  final Map<String, TransportLatency> _transportLatencies = {}; // MAC -> статистика задержек транспорта
  
  // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельные таймеры для каждого транспорта
  Timer? _gattTimeoutTimer;
  Timer? _tcpTimeoutTimer;
  Timer? _sonarTimeoutTimer;
  
  // 🔥 ШАГ 1.3: Поддержка стабильного токена (минимум 10 секунд стабильности перед сменой)
  DateTime? _lastTokenUpdate;
  static const Duration _minTokenStability = Duration(seconds: 10); // Минимум 10 секунд стабильности
  
  // 🔥 ШАГ 4.2: Очередь сообщений - если GATT/TCP заблокированы, payload остаются в outbox
  // После получения токена - сразу инициировать подключение
  final Map<String, DateTime> _pendingBridgeConnections = {}; // MAC -> время обнаружения BRIDGE без токена
  
  // 🔥 КРИТИЧНО: Per-BRIDGE lock для предотвращения race condition при одновременных подключениях
  final Map<String, DateTime> _activeBridgeConnections = {}; // MAC -> время начала подключения
  
  /// Публичный метод для Connection Stabilizer
  Future<void> executeCascadeRelay(ScanResult target, int peerHops) async {
    await _executeCascadeRelay(target, peerHops);
  }
  
  Future<void> _executeCascadeRelay(ScanResult target, int peerHops) async {
    final targetMac = target.device.remoteId.str;
    
    // 🔥 Улучшение: Проверяем, не превышен ли лимит попыток BLE GATT
    final gattAttempts = _bleGattAttempts[targetMac] ?? 0;
    if (gattAttempts >= 2 && peerHops == 0) {
      // Если BLE GATT не удался >2 раз для BRIDGE, сразу пробуем TCP
      _log("🔄 [Cascade] BLE GATT failed $gattAttempts times, trying TCP fallback immediately");
      final candidate = locator<DiscoveryContextService>().getCandidateByMac(targetMac);
      if (candidate != null && candidate.ip != null && candidate.port != null) {
        _isTransferring = true;
        notifyListeners();
        try {
          if (candidate.bridgeToken != null) {
            // 🔥 СИНХРОНИЗАЦИЯ: Увеличено до 45 секунд для синхронизации с новым временем жизни токена
            // 🔥 ШАГ 3: Токен валиден 30 секунд
            await _handleMagnetWave(candidate.bridgeToken!, candidate.port!, 
                DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch);
            _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе
            _isTransferring = false;
            notifyListeners();
            return;
          }
        } catch (e) {
          _log("❌ [Cascade] TCP fallback also failed: $e");
        }
      }
    }
    
    // 🔥 Улучшение: Если transfer уже идёт, добавляем в очередь
    if (_isTransferring) {
      _log("⏸️ [Cascade] Transfer in progress, queuing connection to $targetMac");
      _pendingConnections[targetMac] = DateTime.now();
      // Проверяем, не слишком ли старая очередь (больше 30 секунд)
      final queueTime = _pendingConnections[targetMac]!;
      if (DateTime.now().difference(queueTime).inSeconds > 30) {
        _log("⏸️ [Cascade] Queued connection expired, removing from queue");
        _pendingConnections.remove(targetMac);
        return;
      }
      // Будем пытаться подключиться после завершения текущего transfer
      return;
    }
    
    _isTransferring = true;
    notifyListeners();
    _log("⛓️ Engaging Cascade for node ${target.device.remoteId}");

    // 🔥 Улучшение: Добавляем таймаут для автоматического сброса зависших transfer
    Timer? transferTimeoutTimer;
    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Watchdog таймаут = сумма всех транспортов (BLE 10s + TCP 5s + запас)
    transferTimeoutTimer = Timer(const Duration(seconds: 20), () {
      if (_isTransferring) {
        _log("🚨 [WATCHDOG] Transfer timeout (20s). Resetting _isTransferring flag.");
        _isTransferring = false;
        notifyListeners();
      }
    });

    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) { 
      transferTimeoutTimer?.cancel();
      _isTransferring = false; 
      notifyListeners();
      return; 
    }
    
    // 🔥 МАСШТАБИРУЕМОСТЬ: Ограничение активных payload (10-20 на узел)
    // Обрабатываем только первые _maxActivePayloads сообщений
    final activePending = pending.take(_maxActivePayloads).toList();
    if (activePending.isEmpty) {
      _log("⏸️ [Scalability] No active payloads available (all in processing)");
      transferTimeoutTimer?.cancel();
      _isTransferring = false;
      notifyListeners();
      return;
    }
    
    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Извлекаем messageId из первого активного pending сообщения
    final messageId = activePending.first['id'] as String;
    
    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем, не превышен ли лимит попыток для этого payload
    final retryInfo = _payloadRetries.putIfAbsent(messageId, () => PayloadRetryInfo());
    if (retryInfo.maxRetriesReached) {
      _log("⏸️ [Scalability] Payload $messageId exceeded max retries (GATT: ${retryInfo.gattAttempts}, TCP: ${retryInfo.tcpAttempts}, Sonar: ${retryInfo.sonarAttempts})");
      _activePayloads.remove(messageId);
      transferTimeoutTimer?.cancel();
      _isTransferring = false;
      notifyListeners();
      return;
    }
    
    // 🔥 МАСШТАБИРУЕМОСТЬ: Отмечаем payload как активный и записываем время начала цикла
    if (!_activePayloads.contains(messageId)) {
      _activePayloads.add(messageId);
      retryInfo.cycleStartTime = DateTime.now();
      retryInfo.outboxSizeAtStart = pending.length;
      retryInfo.hopsToBridge = peerHops; // Сохраняем hops для логирования
      _log("📊 [Scalability] Starting cycle for payload $messageId (outbox size: ${pending.length}, active: ${_activePayloads.length}/${_maxActivePayloads}, hops: $peerHops)");
    }
    
    // 🔥 Улучшение: Сохраняем ссылку на таймаут для отмены при успешном завершении
    // (будет использовано в конце функции)

    // 🔥 GHOST ↔ GHOST PROTECTION: Проверяем, что мы не оба пытаемся подключиться одновременно
    final myRole = NetworkMonitor().currentRole;
    final orchestrator = locator<TacticalMeshOrchestrator>();
    final myHops = orchestrator.myHops;
    final myPendingCount = pending.length;
    
    // Извлекаем роль пира из advertising name и hops
    final advName = target.advertisementData.localName ?? '';
    // 🔥 КРИТИЧНО: Определяем роль по hops, а не по имени!
    // Если hops=0, это BRIDGE, независимо от имени (BRIDGE может рекламировать M_0_0_9ff4 без слова "BRIDGE")
    final bool peerIsBridge = peerHops == 0;
    final bool peerIsGhost = !peerIsBridge && !advName.contains('BRIDGE');
    
    _log("🔍 [ROLE-CHECK] My role: ${myRole == MeshRole.GHOST ? 'GHOST' : 'BRIDGE'}, My hops: $myHops, My pending: $myPendingCount");
    _log("🔍 [ROLE-CHECK] Peer role: ${peerIsBridge ? 'BRIDGE' : (peerIsGhost ? 'GHOST' : 'UNKNOWN')}, Peer hops: $peerHops");
    
    // 🔥 КРИТИЧНО: Если мы GHOST и нашли BRIDGE (hops=0) - подключаемся немедленно, ИГНОРИРУЯ hops сравнение
    if (myRole == MeshRole.GHOST && peerIsBridge) {
      _log("🧲 [Ghost→Bridge] ⚡ BRIDGE DETECTED (hops=0)! Connecting immediately to upload messages...");
      _log("🧲 [Ghost→Bridge] Ignoring hops comparison - BRIDGE has priority!");
      // Продолжаем подключение - НЕ проверяем hops для BRIDGE
    } else if (myRole == MeshRole.GHOST && peerIsGhost) {
      // Если оба GHOST - только один должен подключаться (тот, у кого меньше hops или больше pending)
      if (myHops < peerHops) {
        _log("✅ [GHOST↔GHOST] I have better route (my hops: $myHops < peer: $peerHops) - I will connect");
      } else if (myHops > peerHops) {
        _log("⏸️ [GHOST↔GHOST] Peer has better route (my hops: $myHops > peer: $peerHops) - skipping connection");
        _isTransferring = false;
        notifyListeners();
        return;
      } else {
        // Если hops равны - тот, у кого больше pending, подключается
        if (myPendingCount < 1) {
          _log("⏸️ [GHOST↔GHOST] Equal hops, but I have no pending messages - skipping connection");
          _isTransferring = false;
          notifyListeners();
          return;
        }
        _log("✅ [GHOST↔GHOST] Equal hops, I have pending messages ($myPendingCount) - I will connect");
      }
    }

    // --- STAGE 1: WI-FI DIRECT HUNT ---
    _log("📡 Stage 1: Wi-Fi Hunt initiated...");
    _isEscalating = true;
    _targetIdToHunt = target.device.remoteId.str.substring(target.device.remoteId.str.length - 4);

    // Запускаем discovery и ждем появления пиров
    await NativeMeshService.startDiscovery();
    
    // Ждем появления пиров и подключения (до 6 секунд максимум)
    bool peerFound = false;
    bool connectionEstablished = false;
    
    for (int i = 0; i < 6; i++) {
      await Future.delayed(const Duration(seconds: 1));
      
      // Проверяем, установлено ли уже соединение
      if (_isP2pConnected) {
        connectionEstablished = true;
        break;
      }
      
      // Проверяем, появился ли нужный пир в списке
      final wifiNodes = _nearbyNodes.values.where((n) => n.type == SignalType.mesh).toList();
      if (wifiNodes.isNotEmpty && !peerFound) {
        // Пытаемся подключиться к первому найденному Wi-Fi узлу
        final targetNode = wifiNodes.first;
        _log("🔗 Found Wi-Fi peer: ${targetNode.id}, attempting connection...");
        unawaited(connectToNode(targetNode.id)); // Не ждем, продолжаем проверку
        peerFound = true;
      }
    }
    
    // Если пир найден, но соединение еще не установлено - ждем еще 3 секунды
    if (peerFound && !connectionEstablished) {
      for (int i = 0; i < 3; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (_isP2pConnected) {
          connectionEstablished = true;
          break;
        }
      }
    }

    if (connectionEstablished || _isP2pConnected) {
      _log("✅ Stage 1 Success: Wi-Fi link established.");
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
      final msgId = activePending.isNotEmpty ? activePending.first['id'] as String : messageId;
      if (_sentPayloads.containsKey(msgId)) {
        _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
        _isTransferring = false;
        _isEscalating = false;
        notifyListeners();
        return;
      }
      
      // Отправляем данные через TCP
      final String payload = jsonEncode({
        'type': 'OFFLINE_MSG',
        'content': activePending.isNotEmpty ? activePending.first['content'] : '',
        'senderId': _apiService.currentUserId,
        'h': msgId,
        'ttl': 5,
      });
      await sendTcpBurst(payload);
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_OK - очищаем pending
      _sentPayloads[msgId] = 'WIFI_DIRECT';
      await _db.removeFromOutbox(msgId);
      _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (WIFI_DIRECT), removed from outbox");
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
      final retryInfo = _payloadRetries[msgId];
      final cycleDuration = retryInfo?.cycleDuration;
      final hops = retryInfo?.hopsToBridge ?? peerHops;
      final outboxSize = retryInfo?.outboxSizeAtStart ?? activePending.length;
      _log("🔄 [ARCHITECTURE] Cycle CLOSED via WIFI_DIRECT (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");
      
      // Очищаем активный payload и retry info
      _activePayloads.remove(msgId);
      _payloadRetries.remove(msgId);
      
      _isTransferring = false;
      _isEscalating = false;
      notifyListeners();
      return;
    }

    // --- STAGE 2: BLE GATT ATTACK ---
    _log("⚠️ Stage 1 Failed (Wi-Fi silent). Stage 2: BLE GATT...");
    _isEscalating = false;

    // 🔥 Улучшение: Сохраняем ScanResult ПЕРЕД остановкой scan
    // Это решает проблему "Target device not found" после остановки scan
    // targetMac уже определен выше в функции
    ScanResult? savedScanResult;
    
    try {
      final lastScanResults = await FlutterBluePlus.lastScanResults;
      for (final result in lastScanResults) {
        if (result.device.remoteId.str == targetMac) {
          // Проверяем, что это BRIDGE через manufacturerData или service UUID
          final mfData = result.advertisementData.manufacturerData[0xFFFF];
          final isBridgeByMfData = mfData != null && 
              mfData.length >= 2 && 
              mfData[0] == 0x42 && 
              mfData[1] == 0x52; // "BR" = BRIDGE
          final hasService = result.advertisementData.serviceUuids
              .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
          
          if (isBridgeByMfData || hasService || peerHops == 0) {
            savedScanResult = result;
            _log("✅ [STAGE 2] Saved ScanResult before stopping scan (MAC: ${targetMac.substring(targetMac.length - 8)})");
            break;
          }
        }
      }
    } catch (e) {
      _log("⚠️ [STAGE 2] Could not save ScanResult before stopping scan: $e");
    }
    
    // 🔥 HUAWEI FIX: НЕ останавливаем scan на Huawei - это может привести к потере устройства
    // Вместо этого сохраняем ScanResult и используем его для подключения
    _log("🛑 [GHOST] Preparing for GATT connect (saving ScanResult first)...");
    
    // 🔥 КРИТИЧНО: Сохраняем ScanResult ПЕРЕД остановкой scan (если scan активен)
    // Это решает проблему "Target device not found" на Huawei
    if (_isBtScanning) {
      try {
        // Сохраняем последние scan results перед остановкой
        final lastScanResults = await FlutterBluePlus.lastScanResults;
        for (final result in lastScanResults) {
          if (result.device.remoteId.str == targetMac) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBridgeByMfData = mfData != null && 
                mfData.length >= 2 && 
                mfData[0] == 0x42 && 
                mfData[1] == 0x52; // "BR" = BRIDGE
            final hasService = result.advertisementData.serviceUuids
                .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
            
            if (isBridgeByMfData || hasService || peerHops == 0) {
              if (savedScanResult == null) {
                savedScanResult = result;
                _log("✅ [STAGE 2] Saved ScanResult before stopping scan (MAC: ${targetMac.substring(targetMac.length - 8)})");
              }
              break;
            }
          }
        }
        
        // 🔥 HUAWEI FIX: НЕ останавливаем scan - это может привести к потере устройства
        // Вместо этого продолжаем scan в фоне
        _log("ℹ️ [GHOST] Keeping scan active (Huawei optimization)");
        // НЕ останавливаем scan на Huawei
      } catch (e) {
        _log("⚠️ [GHOST] Failed to save ScanResult: $e");
      }
    }
    
    // Останавливаем advertising (если было)
    try {
      if (_btService.state == BleAdvertiseState.advertising) {
        await _btService.stopAdvertising();
        _log("✅ [GHOST] Advertising stopped");
      }
    } catch (e) {
      _log("⚠️ [GHOST] Failed to stop advertising: $e");
    }
    
    // 🔥 Улучшение: Динамическое ожидание стабилизации с проверкой advertising
    // Для нестабильных устройств увеличиваем время ожидания до 1-2 сек
    _log("⏸️ [GHOST] Waiting for BLE stack stabilization and advertising confirmation...");
    
    String? originalAdvName;
    bool originalHasService = false;
    int originalPeerHops = peerHops;
    String? originalToken;
    String originalEffectiveName = '';
    bool originalIsBridgeByMfData = false;
    
    // 🔥 Улучшение: Адаптивное ожидание с проверкой advertising (до 3 секунд для low-end Android)
    // Увеличено с 2 до 3 секунд для стабильности на бюджетных устройствах
    const maxWaitTime = Duration(seconds: 3);
    const checkInterval = Duration(milliseconds: 200);
    int attempts = 0;
    // Вычисляем maxAttempts напрямую (3000ms / 200ms = 15 попыток)
    const maxAttempts = 15;
    bool advertisingConfirmed = false;
    
    while (attempts < maxAttempts && !advertisingConfirmed) {
      await Future.delayed(checkInterval);
      attempts++;
      
      try {
        final lastScanResults = await FlutterBluePlus.lastScanResults;
        final targetScanResult = lastScanResults.firstWhere(
          (r) => r.device.remoteId == target.device.remoteId,
          orElse: () => throw Exception("Target device not found"),
        );
        
        final advName = targetScanResult.advertisementData.localName ?? "";
        final hasService = targetScanResult.advertisementData.serviceUuids
            .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
        
        // Проверяем, что advertising активен и содержит валидные данные
        if ((advName.startsWith("M_") || hasService) && advName.isNotEmpty) {
          originalAdvName = advName;
          originalHasService = hasService;
          advertisingConfirmed = true;
          
          // Извлекаем токен из advertising name (если есть)
          if (advName.contains("BRIDGE") && advName.split("_").length >= 5) {
            originalToken = advName.split("_")[4];
          }
          
          _log("✅ [GHOST] Advertising confirmed after ${attempts * checkInterval.inMilliseconds}ms: '$advName'");
          break;
        }
      } catch (e) {
        // Продолжаем ожидание
        if (attempts % 5 == 0) {
          _log("⏳ [GHOST] Waiting for advertising... (attempt $attempts/$maxAttempts)");
        }
      }
    }
    
    if (!advertisingConfirmed) {
      _log("⚠️ [GHOST] Advertising not confirmed after ${maxWaitTime.inSeconds}s - proceeding with caution");
    }

    // 🔥 КРИТИЧНО: Проверяем, что целевое устройство все еще рекламирует перед подключением
    // 🔥 КРИТИЧНО: Объявляем targetScanResult вне try блоков, чтобы он был доступен во всех блоках
    ScanResult? targetScanResult = savedScanResult;
    
    try {
      // 🔥 Улучшение: Используем сохраненный ScanResult, если текущий scan не находит устройство
      // Это решает проблему "Target device not found" после остановки scan
      // targetScanResult будет использован для создания правильного BluetoothDevice
      
      // Пытаемся найти в последних scan results (если scan еще активен)
      if (targetScanResult == null) {
        try {
          final lastScanResults = await FlutterBluePlus.lastScanResults;
          try {
            // Сначала пытаемся найти по device.remoteId
            targetScanResult = lastScanResults.firstWhere(
              (r) => r.device.remoteId == target.device.remoteId,
            );
          } catch (e) {
            // Fallback: ищем по MAC адресу
            try {
              targetScanResult = lastScanResults.firstWhere(
                (r) => r.device.remoteId.str == targetMac,
              );
              _log("✅ [STAGE 2] Found device by MAC fallback: $targetMac");
            } catch (e2) {
              // Если и по MAC не нашли, пробуем найти по manufacturerData
              for (final result in lastScanResults) {
                final mfData = result.advertisementData.manufacturerData[0xFFFF];
                final isBridgeByMfData = mfData != null && 
                    mfData.length >= 2 && 
                    mfData[0] == 0x42 && 
                    mfData[1] == 0x52; // "BR" = BRIDGE
                
                if (isBridgeByMfData && result.device.remoteId.str == targetMac) {
                  targetScanResult = result;
                  _log("✅ [STAGE 2] Found device by manufacturerData fallback: $targetMac");
                  break;
                }
              }
            }
          }
        } catch (e) {
          _log("⚠️ [STAGE 2] Could not find device in lastScanResults: $e");
        }
      } else {
        _log("✅ [STAGE 2] Using saved ScanResult (MAC: ${targetMac.substring(targetMac.length - 8)})");
      }
      
      // Если все еще не нашли - используем сохраненный или выбрасываем исключение
      if (targetScanResult == null) {
        if (savedScanResult != null) {
          targetScanResult = savedScanResult;
          _log("✅ [STAGE 2] Using saved ScanResult as fallback");
        } else {
          throw Exception("Target device not found in scan results (MAC: ${targetMac.substring(targetMac.length - 8)})");
        }
      }
      
      originalHasService = targetScanResult.advertisementData.serviceUuids
          .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
      originalAdvName = targetScanResult.advertisementData.localName ?? '';
      final originalPlatformName = targetScanResult.device.platformName;
      final originalEffectiveName = originalAdvName.isEmpty ? originalPlatformName : originalAdvName;
      
      // 🔥 Улучшение: Проверяем manufacturerData как fallback
      final originalMfData = targetScanResult.advertisementData.manufacturerData[0xFFFF];
      final originalIsBridgeByMfData = originalMfData != null && 
          originalMfData.length >= 2 && 
          originalMfData[0] == 0x42 && 
          originalMfData[1] == 0x52; // "BR" = BRIDGE
      
      // Извлекаем hops и токен из advertising name для проверки
      if (originalEffectiveName.isNotEmpty && originalEffectiveName.startsWith("M_")) {
        final parts = originalEffectiveName.split("_");
        if (parts.length >= 2) {
          originalPeerHops = int.tryParse(parts[1]) ?? 99;
        }
        // 🔥 ШАГ 2.2: Извлечение токена из тактического имени (формат: M_0_0_BRIDGE_TOKEN)
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          originalToken = parts[4];
          
          // 🔥 ШАГ 2.3: Логирование извлечения токена
          final tokenPreview = originalToken.length > 16 ? originalToken.substring(0, 16) : originalToken;
          _log("🔑 [GHOST] Token extracted from advertising: $tokenPreview... (length: ${originalToken.length})");
          _log("   ✅ Token found - BLE GATT / TCP allowed");
        } else {
          // 🔥 ШАГ 2.2: Токен не найден - логирование для отладки
          _log("⚠️ [GHOST] Token NOT found in advertising name: '$advName'");
          _log("   📋 Parts count: ${parts.length}, expected: >=5");
          if (parts.length >= 4) {
            _log("   📋 Part[3]: '${parts[3]}', expected: 'BRIDGE'");
          }
          _log("   ⚠️ Token not found or expired - fallback to Sonar");
        }
      } else if (originalIsBridgeByMfData) {
        // Если имя пустое, но есть manufacturerData - это BRIDGE
        originalPeerHops = 0;
        _log("✅ [STAGE 2] BRIDGE detected via manufacturerData (empty localName)");
      }
      
      _log("🔍 [STAGE 2] Pre-connect check:");
      _log("   Device: ${target.device.remoteId}");
      _log("   Local name: '$originalAdvName'");
      _log("   Has SERVICE_UUID: $originalHasService");
      _log("   Peer hops: $originalPeerHops");
      _log("   Token: ${originalToken != null ? '${originalToken.substring(0, 8)}...' : 'none'}");
      _log("   Available UUIDs: ${targetScanResult.advertisementData.serviceUuids.map((u) => u.toString()).join(', ')}");
      
      // 🔥 Улучшение: Подтверждение доступности advertising перед GATT с fallback на manufacturerData
      // Проверяем не только наличие, но и валидность токена (если BRIDGE)
      // Используем уже вычисленные значения
      
      // Проверяем, что устройство рекламирует (через имя, service UUID или manufacturerData)
      final isAdvertising = originalHasService || 
                           (originalEffectiveName.isNotEmpty && originalEffectiveName.startsWith("M_")) ||
                           originalIsBridgeByMfData;
      
      if (!isAdvertising) {
        _log("❌ [CRITICAL] Target device does not advertise SERVICE_UUID, tactical name, or manufacturerData");
        _log("   Cannot connect via BLE GATT - device is not advertising correctly");
        _isTransferring = false;
        notifyListeners();
        return;
      }
      
      // Если имя пустое, но есть manufacturerData - это валидный BRIDGE
      if (originalEffectiveName.isEmpty && originalIsBridgeByMfData) {
        _log("✅ [STAGE 2] BRIDGE detected via manufacturerData fallback (empty localName)");
        originalPeerHops = 0; // Устанавливаем hops для BRIDGE
      }
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: BRIDGE без token = GATT ЗАПРЕЩЕН
      if (originalPeerHops == 0) {
        final isDirectMode = originalEffectiveName.contains("BRIDGE_DIRECT");
        
        if (isDirectMode) {
          _log("🚫 [ARCHITECTURE] BRIDGE in DIRECT mode (no GATT server) - GATT FORBIDDEN");
          _isTransferring = false;
          notifyListeners();
          
          // BRIDGE в direct mode не принимает GATT - используем Sonar с реальными данными
          try {
            final msgId = pending.first['id'] as String;
            // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
            if (_sentPayloads.containsKey(msgId)) {
              _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
              _isTransferring = false;
              notifyListeners();
              return;
            }
            
            final messageData = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': pending.first['content'],
              'senderId': _apiService.currentUserId,
              'h': msgId,
              'ttl': 5,
            });
            final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
            await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
            
            // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
            _sentPayloads[msgId] = 'SONAR';
            await _db.removeFromOutbox(msgId);
            _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (SONAR), removed from outbox");
            _log("✅ Stage 3 Success: Sonar Packet Emitted (BRIDGE in direct mode). Cycle CLOSED.");
          } catch (e) { 
            final msgId = activePending.isNotEmpty ? activePending.first['id'] as String : messageId;
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
            _log("❌ Total isolation."); 
          }
          _isTransferring = false;
          notifyListeners();
          return; // Прерываем попытки BLE GATT
        }
        
        if (originalToken == null) {
          // 🔥 СИНХРОНИЗАЦИЯ: Детальное логирование для отладки
          _log("🚫 [ARCHITECTURE] BRIDGE without token — GATT FORBIDDEN");
          _log("   📋 Advertising name: '$advName'");
          _log("   📋 MAC: ${target.device.remoteId.str.substring(target.device.remoteId.str.length - 8)}");
          _log("   ⚠️ Token not found - possible reasons:");
          _log("      1. BRIDGE hasn't updated advertising yet (timing issue)");
          _log("      2. Token expired (>45s old)");
          _log("      3. BLE stack delay on BRIDGE device");
          _log("   Это НЕ ошибка, это нормальный путь. Escalating to Sonar.");
          _isTransferring = false;
          notifyListeners();
          
          // Помечаем BRIDGE как запрещенный для GATT (cooldown 5 минут)
          final discoveryContext = locator<DiscoveryContextService>();
          final targetMac = target.device.remoteId.str;
          final candidate = discoveryContext.getCandidateByMac(targetMac);
          if (candidate != null) {
            discoveryContext.markBridgeAsGattForbidden(candidate.id);
          }
          
          // Сразу переходим к Sonar
          try {
            final messageData = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': pending.first['content'],
              'senderId': _apiService.currentUserId,
              'h': pending.first['id'],
              'ttl': 5,
            });
            final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
            await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
            _log("✅ Stage 3 Success: Sonar Packet Emitted (BRIDGE without token). Cycle CLOSED.");
          } catch (e) { 
            final msgId = activePending.isNotEmpty ? activePending.first['id'] as String : messageId;
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
            _log("❌ Total isolation."); 
          }
          _isTransferring = false;
          notifyListeners();
          return; // Прерываем попытки BLE GATT
        } else {
          _log("✅ [STAGE 2] BRIDGE token found: ${originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken}...");
        }
      }
      
      // 🔥 ПРОВЕРКА: Если оба GHOST, проверяем, что роль не изменилась
      // Используем effectiveName и manufacturerData для определения роли
      final peerIsBridge = originalPeerHops == 0 || 
                          originalEffectiveName.contains('BRIDGE') || 
                          originalIsBridgeByMfData;
      
      if (myRole == MeshRole.GHOST && !peerIsBridge) {
        if (myHops >= originalPeerHops && myPendingCount == 0) {
          _log("⏸️ [GHOST↔GHOST] Peer has better or equal route, and I have no pending - aborting");
          _isTransferring = false;
          notifyListeners();
          return;
        }
      }
      
      if (!originalHasService && originalAdvName.startsWith("M_")) {
        _log("⚠️ [WARNING] Device has tactical name but no SERVICE_UUID (Huawei/Tecno quirk?)");
        _log("   Will attempt connection, but service discovery may fail");
      }
    } catch (e) {
      _log("❌ [CRITICAL] Could not verify target device before BLE GATT: $e");
      _log("   Aborting connection - device may have changed or stopped advertising");
      _isTransferring = false;
      notifyListeners();
      return;
    }

    try {
      // 🔥 Улучшение: ПОВТОРНАЯ ПРОВЕРКА с подтверждением токена и fallback на MAC
      // Убеждаемся, что устройство все еще рекламирует правильный сервис и токен
      // targetMac уже определен выше в функции
      final lastScanResults = await FlutterBluePlus.lastScanResults;
      
      ScanResult? currentScanResult;
      try {
        // Сначала пытаемся найти по device.remoteId
        currentScanResult = lastScanResults.firstWhere(
          (r) => r.device.remoteId == target.device.remoteId,
        );
      } catch (e) {
        // Fallback: ищем по MAC адресу
        try {
          currentScanResult = lastScanResults.firstWhere(
            (r) => r.device.remoteId.str == targetMac,
          );
        } catch (e2) {
          // Если и по MAC не нашли, пробуем найти по manufacturerData
          for (final result in lastScanResults) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBridgeByMfData = mfData != null && 
                mfData.length >= 2 && 
                mfData[0] == 0x42 && 
                mfData[1] == 0x52; // "BR" = BRIDGE
            
            if (isBridgeByMfData && result.device.remoteId.str == targetMac) {
              currentScanResult = result;
              break;
            }
          }
        }
      }
      
      if (currentScanResult != null) {
        final currentAdvName = currentScanResult.advertisementData.localName ?? '';
        final currentHasService = currentScanResult.advertisementData.serviceUuids
            .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
        
        // 🔥 Улучшение: Проверяем не только имя, но и токен (для BRIDGE) с fallback на manufacturerData
        final currentPlatformName = currentScanResult.device.platformName;
        final currentEffectiveName = currentAdvName.isEmpty ? currentPlatformName : currentAdvName;
        final currentMfData = currentScanResult.advertisementData.manufacturerData[0xFFFF];
        final currentIsBridgeByMfData = currentMfData != null && 
            currentMfData.length >= 2 && 
            currentMfData[0] == 0x42 && 
            currentMfData[1] == 0x52; // "BR" = BRIDGE
        
        String? currentToken;
        if (currentEffectiveName.startsWith("M_") && currentEffectiveName.contains("BRIDGE")) {
          final parts = currentEffectiveName.split("_");
          if (parts.length >= 5 && parts[3] == "BRIDGE") {
            currentToken = parts[4];
          }
        }
        
        // Проверяем, что advertising не изменился критически
        // Используем уже вычисленные значения из первого блока проверки
        // originalEffectiveName был определен ранее в первом try блоке (строка 1619)
        
        if (originalEffectiveName.isNotEmpty && 
            currentEffectiveName != originalEffectiveName) {
          // Для BRIDGE проверяем, не изменился ли токен
          if (originalPeerHops == 0 && originalToken != null && currentToken != null) {
            if (originalToken != currentToken) {
              final oldTokenPreview = originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken;
              final newTokenPreview = currentToken.length > 8 ? currentToken.substring(0, 8) : currentToken;
              _log("⚠️ [WARNING] BRIDGE token changed during connection: $oldTokenPreview... -> $newTokenPreview...");
              _log("   Token mismatch - aborting connection to prevent GATT failure");
              _isTransferring = false;
              notifyListeners();
              return;
            }
          } else {
            _log("⚠️ [WARNING] Device advertising name changed during connection: '$originalEffectiveName' -> '$currentEffectiveName'");
            _log("   Role or identity may have changed - aborting connection");
            _isTransferring = false;
            notifyListeners();
            return;
          }
        }
        
        // 🔥 Улучшение: Проверяем, что advertising всё ещё активно (с fallback на manufacturerData)
        final isStillAdvertising = currentHasService || 
                                  (currentEffectiveName.isNotEmpty && currentEffectiveName.startsWith("M_")) ||
                                  currentIsBridgeByMfData;
        
        if (!isStillAdvertising) {
          _log("❌ [CRITICAL] Device stopped advertising during connection preparation");
          _log("   Advertising is no longer active - aborting connection");
          _isTransferring = false;
          notifyListeners();
          return;
        }
        
        // Проверяем, что SERVICE_UUID все еще присутствует
        if (originalHasService && !currentHasService) {
          _log("⚠️ [WARNING] Device stopped advertising SERVICE_UUID during connection");
          _log("   Device may have changed role or stopped advertising - aborting connection");
          _isTransferring = false;
          notifyListeners();
          return;
        }
      } else {
        _log("⚠️ [WARNING] Device no longer found in scan results - may have stopped advertising");
        _log("   Aborting connection");
        _isTransferring = false;
        notifyListeners();
        return;
      }

      final String payload = jsonEncode({
        'type': 'OFFLINE_MSG',
        'content': pending.first['content'],
        'senderId': _apiService.currentUserId,
        'h': pending.first['id'],
        'ttl': 5,
      });

      // 🔥 КРИТИЧНО: Используем сохраненный ScanResult для создания правильного BluetoothDevice
      // targetScanResult определен выше в try блоке, используем его или savedScanResult
      final finalTargetScanResult = targetScanResult ?? savedScanResult;
      final targetDevice = finalTargetScanResult?.device ?? target.device;
      _log("🔗 [STAGE 2] Connecting to device: ${targetDevice.remoteId} (from ${finalTargetScanResult != null ? 'saved' : 'original'} ScanResult)");
      
      // 🔥 КРИТИЧНО: Per-BRIDGE lock - предотвращение race condition при одновременных подключениях
      if (originalPeerHops == 0 && _activeBridgeConnections.containsKey(targetMac)) {
        final connectionStart = _activeBridgeConnections[targetMac]!;
        final connectionAge = DateTime.now().difference(connectionStart).inSeconds;
        if (connectionAge < 10) {
          _log("⏸️ [GHOST] Another connection to BRIDGE $targetMac in progress (${connectionAge}s old) - skipping to avoid conflict");
          _isTransferring = false;
          notifyListeners();
          return;
        } else {
          // Соединение слишком старое - удаляем и продолжаем
          _activeBridgeConnections.remove(targetMac);
        }
      }
      
      // Помечаем BRIDGE как активный для подключения
      if (originalPeerHops == 0) {
        _activeBridgeConnections[targetMac] = DateTime.now();
      }
      
      // 🔥 КРИТИЧНО: Проверка просроченного токена перед использованием
      if (originalToken != null && originalPeerHops == 0) {
        // Проверяем expiresAt из DiscoveryContext (если доступен)
        final discoveryContext = locator<DiscoveryContextService>();
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (candidate != null) {
          // Если есть информация о токене в candidate, проверяем его валидность
          // Note: expiresAt хранится в MAGNET_WAVE пакете, но не в BLE advertising
          // Для BLE advertising токен зашифрован, expiresAt недоступен напрямую
          // Проверяем через время последнего обновления токена (если известно)
          final tokenAge = candidate.lastSeen.difference(DateTime.now()).inSeconds.abs();
          if (tokenAge > 35) { // Токен валиден 30 секунд + буфер 5 секунд
            _log("⏰ [GHOST] Token likely expired (token age: ${tokenAge}s, max: 30s)");
            _log("   → Skipping GATT/TCP, escalating to Sonar");
            _activeBridgeConnections.remove(targetMac);
            // Переход к Sonar (будет выполнен ниже)
            originalToken = null; // Помечаем как невалидный
          }
        }
      }
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: BRIDGE без token = GATT ЗАПРЕЩЕН
      if (originalPeerHops == 0 && originalToken == null) {
        // 🔥 СИНХРОНИЗАЦИЯ: Детальное логирование для отладки
        _log("🚫 [ARCHITECTURE] BRIDGE without token — GATT FORBIDDEN");
        _log("   📋 Advertising name: '$advName'");
        _log("   📋 MAC: ${target.device.remoteId.str.substring(target.device.remoteId.str.length - 8)}");
        _log("   ⚠️ Token not found - possible reasons:");
        _log("      1. BRIDGE hasn't updated advertising yet (timing issue)");
        _log("      2. Token expired (>45s old)");
        _log("      3. BLE stack delay on BRIDGE device");
        _log("   Это НЕ ошибка, это нормальный путь. Escalating to Sonar.");
        _isTransferring = false;
        notifyListeners();
        
        // Помечаем BRIDGE как запрещенный для GATT (cooldown 5 минут)
        final discoveryContext = locator<DiscoveryContextService>();
        final targetMac = target.device.remoteId.str;
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (candidate != null) {
          discoveryContext.markBridgeAsGattForbidden(candidate.id);
        }
        
        // Сразу переходим к Sonar
        try {
          final msgId = pending.first['id'] as String;
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
          if (_sentPayloads.containsKey(msgId)) {
            _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
            _isTransferring = false;
            notifyListeners();
            return;
          }
          
          final messageData = jsonEncode({
            'type': 'OFFLINE_MSG',
            'content': activePending.isNotEmpty ? activePending.first['content'] : '',
            'senderId': _apiService.currentUserId,
            'h': msgId,
            'ttl': 5,
          });
          final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
          await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
          
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
          _sentPayloads[msgId] = 'SONAR';
          await _db.removeFromOutbox(msgId);
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (SONAR), removed from outbox");
          _log("✅ Stage 3 Success: Sonar Packet Emitted (BRIDGE without token). Cycle CLOSED.");
        } catch (e) { 
          final msgId = activePending.isNotEmpty ? activePending.first['id'] as String : messageId;
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
          _log("❌ Total isolation."); 
        }
        _isTransferring = false;
        notifyListeners();
        return; // Прерываем попытки BLE GATT
      }
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: BLE GATT без token ЗАПРЕЩЕН
      if (originalPeerHops == 0 && originalToken == null) {
        _log("🚫 [ARCHITECTURE] BRIDGE without token — BLE GATT FORBIDDEN");
        _log("   This should have been caught earlier. Escalating to Sonar.");
        _isTransferring = false;
        notifyListeners();
        
        // Помечаем BRIDGE как запрещенный для GATT
        final discoveryContext = locator<DiscoveryContextService>();
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (candidate != null) {
          discoveryContext.markBridgeAsGattForbidden(candidate.id);
        }
        
        // Сразу переходим к Sonar
        try {
          final msgId = pending.first['id'] as String;
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
          if (_sentPayloads.containsKey(msgId)) {
            _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
            _isTransferring = false;
            notifyListeners();
            return;
          }
          
          final messageData = jsonEncode({
            'type': 'OFFLINE_MSG',
            'content': activePending.isNotEmpty ? activePending.first['content'] : '',
            'senderId': _apiService.currentUserId,
            'h': msgId,
            'ttl': 5,
          });
          final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
          await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
          
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
          _sentPayloads[msgId] = 'SONAR';
          await _db.removeFromOutbox(msgId);
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (SONAR), removed from outbox");
          _log("✅ Sonar Packet Emitted (BLE GATT without token). Cycle CLOSED.");
        } catch (e) {
          final msgId = activePending.isNotEmpty ? activePending.first['id'] as String : messageId;
          _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
          _log("❌ Sonar failed: $e");
        }
        _isTransferring = false;
        notifyListeners();
        return; // Прерываем попытку BLE GATT
      }
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивный таймаут BLE GATT на основе предыдущих успехов/неудач
      final transportLatency = _transportLatencies.putIfAbsent(targetMac, () => TransportLatency());
      final bleTimeout = transportLatency.adaptiveTimeout;
      // Логирование уже добавлено выше
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельный таймер для BLE GATT
      final gattStartTime = DateTime.now();
      bool gattAborted = false;
      _gattTimeoutTimer?.cancel();
      _gattTimeoutTimer = Timer(bleTimeout, () {
        gattAborted = true;
        _log("⏱️ [GATT-TIMER] BLE GATT timeout after ${bleTimeout.inSeconds}s - aborting");
      });
      
      final success = await _btService.sendMessage(targetDevice, payload)
          .timeout(bleTimeout, onTimeout: () {
        _log("⏱️ BLE GATT timeout after ${bleTimeout.inSeconds}s");
        return false;
      });
      
      _gattTimeoutTimer?.cancel();
      final gattLatency = DateTime.now().difference(gattStartTime);
      
      if (success && !gattAborted) {
        // 🔥 ШАГ 2.3: Логирование успешного подключения
        _log("✅ [GHOST] Connected via BLE GATT - message delivered");
        _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе
        
        // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем успешную задержку для адаптивного таймаута
        transportLatency.recordSuccess(gattLatency);
        
        // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
        final retryInfo = _payloadRetries[messageId]!;
        retryInfo.gattAttempts++;
        
        // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_OK - очищаем pending
        _sentPayloads[messageId] = 'BLE';
        await _db.removeFromOutbox(messageId);
        _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_OK (BLE), removed from outbox");
        
        // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
        final cycleDuration = retryInfo.cycleDuration;
        final hops = retryInfo.hopsToBridge ?? peerHops;
        final outboxSize = retryInfo.outboxSizeAtStart ?? pending.length;
        _log("🔄 [ARCHITECTURE] Cycle CLOSED via BLE GATT (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");
        
        // Очищаем активный payload и retry info
        _activePayloads.remove(messageId);
        _payloadRetries.remove(messageId);
        
        // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после успешной передачи
        _activeBridgeConnections.remove(targetMac);
        
        _isTransferring = false;
        notifyListeners();
        
        // 🔥 Улучшение: Проверяем очередь подключений после успешной передачи
        _processPendingConnections();
        
        // 🔥 GHOST: Вернуться в scan после успешной передачи (для поиска других BRIDGE)
        _log("🔄 [GHOST] Returning to scan mode after successful GATT transfer");
        // Scan будет запущен автоматически через MeshOrchestrator
        
        return;
      } else {
        _log("⚠️ Stage 2 Failed: BLE delivery returned false or timed out.");
        
        // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем неудачу для адаптивного таймаута
        transportLatency.recordFailure();
        
        // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
        final retryInfo = _payloadRetries[messageId]!;
        retryInfo.gattAttempts++;
        
        // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_FAIL - cooldown транспорта 30-60 секунд
        _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (BLE), setting cooldown 60s (attempt ${retryInfo.gattAttempts}/3)");
        _linkCooldowns[targetMac] = DateTime.now(); // Cooldown 60 секунд для BLE GATT
        _bleGattAttempts[targetMac] = (_bleGattAttempts[targetMac] ?? 0) + 1;
        
        // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при неудаче (после cooldown)
        // Lock будет автоматически освобожден через 10 секунд или при следующей попытке
        Future.delayed(const Duration(seconds: 10), () {
          _activeBridgeConnections.remove(targetMac);
        });
      }
    } catch (e) { 
      _log("⚠️ Stage 2 Failed: $e");
      // 🔥 Улучшение: Увеличиваем счётчик неудачных попыток
      _bleGattAttempts[targetMac] = (_bleGattAttempts[targetMac] ?? 0) + 1;
      
      // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при ошибке
      _activeBridgeConnections.remove(targetMac);
    }
    
    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не делаем fallback если payload уже отправлен через Sonar
    if (_sentPayloads.containsKey(messageId) && _sentPayloads[messageId] == 'SONAR') {
      _log("🚫 [ARCHITECTURE] Payload $messageId already sent via SONAR — skipping fallback");
      _isTransferring = false;
      notifyListeners();
      return; // Цикл закрыт, не делаем fallback
    }
    
    // 🔥 КРИТИЧНО: Агрессивный fallback на TCP после неудачи BLE GATT
    // НО: Только если есть bridgeToken - без токена TCP тоже не работает
    final gattAttemptsCount = _bleGattAttempts[targetMac] ?? 0;
    final retryInfoForTcp = _payloadRetries[messageId]!;
    
    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем лимит попыток TCP (максимум 2)
    if (gattAttemptsCount >= 1 && peerHops == 0 && retryInfoForTcp.tcpAttempts < 2) {
      _log("🔄 [Cascade] BLE GATT failed, checking TCP fallback (GATT attempt: $gattAttemptsCount, TCP attempt: ${retryInfoForTcp.tcpAttempts + 1}/2)");
      final candidate = locator<DiscoveryContextService>().getCandidateByMac(targetMac);
      
      // 🔥 КРИТИЧНО: TCP fallback только если есть bridgeToken И IP/порт
      if (candidate != null && candidate.ip != null && candidate.port != null && candidate.bridgeToken != null) {
        try {
          // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивный таймаут TCP
          final tcpLatency = _transportLatencies.putIfAbsent('${targetMac}_tcp', () => TransportLatency());
          final tcpTimeout = tcpLatency.consecutiveFailures >= 2 
              ? const Duration(seconds: 10) 
              : const Duration(seconds: 5);
          
          // 🔥 ШАГ 2.3: Логирование подключения через TCP
          final tcpTokenPreview = candidate.bridgeToken!.length > 16 
              ? candidate.bridgeToken!.substring(0, 16) 
              : candidate.bridgeToken!;
          _log("🌐 [GHOST] Connecting via TCP");
          _log("   🔑 Token: $tcpTokenPreview...");
          _log("   ⏱️ Timeout: ${tcpTimeout.inSeconds}s");
          
          // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельный таймер для TCP
          final tcpStartTime = DateTime.now();
          bool tcpAborted = false;
          _tcpTimeoutTimer?.cancel();
          _tcpTimeoutTimer = Timer(tcpTimeout, () {
            tcpAborted = true;
            _log("⏱️ [TCP-TIMER] TCP timeout after ${tcpTimeout.inSeconds}s - aborting");
          });
          
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: TCP таймаут адаптивный
          // 🔥 ШАГ 3: Токен валиден 30 секунд
          await _handleMagnetWave(candidate.bridgeToken!, candidate.port!, 
              DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch)
              .timeout(tcpTimeout, onTimeout: () {
            throw TimeoutException("TCP connection timeout after ${tcpTimeout.inSeconds}s");
          });
          
          _tcpTimeoutTimer?.cancel();
          final tcpLatencyDuration = DateTime.now().difference(tcpStartTime);
          
          if (!tcpAborted) {
            // 🔥 ШАГ 2.3: Логирование успешного подключения через TCP
            _log("✅ [GHOST] Connected via TCP - message delivered");
            
            // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем успешную задержку TCP
            tcpLatency.recordSuccess(tcpLatencyDuration);
            
            // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
            retryInfoForTcp.tcpAttempts++;
            
            // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_OK - очищаем pending
            _sentPayloads[messageId] = 'TCP';
            await _db.removeFromOutbox(messageId);
            _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_OK (TCP), removed from outbox");
            
            // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
            final cycleDuration = retryInfoForTcp.cycleDuration;
            final hops = retryInfoForTcp.hopsToBridge ?? peerHops;
            final outboxSize = retryInfoForTcp.outboxSizeAtStart ?? activePending.length;
            _log("🔄 [ARCHITECTURE] Cycle CLOSED via TCP (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");
            
            _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе
            
            // Очищаем активный payload и retry info
            _activePayloads.remove(messageId);
            _payloadRetries.remove(messageId);
            
            // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после успешной передачи
            _activeBridgeConnections.remove(targetMac);
            
            _isTransferring = false;
            notifyListeners();
            return;
          }
        } catch (e) {
          // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем неудачу TCP
          final tcpLatency = _transportLatencies.putIfAbsent('${targetMac}_tcp', () => TransportLatency());
          tcpLatency.recordFailure();
          
          // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
          retryInfoForTcp.tcpAttempts++;
          
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_FAIL - cooldown транспорта 1-2 минуты, но НЕ удаляем из outbox
          _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (TCP), keeping in outbox (attempt ${retryInfoForTcp.tcpAttempts}/2)");
          _log("❌ [Cascade] TCP fallback also failed: $e");
          _linkCooldowns[targetMac] = DateTime.now(); // Cooldown 60 секунд для TCP
          _log("⏸️ [Cascade] TCP cooldown set for 60s");
          
          // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при неудаче TCP
          _activeBridgeConnections.remove(targetMac);
        }
      } else {
        // 🔥 КРИТИЧНО: Если нет token или IP/порта - TCP fallback невозможен
        if (candidate?.bridgeToken == null) {
          _log("❌ [Cascade] No bridgeToken - TCP fallback impossible (BRIDGE not accepting connections)");
        } else {
          _log("⚠️ [Cascade] No TCP info in candidate (ip: ${candidate?.ip}, port: ${candidate?.port})");
        }
      }
    }

    // --- STAGE 3: SONAR (ГАРАНТИРОВАННЫЙ маршрут) ---
    // 🔥 ШАГ 2.2: Если токен не найден или просрочен → fallback на Sonar
    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Sonar всегда доступен, работает как последний шаг
    final retryInfoForSonar = _payloadRetries[messageId]!;
    
    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем лимит попыток Sonar (максимум 1)
    if (retryInfoForSonar.sonarAttempts >= 1) {
      _log("⏸️ [Scalability] Payload $messageId already attempted via Sonar - skipping");
      _activePayloads.remove(messageId);
      _isTransferring = false;
      notifyListeners();
      return;
    }
    
    _log("🔊 [GHOST] Escalating to SONAR (token not found or expired)");
    try {
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
      if (_sentPayloads.containsKey(messageId)) {
        _log("🚫 [ARCHITECTURE] Payload $messageId already sent via ${_sentPayloads[messageId]} — skipping duplicate");
        _activePayloads.remove(messageId);
        _isTransferring = false;
        notifyListeners();
        return;
      }
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельный таймер для Sonar
      final sonarStartTime = DateTime.now();
      _sonarTimeoutTimer?.cancel();
      _sonarTimeoutTimer = Timer(const Duration(seconds: 3), () {
        _log("⏱️ [SONAR-TIMER] Sonar timeout after 3s");
      });
      
      // 🔥 КРИТИЧНО: Передаем реальные данные через Sonar, а не только hash
      // Sonar может передать только короткие сообщения - используем первые 200 символов
      final messageData = jsonEncode({
        'type': 'OFFLINE_MSG',
        'content': activePending.first['content'],
        'senderId': _apiService.currentUserId,
        'h': messageId,
        'ttl': 5,
      });
      final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
      await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
      
      _sonarTimeoutTimer?.cancel();
      final sonarLatency = DateTime.now().difference(sonarStartTime);
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
      retryInfoForSonar.sonarAttempts++;
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
      _sentPayloads[messageId] = 'SONAR';
      await _db.removeFromOutbox(messageId);
      _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_OK (SONAR), removed from outbox");
      _log("✅ Stage 3 Success: Sonar Packet Emitted with real data.");
      
      // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
      final cycleDuration = retryInfoForSonar.cycleDuration;
      final hops = retryInfoForSonar.hopsToBridge ?? peerHops;
      final outboxSize = retryInfoForSonar.outboxSizeAtStart ?? activePending.length;
      _log("🔄 [ARCHITECTURE] Cycle CLOSED via Sonar (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize, latency: ${sonarLatency.inMilliseconds}ms)");
      
      // Очищаем активный payload и retry info
      _activePayloads.remove(messageId);
      _payloadRetries.remove(messageId);
      
      _isTransferring = false;
      notifyListeners();
    } catch (e) { 
      // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info при неудаче
      retryInfoForSonar.sonarAttempts++;
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_FAIL - оставляем в pending, но не повторяем
      _log("📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (SONAR), keeping in outbox");
      _log("❌ Total isolation."); 
      
      // Очищаем активный payload, но оставляем retry info для анализа
      _activePayloads.remove(messageId);
      
      // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после завершения цикла
      if (originalPeerHops == 0) {
        _activeBridgeConnections.remove(targetMac);
      }
      
      _isTransferring = false;
      notifyListeners();
    }

    // 🔥 Улучшение: Отменяем таймаут при успешном завершении
    // (таймаут должен быть объявлен в начале функции)
  }
  
  /// 🔥 Улучшение: Обработка очереди подключений после завершения transfer
  void _processPendingConnections() {
    if (_pendingConnections.isEmpty) return;
    
    _log("🔄 [Cascade] Processing ${_pendingConnections.length} pending connection(s)...");
    
    // Очищаем истёкшие подключения (старше 30 секунд)
    final now = DateTime.now();
    _pendingConnections.removeWhere((mac, time) => now.difference(time).inSeconds > 30);
    
    // Пытаемся подключиться к первому в очереди
    if (_pendingConnections.isNotEmpty && !_isTransferring) {
      final nextMac = _pendingConnections.keys.first;
      _pendingConnections.remove(nextMac);
      
      _log("🔄 [Cascade] Attempting queued connection to $nextMac");
      // Находим кандидата и пытаемся подключиться
      final candidate = locator<DiscoveryContextService>().getCandidateByMac(nextMac);
      if (candidate != null && candidate.isValid) {
        // Пытаемся найти ScanResult для подключения
        unawaited(_makeConnectionDecisionFromContext());
      }
    }
  }

  // 🔥 ОБНОВЛЯЕМ ЭТОТ МЕТОД: Он теперь "авто-киллер"


  // 🔥 ЭТОТ МЕТОД ОТВЕЧАЕТ ЗА РЕАЛЬНУЮ ПЕРЕДАЧУ ПОСЛЕ УСТАНОВКИ ЛИНКА
  // --- 🔥 ВЫГРУЗКА ДАННЫХ ПОСЛЕ УСТАНОВКИ ЛИНКА ---
  void onNetworkConnected(bool isHost, String hostAddress) async {
    _isP2pConnected = true;
    _isHost = isHost;
    _isTransferring = false;
    _transferGuardTimer?.cancel(); // Выключаем стража

    _log("🌐 [CONNECTED] Wi-Fi Group Established.");
    notifyListeners();

    // Твоя логика отправки через TCP...
    await Future.delayed(const Duration(seconds: 5));
    _log("🚀 [OFFLOAD] Sending signals...");

    // 2. ВЫГРУЗКА
    final pending = await _db.getPendingFromOutbox();
    if (pending.isNotEmpty) {
      // КЛИЕНТ всегда шлет на .49.1 - это железное правило Android
      String targetIp = isHost ? hostAddress : "192.168.49.1";

      _log("🚀 [OFFLOAD] Pushing signals to $targetIp");

      for (var msgData in pending) {
        final packet = jsonEncode({
          'type': 'OFFLINE_MSG',
          'chatId': msgData['chatRoomId'],
          'content': msgData['content'],
          'senderId': _apiService.currentUserId,
          'h': msgData['id'],
        });

        // Пробуем отправить
        await NativeMeshService.sendTcp(packet, host: targetIp);
      }
      _log("✅ [SUCCESS] Mesh transmission complete.");
    }
    notifyListeners();
  }


  // --- ОБРАБОТКА ПАКЕТОВ ---


  String get lastKnownPeerIp => _lastKnownPeerIp;

  // 🔥 ИСПРАВЛЕННЫЙ МЕТОД ОБРАБОТКИ ПАКЕТОВ



  /// Логика: Распаковка -> Дедупликация -> Peer Lock -> Маршрутизация.
  Future<void> processIncomingPacket(dynamic rawData) async {
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
      // 🔒 Fix IP lock expiry: Only update if expired or new
      if (senderIp != null && senderIp.isNotEmpty && senderIp != "127.0.0.1") {
        final now = DateTime.now();
        final isExpired = _peerIpExpiry[senderIp]?.isBefore(now) ?? true;
        
        if (_lastKnownPeerIp != senderIp || isExpired) {
          _lastKnownPeerIp = senderIp;
          _peerIpExpiry[senderIp] = now.add(const Duration(minutes: 5)); // TTL: 5 minutes
          _log("📍 [Mesh] Peer Locked -> $_lastKnownPeerIp (expires in 5min)");
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
          final int peerDist = data['dist'] ?? 255;
          final String peerId = data['senderId'] ?? "Unknown";

          // Если сосед ближе к интернету, чем я - обновляю свой градиент
          if (peerDist < _myDistanceToBridge) {
            _myDistanceToBridge = peerDist + 1;
            _log("🧭 Route Optimized: Found path to Internet via $peerId ($peerDist hops)");

            // Срочно уведомляем Оркестратор о смене градиента
            locator<TacticalMeshOrchestrator>().processRoutingPulse(RoutingPulse(
              nodeId: peerId,
              hopsToInternet: peerDist,
              batteryLevel: (data['batt'] ?? 0) / 100.0,
              queuePressure: data['press'] ?? 0,
            ));
          }
          break;

        case 'MAGNET_WAVE':
          // 🧲 ОБРАБОТКА MAGNET_WAVE: BRIDGE рекламирует себя
          if (NetworkMonitor().currentRole == MeshRole.GHOST) {
            final serverToken = data['serverToken']?.toString();
            final port = data['port'] is int ? data['port'] as int : (data['port'] != null ? int.tryParse(data['port'].toString()) ?? 55556 : 55556);
            final expiresAt = data['expiresAt'] is int ? data['expiresAt'] as int : (data['expiresAt'] != null ? int.tryParse(data['expiresAt'].toString()) ?? 0 : 0);
            final signature = data['signature']?.toString();
            final publicKey = data['publicKey']?.toString();

            _log("🧲 [Ghost] MAGNET_WAVE received! Token: ${serverToken?.substring(0, 8) ?? 'null'}..., Port: $port, ExpiresAt: $expiresAt");

            // 🔒 SECURITY: Verify signature before processing
            if (signature != null && publicKey != null) {
              final signingService = MessageSigningService();
              await signingService.initialize();
              final isValid = await signingService.verifyMessage(data, signature, publicKey);
              
              if (!isValid) {
                _log("❌ [Ghost] MAGNET_WAVE signature verification failed! Dropping message.");
                break; // Reject unsigned messages
              }
              
              _log("✅ [Ghost] MAGNET_WAVE signature verified");
            } else {
              _log("⚠️ [Ghost] MAGNET_WAVE missing signature or publicKey - rejecting (security)");
              break; // Reject unsigned messages
            }

            // Проверяем валидность токена
            if (serverToken != null && serverToken.isNotEmpty) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now < expiresAt) {
                _log("✅ [Ghost] Magnet wave is valid! Connecting to BRIDGE on port $port...");
                // 🔥 КРИТИЧНО: Запускаем загрузку немедленно (не в фоне)
                // Это важно для быстрой доставки сообщений
                await _handleMagnetWave(serverToken, port, expiresAt);
              } else {
                _log("⚠️ [Ghost] Magnet wave expired (now: $now, expires: $expiresAt)");
              }
            } else {
              _log("⚠️ [Ghost] Magnet wave has no token");
            }
          } else {
            _log("ℹ️ [Bridge] Received MAGNET_WAVE (ignoring, we are BRIDGE)");
          }
          break;

        case 'PING':
          _log("👋 Handshake pulse from $senderId");
          // Если мы клиент, отвечаем синхронизацией рекламных пакетов
          if (!_isHost && senderIp != null) syncGossip(senderIp);
          break;

        case 'PACKET_QUERY':
          // 🔥 ОБРАБОТКА ЗАПРОСА ПАКЕТА: Сосед спрашивает, есть ли у нас пакет
          final queryPacketId = data['packetId']?.toString() ?? "";
          if (queryPacketId.isNotEmpty) {
            _log("❓ [Gossip] Packet query received: ${queryPacketId.substring(0, 8)}...");
            
            // Проверяем, есть ли у нас этот пакет в outbox или в сообщениях
            final pending = await db.getPendingFromOutbox();
            final hasInOutbox = pending.any((msg) => msg['id'] == queryPacketId);
            
            // Также проверяем в базе сообщений
            bool hasInDb = false;
            try {
              // Пробуем найти сообщение по ID во всех чатах
              final allChats = await db.getAllChatRooms();
              for (var chat in allChats) {
                final chatId = chat['id'] as String? ?? '';
                if (chatId.isEmpty) continue;
                final messages = await db.getMessages(chatId);
                if (messages.any((m) => m.id == queryPacketId)) {
                  hasInDb = true;
                  break;
                }
              }
            } catch (e) {
              _log("⚠️ Error checking DB for packet: $e");
            }
            
            if (!hasInOutbox && !hasInDb) {
              // У нас нет пакета - отвечаем "НЕТ" через Sonar
              _log("📭 [Gossip] We don't have packet ${queryPacketId.substring(0, 8)}..., requesting...");
              // Отправляем запрос на получение пакета
              await locator<UltrasonicService>().transmitFrame("REQ:$queryPacketId");
            } else {
              // У нас есть пакет - отвечаем "ДА" и отправляем через сеть (если есть)
              _log("✅ [Gossip] We have packet ${queryPacketId.substring(0, 8)}..., will send via network");
              // Если есть Wi-Fi Direct или Router - отправляем через него
              if (senderIp != null) {
                Map<String, dynamic>? packetData;
                
                if (hasInOutbox) {
                  final msg = pending.firstWhere((m) => m['id'] == queryPacketId);
                  packetData = {
                    'type': 'OFFLINE_MSG',
                    'content': msg['content'],
                    'senderId': msg['senderId'] ?? _apiService.currentUserId,
                    'h': queryPacketId,
                    'ttl': 5,
                  };
                } else if (hasInDb) {
                  // Находим сообщение в БД
                  final allChats = await db.getAllChatRooms();
                  ChatMessage? foundMsg;
                  for (var chat in allChats) {
                    final chatId = chat['id'] as String? ?? '';
                    if (chatId.isEmpty) continue;
                    final messages = await db.getMessages(chatId);
                    foundMsg = messages.firstWhere((m) => m.id == queryPacketId, orElse: () => foundMsg ?? ChatMessage(id: '', content: '', senderId: '', createdAt: DateTime.now()));
                    if (foundMsg != null && foundMsg.id == queryPacketId) break;
                  }
                  
                  if (foundMsg != null && foundMsg.id == queryPacketId) {
                    packetData = {
                      'type': 'OFFLINE_MSG',
                      'content': foundMsg.content,
                      'senderId': foundMsg.senderId,
                      'h': queryPacketId,
                      'ttl': 5,
                    };
                  }
                }
                
                if (packetData != null) {
                  if (_isP2pConnected) {
                    // Отправляем через Wi-Fi Direct
                    await NativeMeshService.sendTcp(jsonEncode(packetData), host: senderIp);
                  } else {
                    // Если нет Wi-Fi Direct - отправляем через Router (если подключен)
                    final routerConnection = RouterConnectionService();
                    final connectedRouter = routerConnection.connectedRouter;
                    if (connectedRouter != null && connectedRouter.hasInternet) {
                      final routerProtocol = RouterBridgeProtocol();
                      // Используем sendViaRouter с IP роутера или шлем на шлюз
                      final routerIp = connectedRouter.ipAddress ?? "192.168.1.1";
                      await routerProtocol.sendViaRouter(jsonEncode(packetData), routerIp);
                    }
                  }
                }
              }
            }
          }
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
            // 🔄 Event Bus: Fire message received event
            _eventBus.bus.fire(MessageReceivedEvent(data));
            // Legacy StreamController (for backward compatibility)
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

        case 'FRIEND_REQUEST':
          // Запрос на добавление в друзья
          await _handleFriendRequest(data, senderIp);
          break;

        case 'FRIEND_RESPONSE':
          // Ответ на запрос дружбы
          await _handleFriendResponse(data);
          break;

        case 'DIRECT_MSG':
          // Личное сообщение
          await _handleDirectMessage(data, senderIp);
          break;

        case 'GLOBAL_CHAT_MSG':
          // Сообщение в общий чат
          await _handleGlobalChatMessage(data, senderIp);
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
    final orchestrator = locator<TacticalMeshOrchestrator>();
    final currentRole = NetworkMonitor().currentRole;

    // Если я BRIDGE - мои хопы 0. Если нет - беру из оркестратора.
    _myDistanceToBridge = (currentRole == MeshRole.BRIDGE) ? 0 : orchestrator.myHops;

    final pulse = jsonEncode({
      'type': 'MAGNET_PULSE',
      'senderId': _apiService.currentUserId,
      'dist': _myDistanceToBridge, // Метрика Hops
      'batt': await _battery.batteryLevel,
      'press': await _db.getOutboxCount(),
    });

    _log("🧲 Emitting Magnet Pulse (My Hops: $_myDistanceToBridge)");

    // 1. Шлем по Wi-Fi всем активным соседям (L3 Ping)
    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh && !node.metadata.contains(":")) {
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
    String targetIp = _isHost ? _lastKnownPeerIp : "192.168.49.1";
    // Используем порт 55556 для временного BRIDGE сервера
    const int bridgePort = 55556;

    _log("🚀 [Burst] Initiating TCP transfer to $targetIp:$bridgePort");

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await NativeMeshService.sendTcp(message, host: targetIp, port: bridgePort);
        _log("✅ [Burst] Success on attempt $attempt");
        return; // Успех, выходим
      } catch (e) {
        _log("⚠️ [Burst] Attempt $attempt failed: $e");
        // Ждем дольше с каждой попыткой (2с, 4с, 6с)
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    _log("❌ [Burst] Fatal: Could not reach $targetIp:$bridgePort after 3 attempts.");
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
      // Используем порт 55556 для временного BRIDGE сервера
      await NativeMeshService.sendTcp(packet.serialize(), host: targetIp, port: 55556);
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



  /// Функция активации "Маяка Интернета"
  /// Вызывается Оркестратором на BRIDGE-ноде
  void emitInternetMagnetWave() async {
    if (NetworkMonitor().currentRole != MeshRole.BRIDGE) return;

    // 🔥 Улучшение: Проверяем, прошло ли достаточно времени с последнего обновления токена
    // Это обеспечивает минимум 10 секунд стабильности advertising перед сменой токена
    if (_lastTokenUpdate != null) {
      final timeSinceLastUpdate = DateTime.now().difference(_lastTokenUpdate!);
      if (timeSinceLastUpdate < _minTokenStability) {
        final remaining = _minTokenStability - timeSinceLastUpdate;
        _log("⏸️ [Bridge] Token stability window active (${remaining.inSeconds}s remaining), skipping update");
        return; // Не обновляем токен слишком часто
      }
    }
    
    _lastTokenUpdate = DateTime.now();
    
    // 🔥 ШАГ 1.1: Генерация токена за 1-2 секунды до старта BLE advertising
    // Генерируем токен СНАЧАЛА, чтобы он был готов до обновления advertising
    final serverToken = _generateTemporaryToken();
    final expiresAt = DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch; // Валиден 30 секунд
    
    // 🔥 ШАГ 1.4: Логирование генерации токена
    final tokenPreview = serverToken.length > 16 ? serverToken.substring(0, 16) : serverToken;
    _log("🔑 [BRIDGE] Generated token: $tokenPreview... (valid 30s, timestamp: ${DateTime.now().millisecondsSinceEpoch})");
    
    // 🔥 ШАГ 1.1: Задержка 1-2 секунды перед обновлением advertising (чтобы токен был готов)
    _log("⏳ [BRIDGE] Waiting 1.5s before updating advertising with token...");
    await Future.delayed(const Duration(milliseconds: 1500));
    
    // 2. Проверяем возможности железа перед поднятием сервера
    final hardwareCheck = HardwareCheckService();
    final canHost = await hardwareCheck.canHostServer();
    
    if (!canHost) {
      _log("⚠️ [Bridge] Hardware check: Device may struggle with server hosting.");
      // 🔥 КРИТИЧНО: Даже для бюджетных устройств рекламируем token
      // Это позволяет GHOST подключаться через BLE GATT
      final orchestrator = locator<TacticalMeshOrchestrator>();
      final pendingCount = await _db.getOutboxCount();
      final String rawUserId = _apiService.currentUserId;
      final String myShortId = rawUserId.isNotEmpty && rawUserId.length >= 4 
          ? rawUserId.substring(0, 4) 
          : (rawUserId.isNotEmpty ? rawUserId : "GHST");
      
      // 🔥 ШАГ 1.2: Вставка токена в тактическое имя (формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN)
      // 🔒 SECURITY: Encrypt token for BLE advertising (HMAC instead of plaintext)
      final tokenSigningService = MessageSigningService();
      await tokenSigningService.initialize();
      final encryptedToken = await tokenSigningService.encryptTokenForAdvertising(serverToken, expiresAt);
      
      // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN
      // M_0 — Mesh, hops=0 (BRIDGE)
      // 1 — есть pending сообщения (0 — нет)
      // BRIDGE — роль
      // ENCRYPTED_TOKEN — HMAC-токен
      final String tacticalName = "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";
      
      // 🔥 ШАГ 1.2: Обновление advertising не позже, чем через 500ms после генерации токена
      await _btService.stopAdvertising();
      await Future.delayed(const Duration(milliseconds: 500)); // Задержка для стабилизации BLE стека
      await _btService.startAdvertising(tacticalName);
      
      // 🔥 ШАГ 1.4: Логирование обновления advertising
      final encryptedTokenPreview = encryptedToken.length > 16 ? encryptedToken.substring(0, 16) : encryptedToken;
      _log("📡 [BRIDGE] Advertising updated with token");
      _log("   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
      _log("   🔑 Encrypted token preview: $encryptedTokenPreview...");
      _log("   ⏰ Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");
      
      // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android - проверка обновления advertising
      await Future.delayed(const Duration(milliseconds: 2000)); // 2-3 секунды для стабилизации
      final isAdvActive = await _btService.state == BleAdvertiseState.advertising;
      if (isAdvActive) {
        _log("✅ [BRIDGE] Advertising stabilized - token visible for GHOST");
      } else {
        _log("⚠️ [BRIDGE] WARNING: Advertising may not be active - repeating update...");
        // Повторное обновление для надежности на медленных устройствах
        await _btService.stopAdvertising();
        await Future.delayed(const Duration(milliseconds: 500));
        await _btService.startAdvertising(tacticalName);
        _log("🔄 [BRIDGE] Advertising updated again for stability");
      }
      
      // 🔥 КРИТИЧНО: Запускаем GATT сервер даже для бюджетных устройств
      // Это позволяет GHOST подключаться через BLE GATT
      try {
        await _btService.startGattServer();
        _log("✅ [Bridge] GATT server started (hardware-limited mode)");
      } catch (e) {
        _log("⚠️ [Bridge] Failed to start GATT server: $e");
      }
      return; // Не поднимаем TCP сервер для бюджетных устройств
    }
    
    // 3. Проверяем, можно ли поднимать TCP сервер
    final canStartServer = await NativeMeshService.canStartTcpServer();
    if (!canStartServer) {
      _log("🚫 [Bridge] TCP server disabled for this device - using BLE GATT with token");
      // 🔥 КРИТИЧНО: Даже без TCP сервера рекламируем token
      // Это позволяет GHOST подключаться через BLE GATT
      final orchestrator = locator<TacticalMeshOrchestrator>();
      final pendingCount = await _db.getOutboxCount();
      final String rawUserId = _apiService.currentUserId;
      final String myShortId = rawUserId.isNotEmpty && rawUserId.length >= 4 
          ? rawUserId.substring(0, 4) 
          : (rawUserId.isNotEmpty ? rawUserId : "GHST");
      
      // 🔥 ШАГ 1.2: Вставка токена в тактическое имя
      // 🔒 SECURITY: Encrypt token for BLE advertising (HMAC instead of plaintext)
      final tokenSigningService = MessageSigningService();
      await tokenSigningService.initialize();
      final encryptedToken = await tokenSigningService.encryptTokenForAdvertising(serverToken, expiresAt);
      
      // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN
      final String tacticalName = "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";
      
      // 🔥 ШАГ 1.2: Обновление advertising не позже, чем через 500ms после генерации токена
      await _btService.stopAdvertising();
      await Future.delayed(const Duration(milliseconds: 500));
      await _btService.startAdvertising(tacticalName);
      
      // 🔥 ШАГ 1.4: Логирование
      final encryptedTokenPreview = encryptedToken.length > 16 ? encryptedToken.substring(0, 16) : encryptedToken;
      _log("📡 [BRIDGE] Advertising updated with token (TCP server disabled)");
      _log("   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
      _log("   🔑 Encrypted token preview: $encryptedTokenPreview...");
      
      // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android
      await Future.delayed(const Duration(milliseconds: 2000));
      final isAdvActive = await _btService.state == BleAdvertiseState.advertising;
      if (!isAdvActive) {
        _log("⚠️ [BRIDGE] WARNING: Advertising may not be active - repeating update...");
        await _btService.stopAdvertising();
        await Future.delayed(const Duration(milliseconds: 500));
        await _btService.startAdvertising(tacticalName);
        _log("🔄 [BRIDGE] Advertising updated again for stability");
      }
      
      // 🔥 КРИТИЧНО: Запускаем GATT сервер даже без TCP сервера
      try {
        await _btService.startGattServer();
        _log("✅ [Bridge] GATT server started (TCP server disabled)");
      } catch (e) {
        _log("⚠️ [Bridge] Failed to start GATT server: $e");
      }
      return;
    }
    
    // 4. 🔥 КРИТИЧНО: Обновляем BLE advertising с токеном ДО запуска TCP сервера
    // Это важно, чтобы GHOST видел BRIDGE даже если TCP сервер не запустится
    final orchestrator = locator<TacticalMeshOrchestrator>();
    final pendingCount = await _db.getOutboxCount();
    final String rawUserId = _apiService.currentUserId;
    final String myShortId = rawUserId.isNotEmpty && rawUserId.length >= 4 
        ? rawUserId.substring(0, 4) 
        : (rawUserId.isNotEmpty ? rawUserId : "GHST");
    // 🔒 SECURITY: Encrypt token for BLE advertising (HMAC instead of plaintext)
    final tokenSigningService = MessageSigningService();
    await tokenSigningService.initialize();
    final encryptedToken = await tokenSigningService.encryptTokenForAdvertising(serverToken, expiresAt);
    
    // 🔥 ШАГ 1.2: Вставка токена в тактическое имя (формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN)
    final String tacticalName = "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";
    
    // 🔥 ШАГ 1.2: Обновление advertising не позже, чем через 500ms после генерации токена
    await _btService.stopAdvertising();
    await Future.delayed(const Duration(milliseconds: 500)); // Задержка для стабилизации BLE стека
    await _btService.startAdvertising(tacticalName);
    
    // 🔥 ШАГ 1.4: Логирование обновления advertising
    final encryptedTokenPreview = encryptedToken.length > 16 ? encryptedToken.substring(0, 16) : encryptedToken;
    _log("📡 [BRIDGE] Advertising updated with token");
    _log("   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
    _log("   🔑 Encrypted token preview: $encryptedTokenPreview... (full length: ${encryptedToken.length})");
    _log("   🔑 Original token preview: ${tokenPreview}...");
    _log("   ⏰ Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");
    
    // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android - проверка обновления advertising (2-3 секунды)
    await Future.delayed(const Duration(milliseconds: 2000));
    final isAdvActive = await _btService.state == BleAdvertiseState.advertising;
    if (isAdvActive) {
      _log("✅ [BRIDGE] Advertising stabilized - token visible for GHOST");
    } else {
      _log("⚠️ [BRIDGE] WARNING: Advertising may not be active - repeating update...");
      // 🔥 ШАГ 1.3: Повторное обновление для медленных BLE устройств (Huawei/Android)
      await _btService.stopAdvertising();
      await Future.delayed(const Duration(milliseconds: 1000)); // 500-1000ms для надежности
      await _btService.startAdvertising(tacticalName);
      _log("🔄 [BRIDGE] Advertising updated again for stability (Huawei/Android fix)");
    }
    
    // 5. 🔥 РАЗДЕЛЕНИЕ TCP И BLE: Запускаем TCP сервер ТОЛЬКО после успешного запуска GATT и ADV
    // Сначала убеждаемся, что BLE операции завершены
    await Future.delayed(const Duration(milliseconds: 500)); // Даем время на стабилизацию BLE стека
    
    // Проверяем, что advertising действительно активен
    final advState = _btService.state;
    if (advState != BleAdvertiseState.advertising) {
      _log("⚠️ [Bridge] Advertising not active (state: $advState), skipping TCP server start");
      _log("📡 [Bridge] Continuing in BLE GATT mode (advertising with token: ${serverToken.substring(0, 8)}...)");
      return;
    }
    
    // 6. Получаем адаптивную длительность сервера на основе батареи
    final serverDuration = await _getAdaptiveServerDuration();
    
    // 7. Поднимаем кратковременный TCP сервер (после GATT и ADV)
    try {
      await NativeMeshService.startTemporaryTcpServer(durationSeconds: serverDuration);
      _log("🛡️ [Bridge] TCP server active for ${serverDuration}s (started after GATT+ADV)");
    } catch (e) {
      _log("⚠️ [Bridge] Failed to start TCP server: $e");
      // Если сервер не поднялся - продолжаем работать в BLE GATT режиме (advertising уже обновлен с токеном)
      _log("📡 [Bridge] Continuing in BLE GATT mode (TCP server failed, but advertising has token)");
      return;
    }

    // 8. Формируем MAGNET_WAVE пакет с токеном и подписью
    final waveSigningService = MessageSigningService();
    await waveSigningService.initialize();
    
    final publicKey = await waveSigningService.getPublicKeyBase64();
    final wave = {
      'type': 'MAGNET_WAVE',
      'bridgeId': _hashUserId(_apiService.currentUserId), // Хеш для анонимности
      'serverToken': serverToken,
      'port': 55556, // Порт для временного BRIDGE сервера
      'expiresAt': expiresAt,
      'hops': 0, // Я - источник
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderId': _hashUserId(_apiService.currentUserId),
      'publicKey': publicKey, // Public key for verification
    };
    
    // Sign the message
    final signature = await waveSigningService.signMessage(wave);
    wave['signature'] = signature;

    _log("📡 [Magnet] Emitting wave with token: ${serverToken.substring(0, 8)}...");

    // 9. 🔥 СЕГРЕГАЦИЯ TCP И BLE: Выстреливаем TCP только после успешного ADV
    // Используем уже проверенное состояние advState (проверено выше)
    // Даем дополнительное время на стабилизацию BLE стека перед TCP операциями
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Выстреливаем во все стороны (Wi-Fi Direct)
    String payload = jsonEncode(wave);
    sendTcpBurst(payload);
  }

  /// Генерирует временный токен для сессии (SHA-256 хеш)
  String _generateTemporaryToken() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final random = math.Random().nextInt(999999).toString();
    final input = '${_apiService.currentUserId}_$timestamp\_$random';
    final bytes = utf8.encode(input);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// Хеширует User ID для анонимности
  String _hashUserId(String userId) {
    if (userId.isEmpty) return 'GHOST';
    final bytes = utf8.encode(userId);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16); // Первые 16 символов
  }

  /// Получает адаптивную длительность сервера на основе батареи
  Future<int> _getAdaptiveServerDuration() async {
    final batteryLevel = await _battery.batteryLevel;
    if (batteryLevel > 50) return 20; // Батарея > 50%: 20 секунд
    if (batteryLevel > 20) return 15; // Батарея 20-50%: 15 секунд
    return 10; // Батарея < 20%: 10 секунд
  }


  // --- ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ ---

  Future<bool> _isHardwareReady() async {
    if (!Platform.isAndroid) return true;
  // Здесь только проверяем, не запрашивая права повторно (они уже должны быть даны на MeshPermissionScreen)
  if (!await Permission.location.isGranted ||
      !await Permission.bluetoothScan.isGranted ||
      !await Permission.bluetoothConnect.isGranted) {
    _log("⛔ Hardware not ready: missing BLE/location permissions.");
    return false;
  }

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
  
  // 🔒 Fix IP lock expiry: Add TTL for peer IP addresses
  final Map<String, DateTime> _peerIpExpiry = {};



  void logSonarEvent(String msg, {bool isError = false}) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final prefix = isError ? "❌ [SONAR-ERR]" : "🔊 [SONAR]";
    final fullLog = "$timestamp $prefix $msg";

    print(fullLog);
    // 🔄 Event Bus: Fire status event
    _eventBus.bus.fire(StatusEvent(fullLog));
    // Legacy StreamController (for backward compatibility)
    _statusController.add(fullLog); // Отправляем в терминал на экране
    notifyListeners();
  }

  // Универсальный логгер с выводом в терминал UI
  void _log(String msg) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final fullMsg = "[$timestamp] $msg";
    print(fullMsg);
    
    // Сохраняем в список всех логов
    _allLogs.add(fullMsg);
    if (_allLogs.length > _maxLogs) {
      _allLogs.removeAt(0); // Удаляем старые логи, если превышен лимит
    }
    
    // 🔄 Event Bus: Fire status event
    _eventBus.bus.fire(StatusEvent(fullMsg));
    // Legacy StreamController (for backward compatibility)
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
    _isTransferring = false; // СБРОС: линк упал, флаг больше не нужен
    _log("🔌 Link severed.");
    notifyListeners();
  }

  void stopAll() async {
    _log("⚙️ Shutting down Link systems...");

    // 1. Сначала останавливаем сканеры
    stopDiscovery();
    _accelSub?.cancel();
    _adaptiveTimer?.cancel();
    _cleanupTimer?.cancel();
    _periodicDiscoveryTimer?.cancel(); // Останавливаем периодический discovery

    // 2. БЕЗОПАСНАЯ ОСТАНОВКА ВЕЩАНИЯ (SONAR / BEACON)
    try {
      // Проверяем статус перед тем как дергать натив
      // Используем существующий экземпляр из BluetoothMeshService, а не создаем новый
      final isAdvertising = await _btService.state == BleAdvertiseState.advertising;
      if (isAdvertising) {
        await _btService.stopAdvertising();
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
  
  // 🧲 Для GHOST с сообщениями - запускаем периодическое BLE сканирование
  if (NetworkMonitor().currentRole == MeshRole.GHOST) {
    _startContinuousBLEScan();
  }
}

// 🧲 Непрерывное BLE сканирование для GHOST с сообщениями
void _startContinuousBLEScan() {
  Timer.periodic(const Duration(seconds: 20), (timer) async {
    if (!_isMeshEnabled) {
      timer.cancel();
      return;
    }
    
    final pending = await _db.getOutboxCount();
    if (pending > 0) {
      _log("🧲 [Ghost] Continuous BLE scan (pending: $pending messages)...");
      startDiscovery(SignalType.bluetooth);
    } else {
      _log("💤 [Ghost] No messages, stopping continuous scan");
      timer.cancel();
    }
  });
}

// Быстрый скан (при движении) — раз в 30 секунд
void _triggerFastScan() {
  _adaptiveTimer?.cancel();
  _adaptiveTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
    if (!_isMeshEnabled) return;
    _log("📡 Fast Scan Pulse...");
    startDiscovery(SignalType.mesh);
    // 🧲 Для GHOST с сообщениями - также сканируем BLE постоянно
    if (NetworkMonitor().currentRole == MeshRole.GHOST) {
      final pending = await _db.getOutboxCount();
      if (pending > 0) {
        _log("🧲 [Ghost] Has $pending messages, starting continuous BLE scan...");
        startDiscovery(SignalType.bluetooth);
      }
    }
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

  void resetTransferLock() {
    _isTransferring = false;
    _log("🔓 Manual lock reset performed.");
    notifyListeners();
  }
  void _startSonar() {
    final sonar = UltrasonicService();
    sonar.transmitBeacon(); // 🔊 ультразвуковой маяк
    _addLog("🔊 SONAR: Ultrasonic beacon emitted.");
  }

  // ============================================================
  // 🧲 PULL-BASED MESH: Обработка MAGNET_WAVE и загрузка на BRIDGE
  // ============================================================

  /// Обрабатывает MAGNET_WAVE из BLE advertising (fallback, если TCP не работает)
  Future<void> _handleMagnetWaveFromBle(String tokenPrefix, int port, int expiresAt) async {
    // 🔒 Fix duplicate MAGNET_WAVE: Atomic check-and-set to prevent race condition
    final cacheKey = 'magnet_$tokenPrefix';
    final now = DateTime.now();
    
    // Check and set atomically
    if (_linkCooldowns.containsKey(cacheKey)) {
      final lastTime = _linkCooldowns[cacheKey]!;
      if (now.difference(lastTime).inSeconds < 5) {
        return; // Слишком часто, пропускаем
      }
    }
    // Set BEFORE processing to prevent race condition
    _linkCooldowns[cacheKey] = now;
    
    final tokenPreview = tokenPrefix.length > 8 ? tokenPrefix.substring(0, 8) : tokenPrefix;
    _log("🧲 [Ghost] Processing MAGNET_WAVE from BLE (token prefix: $tokenPreview...)");
    
    // Используем тот же метод, что и для TCP MAGNET_WAVE
    // Токен в BLE - это префикс, но BRIDGE должен принять его
    await _handleMagnetWave(tokenPrefix, port, expiresAt);
  }

  /// Публичный метод для Connection Stabilizer
  Future<void> handleMagnetWave(String serverToken, int port, int expiresAt) async {
    await _handleMagnetWave(serverToken, port, expiresAt);
  }
  
  /// Обрабатывает MAGNET_WAVE пакет от BRIDGE
  Future<void> _handleMagnetWave(String serverToken, int port, int expiresAt) async {
    // 🔥 КРИТИЧНО: Проверка просроченного токена перед использованием
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now > expiresAt) {
      _log("⏰ [GHOST] Token expired → Skipping GATT/TCP");
      _log("   Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");
      _log("   Current time: ${DateTime.now().toIso8601String()}");
      _log("   → Escalating to Sonar");
      // Переходим к Sonar для отправки сообщений
      final pending = await _db.getPendingFromOutbox();
      if (pending.isNotEmpty) {
        try {
          final msgId = pending.first['id'] as String;
          if (!_sentPayloads.containsKey(msgId)) {
            final messageData = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': pending.first['content'],
              'senderId': _apiService.currentUserId,
              'h': msgId,
              'ttl': 5,
            });
            final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
            await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
            _sentPayloads[msgId] = 'SONAR';
            await _db.removeFromOutbox(msgId);
            _log("📦 [ARCHITECTURE] Payload $msgId sent via SONAR (token expired)");
          }
        } catch (e) {
          _log("❌ [GHOST] Sonar fallback failed: $e");
        }
      }
      return;
    }
    
    // Проверяем, есть ли сообщения для отправки
    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) {
      _log("💤 [Ghost] No messages to upload");
      return;
    }

    // Получаем IP из Wi-Fi Direct группы (стандартный адрес BRIDGE)
    // Если нет P2P соединения, пытаемся его установить
    String? bridgeIp = _isP2pConnected ? "192.168.49.1" : null;
    
    if (bridgeIp == null) {
      _log("🔌 [Ghost] No P2P connection. Attempting to establish...");
      _log("🔌 [Ghost] Current P2P status: _isP2pConnected=$_isP2pConnected");
      
      // Пытаемся запустить discovery для установки P2P соединения
      await NativeMeshService.startDiscovery();
      _log("🔌 [Ghost] Discovery started, waiting for P2P connection...");
      
      // Ждем до 5 секунд для установки соединения
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (_isP2pConnected) {
          bridgeIp = "192.168.49.1";
          _log("✅ [Ghost] P2P connection established!");
          break;
        }
        _log("⏳ [Ghost] Waiting for P2P... (${i + 1}/5), _isP2pConnected=$_isP2pConnected");
      }
      
      if (bridgeIp == null) {
        _log("⚠️ [Ghost] P2P connection failed after 5s. Trying to connect anyway with default IP 192.168.49.1...");
        // Пытаемся подключиться к стандартному IP даже без P2P (может сработать, если устройства уже в одной группе)
        bridgeIp = "192.168.49.1";
      }
    } else {
      _log("✅ [Ghost] P2P already connected, using IP: $bridgeIp");
    }
    
    if (bridgeIp == null) {
      _log("⚠️ [Ghost] No Wi-Fi Direct connection. Falling back to BLE GATT...");
      // Fallback на BLE GATT будет обработан в _executeCascadeRelay
      return;
    }

    final tokenPreview = serverToken.length > 8 ? serverToken.substring(0, 8) : serverToken;
    _log("🚀 [Ghost] 🔗 Connecting to BRIDGE server at $bridgeIp:$port (token: $tokenPreview...)");
    
    // Проверяем, что порт правильный
    if (port != 55556) {
      _log("⚠️ [Ghost] WARNING: Unexpected port $port, expected 55556");
    }
    
    // 🔥 КРИТИЧНО: Проверяем TCP соединение перед попыткой загрузки
    final isTcpAvailable = await _checkTcpConnection(bridgeIp, port);
    if (!isTcpAvailable) {
      _log("⚠️ [Ghost] TCP connection check failed. Falling back to BLE GATT...");
      // Fallback на BLE GATT - не бросаем исключение, чтобы не прервать основной поток
      return;
    }
    
    _log("✅ [Ghost] TCP connection check passed. Proceeding with upload...");
    
    try {
      await _uploadToBridgeServer(bridgeIp, port, serverToken);
      _log("✅ [Ghost] Successfully uploaded messages to BRIDGE!");
    } catch (e, stackTrace) {
      _log("❌ [Ghost] Bridge upload failed: $e");
      _log("📋 [Ghost] Full error: ${e.toString()}");
      _log("🔄 [Ghost] Falling back to BLE GATT...");
      // Fallback на BLE GATT - не бросаем исключение, чтобы не прервать основной поток
    }
  }

  /// Проверяет наличие BRIDGE после сканирования и запускает forced send
  /// 🔥 Discovery Context: Принимаем решения на основе контекста, а не шума эфира
  /// 
  /// Принцип: "Decisions read context, not noise"
  /// 
  /// Этот метод:
  /// - Читает валидный контекст из DiscoveryContextService
  /// - Не зависит от текущего состояния BLE scan
  /// - Работает даже если scan оборвался или localName пустое
  Future<void> _makeConnectionDecisionFromContext() async {
    try {
      final discoveryContext = locator<DiscoveryContextService>();
      final pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;
      
      _log("🔍 [DiscoveryContext] Making connection decision (pending: ${pending.length} messages)...");
      
      // Получаем лучший BRIDGE из контекста
      final bestBridge = discoveryContext.bestBridge;
      
      if (bestBridge == null) {
        _log("ℹ️ [DiscoveryContext] No valid BRIDGE in context");
        return;
      }
      
      // Проверяем валидность кандидата
      // 🔥 Улучшение: Для BRIDGE с высокой уверенностью увеличиваем TTL
      if (!bestBridge.isValid) {
        // Если confidence очень высокий (>0.8) и много подтверждений, даём дополнительное время
        if (bestBridge.confidence > 0.8 && bestBridge.confirmationCount >= 5) {
          final extendedTtl = bestBridge.ttlSeconds + 30; // +30 секунд для надёжных кандидатов
          if (bestBridge.ageSeconds < extendedTtl) {
            _log("🔄 [DiscoveryContext] Best BRIDGE expired but high confidence, using extended TTL (age: ${bestBridge.ageSeconds}s, extended: $extendedTtl)");
            // Продолжаем, но с предупреждением
          } else {
            _log("⏸️ [DiscoveryContext] Best BRIDGE expired even with extended TTL (age: ${bestBridge.ageSeconds}s)");
            return;
          }
        } else {
          _log("⏸️ [DiscoveryContext] Best BRIDGE expired (age: ${bestBridge.ageSeconds}s)");
          return;
        }
      }
      
      // Проверяем уверенность (минимальный порог)
      // 🔥 Улучшение: Для BRIDGE с множественными подтверждениями снижаем порог
      final minConfidence = bestBridge.confirmationCount >= 3 ? 0.2 : 0.3;
      if (bestBridge.confidence < minConfidence) {
        _log("⏸️ [DiscoveryContext] Best BRIDGE confidence too low (${bestBridge.confidence.toStringAsFixed(2)}, min=$minConfidence)");
        return;
      }
      
      // 🔥 Улучшение: Проверяем возраст кандидата - не блокируем если confidence высокий
      if (bestBridge.ageSeconds > 90) {
        if (bestBridge.confidence < 0.7) {
          _log("⏸️ [DiscoveryContext] Best BRIDGE too old (${bestBridge.ageSeconds}s) and low confidence - skipping");
          return;
        } else {
          _log("⚠️ [DiscoveryContext] Best BRIDGE old (${bestBridge.ageSeconds}s) but high confidence (${bestBridge.confidence.toStringAsFixed(2)}) - proceeding with caution");
          // Продолжаем, но будем использовать TCP fallback более агрессивно
        }
      }
      
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверяем cooldown (30-60 секунд для failed transport)
      final cooldownDuration = bestBridge.confidence >= 0.7 ? 30 : 60; // Увеличено для стабильности
      if (_linkCooldowns.containsKey(bestBridge.mac)) {
        final cooldownTime = _linkCooldowns[bestBridge.mac]!;
        final cooldownAge = DateTime.now().difference(cooldownTime).inSeconds;
        if (cooldownAge < cooldownDuration) {
          _log("⏸️ [DiscoveryContext] BRIDGE in cooldown (${cooldownDuration - cooldownAge}s remaining)");
          return;
        }
      }
      
      // Проверяем, не идет ли уже передача
      if (_isTransferring) {
        _log("⏸️ [DiscoveryContext] Transfer already in progress");
        return;
      }
      
      // 🔥 Принимаем решение: подключаемся к лучшему BRIDGE из контекста
      _log("🧲 [DiscoveryContext] ✅ Connecting to best BRIDGE: ${bestBridge.id} "
           "(confidence=${bestBridge.confidence.toStringAsFixed(2)}, "
           "confirmations=${bestBridge.confirmationCount}, "
           "age=${bestBridge.ageSeconds}s, "
           "sources=${bestBridge.discoverySources.join(',')})");
      
      // 🔥 Улучшение: Пытаемся найти актуальный ScanResult для подключения
      // Это гарантирует, что мы используем свежий токен из advertising
      try {
        final lastScanResults = await FlutterBluePlus.lastScanResults;
        ScanResult? matchingScanResult;
        
        // 🔥 КРИТИЧНО: Ищем по MAC адресу, но также проверяем manufacturerData для всех устройств
        // Это решает проблему "No matching ScanResult" когда MAC не совпадает точно
        for (final result in lastScanResults) {
          final resultMac = result.device.remoteId.str;
          final mfData = result.advertisementData.manufacturerData[0xFFFF];
          final isBridgeByMfData = mfData != null && 
              mfData.length >= 2 && 
              mfData[0] == 0x42 && 
              mfData[1] == 0x52; // "BR" = BRIDGE
          final hasService = result.advertisementData.serviceUuids
              .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
          
          // 🔥 Улучшение: Проверяем через manufacturerData как fallback
          final advName = result.advertisementData.localName ?? "";
          final platformName = result.device.platformName;
          final effectiveName = advName.isEmpty ? platformName : advName;
          
          // Проверяем, что это BRIDGE (через MAC, manufacturerData или service UUID)
          final isMatchingMac = resultMac == bestBridge.mac;
          final isBridgeDevice = isBridgeByMfData || hasService || 
                                 effectiveName.contains("BRIDGE") || 
                                 effectiveName.startsWith("M_0_");
          
          if (isMatchingMac && isBridgeDevice) {
            matchingScanResult = result;
            _log("✅ [DiscoveryContext] Found matching ScanResult by MAC (${isBridgeByMfData ? 'via manufacturerData' : 'via name/service'})");
            break;
          } else if (isBridgeByMfData && matchingScanResult == null) {
            // 🔥 FALLBACK: Если MAC не совпадает, но есть manufacturerData BRIDGE - используем его
            // Это решает проблему с рандомизированными MAC адресами на Android
            matchingScanResult = result;
            _log("✅ [DiscoveryContext] Found BRIDGE via manufacturerData fallback (MAC mismatch: $resultMac vs ${bestBridge.mac})");
            // Не break - продолжаем искать точное совпадение по MAC
          }
        }
        
        // 🔥 Улучшение: Проверяем актуальность token перед подключением (с fallback на manufacturerData)
        String? scanResultToken;
        if (matchingScanResult != null) {
          final advName = matchingScanResult.advertisementData.localName ?? "";
          final platformName = matchingScanResult.device.platformName;
          final effectiveName = advName.isEmpty ? platformName : advName;
          
          if (effectiveName.startsWith("M_") && effectiveName.contains("BRIDGE")) {
            final parts = effectiveName.split("_");
            if (parts.length >= 5 && parts[3] == "BRIDGE") {
              scanResultToken = parts[4];
            }
          }
        }
        
        // 🔥 Улучшение: Если token не совпадает или ScanResult не найден, используем TCP как основной канал
        final tokenMismatch = bestBridge.bridgeToken != null && 
                              scanResultToken != null && 
                              bestBridge.bridgeToken != scanResultToken;
        
        if (tokenMismatch) {
          final contextTokenPreview = bestBridge.bridgeToken != null && bestBridge.bridgeToken!.length > 8 
              ? bestBridge.bridgeToken!.substring(0, 8) 
              : bestBridge.bridgeToken ?? 'none';
          final scanTokenPreview = scanResultToken != null && scanResultToken.length > 8 
              ? scanResultToken.substring(0, 8) 
              : scanResultToken ?? 'none';
          _log("⚠️ [DiscoveryContext] Token mismatch: context=$contextTokenPreview..., scan=$scanTokenPreview...");
          _log("🔄 [DiscoveryContext] Using TCP as primary channel due to token mismatch");
        }
        
        // 🔥 КРИТИЧНО: Если нет matching ScanResult, но есть manufacturerData BRIDGE - используем его
        if (matchingScanResult == null) {
          // Пытаемся найти любой BRIDGE через manufacturerData
          for (final result in lastScanResults) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBridgeByMfData = mfData != null && 
                mfData.length >= 2 && 
                mfData[0] == 0x42 && 
                mfData[1] == 0x52; // "BR" = BRIDGE
            final hasService = result.advertisementData.serviceUuids
                .any((uuid) => uuid.toString().toLowerCase() == _btService.SERVICE_UUID.toLowerCase());
            
            if (isBridgeByMfData || hasService) {
              matchingScanResult = result;
              _log("✅ [DiscoveryContext] Found BRIDGE via manufacturerData fallback (no exact MAC match)");
              break;
            }
          }
        }
        
        // 🔥 Улучшение: TCP как основной канал при нестабильном BLE или token mismatch
        // 🔥 КРИТИЧНО: Пробуем TCP даже если нет bridgeToken - используем MAGNET_WAVE discovery
        if ((tokenMismatch || matchingScanResult == null || bestBridge.ageSeconds > 60)) {
          // Пытаемся использовать TCP если есть IP/порт
          if (bestBridge.ip != null && bestBridge.port != null) {
            _log("🌐 [DiscoveryContext] Using TCP as primary channel (token mismatch or stale scan)");
            _linkCooldowns[bestBridge.mac] = DateTime.now();
            _isTransferring = true;
            notifyListeners();
            try {
              // Если есть bridgeToken - используем его, иначе пробуем MAGNET_WAVE discovery
              if (bestBridge.bridgeToken != null) {
                // 🔥 ШАГ 3: Токен валиден 30 секунд
                await _handleMagnetWave(bestBridge.bridgeToken!, bestBridge.port!, 
                    DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch);
              } else {
                // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: TCP без token ЗАПРЕЩЕН
                _log("🚫 [ARCHITECTURE] No bridgeToken — TCP FORBIDDEN");
                _log("   Escalating directly to Sonar");
                final pending = await _db.getPendingFromOutbox();
                if (pending.isNotEmpty) {
                  try {
                    final msgId = pending.first['id'] as String;
                    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
                    if (_sentPayloads.containsKey(msgId)) {
                      _log("🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
                      _isTransferring = false;
                      notifyListeners();
                      return;
                    }
                    
                    final messageData = jsonEncode({
                      'type': 'OFFLINE_MSG',
                      'content': pending.first['content'],
                      'senderId': _apiService.currentUserId,
                      'h': msgId,
                      'ttl': 5,
                    });
                    final sonarPayload = messageData.length > 200 ? messageData.substring(0, 200) : messageData;
                    await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");
                    
                    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SONAR = ГАРАНТИРОВАННЫЙ маршрут, цикл ЗАКРЫТ
                    _sentPayloads[msgId] = 'SONAR';
                    await _db.removeFromOutbox(msgId);
                    _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_OK (SONAR), removed from outbox");
                    _log("✅ Sonar Packet Emitted (TCP without token). Cycle CLOSED.");
                  } catch (e) {
                    final msgId = pending.isNotEmpty ? pending.first['id'] as String : 'unknown';
                    _log("📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
                    _log("❌ Sonar failed: $e");
                  }
                }
                _isTransferring = false;
                notifyListeners();
                return; // Прерываем попытку TCP
              }
              
              // Если есть bridgeToken - используем TCP напрямую
              final pendingForTcp = await _db.getPendingFromOutbox();
              if (pendingForTcp.isNotEmpty) {
                final String payload = jsonEncode({
                  'type': 'OFFLINE_MSG',
                  'content': pendingForTcp.first['content'],
                  'senderId': _apiService.currentUserId,
                  'h': pendingForTcp.first['id'],
                  'ttl': 5,
                });
                await sendTcpBurst(payload);
              }
              _log("✅ [DiscoveryContext] TCP transfer initiated successfully");
              _isTransferring = false;
              notifyListeners();
              return;
            } catch (e) {
              _log("❌ [DiscoveryContext] TCP transfer failed: $e");
              _isTransferring = false;
              notifyListeners();
              // Fallback на BLE GATT если TCP не удался
              if (matchingScanResult != null) {
                _log("🔄 [DiscoveryContext] Falling back to BLE GATT after TCP failure");
                unawaited(_executeCascadeRelay(matchingScanResult, bestBridge.hops));
              }
            }
          }
        } else if (matchingScanResult != null) {
          // 🔥 Улучшение: Используем Connection Stabilizer для стабилизации подключения
          // Это даёт больше времени для подтверждения advertising и повторных попыток
          _log("📡 [DiscoveryContext] Using Connection Stabilizer for BLE GATT connection");
          _linkCooldowns[bestBridge.mac] = DateTime.now();
          
          final stabilizer = locator<ConnectionStabilizer>();
          final updatedBridge = bestBridge.copyWith(
            bridgeToken: scanResultToken ?? bestBridge.bridgeToken,
            lastSeen: DateTime.now(),
          );
          stabilizer.startStabilization(updatedBridge);
        } else if (bestBridge.ip != null && bestBridge.port != null && bestBridge.bridgeToken != null) {
          // Fallback на TCP, если нет ScanResult
          _log("🌐 [DiscoveryContext] Using TCP connection (no ScanResult available): ${bestBridge.ip}:${bestBridge.port}");
          _linkCooldowns[bestBridge.mac] = DateTime.now();
          try {
            await _handleMagnetWave(bestBridge.bridgeToken!, bestBridge.port!, 
                DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch);
          } catch (e) {
            _log("❌ [DiscoveryContext] TCP fallback failed: $e");
          }
        } else {
          _log("⏸️ [DiscoveryContext] No matching ScanResult and no TCP info - will retry on next scan");
        }
      } catch (e) {
        _log("❌ [DiscoveryContext] Error during connection attempt: $e");
      }
    } catch (e) {
      _log("❌ [DiscoveryContext] Error in _makeConnectionDecisionFromContext: $e");
    }
  }
  
  Future<void> _checkForBridgeAndForceSend() async {
    try {
      final pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;
      
      _log("🔍 [Ghost] Checking for BRIDGE after scan (pending: ${pending.length} messages)...");
      
      // 🔥 Discovery Context: Используем контекст вместо прямого поиска
      final discoveryContext = locator<DiscoveryContextService>();
      final bestBridge = discoveryContext.bestBridge;
      
      if (bestBridge != null && bestBridge.isValid && bestBridge.confidence >= 0.3) {
        _log("🧲 [Ghost] ✅ Best BRIDGE from context: ${bestBridge.id} (confidence=${bestBridge.confidence.toStringAsFixed(2)})");
        // Используем контекст для принятия решения
        await _makeConnectionDecisionFromContext();
        return;
      }
      
      // Получаем последние результаты сканирования
      final lastScanResults = await FlutterBluePlus.lastScanResults;
      
      // Ищем BRIDGE (hops=0) в результатах сканирования
      for (var result in lastScanResults) {
        final advName = result.advertisementData.localName ?? '';
        if (advName.startsWith("M_")) {
          final parts = advName.split("_");
          if (parts.length >= 2) {
            final peerHops = int.tryParse(parts[1]) ?? 99;
            if (peerHops == 0) {
              // Найден BRIDGE!
              final mac = result.device.remoteId.str;
              _log("🧲 [Ghost] ⚡ BRIDGE found after scan! Initiating forced send...");
              
              // Проверяем cooldown
              if (!_linkCooldowns.containsKey(mac) && !_isTransferring) {
                _linkCooldowns[mac] = DateTime.now();
                // Запускаем каскадное подключение
                unawaited(_executeCascadeRelay(result, peerHops));
                return; // Обрабатываем только первый найденный BRIDGE
              } else {
                _log("⏸️ [Ghost] BRIDGE found but cooldown active or transfer in progress");
              }
            }
          }
        }
      }
      
      _log("ℹ️ [Ghost] No BRIDGE found after scan");
    } catch (e) {
      _log("❌ [Ghost] Error checking for BRIDGE: $e");
    }
  }

  /// Проверяет доступность TCP соединения к BRIDGE серверу
  /// Возвращает true, если соединение доступно, false - если нет
  Future<bool> _checkTcpConnection(String ip, int port) async {
    try {
      _log("🔍 [Ghost] Checking TCP connection to $ip:$port (timeout: 3s)...");
      
      // Быстрая проверка соединения с коротким таймаутом (3 секунды)
      final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 3))
          .timeout(const Duration(seconds: 3), onTimeout: () {
        _log("⏱️ [Ghost] TCP connection check timeout after 3s");
        throw TimeoutException("Connection check timeout");
      });
      
      // Если соединение установлено - сразу закрываем (это только проверка)
      await socket.close();
      _log("✅ [Ghost] TCP connection check passed - server is available");
      return true;
    } catch (e) {
      _log("❌ [Ghost] TCP connection check failed: $e");
      return false;
    }
  }

  /// Загружает batch сообщений на BRIDGE TCP сервер
  Future<void> _uploadToBridgeServer(String ip, int port, String token) async {
    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) return;

    // Ограничиваем batch до 100 сообщений
    final batch = pending.take(100).toList();
    final batchId = 'batch_${DateTime.now().millisecondsSinceEpoch}';

    _log("📦 [Ghost] Uploading ${batch.length} messages to BRIDGE...");

    Socket? socket;
    try {
      _log("🔌 [Ghost] Attempting connection to $ip:$port (timeout: 10s)");
      _log("🔌 [Ghost] Socket.connect starting...");
      
      // 🔒 Fix TCP reconnect: Add retry logic with exponential backoff
      Socket? socket;
      int retries = 0;
      const maxRetries = 3;
      
      while (retries < maxRetries) {
        try {
          socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 10))
              .timeout(const Duration(seconds: 10), onTimeout: () {
            throw TimeoutException("Connection timeout");
          });
          break; // Success, exit retry loop
        } catch (e) {
          retries++;
          if (retries >= maxRetries) {
            _log("❌ [Ghost] TCP connection failed after $maxRetries attempts: $e");
            rethrow;
          }
          final delay = Duration(seconds: retries * 2); // Exponential backoff: 2s, 4s, 6s
          _log("⚠️ [Ghost] TCP connection attempt $retries failed, retrying in ${delay.inSeconds}s...");
          await Future.delayed(delay);
        }
      }
      
      _log("✅ [Ghost] Connected to BRIDGE server at $ip:$port");
      
      // Формируем upload пакет
      final uploadPacket = {
        'type': 'GHOST_UPLOAD',
        'token': token,
        'senderId': _hashUserId(_apiService.currentUserId),
        'batchId': batchId,
        'messages': batch.map((m) => {
          'id': m['id']?.toString() ?? '',
          'chatId': m['chatRoomId']?.toString() ?? 'THE_BEACON_GLOBAL',
          'content': m['content']?.toString() ?? '',
          'timestamp': m['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
        }).toList(),
        'count': batch.length,
      };

      // Отправляем JSON (без пробелов для экономии)
      final jsonString = jsonEncode(uploadPacket);
      socket?.add(utf8.encode('$jsonString\n'));
      await socket?.flush();

      _log("✅ [Ghost] Batch sent. Waiting for ACK...");

      // Ждем ACK (таймаут 3 секунды)
      final completer = Completer<String>();
      final subscription = socket?.listen(
        (data) {
          if (!completer.isCompleted) {
            completer.complete(utf8.decode(data));
          }
        },
        onError: (e) {
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.completeError(Exception("Socket closed before ACK received"));
          }
        },
        cancelOnError: true,
      );

      final response = await completer.future.timeout(const Duration(seconds: 3));
      await subscription?.cancel();
      
      final ack = jsonDecode(response) as Map<String, dynamic>;
      
      if (ack['status'] == 'OK' && ack['processed'] == true) {
        final received = ack['received'] ?? 0;
        _log("✅ [Ghost] Upload successful! BRIDGE received $received messages");
        
        // Удаляем из Outbox только успешно отправленные
        final ids = batch.map((m) => m['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
        if (ids.isNotEmpty) {
          for (final id in ids) {
            await _db.removeFromOutbox(id);
          }
          _log("🗑️ [Ghost] Removed ${ids.length} messages from Outbox");
        }
      } else {
        _log("⚠️ [Ghost] BRIDGE rejected batch: ${ack['status']}");
      }
      
    } catch (e, stackTrace) {
      _log("❌ [Ghost] Upload error: $e");
      _log("📋 [Ghost] Error type: ${e.runtimeType}");
      _log("📋 [Ghost] Stack trace: $stackTrace");
      rethrow; // Пробрасываем для fallback логики
    } finally {
      socket?.close();
      _log("🔌 [Ghost] Socket closed");
    }
  }

  // ============================================================
  // 👥 FRIENDS & MESSAGING PROTOCOLS (Масштабируемая система)
  // ============================================================

  /// Обрабатывает запрос на добавление в друзья
  Future<void> _handleFriendRequest(Map<String, dynamic> data, String? senderIp) async {
    final senderId = data['senderId']?.toString() ?? '';
    final receiverId = _apiService.currentUserId;
    final senderUsername = data['senderUsername']?.toString() ?? 'Unknown';
    final message = data['message']?.toString() ?? '';

    if (senderId.isEmpty || senderId == receiverId) return;

    _log("👥 [Friends] Friend request from $senderUsername ($senderId)");

    // Сохраняем в БД со статусом 'pending'
    await _db.saveFriend(
      friendId: senderId,
      username: senderUsername,
      status: 'pending',
      requestedAt: DateTime.now().millisecondsSinceEpoch,
    );

    // Уведомляем UI (можно показать диалог подтверждения)
    final eventData = {
      'type': 'FRIEND_REQUEST',
      'senderId': senderId,
      'senderUsername': senderUsername,
      'message': message,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    // 🔄 Event Bus: Fire message received event
    _eventBus.bus.fire(MessageReceivedEvent(eventData));
    // Legacy StreamController (for backward compatibility)
    _messageController.add(eventData);
  }

  /// Обрабатывает ответ на запрос дружбы
  Future<void> _handleFriendResponse(Map<String, dynamic> responseData) async {
    final senderId = responseData['senderId']?.toString() ?? '';
    final status = responseData['status']?.toString() ?? 'rejected';

    if (senderId.isEmpty) return;

    _log("👥 [Friends] Friend response from $senderId: $status");

    // Обновляем статус в БД
    await _db.updateFriendStatus(
      senderId,
      status == 'accepted' ? 'accepted' : 'rejected',
      acceptedAt: status == 'accepted' ? DateTime.now().millisecondsSinceEpoch : null,
    );

    // Уведомляем UI
    final eventData = {
      'type': 'FRIEND_RESPONSE',
      'senderId': senderId,
      'status': status,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    // 🔄 Event Bus: Fire message received event
    _eventBus.bus.fire(MessageReceivedEvent(eventData));
    // Legacy StreamController (for backward compatibility)
    _messageController.add(eventData);
  }

  /// Обрабатывает личное сообщение
  Future<void> _handleDirectMessage(Map<String, dynamic> messageData, String? senderIp) async {
    final senderId = messageData['senderId']?.toString() ?? '';
    final receiverId = messageData['receiverId']?.toString() ?? '';
    final myId = _apiService.currentUserId;
    final chatId = messageData['chatId']?.toString() ?? '';

    // Проверяем, что сообщение адресовано нам
    if (receiverId != myId && !chatId.contains(myId)) {
      // Это не нам, но можем ретранслировать через Gossip
      await locator<GossipManager>().processEnvelope(messageData);
      return;
    }

    _log("📨 [DM] Direct message from $senderId");

    final content = messageData['content']?.toString() ?? '';
    final messageId = messageData['id']?.toString() ?? 'msg_${DateTime.now().millisecondsSinceEpoch}';

    // Сохраняем в БД
    await _db.saveDirectMessage(
      id: messageId,
      chatId: chatId,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      isEncrypted: messageData['isEncrypted'] == true,
    );

    // Отмечаем как доставленное
    await _db.markMessageDelivered(messageId);

    // Отправляем подтверждение отправителю (если он в радиусе)
    if (senderIp != null && _isP2pConnected) {
      final ack = jsonEncode({
        'type': 'DM_DELIVERED',
        'messageId': messageId,
        'receiverId': myId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await NativeMeshService.sendTcp(ack, host: senderIp);
    }

    // Уведомляем UI
    final eventData = {
      'type': 'DIRECT_MSG',
      'senderId': senderId,
      'chatId': chatId,
      'content': content,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    // 🔄 Event Bus: Fire message received event
    _eventBus.bus.fire(MessageReceivedEvent(eventData));
    // Legacy StreamController (for backward compatibility)
    _messageController.add(eventData);
  }

  /// Обрабатывает сообщение в общий чат
  Future<void> _handleGlobalChatMessage(Map<String, dynamic> messageData, String? senderIp) async {
    final senderId = messageData['senderId']?.toString() ?? '';
    final content = messageData['content']?.toString() ?? '';
    final gossipHash = messageData['gossip_hash']?.toString() ?? '';
    final messageId = messageData['id']?.toString() ?? 'msg_${DateTime.now().millisecondsSinceEpoch}';

    // Проверяем дедупликацию через gossip hash
    if (gossipHash.isNotEmpty && await _db.isGossipMessageSeen(gossipHash)) {
      _log("♻️ [Global] Duplicate message (gossip hash: ${gossipHash.substring(0, 8)}...). Dropping.");
      return;
    }

    _log("🌐 [Global] Global chat message from $senderId");

    // Сохраняем в БД
    await _db.saveGlobalChatMessage(
      id: messageId,
      senderId: senderId,
      senderUsername: messageData['senderUsername']?.toString(),
      content: content,
      gossipHash: gossipHash,
      ttl: messageData['ttl'] ?? 7,
      isEncrypted: messageData['isEncrypted'] == true,
    );

    // Ретранслируем через Gossip (если это новое сообщение)
    if (gossipHash.isEmpty || !await _db.isGossipMessageSeen(gossipHash)) {
      await locator<GossipManager>().processEnvelope(messageData);
    }

    // Уведомляем UI
    final eventData = {
      'type': 'GLOBAL_CHAT_MSG',
      'senderId': senderId,
      'senderUsername': messageData['senderUsername'],
      'content': content,
      'chatId': 'THE_BEACON_GLOBAL',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    // 🔄 Event Bus: Fire message received event
    _eventBus.bus.fire(MessageReceivedEvent(eventData));
    // Legacy StreamController (for backward compatibility)
    _messageController.add(eventData);
  }

  /// Отправляет запрос на добавление в друзья
  Future<void> sendFriendRequest(String friendId, {String? message}) async {
    final myId = _apiService.currentUserId;
    final myUsername = await Vault.read('user_name') ?? 'Nomad';

    final request = jsonEncode({
      'type': 'FRIEND_REQUEST',
      'senderId': _hashUserId(myId),
      'receiverId': friendId,
      'senderUsername': myUsername,
      'message': message ?? 'Привет! Добавь меня в друзья',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Ищем друга через mesh
    final friendNode = _nearbyNodes.values.firstWhere(
      (node) => node.id == friendId || node.metadata == friendId,
      orElse: () => SignalNode(
        id: friendId,
        name: 'Unknown',
        type: SignalType.bluetooth,
        metadata: friendId, // Используем friendId как metadata для fallback
      ),
    );

    // Отправляем через доступный канал
    if (friendNode.type == SignalType.mesh && _isP2pConnected) {
      await NativeMeshService.sendTcp(request, host: friendNode.metadata);
    } else if (friendNode.type == SignalType.bluetooth) {
      // Fallback на BLE GATT
      try {
        final device = BluetoothDevice.fromId(friendNode.id);
        await _btService.sendMessage(device, request);
      } catch (e) {
        _log("❌ [Friends] Failed to send friend request: $e");
      }
    }
  }

  /// Отправляет личное сообщение другу
  Future<void> sendDirectMessage(String friendId, String content) async {
    final myId = _apiService.currentUserId;
    final chatId = 'dm_${_hashUserId(myId)}_$friendId';
    final messageId = 'dm_${DateTime.now().millisecondsSinceEpoch}';

    // Шифруем сообщение
    final encryption = locator<EncryptionService>();
    final key = await encryption.getChatKey(chatId);
    final encryptedContent = await encryption.encrypt(content, key);

    final message = jsonEncode({
      'type': 'DIRECT_MSG',
      'id': messageId,
      'senderId': _hashUserId(myId),
      'receiverId': friendId,
      'chatId': chatId,
      'content': encryptedContent,
      'isEncrypted': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'ttl': 5,
    });

    // Сохраняем в БД (для истории)
    await _db.saveDirectMessage(
      id: messageId,
      chatId: chatId,
      senderId: myId,
      receiverId: friendId,
      content: encryptedContent,
      isEncrypted: true,
    );

    // Добавляем в Outbox для доставки
    final chatMessage = ChatMessage(
      id: messageId,
      content: encryptedContent,
      senderId: myId,
      createdAt: DateTime.now(),
      status: 'PENDING_DELIVERY',
    );
    await _db.addToOutbox(chatMessage, chatId);

    // Пытаемся доставить через mesh
    final friendNode = _nearbyNodes.values.firstWhere(
      (node) => node.id == friendId,
      orElse: () => SignalNode(
        id: friendId,
        name: 'Unknown',
        type: SignalType.bluetooth,
        metadata: friendId, // Используем friendId как metadata для fallback
      ),
    );

    if (friendNode.type == SignalType.mesh && _isP2pConnected) {
      await NativeMeshService.sendTcp(message, host: friendNode.metadata);
    } else if (friendNode.type == SignalType.bluetooth) {
      try {
        final device = BluetoothDevice.fromId(friendNode.id);
        await _btService.sendMessage(device, message);
      } catch (e) {
        _log("❌ [DM] Failed to send direct message: $e");
      }
    }
  }
}
