import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'fragment_security_service.dart';

import 'api_service.dart';
import 'ble_session.dart';
import 'bluetooth_service.dart';
import 'hardware_check_service.dart';
import 'mesh_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'native_mesh_service.dart';
import 'models/signal_node.dart';
import '../features/chat/conversation_screen.dart';
import 'network_monitor.dart';
import 'MeshOrchestrator.dart';
import 'repeater_service.dart';
import 'peer_cache_service.dart';

/// 🔒 SECURITY FIX: Rate limiter for flood protection
class RateLimiter {
  final int maxRequests;
  final Duration window;
  final Map<String, List<DateTime>> _requestHistory = {};

  // 🔒 Global rate limit across all senders
  int _globalRequestCount = 0;
  DateTime _globalWindowStart = DateTime.now();
  static const int _globalMaxRequests =
      500; // Max 500 packets per window globally

  RateLimiter({
    this.maxRequests = 30, // Max requests per sender per window
    this.window = const Duration(seconds: 60),
  });

  /// Check if request is allowed, returns true if allowed
  bool checkAndRecord(String senderId) {
    final now = DateTime.now();

    // 🔒 Check global rate limit first
    if (now.difference(_globalWindowStart) > window) {
      _globalWindowStart = now;
      _globalRequestCount = 0;
    }

    if (_globalRequestCount >= _globalMaxRequests) {
      return false; // Global limit exceeded
    }

    // 🔒 Per-sender rate limit
    _requestHistory[senderId] ??= [];
    final senderHistory = _requestHistory[senderId]!;

    // Remove old entries outside the window
    senderHistory.removeWhere((time) => now.difference(time) > window);

    if (senderHistory.length >= maxRequests) {
      return false; // Per-sender limit exceeded
    }

    // Record this request
    senderHistory.add(now);
    _globalRequestCount++;

    return true;
  }

  /// Get current rate for a sender (requests per minute)
  double getCurrentRate(String senderId) {
    final history = _requestHistory[senderId];
    if (history == null || history.isEmpty) return 0;

    final now = DateTime.now();
    final recentRequests =
        history.where((time) => now.difference(time) < window).length;

    return recentRequests / (window.inSeconds / 60);
  }

  /// Check if a sender is potentially malicious (high rate)
  bool isSuspicious(String senderId) {
    return getCurrentRate(senderId) > maxRequests * 0.8;
  }

  /// Clean up old entries periodically
  void cleanup() {
    final now = DateTime.now();
    _requestHistory.removeWhere((_, history) {
      history.removeWhere((time) => now.difference(time) > window * 2);
      return history.isEmpty;
    });
  }
}

/// Gossip — эвристическое распространение и дедупликация, не маршрутизатор.
///
/// 🔒 КОНЦЕПТУАЛЬНЫЕ КОНТРАКТЫ (не нарушать):
/// - Gossip не является маршрутизатором; Magnet даёт градиент, не путь.
/// - Relay — эвристический, не гарантированный.
/// - Дедупликация — защита от шума, не источник истины.
/// - При отсутствии аплинка Gossip работает как локальный epidemic.
class GossipManager {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  // Используем геттер для защиты от циклических зависимостей
  MeshService get _mesh => locator<MeshService>();

  Timer? _propagationTimer;
  bool _epidemicStopped = true;

  // 🔒 EVOLUTION: Адаптивный интервал epidemic. Риск: слишком редкий цикл при пустом outbox — первый push после появления сообщения задержится; не ломает доставку, только латентность.
  static const int _epidemicIntervalBaseSec = 30;
  static const int _epidemicIntervalWhenBusySec = 20;
  static const int _epidemicIntervalWhenIdleSec = 45;

  // 🔒 EVOLUTION: Наблюдаемость. In-memory счётчики для адаптации порогов.
  // Риск при масштабе: только рост int; периодический лог не блокирует доставку.
  int _statsAccepted = 0;
  int _statsDroppedRateLimit = 0;
  int _statsDroppedTtl = 0;
  int _statsRelayedGatt = 0;
  int _statsRelayedBle = 0;
  int _statsRelayedNetwork = 0;
  static const Duration _statsSummaryInterval = Duration(minutes: 5);

  // 🔒 SECURITY FIX: Rate limiters for different packet types
  final RateLimiter _messageRateLimiter = RateLimiter(
    maxRequests: 30, // Max 30 messages per sender per minute
    window: const Duration(seconds: 60),
  );

  final RateLimiter _fragmentRateLimiter = RateLimiter(
    maxRequests: 100, // Max 100 fragments per sender per minute
    window: const Duration(seconds: 60),
  );

  final RateLimiter _waveRateLimiter = RateLimiter(
    maxRequests: 20, // Max 20 routing waves per sender per minute
    window: const Duration(seconds: 60),
  );

  // 🔒 Cleanup timer
  Timer? _rateLimiterCleanupTimer;

  GossipManager() {
    // Periodic cleanup of rate limiter history + наблюдаемость (сводка счётчиков, размер outbox)
    _rateLimiterCleanupTimer = Timer.periodic(
      _statsSummaryInterval,
      (_) {
        _messageRateLimiter.cleanup();
        _fragmentRateLimiter.cleanup();
        _waveRateLimiter.cleanup();
        unawaited(_emitStatsSummary());
      },
    );
  }

  /// 🔒 P1: Наблюдаемость — агрегаты (drop, relay по каналам, размер outbox). Не меняет логику доставки.
  Future<void> _emitStatsSummary() async {
    final outboxCount = await _db.getOutboxCount();
    if (_statsAccepted == 0 &&
        _statsDroppedRateLimit == 0 &&
        _statsDroppedTtl == 0 &&
        _statsRelayedGatt == 0 &&
        _statsRelayedBle == 0 &&
        _statsRelayedNetwork == 0 &&
        outboxCount == 0) return;
    _mesh.addLog(
        "📊 [GOSSIP] summary: accepted=$_statsAccepted droppedRate=$_statsDroppedRateLimit droppedTtl=$_statsDroppedTtl "
        "relayGatt=$_statsRelayedGatt relayBle=$_statsRelayedBle relayNet=$_statsRelayedNetwork outbox=$outboxCount");
    _statsAccepted = 0;
    _statsDroppedRateLimit = 0;
    _statsDroppedTtl = 0;
    _statsRelayedGatt = 0;
    _statsRelayedBle = 0;
    _statsRelayedNetwork = 0;
  }

  void dispose() {
    _rateLimiterCleanupTimer?.cancel();
    _propagationTimer?.cancel();
  }

  // ============================================================
  // 📥 ВХОДЯЩИЙ ПОТОК (INGRESS)
  // ============================================================

  /// Главная точка входа для любого пакета из Mesh-эфира.
  Future<void> processEnvelope(Map<String, dynamic> packet) async {
    packet = Map<String, dynamic>.from(packet);
    final String type = packet['type'] ?? 'UNKNOWN';
    // 🔥 FIX: MSG_FRAG must use per-fragment packetId so both fragments are processed
    // (otherwise same pulse_ts_senderId would drop the 2nd fragment and message never assembles)
    final String packetId = type == 'MSG_FRAG'
        ? '${packet['mid']}_${packet['idx']}'
        : (packet['h'] ?? "pulse_${packet['timestamp']}_${packet['senderId']}");
    final String senderId = packet['senderId'] ?? 'unknown';

    // 🔒 SECURITY FIX: Rate limiting check BEFORE processing
    bool rateLimitAllowed = true;

    switch (type) {
      case 'MAGNET_WAVE':
        rateLimitAllowed = _waveRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog(
              "🛡️ [RATE-LIMIT] Wave flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
      case 'MSG_FRAG':
        rateLimitAllowed = _fragmentRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog(
              "🛡️ [RATE-LIMIT] Fragment flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
      case 'OFFLINE_MSG':
      case 'SOS':
        rateLimitAllowed = _messageRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog(
              "🛡️ [RATE-LIMIT] Message flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
    }

    // 🔒 Drop packet if rate limit exceeded
    if (!rateLimitAllowed) {
      _statsDroppedRateLimit++;
      // Log suspicious activity
      if (_messageRateLimiter.isSuspicious(senderId) ||
          _fragmentRateLimiter.isSuspicious(senderId)) {
        _mesh.addLog(
            "⚠️ [SECURITY] Suspicious sender flagged: ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
      }
      return;
    }

    // 1. СТРАТЕГИЧЕСКАЯ ДЕДУПЛИКАЦИЯ
    if (type == 'MAGNET_WAVE') {
      _statsAccepted++;
      // Для поисковой волны проверяем: не видели ли мы этот путь короче?
      await _handleMagnetWave(packet);
      return;
    }

    // Обычная дедупликация для данных (O(1) через SQLite)
    if (await _db.isPacketSeen(packetId)) return;

    _statsAccepted++;
    // 2. СЕМАНТИЧЕСКИЙ РАЗБОР
    if (type == 'MSG_FRAG') {
      // КЕЙС А: Фрагмент (Meaning Unit)
      await _handleFragment(packet);
    } else if (type == 'OFFLINE_MSG' || type == 'SOS') {
      // КЕЙС Б: Цельное сообщение
      await _incubateAndRelay(packet, packetId);
    }
  }

  // ============================================================
  // 🌊 MAGNET PROTOCOL (ПОИСК ОПТИМАЛЬНОГО ПУТИ)
  // ============================================================

  /// Обработка волны "Интернет-Магнита"
  Future<void> _handleMagnetWave(Map<String, dynamic> wave) async {
    final int peerHops = wave['hops'] ?? 255;
    final String senderId = wave['senderId'] ?? "Unknown";
    final orchestrator = locator<TacticalMeshOrchestrator>();

    // Если этот путь через соседа дает нам меньшее количество прыжков до интернета
    if (peerHops + 1 < orchestrator.myHops) {
      _mesh.addLog(
          "🌊 Magnet Wave: Internet detected via $senderId (${peerHops + 1} hops)");

      // 1. Обновляем градиент в Оркестраторе (теперь мы знаем, куда слать данные)
      orchestrator.processRoutingPulse(RoutingPulse(
        nodeId: senderId,
        hopsToInternet: peerHops,
        batteryLevel: 1.0,
        queuePressure: 0,
      ));

      // 2. Ретранслируем волну дальше (Epidemic Spread)
      // Ограничиваем глубину прострела сети (15 хопов максимум)
      if (peerHops < 15) {
        final senderId = locator.isRegistered<ApiService>()
            ? locator<ApiService>().currentUserId
            : await getCurrentUserIdSafe();
        final nextWave = {
          ...wave,
          'senderId': senderId,
          'hops': peerHops + 1,
        };
        // Вирусное распространение градиента
        await _mesh.sendTcpBurst(jsonEncode(nextWave));
      }
    }
  }

  // ============================================================
  // 🧩 MEANING UNITS (СБОРКА ПАЗЛА)
  // ============================================================

  /// 🔥 MESH FRAGMENT REASSEMBLY: Сборка сообщений из фрагментов
  /// Независимо от источника (BRIDGE A, BRIDGE B, direct) - по messageId
  Future<bool> _handleFragment(Map<String, dynamic> frag) async {
    // 🔥 ДИАГНОСТИКА: Логируем все поля фрагмента для отладки
    _mesh
        .addLog("🔍 [FRAGMENT-DEBUG] Raw fragment keys: ${frag.keys.toList()}");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['mid']: ${frag['mid']}");
    _mesh.addLog(
        "🔍 [FRAGMENT-DEBUG] frag['idx']: ${frag['idx']} (type: ${frag['idx'].runtimeType})");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['tot']: ${frag['tot']}");
    _mesh.addLog(
        "🔍 [FRAGMENT-DEBUG] frag['data']: ${frag['data']?.toString().length ?? 0} bytes");

    final String messageId = frag['mid'] ?? '';
    // 🔥 FIX: Правильное извлечение idx (может быть int или String)
    final dynamic idxRaw = frag['idx'];
    final int index = idxRaw is int
        ? idxRaw
        : (idxRaw is String ? int.tryParse(idxRaw) ?? -1 : -1);
    final dynamic totRaw = frag['tot'];
    final int total = totRaw is int
        ? totRaw
        : (totRaw is String ? int.tryParse(totRaw) ?? -1 : -1);
    // 🔥 FIX: Правильное извлечение data (может быть String или другой тип)
    final dynamic dataRaw = frag['data'];
    final String data = dataRaw?.toString() ?? '';
    final String senderId = frag['senderId'] ?? 'unknown';
    final String chatId = frag['chatId'] ?? 'THE_BEACON_GLOBAL';

    // 🛡️ VALIDATION
    if (messageId.isEmpty || index < 0 || total <= 0 || data.isEmpty) {
      _mesh.addLog(
          "⚠️ [FRAGMENT] Invalid fragment: mid=$messageId idx=$index tot=$total dataLen=${data.length}");
      _mesh.addLog(
          "   🔍 Debug: idxRaw=$idxRaw (${idxRaw.runtimeType}), totRaw=$totRaw (${totRaw.runtimeType})");
      return false;
    }

    // 📊 FORENSIC LOG: fragment_received
    _mesh.addLog(
        "📦 [FRAGMENT] fragment_received: mid=${messageId.substring(0, messageId.length > 8 ? 8 : messageId.length)}... idx=$index/$total sender=${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");

    // 💾 SAVE TO SQL (with flooding protection). Pass chatId/senderId so first
    // fragment can create placeholder in messages and satisfy message_fragments FK.
    final saved = await _db.saveFragment(
        messageId: messageId,
        index: index,
        total: total,
        data: data,
        chatId: chatId,
        senderId: senderId);

    if (!saved) {
      // 📊 FORENSIC LOG: fragment_duplicate or fragment_rejected
      _mesh.addLog(
          "ℹ️ [FRAGMENT] fragment_duplicate_or_rejected: $messageId idx=$index");
      return false;
    }

    // 📊 FORENSIC LOG: fragment_stored
    _mesh.addLog(
        "💾 [FRAGMENT] fragment_stored: $messageId idx=$index/${total}");

    // 🔍 CHECK IF COMPLETE
    final List<Map<String, dynamic>> allFrags =
        await _db.getFragments(messageId);

    _mesh.addLog(
        "📊 [FRAGMENT] Progress: ${allFrags.length}/$total for $messageId");

    // 🔥 ДИАГНОСТИКА: Логируем все сохраненные фрагменты
    if (allFrags.isNotEmpty) {
      final indices = allFrags.map((f) => f['index_num']).toList();
      _mesh.addLog("🔍 [FRAGMENT-DEBUG] Saved fragments indices: $indices");
      _mesh.addLog(
          "🔍 [FRAGMENT-DEBUG] Expected indices: ${List.generate(total, (i) => i)}");
    }

    if (allFrags.length == total) {
      // 🎉 MESSAGE COMPLETE!
      // 📊 FORENSIC LOG: message_assembled
      _mesh.addLog(
          "🎉 [FRAGMENT] message_assembled: $messageId (${allFrags.length} fragments)");

      // 🔥 FIX: Копируем список перед sort — getFragments может вернуть read-only list на части устройств
      final sortedFrags = List<Map<String, dynamic>>.from(allFrags);
      sortedFrags.sort((a, b) {
        final aIdx = a['index_num'];
        final bIdx = b['index_num'];
        final aInt = aIdx is int
            ? aIdx
            : (aIdx is String ? int.tryParse(aIdx) ?? 999 : 999);
        final bInt = bIdx is int
            ? bIdx
            : (bIdx is String ? int.tryParse(bIdx) ?? 999 : 999);
        return aInt.compareTo(bInt);
      });

      // 🔥 ДИАГНОСТИКА: Проверяем порядок после сортировки
      final sortedIndices = sortedFrags.map((f) => f['index_num']).toList();
      _mesh.addLog("🔍 [FRAGMENT-DEBUG] Sorted indices: $sortedIndices");

      String fullContent =
          sortedFrags.map((f) => f['data']?.toString() ?? '').join("");

      _mesh.addLog(
          "📝 [FRAGMENT] Assembled content: ${fullContent.length} bytes");

      // Build assembled packet from deep copy so mutations never hit read-only (BLE/DB).
      final fullPacket = jsonDecode(jsonEncode(frag)) as Map<String, dynamic>;
      fullPacket['type'] = 'OFFLINE_MSG';
      fullPacket['content'] = fullContent;
      fullPacket['h'] = messageId;
      fullPacket['chatId'] = chatId;
      fullPacket['senderId'] = senderId;
      fullPacket['_assembled'] = true;
      if (frag['isEncrypted'] == true) fullPacket['isEncrypted'] = true;

      // 📤 DELIVER TO UI (только полное сообщение!)
      _mesh.messageController.add(fullPacket);

      // 💾 SAVE TO SQL (content may already be encrypted from mesh)
      await _db.saveMessage(ChatMessage.fromJson(fullPacket), chatId,
          contentAlreadyEncrypted: fullPacket['isEncrypted'] == true);

      // 📊 FORENSIC LOG: message_committed
      _mesh
          .addLog("✅ [FRAGMENT] message_committed: $messageId to chat $chatId");

      // 🧹 CLEANUP fragments
      await _db.clearFragments(messageId);

      // 🔄 RELAY: deep copy so TTL/relay never hit read-only or nested immutability
      final packetForRelay =
          jsonDecode(jsonEncode(fullPacket)) as Map<String, dynamic>;
      await attemptRelay(packetForRelay);

      // 📊 FORENSIC LOG: relay_forwarded
      _mesh.addLog(
          "📤 [FRAGMENT] relay_forwarded: assembled message $messageId");

      return true; // Сообщение собрано
    }

    return false; // Ждём остальные фрагменты
  }

  Future<void> _incubateAndRelay(Map<String, dynamic> packet, String id) async {
    await _db.saveMessage(
        ChatMessage.fromJson(packet), packet['chatId'] ?? 'THE_BEACON_GLOBAL',
        contentAlreadyEncrypted: packet['isEncrypted'] == true);
    _mesh.addLog("📥 [Grid] Signal captured: ${id.substring(0, 8)}");
    await attemptRelay(packet);
  }

  // ============================================================
  // 🚀 ТАКТИЧЕСКАЯ РЕТРАНСЛЯЦИЯ (PUSH PHASE)
  // ============================================================

  /// 🔥 TTL: Проверяет и обрабатывает TTL в пакете
  /// Возвращает false если TTL истек, true если пакет валиден
  /// 🔥 STABILIZATION: Различает relay и конечную доставку
  bool _checkAndDecrementTtl(Map<String, dynamic> packet,
      {bool isFinalRecipient = false}) {
    final ttl = packet['ttl'] as int?;

    // Если TTL отсутствует - текущее поведение без изменений
    if (ttl == null) return true;

    // Если TTL истек - дропаем пакет
    if (ttl <= 0) {
      _mesh.addLog("⚠️ [TTL] Packet TTL expired (ttl=$ttl), dropping");
      return false;
    }

    // 🔥 STABILIZATION: Уменьшаем TTL только при relay, не при конечной доставке
    if (!isFinalRecipient) {
      packet['ttl'] = ttl - 1;
    } else {
      _mesh.addLog("📥 [TTL] Final recipient, TTL not decremented (ttl=$ttl)");
    }

    return true;
  }

  Future<void> attemptRelay(Map<String, dynamic> packet) async {
    packet = jsonDecode(jsonEncode(packet)) as Map<String, dynamic>;
    // 🔥 TTL: Проверяем TTL перед ретрансляцией (это relay, не конечная доставка)
    if (!_checkAndDecrementTtl(packet, isFinalRecipient: false)) {
      _statsDroppedTtl++;
      return; // TTL истек, не ретранслируем
    }

    final String packetId =
        packet['h'] ?? "pulse_${packet['timestamp']}_${packet['senderId']}";
    final currentRole = NetworkMonitor().currentRole;
    final senderId = packet['senderId']?.toString();

    // 🔥 REPEATER: Используем RepeaterService для ретрансляции всем доверенным устройствам
    try {
      final repeater = locator<RepeaterService>();
      if (repeater.isRunning && repeater.activeConnectionCount > 0) {
        final repeatedCount = await repeater.repeatPacket(
          packet,
          excludeDeviceId: senderId,
        );
        if (repeatedCount > 0) {
          _mesh
              .addLog("🔄 [REPEATER] Packet relayed to $repeatedCount devices");
        }
      }
    } catch (e) {
      // RepeaterService может быть недоступен - продолжаем стандартную логику
    }

    // 🔥 BRIDGE: Ретранслируем сообщения GHOST устройствам
    if (currentRole == MeshRole.BRIDGE) {
      final String packetIdForLog =
          packetId.length > 8 ? packetId.substring(0, 8) : packetId;

      _mesh.addLog("🌉 [BRIDGE-GOSSIP] Relaying message to GHOST devices...");
      _mesh.addLog("   📋 Packet ID: $packetIdForLog...");
      _mesh.addLog("   📋 Packet type: ${packet['type']}");
      _mesh.addLog("   📋 Chat ID: ${packet['chatId']}");
      _mesh.addLog("   📋 TTL: ${packet['ttl'] ?? 5}");

      // 1. Если есть Wi-Fi Direct - используем сеть
      if (_mesh.isP2pConnected) {
        _mesh.addLog("   📡 Using Wi-Fi Direct for relay");
        await _relayViaNetwork(packet);
      } else {
        _mesh
            .addLog("   ⚠️ Wi-Fi Direct not connected, skipping network relay");
      }

      // 2. 🔥 КРИТИЧНО: Всегда ретранслируем через BLE к GHOST устройствам
      // Это гарантирует доставку даже без Wi-Fi Direct
      // 🔥 FIX: Используем снимок подключённых клиентов на момент приёма (_relayRecipientsSnapshot),
      // иначе к моменту attemptRelay GHOST может уже отключиться и connectedGattClients пуст.
      final btService = _mesh.btService;
      final List<String>? snapshot = _parseRelayRecipientsSnapshot(packet);
      final int connectedClientsCount = btService.connectedGattClientsCount;
      final int snapshotCount = snapshot?.length ?? 0;
      _mesh.addLog("   🔍 Active GATT clients (now): $connectedClientsCount");
      if (snapshotCount > 0) {
        _mesh.addLog(
            "   🔍 Relay recipients snapshot (at receive): $snapshotCount");
      }

      final bluetoothNodes = _mesh.nearbyNodes
          .where((n) => n.type == SignalType.bluetooth)
          .toList();
      _mesh.addLog(
          "   🔍 Found ${bluetoothNodes.length} BLE node(s) in nearbyNodes");

      // 🔥 FIX: Для BRIDGE → GHOST НЕ проверяем наличие сообщения в БД BRIDGE
      _mesh.addLog(
          "   📤 [BRIDGE→GHOST] Relaying message to GHOST devices (no DB check for BRIDGE→GHOST)...");

      // 🔥 FIX: Сначала отправляем по снимку (получатель на момент приёма), затем по текущему списку
      final bool hasRecipients =
          (snapshotCount > 0) || (connectedClientsCount > 0);
      if (snapshotCount > 0) {
        _mesh.addLog(
            "   🦷 Relaying to $snapshotCount recipient(s) from snapshot...");
        await _relayToConnectedGattClients(packet, btService,
            recipientsSnapshot: snapshot);
      }
      if (connectedClientsCount > 0 && snapshotCount == 0) {
        _mesh.addLog(
            "   🦷 Relaying to $connectedClientsCount active GATT client(s)...");
        await _relayToConnectedGattClients(packet, btService);
      }

      // Также отправляем через nearbyNodes для устройств, которые еще не подключены
      if (bluetoothNodes.isNotEmpty) {
        _mesh.addLog(
            "   🦷 Relaying to ${bluetoothNodes.length} BLE node(s) via GATT...");
        for (var node in bluetoothNodes) {
          _mesh.addLog(
              "      📋 Node: ${node.name} (${node.id.substring(node.id.length > 8 ? node.id.length - 8 : 0)})");
        }
        await _relayViaBle(packet, bluetoothNodes);
      } else if (!hasRecipients) {
        _mesh.addLog("   ⚠️ No BLE nodes available for relay");
        _mesh.addLog(
            "   💡 GHOST devices need to be in BLE scan range or connected via GATT");
        _mesh.addLog(
            "   💡 Message will be synced when GHOST connects (via MessageSyncService)");
      }

      return;
    }

    // Для GHOST: проверяем наличие пакета у соседа перед передачей
    if (!_mesh.isP2pConnected) {
      // Если нет Wi-Fi Direct - используем BLE или Sonar для проверки
      await _relayWithPacketCheck(packet, packetId);
      return;
    }

    // Если есть Wi-Fi Direct соединение - передаем через сеть
    // 🔥 КОНЦЕПТУАЛЬНОЕ ВЫРАВНИВАНИЕ: Wi-Fi Direct рассматривается как high-bandwidth link
    // Приоритеты доставки не изменены, но логика не привязана к типу канала
    await _relayViaNetwork(packet);
  }

  /// Парсит снимок получателей из пакета (на момент приёма по GATT). Не уходит в сеть.
  static List<String>? _parseRelayRecipientsSnapshot(
      Map<String, dynamic> packet) {
    final raw = packet['_relayRecipientsSnapshot'];
    if (raw == null || raw is! List) return null;
    final list = raw.map((e) => e?.toString()).whereType<String>().toList();
    return list.isEmpty ? null : list;
  }

  /// 🔥 Ретрансляция к подключенным GATT клиентам (BRIDGE → GHOST)
  /// [recipientsSnapshot] — снимок MAC-адресов на момент приёма (избегает race с disconnect).
  Future<void> _relayToConnectedGattClients(
      Map<String, dynamic> packet, dynamic btService,
      {List<String>? recipientsSnapshot}) async {
    final clients = recipientsSnapshot ?? btService.connectedGattClients;
    if (clients.isEmpty) {
      _mesh.addLog("   ⚠️ No connected GATT clients to relay to");
      return;
    }
    // Не отправляем по GATT внутреннее поле _relayRecipientsSnapshot.
    // Stage 2.1: packet['content'] is ciphertext (from sendAuto or from wire).
    final packetForSend = Map<String, dynamic>.from(packet)
      ..remove('_relayRecipientsSnapshot');
    final packetJson = jsonEncode(packetForSend);

    _mesh.addLog(
        "🦷 [GOSSIP-GATT] Relaying to ${clients.length} GATT client(s)${recipientsSnapshot != null ? " (snapshot)" : ""}...");
    final packetId = packet['h']?.toString() ?? 'unknown';
    final packetIdPreview =
        packetId.length > 8 ? packetId.substring(0, 8) : packetId;
    _mesh.addLog("   📋 Packet ID: $packetIdPreview...");

    _mesh.addLog(
        "   📤 [BRIDGE→GHOST] Relaying to connected GATT clients (no DB check for BRIDGE→GHOST)...");

    // 🔒 EVOLUTION: Обратная связь в PeerCache (существующие метрики). Риск: рост числа пиров — уже есть cleanup по времени.
    final peerCache = locator<PeerCacheService>();
    int successCount = 0;
    for (var deviceAddress in clients) {
      try {
        final shortMac = deviceAddress.length > 8
            ? deviceAddress.substring(deviceAddress.length - 8)
            : deviceAddress;
        _mesh.addLog("   📤 Relaying to client (MAC: $shortMac)...");

        final success =
            await btService.sendMessageToGattClient(deviceAddress, packetJson);

        if (success) {
          successCount++;
          peerCache.recordSuccess(
              peerId: deviceAddress,
              latency: Duration.zero,
              channel: 'bleGatt');
          _mesh.addLog("   ✅ Successfully relayed to client (MAC: $shortMac)");
        } else {
          peerCache.recordFailure(
              peerId: deviceAddress, channel: 'bleGatt', reason: null);
          _mesh.addLog("   ⚠️ Failed to relay to client (MAC: $shortMac)");
        }
      } catch (e) {
        peerCache.recordFailure(
            peerId: deviceAddress, channel: 'bleGatt', reason: e.toString());
        _mesh.addLog("   ❌ Error relaying to client: $e");
      }
    }

    _mesh.addLog(
        "🦷 [GOSSIP-GATT] Relay complete: $successCount/${clients.length} successful");
    _statsRelayedGatt += successCount;
  }

  /// 🔥 Ретрансляция через BLE GATT (BRIDGE → GHOST)
  /// Stage 2.1: [packet] is relayed as-is; packet['content'] is ciphertext.
  Future<void> _relayViaBle(
      Map<String, dynamic> packet, List<dynamic> bluetoothNodes) async {
    final btService = _mesh.btService;
    final packetForSend = Map<String, dynamic>.from(packet)
      ..remove('_relayRecipientsSnapshot');
    final packetJson = jsonEncode(packetForSend);

    _mesh.addLog(
        "🦷 [GOSSIP-BLE] Starting BLE relay to ${bluetoothNodes.length} device(s)...");
    final packetId = packet['h']?.toString() ?? 'unknown';
    final packetIdPreview =
        packetId.length > 8 ? packetId.substring(0, 8) : packetId;
    _mesh.addLog("   📋 Packet ID: $packetIdPreview...");
    _mesh.addLog(
        "   📋 Content length: ${(packet['content']?.toString() ?? '').length} bytes");

    // 🔒 EVOLUTION: Обратная связь в PeerCache по каналу bleNearby (отличие от GATT-клиентов).
    final peerCache = locator<PeerCacheService>();
    int successCount = 0;
    for (var node in bluetoothNodes) {
      try {
        final deviceId = node.id;
        if (deviceId.isEmpty) continue;

        final shortMac = deviceId.length > 8
            ? deviceId.substring(deviceId.length - 8)
            : deviceId;
        _mesh.addLog("   📤 Relaying to ${node.name} (MAC: $shortMac)...");

        final device = BluetoothDevice.fromId(deviceId);
        final result = await btService.sendMessageForRelay(device, packetJson);

        switch (result) {
          case BleRelayResult.success:
            successCount++;
            peerCache.recordSuccess(
                peerId: deviceId, latency: Duration.zero, channel: 'bleNearby');
            _mesh.addLog(
                "   ✅ Successfully relayed to ${node.name} (MAC: $shortMac)");
            break;
          case BleRelayResult.skippedDueToRole:
            // Transport not eligible (e.g. PERIPHERAL). Not an error — do not record failure.
            break;
          case BleRelayResult.failure:
            peerCache.recordFailure(
                peerId: deviceId, channel: 'bleNearby', reason: null);
            _mesh.addLog(
                "   ⚠️ Failed to relay to ${node.name} (MAC: $shortMac)");
            break;
        }
      } catch (e) {
        peerCache.recordFailure(
            peerId: node.id, channel: 'bleNearby', reason: e.toString());
        _mesh.addLog("   ❌ Error relaying to ${node.name}: $e");
      }
    }

    _mesh.addLog(
        "🦷 [GOSSIP-BLE] Relay complete: $successCount/${bluetoothNodes.length} successful");
    _statsRelayedBle += successCount;
  }

  /// Передача через сеть (Wi-Fi Direct или Router)
  /// 🔥 КОНЦЕПТУАЛЬНОЕ ВЫРАВНИВАНИЕ: Рассматривает любой high-bandwidth link
  /// Не привязан к типу канала, только к характеристикам (bandwidth, latency)
  /// 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Wi-Fi Direct = link (bandwidth, latency) + topology (Group Owner)
  Future<void> _relayViaNetwork(Map<String, dynamic> packet) async {
    // 1. Управление жизненным циклом (TTL уже обработан в attemptRelay)
    // Проверяем еще раз на всякий случай
    final ttl = packet['ttl'] as int?;
    if (ttl != null && ttl <= 0) {
      _mesh.addLog("⚠️ [GOSSIP-NETWORK] TTL expired, dropping packet");
      return;
    }

    // 🔥 STABILIZATION: TTL уже уменьшен в attemptRelay (это relay, не конечная доставка)
    // Здесь только проверка на истечение

    // 2. Вероятностный фильтр нагрузки (масштабируемость)
    // 🔥 FIX: Для BRIDGE всегда ретранслируем (вероятность = 1.0)
    final currentRole = NetworkMonitor().currentRole;
    double relayProbability;
    if (currentRole == MeshRole.BRIDGE) {
      relayProbability = 1.0; // BRIDGE всегда ретранслирует
      _mesh.addLog("🌉 [BRIDGE-GOSSIP] Relay probability: 1.0 (always relay)");
    } else {
      final ttlValue = ttl ?? 5; // Fallback если ttl null
      relayProbability =
          math.pow(ttlValue / 5.0, 1.5).toDouble().clamp(0.0, 1.0);
      // 🔒 EVOLUTION: Мягкая безопасность — понижаем приоритет релея для подозрительного отправителя, не дропаем. Локальная доставка уже произошла.
      final senderId = packet['senderId']?.toString();
      if (senderId != null && _messageRateLimiter.isSuspicious(senderId)) {
        relayProbability *= 0.5;
        _mesh.addLog(
            "👻 [GHOST-GOSSIP] Demoted relay (suspicious sender): ${relayProbability.toStringAsFixed(2)}");
      } else {
        _mesh.addLog(
            "👻 [GHOST-GOSSIP] Relay probability: ${relayProbability.toStringAsFixed(2)} (TTL: $ttlValue)");
      }
    }

    if (math.Random().nextDouble() > relayProbability) {
      _mesh.addLog("⏸️ [GOSSIP-NETWORK] Packet dropped by probability filter");
      return;
    }

    // 3. Фрагментация перед отправкой (с защитой от перехвата)
    final List<Map<String, dynamic>> fragments = _fragmentMessage(packet);
    _mesh.addLog("   📦 Fragmented into ${fragments.length} piece(s)");
    if (fragments.length > 1) {
      // 🔒 Логируем порядок отправки (для диагностики)
      final indices = fragments.map((f) => f['idx'] as int).toList();
      _mesh.addLog(
          "   🔒 [SECURITY] Fragment order: $indices (shuffled for anti-interception)");
    }

    // 4. Выбор цели на основе градиента (ищем аплинк)
    // 🔥 BRIDGE — сам аплинк: не шлём relay на свой IP (192.168.49.1), иначе ECONNREFUSED
    if (currentRole == MeshRole.BRIDGE) {
      _mesh.addLog(
          "🌉 [BRIDGE-GOSSIP] BRIDGE is uplink — skipping network relay (no peer to send to)");
      _mesh.addLog("   💡 Relay to GHOSTs is done via GATT/BLE only");
      return;
    }

    final mesh = locator<MeshService>();
    // 🔥 RELAY (GO): Мы Group Owner — 192.168.49.1 это наш IP. getBestUplink() возвращает nodeId (MAC), не IP,
    // поэтому targetIp всегда становится 192.168.49.1 → отправка на себя → пакет приходит обратно и дропается как duplicate.
    // Не шлём network relay на себя; клиенты подключаются к нам по TCP, relay к ним — через BLE/GATT или когда узнаем их IP.
    if (mesh.isHost) {
      _mesh.addLog(
          "🛡️ [GO-GOSSIP] We are Group Owner — skipping network relay to 192.168.49.1 (would send to self)");
      _mesh.addLog("   💡 Relay to clients via GATT/BLE or when client IP is known");
      return;
    }

    final bestUplink = locator<TacticalMeshOrchestrator>().getBestUplink();
    String targetIp = "192.168.49.1"; // Default WiFi Direct Host (GO) — только для CLIENT это peer

    if (bestUplink != null) {
      _mesh.addLog("🧭 Routing packet towards Magnet: ${bestUplink.nodeId}");
      targetIp =
          bestUplink.nodeId.contains(".") ? bestUplink.nodeId : "192.168.49.1";
    } else {
      _mesh.addLog("⚠️ No best uplink found, using default IP: $targetIp");
    }

    _mesh.addLog(
        "   📤 Transmitting ${fragments.length} fragment(s) to $targetIp...");
    await _transmitWithRetry(fragments, targetIp, "Relay-Node");
    _statsRelayedNetwork++;
    _mesh.addLog("   ✅ Network relay transmission completed");
  }

  /// Передача с проверкой наличия пакета у соседа (для GHOST без Wi-Fi Direct)
  /// 🔥 FIX: Проверяет наличие сообщения в БД перед отправкой (Gossip протокол)
  Future<void> _relayWithPacketCheck(
      Map<String, dynamic> packet, String packetId) async {
    final ultrasonic = locator<UltrasonicService>();
    final mesh = locator<MeshService>();

    // 🔥 FIX: Проверяем наличие сообщения в БД перед отправкой (Gossip протокол)
    // Это позволяет проверить, какие сообщения уже есть на устройстве
    final chatId = packet['chatId']?.toString() ?? 'THE_BEACON_GLOBAL';
    final messages = await _db.getMessages(chatId);
    final messageExists = messages.any((msg) => msg.id == packetId);

    if (messageExists) {
      _mesh.addLog(
          "✅ [GOSSIP] Message ${packetId.substring(0, packetId.length > 8 ? 8 : packetId.length)} already exists in DB - skipping relay (Gossip deduplication)");
      return; // Сообщение уже есть - не отправляем дубликат
    }

    _mesh.addLog(
        "📤 [GOSSIP] Message ${packetId.substring(0, packetId.length > 8 ? 8 : packetId.length)} not found in DB - will relay to neighbors...");

    // 1. Отправляем запрос через Sonar: "Есть ли у тебя пакет с ID?"
    _mesh.addLog(
        "🔊 [Gossip] Querying neighbors for packet: ${packetId.substring(0, 8)}...");

    // Отправляем запрос через Sonar (короткий сигнал)
    final querySignal = "Q:${packetId.hashCode}"; // Хеш для краткости
    await ultrasonic.transmitFrame(querySignal);

    // Ждем ответа 3 секунды (сосед должен ответить через BLE или Sonar)
    await Future.delayed(const Duration(seconds: 3));

    // 2. Проверяем ближайших соседей через BLE
    // 🔒 BLE BACKPRESSURE: Skip BLE relay when a BLE transaction is active (single FSM).
    if (mesh.btService.bleTransactionState != BleTransactionState.IDLE) {
      _mesh.addLog(
          "[BLE-BLOCK] Gossip skipping BLE relay — BLE transaction active (${mesh.btService.bleTransactionState})");
      if ((packet['content'] as String? ?? '').length < 64) {
        _mesh.addLog("🔊 [Gossip] Using Sonar fallback instead");
        final sonarPayload = "MSG:${packetId.hashCode}";
        await ultrasonic.transmitFrame(sonarPayload);
      }
      return;
    }
    // 🔥 FIX: Не конкурировать с Cascade Stage 2 — пропускаем BLE relay когда идёт GATT connect
    if (mesh.isTransferring) {
      _mesh.addLog(
          "⏸️ [Gossip] Cascade transfer active - skipping BLE relay (avoid GATT mutex conflict)");
      if ((packet['content'] as String? ?? '').length < 64) {
        _mesh.addLog("🔊 [Gossip] Using Sonar fallback instead");
        final sonarPayload = "MSG:${packetId.hashCode}";
        await ultrasonic.transmitFrame(sonarPayload);
      }
      return;
    }
    // 🔥 Huawei/Honor: на этих устройствах BLE в роли CENTRAL не работает (таймаут 20s).
    // Gossip не должен инициировать BLE relay — иначе enterCentralMode() падает (PERIPHERAL must not enter QUIET).
    if (await HardwareCheckService().preferGattPeripheral()) {
      _mesh.addLog(
          "🦷 [Gossip] Device prefers PERIPHERAL (Huawei/Honor) — skipping BLE relay, using Sonar");
      if ((packet['content'] as String? ?? '').length < 64) {
        final sonarPayload = "MSG:${packetId.hashCode}";
        await ultrasonic.transmitFrame(sonarPayload);
      }
      return;
    }
    final bluetoothNodes =
        mesh.nearbyNodes.where((n) => n.type == SignalType.bluetooth).toList();

    if (bluetoothNodes.isNotEmpty) {
      // Пытаемся передать через BLE с проверкой
      for (var node in bluetoothNodes) {
        // Проверяем, есть ли у соседа этот пакет (через BLE запрос)
        // Если нет - передаем
        _mesh.addLog("🦷 [Gossip] Attempting BLE relay to ${node.name}...");

        try {
          final device = BluetoothDevice.fromId(node.id);
          final packetJson = jsonEncode(packet);
          final result = await mesh.btService.sendMessageForRelay(device, packetJson);

          switch (result) {
            case BleRelayResult.success:
              _mesh.addLog("✅ [Gossip] BLE relay successful to ${node.name}");
              break;
            case BleRelayResult.skippedDueToRole:
              // Transport not eligible (e.g. PERIPHERAL). Not an error — continue epidemic round.
              break;
            case BleRelayResult.failure:
              _mesh.addLog("⚠️ [Gossip] BLE relay failed to ${node.name}");
              break;
          }
        } catch (e) {
          _mesh.addLog("⚠️ [Gossip] BLE relay failed: $e");
        }
      }
    } else {
      // Если нет BLE соседей - отправляем через Sonar (только для коротких сообщений)
      if ((packet['content'] as String? ?? '').length < 64) {
        _mesh.addLog("🔊 [Gossip] No BLE neighbors, using Sonar fallback");
        final sonarPayload = "MSG:${packetId.hashCode}";
        await ultrasonic.transmitFrame(sonarPayload);
      }
    }
  }

  // 🔒 Fragment Security Service для защиты от перехвата
  final FragmentSecurityService _fragmentSecurity = FragmentSecurityService();

  List<Map<String, dynamic>> _fragmentMessage(Map<String, dynamic> packet) {
    // 🔒 Используем защищенную фрагментацию с перемешиванием
    return _fragmentSecurity.fragmentWithSecurity(packet, chunkSize: 160);
  }

  Future<void> _transmitWithRetry(
      List<Map<String, dynamic>> units, String ip, String name) async {
    for (var unit in units) {
      try {
        await NativeMeshService.sendTcp(jsonEncode(unit), host: ip);
      } catch (e) {
        // Если TCP упал, пакет остается в Outbox и будет подхвачен циклом Epidemic
        _mesh.addLog("⚠️ [Gossip] Hop failed to $ip. Deferred.");
      }
    }
  }

  // ============================================================
  // 🔄 EPIDEMIC CYCLE (PULL/PUSH SYNC)
  // ============================================================
  // 🔒 EVOLUTION: Адаптивный интервал + приоритизация (старые, SOS). Порядок каналов и fallback не меняются.

  void startEpidemicCycle() {
    _propagationTimer?.cancel();
    _epidemicStopped = false;
    _runEpidemicCycle();
  }

  void _runEpidemicCycle() async {
    if (_epidemicStopped) return;

    final List<Map<String, dynamic>> pending = await _db.getPendingFromOutbox();
    final bool hadPending = pending.isNotEmpty;
    final int pendingCount = pending.length;

    if (pending.isNotEmpty) {
      // Если я сам стал мостом и есть ApiService — выгружаю всё в облако
      if (NetworkMonitor().currentRole == MeshRole.BRIDGE &&
          locator.isRegistered<ApiService>()) {
        await locator<ApiService>().syncOutbox();
      } else {
        // Приоритизация: SOS первыми, затем по ts (старые первыми). Не меняет каналы доставки.
        final sorted = List<Map<String, dynamic>>.from(pending);
        sorted.sort((a, b) {
          final aSos = (a['type'] ?? '') == 'SOS' ? 1 : 0;
          final bSos = (b['type'] ?? '') == 'SOS' ? 1 : 0;
          if (aSos != bSos) return bSos.compareTo(aSos);
          final aTs = a['ts'] ?? a['timestamp'] ?? 0;
          final bTs = b['ts'] ?? b['timestamp'] ?? 0;
          final aNum = aTs is num ? aTs : 0;
          final bNum = bTs is num ? bTs : 0;
          return aNum.compareTo(bNum);
        });

        final bestUplink = locator<TacticalMeshOrchestrator>().getBestUplink();
        if (bestUplink != null) {
          _mesh.addLog(
              "🦠 [Epidemic] Infecting superior node: ${bestUplink.nodeId}");
          for (var msg in sorted) {
            await attemptRelay(msg);
          }
        } else {
          _mesh.addLog(
              "🦠 [Epidemic] No uplink found, attempting neighbor infection...");
          for (var msg in sorted) {
            await attemptRelay(msg);
          }
        }
      }
    }

    // 🔒 EVOLUTION: агрегат после эпидемического цикла (только наблюдение, интервал не меняется)
    final relayAttempts =
        hadPending && NetworkMonitor().currentRole != MeshRole.BRIDGE
            ? pendingCount
            : 0;
    if (hadPending || relayAttempts > 0) {
      _mesh.addLog(
          "🦠 [Epidemic] run: pending=$pendingCount, relay_attempts=$relayAttempts");
    }

    if (!_epidemicStopped) {
      final nextSec = _computeEpidemicIntervalSeconds(hadPending, pendingCount);
      _propagationTimer = Timer(Duration(seconds: nextSec), _runEpidemicCycle);
    }
  }

  int _computeEpidemicIntervalSeconds(bool hadPending, int pendingCount) {
    if (hadPending && pendingCount > 0) return _epidemicIntervalWhenBusySec;
    if (!hadPending) return _epidemicIntervalWhenIdleSec;
    return _epidemicIntervalBaseSec;
  }

  void stop() {
    _epidemicStopped = true;
    _propagationTimer?.cancel();
  }
}
