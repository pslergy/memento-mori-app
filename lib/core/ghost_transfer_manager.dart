import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'locator.dart';
import 'mesh_service.dart';
import 'bluetooth_service.dart';
import 'native_mesh_service.dart';
import 'ultrasonic_service.dart';
import 'local_db_service.dart';
import 'api_service.dart';
import 'peer_cache_service.dart';

/// ============================================================================
/// 🔥 GHOST TRANSFER MANAGER - ОПТИМИЗИРОВАННАЯ АРХИТЕКТУРА
/// ============================================================================
/// 
/// ПРОБЛЕМЫ СТАРОЙ АРХИТЕКТУРЫ:
/// 1. Глобальный _isTransferring блокирует ВСЕ каналы
/// 2. Cooldown на MAC блокирует повторные попытки к тому же BRIDGE
/// 3. Один зависший transfer = вся очередь стоит
/// 4. Нет приоритизации BRIDGE по качеству связи
/// 5. Последовательная эскалация каналов вместо параллельной
/// 
/// РЕШЕНИЕ:
/// 1. Per-Channel transfer флаги (BLE, Wi-Fi, TCP, Sonar)
/// 2. Per-BRIDGE очереди сообщений
/// 3. Параллельная работа разных каналов
/// 4. Умный выбор BRIDGE (токен, latency, success rate)
/// 5. Быстрый fallback без полного cooldown

/// Состояние канала
enum ChannelStatus {
  idle,
  connecting,
  transferring,
  cooldown,
  failed,
}

/// Тип транспортного канала
enum TransportChannel {
  wifiDirect,
  bleGatt,
  tcp,
  sonar,
}

/// Информация о канале
class ChannelState {
  TransportChannel channel;
  ChannelStatus status;
  DateTime? lastActivity;
  DateTime? cooldownUntil;
  int consecutiveFailures;
  int successCount;
  Duration avgLatency;
  
  ChannelState({
    required this.channel,
    this.status = ChannelStatus.idle,
    this.lastActivity,
    this.cooldownUntil,
    this.consecutiveFailures = 0,
    this.successCount = 0,
    this.avgLatency = const Duration(seconds: 5),
  });
  
  bool get isAvailable {
    if (status == ChannelStatus.idle) return true;
    if (status == ChannelStatus.cooldown && cooldownUntil != null) {
      return DateTime.now().isAfter(cooldownUntil!);
    }
    return false;
  }
  
  double get successRate {
    final total = successCount + consecutiveFailures;
    if (total == 0) return 0.5; // Неизвестно - средний приоритет
    return successCount / total;
  }
  
  void markBusy() {
    status = ChannelStatus.transferring;
    lastActivity = DateTime.now();
  }
  
  void markSuccess(Duration latency) {
    status = ChannelStatus.idle;
    lastActivity = DateTime.now();
    consecutiveFailures = 0;
    successCount++;
    // Обновляем среднюю latency
    avgLatency = Duration(milliseconds: 
      ((avgLatency.inMilliseconds * 0.7) + (latency.inMilliseconds * 0.3)).round()
    );
  }
  
  void markFailed({Duration cooldownDuration = const Duration(seconds: 5)}) {
    consecutiveFailures++;
    lastActivity = DateTime.now();
    
    // Адаптивный cooldown: больше неудач = дольше cooldown
    final adaptiveCooldown = Duration(
      seconds: (cooldownDuration.inSeconds * (1 + consecutiveFailures * 0.5)).round().clamp(2, 30)
    );
    cooldownUntil = DateTime.now().add(adaptiveCooldown);
    status = ChannelStatus.cooldown;
  }
  
  void reset() {
    status = ChannelStatus.idle;
    cooldownUntil = null;
  }
}

/// Информация о BRIDGE
class BridgeInfo {
  final String mac;
  String? token;
  String? ip;
  int? port;
  int hops;
  DateTime lastSeen;
  ScanResult? scanResult;
  
  // Состояние каналов для этого BRIDGE
  final Map<TransportChannel, ChannelState> channels = {};
  
  // Очередь сообщений для этого BRIDGE
  final Queue<PendingMessage> messageQueue = Queue();
  
  // Статистика
  int totalAttempts = 0;
  int totalSuccesses = 0;
  
  BridgeInfo({
    required this.mac,
    this.token,
    this.ip,
    this.port,
    this.hops = 0,
    required this.lastSeen,
    this.scanResult,
  }) {
    // Инициализируем каналы
    for (final channel in TransportChannel.values) {
      channels[channel] = ChannelState(channel: channel);
    }
  }
  
  double get priority {
    // 🔥 УЛУЧШЕННЫЙ SCORING: Используем peer cache если доступен
    final peerCache = PeerCacheService();
    final cachedScore = peerCache.calculateBridgeScore(
      peerId: mac,
      hasInternet: true, // BRIDGE всегда имеет интернет
      hops: hops,
    );
    
    // 🔥 PER-CHANNEL STATS: Используем метрики по каналам если доступны
    final metrics = peerCache.getPeer(mac);
    double? perChannelBonus = null;
    
    if (metrics != null && metrics.channelStats.isNotEmpty) {
      // Находим лучший канал по успешности
      final bestChannel = metrics.bestChannel;
      if (bestChannel != null) {
        final channelStats = metrics.channelStats[bestChannel]!;
        // Бонус за хорошую успешность на конкретном канале
        perChannelBonus = channelStats.successRate * 10.0; // До 10 баллов
      }
    }
    
    // Если есть кешированные метрики - используем их
    if (cachedScore != null) {
      // Комбинируем с текущими метриками (70% cache, 30% текущие)
      final currentScore = _calculateCurrentPriority();
      var combinedScore = (cachedScore * 0.7) + (currentScore * 0.3);
      
      // Добавляем per-channel bonus если доступен
      if (perChannelBonus != null) {
        combinedScore += perChannelBonus;
      }
      
      return combinedScore;
    }
    
    // Fallback к текущему поведению (с per-channel bonus если доступен)
    final baseScore = _calculateCurrentPriority();
    if (perChannelBonus != null) {
      return baseScore + perChannelBonus;
    }
    
    return baseScore;
  }
  
  /// Текущий расчет приоритета (оригинальная логика)
  double _calculateCurrentPriority() {
    // Приоритет = (наличие токена * 100) + (1 / hops) * 50 + successRate * 30 - avgLatency/1000
    double score = 0;
    if (token != null && token!.isNotEmpty) score += 100;
    if (hops == 0) score += 50;
    score += (totalSuccesses / (totalAttempts + 1)) * 30;
    
    // Учитываем latency лучшего канала
    final bestChannel = getBestAvailableChannel();
    if (bestChannel != null) {
      score -= channels[bestChannel]!.avgLatency.inMilliseconds / 1000;
    }
    
    return score;
  }
  
  /// Получает лучший доступный канал
  TransportChannel? getBestAvailableChannel() {
    // Приоритет: Wi-Fi Direct > BLE GATT > TCP > Sonar
    final priority = [
      TransportChannel.wifiDirect,
      TransportChannel.bleGatt,
      TransportChannel.tcp,
      TransportChannel.sonar,
    ];
    
    for (final channel in priority) {
      if (channels[channel]!.isAvailable) {
        return channel;
      }
    }
    return null;
  }
  
  /// Получает все доступные каналы (для параллельной работы)
  List<TransportChannel> getAvailableChannels() {
    return channels.entries
        .where((e) => e.value.isAvailable)
        .map((e) => e.key)
        .toList();
  }
  
  bool get hasAvailableChannel => getBestAvailableChannel() != null;
  
  bool get isStale => DateTime.now().difference(lastSeen).inMinutes > 5;
}

/// Сообщение в очереди
class PendingMessage {
  final String id;
  final String content;
  final String chatId;
  final String senderId;
  final DateTime createdAt;
  final int priority; // 0 = высший
  int attempts;
  String? lastFailReason;
  
  PendingMessage({
    required this.id,
    required this.content,
    required this.chatId,
    required this.senderId,
    required this.createdAt,
    this.priority = 5,
    this.attempts = 0,
    this.lastFailReason,
  });
  
  Map<String, dynamic> toPacket({int? ttl, bool isFinalRecipient = false}) => {
    'type': 'OFFLINE_MSG',
    'content': content,
    'chatId': chatId,
    'senderId': senderId,
    'h': id,
    'ttl': ttl ?? 5, // 🔥 TTL: Опциональное поле, по умолчанию 5
    'isFinalRecipient': isFinalRecipient, // 🔥 TTL: Флаг конечного получателя (не уменьшаем TTL)
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  };
  
  bool get isExpired => DateTime.now().difference(createdAt).inHours > 24;
  bool get maxAttemptsReached => attempts >= 10;
}

/// 🔥 ГЛАВНЫЙ МЕНЕДЖЕР ПЕРЕДАЧИ
class GhostTransferManager with ChangeNotifier {
  static final GhostTransferManager _instance = GhostTransferManager._internal();
  factory GhostTransferManager() => _instance;
  GhostTransferManager._internal();
  
  // ============================================================================
  // КОНФИГУРАЦИЯ
  // ============================================================================
  
  static const int MAX_PARALLEL_TRANSFERS = 3;
  static const int MAX_QUEUE_PER_BRIDGE = 20;
  static const Duration CHANNEL_TIMEOUT_BLE = Duration(seconds: 12);
  static const Duration CHANNEL_TIMEOUT_WIFI = Duration(seconds: 5);
  static const Duration CHANNEL_TIMEOUT_TCP = Duration(seconds: 8);
  static const Duration CHANNEL_TIMEOUT_SONAR = Duration(seconds: 3);
  static const Duration MIN_COOLDOWN = Duration(seconds: 2);
  static const Duration MAX_COOLDOWN = Duration(seconds: 30);
  
  // ============================================================================
  // СОСТОЯНИЕ
  // ============================================================================
  
  // Известные BRIDGE
  final Map<String, BridgeInfo> _bridges = {};
  
  // Глобальная очередь сообщений (fallback)
  final Queue<PendingMessage> _globalQueue = Queue();
  
  // Активные трансферы по каналам
  final Map<TransportChannel, Set<String>> _activeTransfers = {
    TransportChannel.wifiDirect: {},
    TransportChannel.bleGatt: {},
    TransportChannel.tcp: {},
    TransportChannel.sonar: {},
  };
  
  // Таймеры
  Timer? _processTimer;
  Timer? _cleanupTimer;
  
  // Флаги
  bool _isRunning = false;
  bool _isPaused = false;
  
  // 🔥 STABILIZATION: Hysteresis для выбора BRIDGE
  String? _currentBridgeMac; // Текущий выбранный BRIDGE
  DateTime? _currentBridgeSelectedAt; // Когда был выбран
  static const Duration MIN_BRIDGE_STICKINESS = Duration(seconds: 45); // Минимальное время привязки
  static const double BRIDGE_SWITCH_THRESHOLD = 15.0; // ε-порог для переключения (score delta)
  
  // Логи
  final List<String> _logs = [];
  static const int MAX_LOGS = 200;
  
  // ============================================================================
  // ПУБЛИЧНЫЕ ГЕТТЕРЫ
  // ============================================================================
  
  bool get isRunning => _isRunning;
  int get bridgeCount => _bridges.length;
  int get activeBridgeCount => _bridges.values.where((b) => b.hasAvailableChannel && !b.isStale).length;
  int get globalQueueSize => _globalQueue.length;
  List<String> get logs => List.unmodifiable(_logs);
  
  int get totalActiveTransfers {
    int count = 0;
    for (final set in _activeTransfers.values) {
      count += set.length;
    }
    return count;
  }
  
  Map<String, dynamic> get statistics => {
    'bridges': bridgeCount,
    'activeBridges': activeBridgeCount,
    'globalQueue': globalQueueSize,
    'activeTransfers': {
      'wifiDirect': _activeTransfers[TransportChannel.wifiDirect]!.length,
      'bleGatt': _activeTransfers[TransportChannel.bleGatt]!.length,
      'tcp': _activeTransfers[TransportChannel.tcp]!.length,
      'sonar': _activeTransfers[TransportChannel.sonar]!.length,
    },
    'isRunning': _isRunning,
  };
  
  // ============================================================================
  // ЖИЗНЕННЫЙ ЦИКЛ
  // ============================================================================
  
  void start() {
    if (_isRunning) return;
    
    _isRunning = true;
    _log("🚀 [TRANSFER-MGR] Запуск Ghost Transfer Manager");
    
    // Процессор очереди - каждые 500ms
    _processTimer?.cancel();
    _processTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _processQueues());
    
    // Очистка - каждую минуту
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) => _cleanup());
    
    notifyListeners();
  }
  
  void stop() {
    if (!_isRunning) return;
    
    _log("🛑 [TRANSFER-MGR] Остановка Ghost Transfer Manager");
    
    _isRunning = false;
    _processTimer?.cancel();
    _cleanupTimer?.cancel();
    
    notifyListeners();
  }
  
  void pause() {
    _isPaused = true;
    _log("⏸️ [TRANSFER-MGR] Пауза");
  }
  
  void resume() {
    _isPaused = false;
    _log("▶️ [TRANSFER-MGR] Возобновление");
  }
  
  // ============================================================================
  // УПРАВЛЕНИЕ BRIDGE
  // ============================================================================
  
  /// Регистрирует или обновляет BRIDGE
  void registerBridge({
    required String mac,
    String? token,
    String? ip,
    int? port,
    int hops = 0,
    ScanResult? scanResult,
  }) {
    final existing = _bridges[mac];
    
    if (existing != null) {
      // Обновляем существующий
      existing.lastSeen = DateTime.now();
      if (token != null) existing.token = token;
      if (ip != null) existing.ip = ip;
      if (port != null) existing.port = port;
      existing.hops = hops;
      if (scanResult != null) existing.scanResult = scanResult;
      
      _log("📡 [BRIDGE] Обновлен: ${mac.substring(mac.length - 8)} (token: ${token != null ? 'yes' : 'no'})");
    } else {
      // Добавляем новый
      _bridges[mac] = BridgeInfo(
        mac: mac,
        token: token,
        ip: ip,
        port: port,
        hops: hops,
        lastSeen: DateTime.now(),
        scanResult: scanResult,
      );
      
      _log("✅ [BRIDGE] Добавлен: ${mac.substring(mac.length - 8)} (token: ${token != null ? 'yes' : 'no'}, hops: $hops)");
    }
    
    notifyListeners();
  }
  
  /// Удаляет BRIDGE
  void removeBridge(String mac) {
    final removed = _bridges.remove(mac);
    if (removed != null) {
      _log("🗑️ [BRIDGE] Удален: ${mac.substring(mac.length - 8)}");
      
      // 🔥 STABILIZATION: Сбрасываем текущий BRIDGE если он был удален
      if (_currentBridgeMac == mac) {
        _currentBridgeMac = null;
        _currentBridgeSelectedAt = null;
        _log("🔄 [STABILIZATION] Current BRIDGE removed, will select new one on next getBestBridge()");
      }
      
      notifyListeners();
    }
  }
  
  /// Получает лучший BRIDGE для отправки
  /// 🔥 STABILIZATION: Добавлен hysteresis для предотвращения осцилляций
  BridgeInfo? getBestBridge() {
    final available = _bridges.values
        .where((b) => b.hasAvailableChannel && !b.isStale)
        .toList();
    
    if (available.isEmpty) return null;
    
    // Сортируем по приоритету (токен, hops, success rate)
    available.sort((a, b) => b.priority.compareTo(a.priority));
    
    final bestCandidate = available.first;
    
    // 🔥 STABILIZATION: Hysteresis - проверяем, нужно ли переключаться
    if (_currentBridgeMac != null) {
      final currentBridge = _bridges[_currentBridgeMac];
      
      // Если текущий BRIDGE всё ещё доступен и "достаточно хорош"
      if (currentBridge != null && 
          currentBridge.hasAvailableChannel && 
          !currentBridge.isStale) {
        
        final timeSinceSelection = _currentBridgeSelectedAt != null
            ? DateTime.now().difference(_currentBridgeSelectedAt!)
            : Duration.zero;
        
        // Проверка 1: Минимальное время привязки (stickiness)
        if (timeSinceSelection < MIN_BRIDGE_STICKINESS) {
          _log("📌 [STABILIZATION] Keeping current BRIDGE ${_currentBridgeMac!.substring(_currentBridgeMac!.length - 8)} (stickiness: ${timeSinceSelection.inSeconds}s < ${MIN_BRIDGE_STICKINESS.inSeconds}s)");
          return currentBridge; // Не переключаемся, если не прошло минимальное время
        }
        
        // Проверка 2: ε-порог (delta threshold)
        final currentScore = currentBridge.priority;
        final candidateScore = bestCandidate.priority;
        final scoreDelta = candidateScore - currentScore;
        
        if (scoreDelta < BRIDGE_SWITCH_THRESHOLD) {
          _log("📌 [STABILIZATION] Keeping current BRIDGE ${_currentBridgeMac!.substring(_currentBridgeMac!.length - 8)} (score delta: ${scoreDelta.toStringAsFixed(2)} < $BRIDGE_SWITCH_THRESHOLD)");
          return currentBridge; // Не переключаемся, если преимущество недостаточно
        }
        
        // Переключаемся только при явном преимуществе
        _log("🔄 [STABILIZATION] Switching BRIDGE: ${_currentBridgeMac!.substring(_currentBridgeMac!.length - 8)} → ${bestCandidate.mac.substring(bestCandidate.mac.length - 8)} (score delta: ${scoreDelta.toStringAsFixed(2)})");
      }
    }
    
    // Обновляем текущий BRIDGE
    _currentBridgeMac = bestCandidate.mac;
    _currentBridgeSelectedAt = DateTime.now();
    
    return bestCandidate;
  }
  
  /// Получает все доступные BRIDGE отсортированные по приоритету
  List<BridgeInfo> getAvailableBridges() {
    final available = _bridges.values
        .where((b) => b.hasAvailableChannel && !b.isStale)
        .toList();
    
    available.sort((a, b) => b.priority.compareTo(a.priority));
    
    return available;
  }
  
  // ============================================================================
  // УПРАВЛЕНИЕ ОЧЕРЕДЬЮ СООБЩЕНИЙ
  // ============================================================================
  
  /// Добавляет сообщение в очередь
  Future<void> enqueueMessage({
    required String id,
    required String content,
    required String chatId,
    required String senderId,
    int priority = 5,
  }) async {
    final message = PendingMessage(
      id: id,
      content: content,
      chatId: chatId,
      senderId: senderId,
      createdAt: DateTime.now(),
      priority: priority,
    );
    
    // Пытаемся добавить в очередь лучшего BRIDGE
    final bestBridge = getBestBridge();
    
    if (bestBridge != null && bestBridge.messageQueue.length < MAX_QUEUE_PER_BRIDGE) {
      bestBridge.messageQueue.add(message);
      _log("📥 [QUEUE] Сообщение $id → BRIDGE ${bestBridge.mac.substring(bestBridge.mac.length - 8)}");
    } else {
      // Fallback на глобальную очередь
      _globalQueue.add(message);
      _log("📥 [QUEUE] Сообщение $id → глобальная очередь");
    }
    
    notifyListeners();
  }
  
  /// Загружает сообщения из outbox в очереди
  Future<void> loadFromOutbox() async {
    try {
      final db = locator<LocalDatabaseService>();
      final pending = await db.getPendingFromOutbox();
      
      for (final msgData in pending) {
        final id = msgData['id'] as String?;
        if (id == null) continue;
        
        // Проверяем, не в очереди ли уже
        final alreadyQueued = _globalQueue.any((m) => m.id == id) ||
            _bridges.values.any((b) => b.messageQueue.any((m) => m.id == id));
        
        if (!alreadyQueued) {
          await enqueueMessage(
            id: id,
            content: msgData['content'] as String? ?? '',
            chatId: msgData['chatRoomId'] as String? ?? '',
            senderId: locator<ApiService>().currentUserId,
          );
        }
      }
    } catch (e) {
      _log("❌ [QUEUE] Ошибка загрузки из outbox: $e");
    }
  }
  
  // ============================================================================
  // ОБРАБОТКА ОЧЕРЕДЕЙ
  // ============================================================================
  
  /// Главный цикл обработки
  Future<void> _processQueues() async {
    if (!_isRunning || _isPaused) return;
    if (totalActiveTransfers >= MAX_PARALLEL_TRANSFERS) return;
    
    // 1. Обрабатываем очереди BRIDGE по приоритету
    final bridges = getAvailableBridges();
    
    for (final bridge in bridges) {
      if (totalActiveTransfers >= MAX_PARALLEL_TRANSFERS) break;
      if (bridge.messageQueue.isEmpty) continue;
      
      final channel = bridge.getBestAvailableChannel();
      if (channel == null) continue;
      
      // Проверяем, не занят ли канал для этого BRIDGE
      if (_activeTransfers[channel]!.contains(bridge.mac)) continue;
      
      // Берем сообщение из очереди
      final message = bridge.messageQueue.first;
      
      // Запускаем передачу асинхронно
      unawaited(_executeTransfer(bridge, message, channel));
    }
    
    // 2. Обрабатываем глобальную очередь
    if (_globalQueue.isNotEmpty && totalActiveTransfers < MAX_PARALLEL_TRANSFERS) {
      final bestBridge = getBestBridge();
      
      if (bestBridge != null) {
        final channel = bestBridge.getBestAvailableChannel();
        
        if (channel != null && !_activeTransfers[channel]!.contains(bestBridge.mac)) {
          final message = _globalQueue.first;
          
          // Перемещаем в очередь BRIDGE
          bestBridge.messageQueue.add(message);
          _globalQueue.removeFirst();
          
          unawaited(_executeTransfer(bestBridge, message, channel));
        }
      }
    }
  }
  
  /// Выполняет передачу сообщения
  Future<void> _executeTransfer(
    BridgeInfo bridge,
    PendingMessage message,
    TransportChannel channel,
  ) async {
    final mac = bridge.mac;
    final msgId = message.id;
    final startTime = DateTime.now();
    
    // Отмечаем канал как занятый
    _activeTransfers[channel]!.add(mac);
    bridge.channels[channel]!.markBusy();
    bridge.totalAttempts++;
    message.attempts++;
    
    _log("📤 [TRANSFER] Начало: $msgId → ${mac.substring(mac.length - 8)} via ${channel.name}");
    
    try {
      bool success = false;
      
      switch (channel) {
        case TransportChannel.wifiDirect:
          success = await _sendViaWifiDirect(bridge, message);
          break;
        case TransportChannel.bleGatt:
          success = await _sendViaBleGatt(bridge, message);
          break;
        case TransportChannel.tcp:
          success = await _sendViaTcp(bridge, message);
          break;
        case TransportChannel.sonar:
          success = await _sendViaSonar(bridge, message);
          break;
      }
      
      final latency = DateTime.now().difference(startTime);
      
      if (success) {
        _onTransferSuccess(bridge, message, channel, latency);
      } else {
        _onTransferFailed(bridge, message, channel, "Передача неуспешна");
      }
      
    } catch (e) {
      _onTransferFailed(bridge, message, channel, e.toString());
    } finally {
      // Освобождаем канал
      _activeTransfers[channel]!.remove(mac);
    }
  }
  
  /// Обработка успешной передачи
  void _onTransferSuccess(
    BridgeInfo bridge,
    PendingMessage message,
    TransportChannel channel,
    Duration latency,
  ) {
    final mac = bridge.mac;
    final msgId = message.id;
    
    bridge.channels[channel]!.markSuccess(latency);
    bridge.totalSuccesses++;
    
    // 🔥 PEER CACHE: Записываем успешную передачу
    PeerCacheService().recordSuccess(
      peerId: mac,
      latency: latency,
      channel: channel.name,
    );
    
    // Удаляем из очереди
    bridge.messageQueue.remove(message);
    
    // Удаляем из outbox
    unawaited(_removeFromOutbox(msgId));
    
    _log("✅ [TRANSFER] Успех: $msgId → ${mac.substring(mac.length - 8)} via ${channel.name} (${latency.inMilliseconds}ms)");
    
    notifyListeners();
  }
  
  /// Обработка неудачной передачи
  void _onTransferFailed(
    BridgeInfo bridge,
    PendingMessage message,
    TransportChannel channel,
    String reason,
  ) {
    final mac = bridge.mac;
    final msgId = message.id;
    
    message.lastFailReason = reason;
    
    // Адаптивный cooldown для канала
    bridge.channels[channel]!.markFailed();
    
    // 🔥 PEER CACHE: Записываем неудачную передачу
    PeerCacheService().recordFailure(
      peerId: mac,
      channel: channel.name,
      reason: reason,
    );
    
    _log("❌ [TRANSFER] Неудача: $msgId → ${mac.substring(mac.length - 8)} via ${channel.name}: $reason");
    
    // Пытаемся fallback на другой канал
    final nextChannel = _getNextFallbackChannel(bridge, channel);
    
    if (nextChannel != null && !message.maxAttemptsReached) {
      _log("🔄 [FALLBACK] Пробуем ${nextChannel.name} для $msgId");
      // Сообщение остается в очереди, следующий цикл попробует другой канал
    } else if (message.maxAttemptsReached) {
      _log("🚫 [TRANSFER] Исчерпаны попытки для $msgId");
      bridge.messageQueue.remove(message);
      // Можно переместить в глобальную очередь или пометить как failed
    }
    
    notifyListeners();
  }
  
  /// Получает следующий канал для fallback
  TransportChannel? _getNextFallbackChannel(BridgeInfo bridge, TransportChannel failedChannel) {
    // Порядок fallback: Wi-Fi → BLE → TCP → Sonar
    final priority = [
      TransportChannel.wifiDirect,
      TransportChannel.bleGatt,
      TransportChannel.tcp,
      TransportChannel.sonar,
    ];
    
    final failedIndex = priority.indexOf(failedChannel);
    
    // Ищем следующий доступный канал
    for (int i = failedIndex + 1; i < priority.length; i++) {
      if (bridge.channels[priority[i]]!.isAvailable) {
        return priority[i];
      }
    }
    
    return null;
  }
  
  // ============================================================================
  // МЕТОДЫ ПЕРЕДАЧИ
  // ============================================================================
  
  Future<bool> _sendViaWifiDirect(BridgeInfo bridge, PendingMessage message) async {
    try {
      final mesh = locator<MeshService>();
      
      if (!mesh.isP2pConnected) {
        _log("   📋 [WIFI-DIRECT] skip: isP2pConnected=false");
        return false;
      }
      
      // 🔥 Wi-Fi Direct Fix: единый порт MESH_PORT (55555)
      final hostAddress = mesh.lastKnownPeerIp.isNotEmpty 
          ? mesh.lastKnownPeerIp 
          : "192.168.49.1";
      final port = MeshService.meshTcpPort;
      _log("   📋 [WIFI-DIRECT] host=$hostAddress port=$port isRouteReady=${mesh.isRouteReady}");
      
      if (hostAddress == "192.168.49.1") {
        _log("⚠️ [WIFI-DIRECT] Using fallback IP, hostAddress may not be set");
      }
      
      final packet = message.toPacket();
      final ttl = packet['ttl'] as int?;
      final isFinalRecipient = packet['isFinalRecipient'] as bool? ?? false;
      
      if (ttl != null && ttl <= 0) {
        _log("⚠️ [WIFI-DIRECT] TTL expired (ttl=$ttl), dropping message");
        return false;
      }
      
      if (ttl != null && ttl > 0 && !isFinalRecipient) {
        packet['ttl'] = ttl - 1;
      } else if (isFinalRecipient) {
        _log("📥 [WIFI-DIRECT] Final recipient, TTL not decremented (ttl=$ttl)");
      }
      
      final payload = jsonEncode(packet);
      await NativeMeshService.sendTcp(payload, host: hostAddress, port: port);
      
      _log("✅ [WIFI-DIRECT] Sent to $hostAddress:$port");
      return true;
    } catch (e) {
      _log("⚠️ [WIFI-DIRECT] Ошибка: $e");
      return false;
    }
  }
  
  Future<bool> _sendViaBleGatt(BridgeInfo bridge, PendingMessage message) async {
    try {
      if (bridge.scanResult == null) {
        _log("⚠️ [BLE-GATT] Нет ScanResult для ${bridge.mac.substring(bridge.mac.length - 8)}");
        return false;
      }
      
      // 🔥 TTL: Проверяем и уменьшаем TTL перед отправкой (только если не конечный получатель)
      final packet = message.toPacket();
      final ttl = packet['ttl'] as int?;
      final isFinalRecipient = packet['isFinalRecipient'] as bool? ?? false;
      
      if (ttl != null && ttl <= 0) {
        _log("⚠️ [BLE-GATT] TTL expired (ttl=$ttl), dropping message");
        return false;
      }
      
      // Уменьшаем TTL только если это relay, не конечная доставка
      if (ttl != null && ttl > 0 && !isFinalRecipient) {
        packet['ttl'] = ttl - 1; // Уменьшаем TTL при relay
      } else if (isFinalRecipient) {
        _log("📥 [BLE-GATT] Final recipient, TTL not decremented (ttl=$ttl)");
      }
      
      final bt = locator<BluetoothMeshService>();
      final payload = jsonEncode(packet);
      
      final success = await bt.sendMessage(bridge.scanResult!.device, payload)
          .timeout(CHANNEL_TIMEOUT_BLE, onTimeout: () => false);
      
      return success;
    } catch (e) {
      _log("⚠️ [BLE-GATT] Ошибка: $e");
      return false;
    }
  }
  
  Future<bool> _sendViaTcp(BridgeInfo bridge, PendingMessage message) async {
    try {
      if (bridge.ip == null || bridge.port == null) {
        _log("⚠️ [TCP] Нет IP/порта для ${bridge.mac.substring(bridge.mac.length - 8)}");
        return false;
      }
      
      // 🔥 TTL: Проверяем и уменьшаем TTL перед отправкой (только если не конечный получатель)
      final packet = message.toPacket();
      final ttl = packet['ttl'] as int?;
      final isFinalRecipient = packet['isFinalRecipient'] as bool? ?? false;
      
      if (ttl != null && ttl <= 0) {
        _log("⚠️ [TCP] TTL expired (ttl=$ttl), dropping message");
        return false;
      }
      
      // Уменьшаем TTL только если это relay, не конечная доставка
      if (ttl != null && ttl > 0 && !isFinalRecipient) {
        packet['ttl'] = ttl - 1; // Уменьшаем TTL при relay
      } else if (isFinalRecipient) {
        _log("📥 [TCP] Final recipient, TTL not decremented (ttl=$ttl)");
      }
      
      final payload = jsonEncode(packet);
      await NativeMeshService.sendTcp(payload, host: bridge.ip!, port: bridge.port);
      
      return true;
    } catch (e) {
      _log("⚠️ [TCP] Ошибка: $e");
      return false;
    }
  }
  
  Future<bool> _sendViaSonar(BridgeInfo bridge, PendingMessage message) async {
    try {
      final sonar = locator<UltrasonicService>();
      
      // Sonar ограничен по размеру - отправляем только ID и хеш
      final shortPayload = "MSG:${message.id.hashCode}";
      await sonar.transmitFrame(shortPayload);
      
      // Sonar не гарантирует доставку, но это последний fallback
      return true;
    } catch (e) {
      _log("⚠️ [SONAR] Ошибка: $e");
      return false;
    }
  }
  
  Future<void> _removeFromOutbox(String messageId) async {
    try {
      final db = locator<LocalDatabaseService>();
      await db.removeFromOutbox(messageId);
    } catch (e) {
      _log("⚠️ [DB] Ошибка удаления из outbox: $e");
    }
  }
  
  // ============================================================================
  // ОЧИСТКА
  // ============================================================================
  
  void _cleanup() {
    // Удаляем устаревшие BRIDGE
    final staleMacs = _bridges.entries
        .where((e) => e.value.isStale)
        .map((e) => e.key)
        .toList();
    
    for (final mac in staleMacs) {
      final bridge = _bridges[mac]!;
      
      // Перемещаем сообщения в глобальную очередь
      while (bridge.messageQueue.isNotEmpty) {
        _globalQueue.add(bridge.messageQueue.removeFirst());
      }
      
      _bridges.remove(mac);
      _log("🧹 [CLEANUP] Удален устаревший BRIDGE: ${mac.substring(mac.length - 8)}");
    }
    
    // Удаляем истекшие сообщения из глобальной очереди
    _globalQueue.removeWhere((m) => m.isExpired || m.maxAttemptsReached);
    
    // Сбрасываем cooldowns каналов если они истекли
    for (final bridge in _bridges.values) {
      for (final channel in bridge.channels.values) {
        if (channel.status == ChannelStatus.cooldown && channel.isAvailable) {
          channel.reset();
        }
      }
    }
    
    notifyListeners();
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
    
    print("👻 [GhostTransfer] $message");
  }
  
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
  
  // ============================================================================
  // ИНТЕГРАЦИЯ С MESH SERVICE
  // ============================================================================
  
  /// Вызывается при обнаружении BRIDGE в BLE scan
  void onBridgeDiscovered(ScanResult scanResult, {String? token, int hops = 0}) {
    final mac = scanResult.device.remoteId.str;
    
    registerBridge(
      mac: mac,
      token: token,
      hops: hops,
      scanResult: scanResult,
    );
  }
  
  /// Вызывается при получении MAGNET_WAVE с TCP информацией
  void onMagnetWaveReceived({
    required String mac,
    required String token,
    required String ip,
    required int port,
  }) {
    registerBridge(
      mac: mac,
      token: token,
      ip: ip,
      port: port,
      hops: 0,
    );
  }
  
  /// Вызывается при установке Wi-Fi Direct соединения
  void onWifiDirectConnected(String hostAddress) {
    // Обновляем все BRIDGE с IP адресом хоста
    for (final bridge in _bridges.values) {
      if (bridge.ip == hostAddress || bridge.hops == 0) {
        bridge.channels[TransportChannel.wifiDirect]!.reset();
      }
    }
  }
  
  /// Вызывается при разрыве соединения
  void onDisconnected(String mac) {
    final bridge = _bridges[mac];
    if (bridge != null) {
      // Помечаем все каналы как failed с коротким cooldown
      for (final channel in bridge.channels.values) {
        channel.markFailed(cooldownDuration: MIN_COOLDOWN);
      }
    }
  }
}
