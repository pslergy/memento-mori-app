import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'locator.dart';
import 'mesh_service.dart';
import 'bluetooth_service.dart';
import 'native_mesh_service.dart';
import 'network_monitor.dart';
import 'local_db_service.dart';
import 'api_service.dart';
import 'gossip_manager.dart';
import 'peer_cache_service.dart';

/// Состояние соединения
enum ConnectionState {
  idle,
  connecting,
  connected,
  disconnecting,
  failed,
  reparing,
}

/// Тип канала связи
enum ChannelType {
  bleGatt,
  wifiDirect,
  tcp,
  sonar,
}

/// Информация об активном соединении
class ActiveConnection {
  final String deviceId;
  final String? deviceToken;
  ChannelType channelType; // Не final - может меняться при repair/fallback
  final DateTime connectedAt;
  ConnectionState state;
  int failureCount;
  DateTime? lastActivity;
  String? ipAddress;
  int? port;
  
  ActiveConnection({
    required this.deviceId,
    this.deviceToken,
    required this.channelType,
    required this.connectedAt,
    this.state = ConnectionState.connected,
    this.failureCount = 0,
    this.lastActivity,
    this.ipAddress,
    this.port,
  });
  
  bool get isHealthy => state == ConnectionState.connected && failureCount < 3;
  bool get needsRepair => state == ConnectionState.failed || failureCount >= 3;
  
  Duration get connectionAge => DateTime.now().difference(connectedAt);
  Duration? get inactivityTime => lastActivity != null 
      ? DateTime.now().difference(lastActivity!) 
      : null;
  
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceToken': deviceToken?.substring(0, math.min(8, deviceToken?.length ?? 0)),
    'channelType': channelType.name,
    'connectedAt': connectedAt.toIso8601String(),
    'state': state.name,
    'failureCount': failureCount,
    'lastActivity': lastActivity?.toIso8601String(),
    'ipAddress': ipAddress,
  };
}

/// Элемент очереди подключений
class ConnectionQueueItem {
  final String deviceId;
  final String? deviceToken;
  final ChannelType preferredChannel;
  final DateTime requestedAt;
  final int priority; // 0 = высший, 10 = низший
  final Completer<bool> completer;
  int retryCount;
  
  ConnectionQueueItem({
    required this.deviceId,
    this.deviceToken,
    required this.preferredChannel,
    required this.requestedAt,
    this.priority = 5,
    required this.completer,
    this.retryCount = 0,
  });
  
  bool get isExpired => DateTime.now().difference(requestedAt).inSeconds > 60;
}

/// Доверенное устройство
class TrustedDevice {
  final String deviceId;
  final String token;
  final DateTime addedAt;
  final DateTime? lastSeen;
  int trustScore; // 0-100
  
  TrustedDevice({
    required this.deviceId,
    required this.token,
    required this.addedAt,
    this.lastSeen,
    this.trustScore = 50,
  });
  
  bool get isExpired => lastSeen != null && 
      DateTime.now().difference(lastSeen!).inHours > 24;
}

/// 🔥 ГЛАВНЫЙ REPEATER/REPAIR СЕРВИС
class RepeaterService with ChangeNotifier {
  static final RepeaterService _instance = RepeaterService._internal();
  factory RepeaterService() => _instance;
  RepeaterService._internal();
  
  // ============================================================================
  // КОНФИГУРАЦИЯ
  // ============================================================================
  
  static const int MAX_CONCURRENT_CONNECTIONS = 5;
  static const int CONNECTION_TIMEOUT_SECONDS = 30;
  static const int REPAIR_INTERVAL_SECONDS = 15;
  static const int HEALTH_CHECK_INTERVAL_SECONDS = 10;
  static const int MAX_QUEUE_SIZE = 20;
  static const int MAX_RETRY_COUNT = 3;
  
  // ============================================================================
  // СОСТОЯНИЕ
  // ============================================================================
  
  // Активные соединения
  final Map<String, ActiveConnection> _activeConnections = {};
  
  // Очередь подключений (приоритетная)
  final PriorityQueue<ConnectionQueueItem> _connectionQueue = 
      PriorityQueue<ConnectionQueueItem>((a, b) => a.priority.compareTo(b.priority));
  
  // Доверенные устройства
  final Map<String, TrustedDevice> _trustedDevices = {};
  
  // Таймеры
  Timer? _repairTimer;
  Timer? _healthCheckTimer;
  Timer? _queueProcessorTimer;
  
  // Флаги
  bool _isRunning = false;
  bool _isProcessingQueue = false;
  
  // Статистика
  int _totalRepeatedPackets = 0;
  int _totalRepairedConnections = 0;
  int _totalBlockedConnections = 0;
  
  // Логи
  final List<String> _logs = [];
  static const int MAX_LOGS = 100;
  
  // ============================================================================
  // ПУБЛИЧНЫЕ ГЕТТЕРЫ
  // ============================================================================
  
  bool get isRunning => _isRunning;
  int get activeConnectionCount => _activeConnections.length;
  int get queueSize => _connectionQueue.toList().length;
  int get trustedDeviceCount => _trustedDevices.length;
  List<ActiveConnection> get connections => _activeConnections.values.toList();
  List<String> get logs => List.unmodifiable(_logs);
  
  Map<String, dynamic> get statistics => {
    'activeConnections': activeConnectionCount,
    'queueSize': queueSize,
    'trustedDevices': trustedDeviceCount,
    'totalRepeatedPackets': _totalRepeatedPackets,
    'totalRepairedConnections': _totalRepairedConnections,
    'totalBlockedConnections': _totalBlockedConnections,
    'isRunning': _isRunning,
  };
  
  // ============================================================================
  // ЖИЗНЕННЫЙ ЦИКЛ
  // ============================================================================
  
  /// Запуск Repeater/Repair режима
  void start() {
    if (_isRunning) {
      _log("⚠️ Repeater уже запущен");
      return;
    }
    
    _isRunning = true;
    _log("🚀 [REPEATER] Starting Repeater/Repair mode...");
    
    // Запускаем таймеры
    _startHealthCheck();
    _startRepairCycle();
    _startQueueProcessor();
    
    _log("✅ [REPEATER] Mode active");
    _log("   📋 Max connections: $MAX_CONCURRENT_CONNECTIONS");
    _log("   📋 Repair interval: ${REPAIR_INTERVAL_SECONDS}s");
    _log("   📋 Health check: ${HEALTH_CHECK_INTERVAL_SECONDS}s");
    
    notifyListeners();
  }
  
  /// Остановка Repeater/Repair режима
  void stop() {
    if (!_isRunning) return;
    
    _log("🛑 [REPEATER] Остановка Repeater/Repair режима...");
    
    _isRunning = false;
    _repairTimer?.cancel();
    _healthCheckTimer?.cancel();
    _queueProcessorTimer?.cancel();
    
    // Закрываем все соединения
    for (final conn in _activeConnections.values) {
      conn.state = ConnectionState.disconnecting;
    }
    _activeConnections.clear();
    
    // Очищаем очередь
    while (_connectionQueue.toList().isNotEmpty) {
      final item = _connectionQueue.removeFirst();
      if (!item.completer.isCompleted) {
        item.completer.complete(false);
      }
    }
    
    _log("✅ [REPEATER] Mode stopped");
    notifyListeners();
  }
  
  // ============================================================================
  // УПРАВЛЕНИЕ ДОВЕРЕННЫМИ УСТРОЙСТВАМИ
  // ============================================================================
  
  /// Добавляет устройство в список доверенных
  void addTrustedDevice(String deviceId, String token) {
    if (deviceId.isEmpty || token.isEmpty) {
      _log("❌ [TRUST] Невозможно добавить: пустой deviceId или token");
      return;
    }
    
    // Валидация токена
    if (!_validateToken(token)) {
      _log("❌ [TRUST] Невалидный токен для устройства $deviceId");
      _totalBlockedConnections++;
      return;
    }
    
    _trustedDevices[deviceId] = TrustedDevice(
      deviceId: deviceId,
      token: token,
      addedAt: DateTime.now(),
      lastSeen: DateTime.now(),
      trustScore: 50,
    );
    
    _log("✅ [TRUST] Устройство $deviceId добавлено в доверенные");
    notifyListeners();
  }
  
  /// Удаляет устройство из списка доверенных
  void removeTrustedDevice(String deviceId) {
    if (_trustedDevices.remove(deviceId) != null) {
      _log("🗑️ [TRUST] Устройство $deviceId удалено из доверенных");
      
      // Закрываем соединение если есть
      final conn = _activeConnections[deviceId];
      if (conn != null) {
        _closeConnection(deviceId, reason: "Устройство удалено из доверенных");
      }
      
      notifyListeners();
    }
  }
  
  /// Проверяет, является ли устройство доверенным
  bool isTrustedDevice(String deviceId, String? token) {
    final trusted = _trustedDevices[deviceId];
    if (trusted == null) return false;
    
    // Проверяем токен
    if (token != null && trusted.token != token) {
      _log("⚠️ [TRUST] Токен не совпадает для $deviceId");
      return false;
    }
    
    // Проверяем срок доверия
    if (trusted.isExpired) {
      _log("⚠️ [TRUST] Срок доверия истек для $deviceId");
      return false;
    }
    
    return true;
  }
  
  /// Обновляет trust score устройства
  void updateTrustScore(String deviceId, int delta) {
    final trusted = _trustedDevices[deviceId];
    if (trusted != null) {
      trusted.trustScore = (trusted.trustScore + delta).clamp(0, 100);
      _log("📊 [TRUST] Trust score для $deviceId: ${trusted.trustScore}");
    }
  }
  
  // ============================================================================
  // УПРАВЛЕНИЕ СОЕДИНЕНИЯМИ
  // ============================================================================
  
  /// Запрашивает подключение к устройству (через очередь)
  Future<bool> requestConnection({
    required String deviceId,
    String? deviceToken,
    ChannelType preferredChannel = ChannelType.bleGatt,
    int priority = 5,
  }) async {
    _log("📥 [QUEUE] Запрос подключения к $deviceId (priority: $priority)");
    
    // Проверяем безопасность
    if (deviceToken != null && !isTrustedDevice(deviceId, deviceToken)) {
      // Если токен предоставлен но устройство не доверенное - добавляем
      if (_validateToken(deviceToken)) {
        addTrustedDevice(deviceId, deviceToken);
      } else {
        _log("❌ [SECURITY] Отклонено: устройство $deviceId не доверенное");
        _totalBlockedConnections++;
        return false;
      }
    }
    
    // Проверяем, нет ли уже активного соединения
    if (_activeConnections.containsKey(deviceId)) {
      final existing = _activeConnections[deviceId]!;
      if (existing.isHealthy) {
        _log("ℹ️ [QUEUE] Соединение с $deviceId уже активно");
        return true;
      }
    }
    
    // Проверяем размер очереди
    if (_connectionQueue.toList().length >= MAX_QUEUE_SIZE) {
      _log("⚠️ [QUEUE] Очередь переполнена, отклоняем запрос");
      return false;
    }
    
    // Добавляем в очередь
    final completer = Completer<bool>();
    _connectionQueue.add(ConnectionQueueItem(
      deviceId: deviceId,
      deviceToken: deviceToken,
      preferredChannel: preferredChannel,
      requestedAt: DateTime.now(),
      priority: priority,
      completer: completer,
    ));
    
    _log("📋 [QUEUE] Добавлено в очередь (позиция: ${_connectionQueue.toList().length})");
    
    // Ждем результат
    return completer.future.timeout(
      Duration(seconds: CONNECTION_TIMEOUT_SECONDS),
      onTimeout: () {
        _log("⏱️ [QUEUE] Таймаут подключения к $deviceId");
        return false;
      },
    );
  }
  
  /// Регистрирует активное соединение
  void registerConnection({
    required String deviceId,
    String? deviceToken,
    required ChannelType channelType,
    String? ipAddress,
    int? port,
  }) {
    // Проверяем безопасность
    if (deviceToken != null && !_validateToken(deviceToken)) {
      _log("❌ [SECURITY] Отклонена регистрация: невалидный токен");
      _totalBlockedConnections++;
      return;
    }
    
    final connection = ActiveConnection(
      deviceId: deviceId,
      deviceToken: deviceToken,
      channelType: channelType,
      connectedAt: DateTime.now(),
      lastActivity: DateTime.now(),
      ipAddress: ipAddress,
      port: port,
    );
    
    _activeConnections[deviceId] = connection;
    
    _log("✅ [CONN] Зарегистрировано соединение: $deviceId via ${channelType.name}");
    _log("   📋 IP: $ipAddress, Port: $port");
    _log("   📋 Активных соединений: ${_activeConnections.length}");
    
    // Обновляем trust score
    if (deviceToken != null) {
      updateTrustScore(deviceId, 5);
    }
    
    notifyListeners();
  }
  
  /// Обновляет активность соединения
  void updateConnectionActivity(String deviceId) {
    final conn = _activeConnections[deviceId];
    if (conn != null) {
      conn.lastActivity = DateTime.now();
      conn.failureCount = 0; // Сбрасываем счетчик ошибок при активности
    }
  }
  
  /// Отмечает ошибку соединения
  void markConnectionFailure(String deviceId) {
    final conn = _activeConnections[deviceId];
    if (conn != null) {
      conn.failureCount++;
      _log("⚠️ [CONN] Ошибка соединения $deviceId (${conn.failureCount}/$MAX_RETRY_COUNT)");
      
      if (conn.failureCount >= MAX_RETRY_COUNT) {
        conn.state = ConnectionState.failed;
        _log("❌ [CONN] Соединение $deviceId помечено как failed");
        
        // Уменьшаем trust score
        updateTrustScore(deviceId, -10);
      }
    }
  }
  
  /// Закрывает соединение
  void _closeConnection(String deviceId, {String? reason}) {
    final conn = _activeConnections.remove(deviceId);
    if (conn != null) {
      conn.state = ConnectionState.disconnecting;
      _log("🔌 [CONN] Закрыто соединение с $deviceId${reason != null ? ' ($reason)' : ''}");
      notifyListeners();
    }
  }
  
  // ============================================================================
  // REPEATER ЛОГИКА (РЕТРАНСЛЯЦИЯ ТРАФИКА)
  // ============================================================================
  
  /// Ретранслирует пакет доверенным устройствам
  /// 🔥 MESH RELAY: Store & Forward для всех устройств (BRIDGE и GHOST)
  Future<int> repeatPacket(Map<String, dynamic> packet, {String? excludeDeviceId}) async {
    if (!_isRunning) return 0;
    
    final String packetId = packet['h'] ?? packet['mid'] ?? packet['id'] ?? 'unknown';
    final String packetType = packet['type'] ?? 'UNKNOWN';
    final int ttl = packet['ttl'] ?? 5;
    final String senderId = packet['senderId'] ?? 'unknown';
    
    // 📊 FORENSIC LOG: relay_start
    _log("📡 [RELAY] relay_start: ${packetId.substring(0, math.min(8, packetId.length))}...");
    _log("   📋 Type: $packetType, TTL: $ttl, Sender: ${senderId.substring(0, math.min(8, senderId.length))}...");
    
    // 🛡️ TTL CHECK: Не ретранслируем пакеты с истёкшим TTL
    if (ttl <= 0) {
      // 📊 FORENSIC LOG: relay_dropped (TTL)
      _log("🛑 [RELAY] relay_dropped: TTL expired for $packetId");
      return 0;
    }
    
    // Декрементируем TTL для ретрансляции
    final relayPacket = Map<String, dynamic>.from(packet);
    relayPacket['ttl'] = ttl - 1;
    
    int successCount = 0;
    int skippedCount = 0;
    
    for (final conn in _activeConnections.values) {
      // Пропускаем отправителя
      if (conn.deviceId == excludeDeviceId) {
        skippedCount++;
        continue;
      }
      
      // Проверяем здоровье соединения
      if (!conn.isHealthy) {
        _log("⏭️ [RELAY] Skip ${conn.deviceId.substring(0, math.min(8, conn.deviceId.length))}... (unhealthy)");
        skippedCount++;
        continue;
      }
      
      // Проверяем доверие
      if (!isTrustedDevice(conn.deviceId, conn.deviceToken)) {
        _log("⏭️ [RELAY] Skip ${conn.deviceId.substring(0, math.min(8, conn.deviceId.length))}... (untrusted)");
        skippedCount++;
        continue;
      }
      
      try {
        final success = await _sendToDevice(conn, relayPacket);
        if (success) {
          successCount++;
          updateConnectionActivity(conn.deviceId);
          try {
            locator<PeerCacheService>().recordSuccess(
              peerId: conn.deviceId,
              latency: Duration.zero,
              channel: conn.channelType.name,
            );
          } catch (_) {}
          // 📊 FORENSIC LOG: relay_forwarded
          _log("✅ [RELAY] relay_forwarded: $packetId -> ${conn.deviceId.substring(0, math.min(8, conn.deviceId.length))}... via ${conn.channelType.name}");
        } else {
          markConnectionFailure(conn.deviceId);
          try {
            locator<PeerCacheService>().recordFailure(
              peerId: conn.deviceId,
              channel: conn.channelType.name,
              reason: null,
            );
          } catch (_) {}
          // 📊 FORENSIC LOG: relay_failed
          _log("⚠️ [RELAY] relay_failed: $packetId -> ${conn.deviceId.substring(0, math.min(8, conn.deviceId.length))}...");
        }
      } catch (e) {
        markConnectionFailure(conn.deviceId);
        try {
          locator<PeerCacheService>().recordFailure(
            peerId: conn.deviceId,
            channel: conn.channelType.name,
            reason: e.toString(),
          );
        } catch (_) {}
        // 📊 FORENSIC LOG: relay_error
        _log("❌ [RELAY] relay_error: $packetId -> ${conn.deviceId.substring(0, math.min(8, conn.deviceId.length))}...: $e");
      }
    }
    
    _totalRepeatedPackets++;
    // 📊 FORENSIC LOG: relay_complete
    _log("📊 [RELAY] relay_complete: $packetId (sent: $successCount, skipped: $skippedCount, total: ${_activeConnections.length})");
    
    return successCount;
  }
  
  /// Отправляет пакет на конкретное устройство
  Future<bool> _sendToDevice(ActiveConnection conn, Map<String, dynamic> packet) async {
    final payload = jsonEncode(packet);
    
    switch (conn.channelType) {
      case ChannelType.tcp:
        if (conn.ipAddress != null) {
          try {
            await NativeMeshService.sendTcp(
              payload,
              host: conn.ipAddress!,
              port: conn.port,
            );
            return true;
          } catch (e) {
            _log("⚠️ [SEND] TCP failed to ${conn.deviceId}: $e");
            return false;
          }
        }
        return false;
        
      case ChannelType.wifiDirect:
        try {
          await NativeMeshService.sendTcp(
            payload,
            host: conn.ipAddress ?? "192.168.49.1",
          );
          return true;
        } catch (e) {
          _log("⚠️ [SEND] Wi-Fi Direct failed to ${conn.deviceId}: $e");
          return false;
        }
        
      case ChannelType.bleGatt:
        // BLE GATT отправка через BluetoothMeshService
        try {
          final bt = locator<BluetoothMeshService>();
          // Используем существующий механизм GATT
          _log("📡 [SEND] BLE GATT to ${conn.deviceId}");
          // TODO: Интеграция с существующим BLE GATT механизмом
          return true;
        } catch (e) {
          _log("⚠️ [SEND] BLE GATT failed to ${conn.deviceId}: $e");
          return false;
        }
        
      case ChannelType.sonar:
        // Sonar только для коротких сообщений
        if (payload.length < 64) {
          _log("📡 [SEND] Sonar to ${conn.deviceId}");
          // TODO: Интеграция с UltrasonicService
          return true;
        }
        return false;
    }
  }
  
  // ============================================================================
  // REPAIR ЛОГИКА (ВОССТАНОВЛЕНИЕ СОЕДИНЕНИЙ)
  // ============================================================================
  
  /// Запускает цикл восстановления соединений
  void _startRepairCycle() {
    _repairTimer?.cancel();
    _repairTimer = Timer.periodic(
      Duration(seconds: REPAIR_INTERVAL_SECONDS),
      (_) => _runRepairCycle(),
    );
  }
  
  /// Выполняет цикл восстановления
  Future<void> _runRepairCycle() async {
    if (!_isRunning) return;
    
    final failedConnections = _activeConnections.values
        .where((c) => c.needsRepair)
        .toList();
    
    if (failedConnections.isEmpty) return;
    
    _log("🔧 [REPAIR] Starting recovery of ${failedConnections.length} connection(s)...");
    
    for (final conn in failedConnections) {
      await _repairConnection(conn);
    }
  }
  
  /// Восстанавливает конкретное соединение
  Future<bool> _repairConnection(ActiveConnection conn) async {
    _log("🔧 [REPAIR] Восстановление соединения с ${conn.deviceId}...");
    conn.state = ConnectionState.reparing;
    
    // Определяем порядок fallback каналов
    final fallbackOrder = _getFallbackOrder(conn.channelType);
    
    for (final channel in fallbackOrder) {
      _log("   🔄 Попытка через ${channel.name}...");
      
      final success = await _attemptChannelConnection(conn.deviceId, channel);
      
      if (success) {
        conn.channelType = channel;
        conn.state = ConnectionState.connected;
        conn.failureCount = 0;
        conn.lastActivity = DateTime.now();
        
        _totalRepairedConnections++;
        _log("✅ [REPAIR] Восстановлено через ${channel.name}");
        
        // Повышаем trust score за успешное восстановление
        updateTrustScore(conn.deviceId, 3);
        
        notifyListeners();
        return true;
      }
    }
    
    // Не удалось восстановить
    _log("❌ [REPAIR] Не удалось восстановить соединение с ${conn.deviceId}");
    _closeConnection(conn.deviceId, reason: "Не удалось восстановить");
    
    // Понижаем trust score
    updateTrustScore(conn.deviceId, -15);
    
    return false;
  }
  
  /// Определяет порядок fallback каналов
  List<ChannelType> _getFallbackOrder(ChannelType currentChannel) {
    // Приоритет: Wi-Fi Direct -> BLE GATT -> TCP -> Sonar
    final allChannels = [
      ChannelType.wifiDirect,
      ChannelType.bleGatt,
      ChannelType.tcp,
      ChannelType.sonar,
    ];
    
    // Убираем текущий канал и ставим его в конец
    allChannels.remove(currentChannel);
    allChannels.add(currentChannel);
    
    return allChannels;
  }
  
  /// Пытается установить соединение через указанный канал
  Future<bool> _attemptChannelConnection(String deviceId, ChannelType channel) async {
    try {
      switch (channel) {
        case ChannelType.wifiDirect:
          // Проверяем Wi-Fi Direct группу
          final groupInfo = await NativeMeshService.getWifiDirectGroupInfo();
          return groupInfo != null;
          
        case ChannelType.bleGatt:
          // BLE GATT всегда доступен если Bluetooth включен
          final btState = await FlutterBluePlus.adapterState.first;
          return btState == BluetoothAdapterState.on;
          
        case ChannelType.tcp:
          // TCP доступен если есть сеть
          final role = NetworkMonitor().currentRole;
          return role == MeshRole.BRIDGE || locator<MeshService>().isP2pConnected;
          
        case ChannelType.sonar:
          // Sonar всегда доступен (ограниченно)
          return true;
      }
    } catch (e) {
      _log("⚠️ [REPAIR] Ошибка проверки канала ${channel.name}: $e");
      return false;
    }
  }
  
  // ============================================================================
  // HEALTH CHECK
  // ============================================================================
  
  /// Запускает проверку здоровья соединений
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(
      Duration(seconds: HEALTH_CHECK_INTERVAL_SECONDS),
      (_) => _runHealthCheck(),
    );
  }
  
  /// Выполняет проверку здоровья
  void _runHealthCheck() {
    if (!_isRunning) return;
    
    final now = DateTime.now();
    final staleConnections = <String>[];
    
    for (final entry in _activeConnections.entries) {
      final conn = entry.value;
      
      // Проверяем неактивность (более 2 минут)
      if (conn.inactivityTime != null && conn.inactivityTime!.inMinutes > 2) {
        _log("⚠️ [HEALTH] Соединение ${conn.deviceId} неактивно ${conn.inactivityTime!.inMinutes} мин");
        conn.failureCount++;
      }
      
      // Проверяем возраст соединения (более 30 минут - пересоздаем)
      if (conn.connectionAge.inMinutes > 30) {
        _log("⚠️ [HEALTH] Соединение ${conn.deviceId} устарело (${conn.connectionAge.inMinutes} мин)");
        staleConnections.add(entry.key);
      }
    }
    
    // Закрываем устаревшие соединения для пересоздания
    for (final deviceId in staleConnections) {
      _closeConnection(deviceId, reason: "Устаревшее соединение");
    }
  }
  
  // ============================================================================
  // ОБРАБОТКА ОЧЕРЕДИ
  // ============================================================================
  
  /// Запускает обработчик очереди
  void _startQueueProcessor() {
    _queueProcessorTimer?.cancel();
    _queueProcessorTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _processQueue(),
    );
  }
  
  /// Обрабатывает очередь подключений
  Future<void> _processQueue() async {
    if (!_isRunning || _isProcessingQueue) return;
    if (_connectionQueue.toList().isEmpty) return;
    if (_activeConnections.length >= MAX_CONCURRENT_CONNECTIONS) return;
    
    _isProcessingQueue = true;
    
    try {
      // Удаляем истекшие запросы
      final queueList = _connectionQueue.toList();
      for (final item in queueList) {
        if (item.isExpired && !item.completer.isCompleted) {
          item.completer.complete(false);
        }
      }
      
      // Берем следующий запрос
      if (_connectionQueue.toList().isEmpty) return;
      
      final item = _connectionQueue.removeFirst();
      
      if (item.completer.isCompleted || item.isExpired) return;
      
      _log("⚙️ [QUEUE] Обработка запроса к ${item.deviceId}...");
      
      // Пытаемся подключиться
      final success = await _attemptChannelConnection(item.deviceId, item.preferredChannel);
      
      if (success) {
        registerConnection(
          deviceId: item.deviceId,
          deviceToken: item.deviceToken,
          channelType: item.preferredChannel,
        );
        item.completer.complete(true);
      } else {
        // Retry логика
        if (item.retryCount < MAX_RETRY_COUNT) {
          item.retryCount++;
          _connectionQueue.add(item);
          _log("🔄 [QUEUE] Retry ${item.retryCount}/$MAX_RETRY_COUNT для ${item.deviceId}");
        } else {
          item.completer.complete(false);
          _log("❌ [QUEUE] Исчерпаны попытки для ${item.deviceId}");
        }
      }
    } finally {
      _isProcessingQueue = false;
    }
  }
  
  // ============================================================================
  // БЕЗОПАСНОСТЬ
  // ============================================================================
  
  /// Валидирует токен устройства
  bool _validateToken(String token) {
    // Минимальная длина токена
    if (token.length < 8) return false;
    
    // Токен должен содержать только допустимые символы
    final validChars = RegExp(r'^[a-zA-Z0-9_-]+$');
    if (!validChars.hasMatch(token)) return false;
    
    // Проверка на известные плохие токены
    final blacklist = ['test', 'debug', 'admin', '12345678'];
    if (blacklist.contains(token.toLowerCase())) return false;
    
    return true;
  }
  
  /// Генерирует хеш для проверки целостности пакета
  String generatePacketHash(Map<String, dynamic> packet) {
    final content = jsonEncode(packet);
    final bytes = utf8.encode(content);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }
  
  /// Проверяет целостность пакета
  bool verifyPacketIntegrity(Map<String, dynamic> packet, String expectedHash) {
    final actualHash = generatePacketHash(packet);
    return actualHash == expectedHash;
  }
  
  // ============================================================================
  // ЛОГИРОВАНИЕ
  // ============================================================================
  
  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final logEntry = "[$timestamp] $message";
    
    _logs.add(logEntry);
    if (_logs.length > MAX_LOGS) {
      _logs.removeAt(0);
    }
    
    print("🔄 [Repeater] $message");
  }
  
  /// Очищает логи
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
  
  // ============================================================================
  // ИНТЕГРАЦИЯ С MESH
  // ============================================================================
  
  /// Вызывается из MeshService при получении пакета
  /// 🔥 MESH: Обрабатывает входящий пакет и решает о ретрансляции
  Future<void> onPacketReceived(Map<String, dynamic> packet, String fromDeviceId) async {
    if (!_isRunning) return;
    
    final String packetId = packet['h'] ?? packet['mid'] ?? packet['id'] ?? 'unknown';
    final String packetType = packet['type'] ?? 'UNKNOWN';
    
    // 📊 FORENSIC LOG: packet_received_for_relay
    _log("📥 [MESH] packet_received: ${packetId.substring(0, math.min(8, packetId.length))}... type=$packetType from=${fromDeviceId.substring(0, math.min(8, fromDeviceId.length))}...");
    
    // Обновляем активность соединения
    updateConnectionActivity(fromDeviceId);
    
    // Проверяем, нужно ли ретранслировать
    final List<String> relayableTypes = [
      'OFFLINE_MSG',
      'SOS',
      'MAGNET_WAVE',
      'MSG_FRAG',
      'DELIVERED_TO_CLOUD',
    ];
    
    final bool shouldRepeat = relayableTypes.contains(packetType);
    
    if (shouldRepeat) {
      _log("📤 [MESH] Initiating relay for $packetType packet...");
      await repeatPacket(packet, excludeDeviceId: fromDeviceId);
    } else {
      _log("⏭️ [MESH] Skipping relay for type: $packetType (not in relay list)");
    }
  }
  
  /// Вызывается при обнаружении нового устройства
  void onDeviceDiscovered(String deviceId, String? token, ChannelType channel) {
    if (!_isRunning) return;
    
    // Добавляем в доверенные если токен валиден
    if (token != null && _validateToken(token)) {
      addTrustedDevice(deviceId, token);
    }
    
    _log("👁️ [DISCOVERY] Обнаружено устройство: $deviceId via ${channel.name}");
  }
  
  /// Вызывается при отключении устройства
  void onDeviceDisconnected(String deviceId) {
    markConnectionFailure(deviceId);
    _log("🔌 [DISCONNECT] Устройство отключилось: $deviceId");
  }
}

/// Приоритетная очередь
class PriorityQueue<E> {
  final List<E> _items = [];
  final Comparator<E> _comparator;
  
  PriorityQueue(this._comparator);
  
  void add(E item) {
    _items.add(item);
    _items.sort(_comparator);
  }
  
  E removeFirst() => _items.removeAt(0);
  
  List<E> toList() => List.unmodifiable(_items);
}
