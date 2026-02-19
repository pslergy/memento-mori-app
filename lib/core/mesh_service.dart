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
import 'package:shared_preferences/shared_preferences.dart';
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
import 'ble_hardware_strategy.dart';
import 'ble_interaction_stats.dart';
import 'router/router_connection_service.dart';
import 'router/router_bridge_protocol.dart';
import 'security_config.dart';
import 'log_mac_mask.dart';
import 'models/ad_packet.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';
import 'network_phase_context.dart';
import 'network_monitor.dart';
import 'role/ghost_role.dart';
import 'websocket_service.dart';
import 'ble_session.dart';
import 'bluetooth_service.dart';
import 'mesh_diagnostics.dart';
import 'message_status.dart';
import 'message_signing_service.dart';
import 'event_bus_service.dart';
import 'discovery_context_service.dart';
import 'models/uplink_candidate.dart';
import 'connection_stabilizer.dart';
import 'repeater_service.dart';
import 'ghost_transfer_manager.dart';
import 'peer_cache_service.dart';
import 'role/delivery_path.dart';
import 'role/message_router.dart';
import 'crdt_reconciliation.dart';

// 🔒 EVOLUTION: мягкое охлаждение Wi-Fi Direct в sendAuto (Вариант A). Не меняет порядок каналов, не трогает BLE.
// Влияние: только задержка перед попыткой Channel 2, если по опыту (PeerCache) у peer/channel плохая история.
const bool kSendAutoWifiDirectSoftCooldownEnabled = true;
const int kSendAutoWifiDirectCooldownMinMs = 0;
const int kSendAutoWifiDirectCooldownMaxMs = 2000;

// 🛡️ ANTICENSORSHIP: Protocol for anonymity — pseudonyms, encrypted outbox/cloud, no timing changes
const String kAnticensorshipProtocolName = 'Anticensorship';

// 🔥 МАСШТАБИРУЕМОСТЬ: Классы для оптимизации отправки
class PayloadRetryInfo {
  int gattAttempts = 0;
  int tcpAttempts = 0;
  int sonarAttempts = 0;
  DateTime? cycleStartTime;
  int? hopsToBridge;
  int? outboxSizeAtStart;

  bool get maxRetriesReached =>
      gattAttempts >= 3 && tcpAttempts >= 2 && sonarAttempts >= 1;

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
    if (successfulLatencies.isEmpty) return const Duration(seconds: 15);
    final total =
        successfulLatencies.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return Duration(milliseconds: total ~/ successfulLatencies.length);
  }

  // 🔒 SECURITY FIX #5: Увеличенные таймауты для GATT соединений
  // Проблема: 15s недостаточно для Huawei/Tecno где GATT connect занимает 10-15s
  // Решение: Base timeout 25s, увеличенный до 35s при множественных неудачах
  // ⚡ OPTIMIZATION: Более агрессивные таймауты для быстрых устройств
  Duration get adaptiveTimeout {
    if (consecutiveFailures >= 3) {
      return const Duration(
          seconds: 35); // Максимальный для проблемных устройств
    }
    if (consecutiveFailures >= 1) {
      return const Duration(seconds: 30); // Увеличенный после первой неудачи
    }
    // ⚡ OPTIMIZATION: Если средняя задержка < 5 секунд - используем 15s timeout (было 20s)
    // Это ускоряет failover к TCP/Sonar на быстрых устройствах
    if (successfulLatencies.isNotEmpty &&
        averageSuccessLatency.inSeconds <= 5) {
      return const Duration(
          seconds: 15); // Агрессивный для очень быстрых устройств
    }
    if (successfulLatencies.isNotEmpty &&
        averageSuccessLatency.inSeconds <= 8) {
      return const Duration(seconds: 20); // Стандартный для быстрых устройств
    }
    return const Duration(seconds: 25); // Base timeout для медленных устройств
  }

  void recordSuccess(Duration latency) {
    successfulLatencies.add(latency);
    if (successfulLatencies.length > 10)
      successfulLatencies.removeAt(0); // Храним последние 10
    consecutiveSuccesses++;
    consecutiveFailures = 0;
  }

  void recordFailure() {
    failedLatencies
        .add(DateTime.now().difference(DateTime.now())); // Placeholder
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
  PROXY_REQUEST, // Призрак просит Мост выполнить запрос
  PROXY_RESPONSE, // Мост возвращает ответ Призраку
}

class MeshService with ChangeNotifier {
  static final MeshService _instance = MeshService._internal();
  factory MeshService() => _instance;

  FlutterLocalNotificationsPlugin? _meshNotifications;
  bool _meshNotificationsInitialized = false;
  bool _preferOfflineMode = false;

  /// MESSENGER MODE: when true, BRIDGE sends only via mesh (no Cloud).
  bool get preferOfflineMode => _preferOfflineMode;

  /// Load saved messenger mode preference.
  Future<void> loadMessengerMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferOfflineMode = prefs.getBool('prefer_offline_mode') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  /// Set messenger mode (OFFLINE = mesh only). Persists and notifies.
  void setPreferOfflineMode(bool value) {
    if (_preferOfflineMode == value) return;
    _preferOfflineMode = value;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('prefer_offline_mode', value);
    });
  }

  MeshService._internal() {
    // Запускаем таймер очистки "мертвых" нод раз в 10 секунд
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _pruneDeadNodes());

    // 🔒 Fix memory leaks: Periodic cleanup of cooldowns and timestamps
    _memoryCleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      final now = DateTime.now();
      // Clean up expired cooldowns (older than 1 hour)
      _linkCooldowns.removeWhere((_, time) => now.difference(time).inHours > 1);
      // 🔥 FIX: Clean up token-to-MAC mapping (older than 5 minutes)
      // Tokens change every 30 seconds, so 5 minutes is more than enough
      _tokenToMacMapping.clear(); // Will be repopulated on next scan
      // Clean up expired IP locks (older than 10 minutes)
      _peerIpExpiry.removeWhere((_, expiry) => now.isAfter(expiry));
      // Clean up old timestamps (older than 1 hour)
      final oneHourAgoTimestamp = now.millisecondsSinceEpoch - (60 * 60 * 1000);
      _lastSeenTimestamps
          .removeWhere((_, timestamp) => timestamp < oneHourAgoTimestamp);

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
        _log(
            "🧹 [Memory] Cleaned up ${sentPayloadsToRemove.length} old _sentPayloads entries (older than 1 hour)");
      }

      // 🔥 МАСШТАБИРУЕМОСТЬ: Динамическая очистка _sentPayloads при превышении лимита (500-1000)
      if (_sentPayloads.length > 1000) {
        // Оставляем только последние 500 записей
        final entries = _sentPayloads.entries.toList();
        _sentPayloads.clear();
        _sentPayloads.addEntries(entries.skip(entries.length - 500));
        _log(
            "🧹 [Memory] Cleaned up _sentPayloads (kept last 500 of ${entries.length})");
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
        return latency.successfulLatencies.isEmpty &&
            latency.consecutiveFailures > 10;
      });

      // 🔥 GROSII: prune damping map so it does not grow if no signals received for long time
      _grosiiLastSeen.removeWhere((_, t) => now.difference(t).inSeconds > 60);

      _log(
          "🧹 [Memory] Cleaned up expired cooldowns, IP locks, timestamps, _sentPayloads, retry info, transport latencies, and Grosii damping");
    });

    // [ACTIVE-SYNC] Bounded periodic CRDT-only sync (no outbox cascade). First run after 1 min.
    Future.delayed(const Duration(minutes: 1), () {
      if (!_isMeshEnabled) return;
      _scheduleNextActiveSyncEpoch();
    });

    // 🔄 RELAY: периодическая проверка — стать релеятором (GHOST) или снять режим при отсутствии клиентов
    _relayCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!_isMeshEnabled) return;
      if (_isRelayMode) {
        stopRelayIfNoClients();
        return;
      }
      if (NetworkMonitor().currentRole == MeshRole.GHOST) {
        unawaited(tryBecomeRelay());
      }
    });

    // 🔥 СЛУШАТЕЛЬ SONAR: контракт — любой принятый сигнал = намёк, не факт доставки.
    // Beacon при приёме (если когда-либо декодируется) — только presence / lastSeen; не вызывать sendAuto, cascade, relay.
    locator<UltrasonicService>().sonarMessages.listen((signal) {
      _handleSonarSignal(signal);
    });
  }

  /// Обработка сигналов Sonar (контракт: Sonar = намёк, не факт доставки).
  ///
  /// Классификация префиксов:
  /// • GROSII: — excitation pulse (нервный импульс). НЕ payload, НЕ ACK. Только ускоряет scan/sendAuto с демпфированием.
  /// • Q:     — discovery / query (запрос «есть ли пакет по хешу»). Сейчас только лог; не рекомендуется расширять в сторону доставки.
  /// • REQ:   — bootstrap / handshake (запрос пакета по id). Инициирует попытку отправки по BLE/Wi‑Fi (архитектурно: должен быть только hint, см. TODO у _sendPacketOnRequest).
  /// • MSG:   — уведомление о наличии пакета (hash). Сейчас только лог; не рекомендуется использовать для gossip.
  /// • DATA:  — emergency signal (кусок данных). Обрабатывается как входящий пакет; Sonar не гарантирует доставку — возможны дубликаты/потери.
  void _handleSonarSignal(String signal) {
    final currentRole = NetworkMonitor().currentRole;
    final roleLabel = currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST';

    // 🔥 GROSII: excitation only — no payload, no ACK, no transport lock
    if (signal.startsWith("GROSII:")) {
      _handleGrosiiSignal(signal);
      return;
    }

    if (signal.startsWith("Q:")) {
      // discovery / query — только наблюдение
      final queryHash = signal.substring(2);
      _log("🔊 [Sonar] Packet query received: $queryHash");
      // TODO: Найти пакет по хешу и ответить
    } else if (signal.startsWith("REQ:")) {
      // bootstrap / handshake — сейчас напрямую вызывает _sendPacketOnRequest (идеально: только hint для существующей логики)
      final packetId = signal.substring(4);
      _log("🔊 [Sonar] Packet request received: $packetId");
      unawaited(_sendPacketOnRequest(packetId));
    } else if (signal.startsWith("MSG:")) {
      // уведомление о пакете — только наблюдение; не использовать для gossip
      final msgHash = signal.substring(4);
      _log("🔊 [Sonar] Packet notification: $msgHash");
      // TODO: Запросить пакет через BLE/Wi-Fi
    } else if (signal.startsWith("DATA:")) {
      // emergency signal — обрабатываем как пакет (Sonar не гарантирует доставку)
      final dataPayload = signal.substring(5); // Убираем префикс "DATA:"
      _log("🔊 [Sonar] Real data received: ${dataPayload.length} bytes");
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

  /// Отправляет пакет по запросу, инициированному Sonar (REQ:).
  /// 🔒 АРХИТЕКТУРА: Sonar-сигнал должен использоваться только как hint для уже существующей логики
  /// подключения, а не как прямой триггер доставки. TODO: заменить прямой вызов sendTcpBurst/BLE
  /// на установку hint (например lastSeen / «есть запрос»), чтобы попытку инициировала существующая
  /// логика cascade/scan, а не Sonar-обработчик.
  Future<void> _sendPacketOnRequest(String packetId) async {
    final pending = await _db.getPendingFromOutbox();
    final msg =
        pending.firstWhere((m) => m['id'] == packetId, orElse: () => {});

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
    final bluetoothNodes = _nearbyNodes.values
        .where((n) => n.type == SignalType.bluetooth)
        .toList();
    if (bluetoothNodes.isNotEmpty) {
      // TODO: Отправить через BLE GATT
      _log("🦷 [Sonar] Sending via BLE to ${bluetoothNodes.first.name}");
    }
  }

  /// 🔥 GROSII: excitation pulse handler. No payload, no ACK, no transport lock. Damping: TTL + per-id cooldown.
  void _handleGrosiiSignal(String signal) {
    // Format: GROSII:<id>:<hops>
    final parts = signal.split(":");
    if (parts.length < 3) {
      _log("🔊 [Grosii] Ignored (bad format)");
      return;
    }
    final id = parts[1].length > 8 ? parts[1].substring(0, 8) : parts[1];
    if (id.isEmpty) {
      _log("🔊 [Grosii] Ignored (empty id)");
      return;
    }
    final hops = int.tryParse(parts[2]) ?? 0;
    if (hops <= 0) {
      _log("🔊 [Grosii] Ignored (TTL expired, hops=$hops)");
      return;
    }
    final now = DateTime.now();
    final last = _grosiiLastSeen[id];
    if (last != null && now.difference(last).inSeconds < _grosiiCooldownSec) {
      _log("🔊 [Grosii] Ignored (cooldown, id=$id)");
      return;
    }
    _grosiiLastSeen[id] = now;
    // Prune old entries (keep map small)
    _grosiiLastSeen.removeWhere((_, t) => now.difference(t).inSeconds > 60);
    _log("🔊 [Grosii] Received (id=$id, hops=$hops) — excitation");
    print("🦠 [GROSII] Received id=$id hops=$hops — triggering scan");
    _onGrosiiExcitation();
    // Re-emit with TTL-1 (spread impulse, no payload)
    if (hops > 1) {
      final ultrasonic = locator<UltrasonicService>();
      if (!ultrasonic.isTransmitting) {
        unawaited(ultrasonic.transmitFrame("GROSII:$id:${hops - 1}"));
        _log("🔊 [Grosii] Relay (id=$id, hops→${hops - 1})");
        print("🦠 [GROSII] Relay id=$id hops→${hops - 1}");
      }
    }
  }

  /// 🔥 GROSII: excitation — hasten scan/sendAuto. Does NOT block transport; does NOT call sendAuto if transport busy.
  void _onGrosiiExcitation() {
    if (!locator.isRegistered<NetworkPhaseContext>()) return;
    if (!locator<NetworkPhaseContext>().allowsGrosii) return;
    if (NetworkMonitor().currentRole != MeshRole.GHOST) return;
    if (_isTransferring) {
      _log(
          "🔊 [Grosii] Transport busy — not triggering scan (excitation only)");
      return;
    }
    unawaited(_triggerAutoScanForOutbox());
    _log("🔊 [Grosii] Triggered scan (excitation)");
  }

  /// 🔥 GROSII: emit excitation pulse fire-and-forget. No payload. Does NOT wait for Sonar; if Sonar busy, skip.
  void _emitGrosiiPulse({int ttl = 2}) {
    if (!locator.isRegistered<NetworkPhaseContext>()) {
      print("🦠 [GROSII] SKIP — NetworkPhaseContext not registered");
      return;
    }
    if (!locator<NetworkPhaseContext>().allowsGrosii) {
      final phase = locator<NetworkPhaseContext>().phase;
      _log("[Grosii][SKIP] pulse skipped (phase=$phase)");
      print("🦠 [GROSII] SKIP — phase=$phase");
      return;
    }
    final ultrasonic = locator<UltrasonicService>();
    if (ultrasonic.isTransmitting) {
      _log("🔊 [Grosii] Skipped (Sonar busy)");
      print("🦠 [GROSII] SKIP — Sonar busy");
      return;
    }
    final id =
        DateTime.now().millisecondsSinceEpoch.toRadixString(16).substring(0, 4);
    final payload = "GROSII:$id:$ttl";
    unawaited(ultrasonic.transmitFrame(payload));
    _log("🔊 [Grosii] Emitted (id=$id, ttl=$ttl)");
    print("🦠 [GROSII] Emitted id=$id ttl=$ttl (Sonar pulse)");
  }

  GossipManager get _gossipManager => locator<GossipManager>();

  // 🛡️ ANTICENSORSHIP: Rotatable pseudonym for senderUsername (avoids fixed "Nomad" correlation)
  String? _senderPseudonym;
  DateTime? _senderPseudonymExpiry;
  static const Duration _senderPseudonymRotation = Duration(minutes: 20);
  String _getSenderPseudonym() {
    final now = DateTime.now();
    if (_senderPseudonym != null &&
        _senderPseudonymExpiry != null &&
        now.isBefore(_senderPseudonymExpiry!)) {
      return _senderPseudonym!;
    }
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = List.generate(
        6, (_) => chars[math.Random.secure().nextInt(chars.length)]).join();
    _senderPseudonym = 'Nmd_$suffix';
    _senderPseudonymExpiry = now.add(_senderPseudonymRotation);
    return _senderPseudonym!;
  }

  final BluetoothMeshService _btService = BluetoothMeshService();
  final ApiService _apiService = ApiService();
  final LocalDatabaseService _db = locator<LocalDatabaseService>();
  final math.Random _rng = math.Random(); // Добавь эту строку
  ApiService get apiService => _apiService;
  BluetoothMeshService get btService =>
      _btService; // 🔥 GOSSIP: Expose btService for relay
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
  DateTime? _transferStartTime; // 🔥 FIX: Track transfer start for timeout
  /// DTN: Number of cascades in progress. Observation only; must NOT block other candidates.
  int _cascadeInProgressCount = 0;

  /// DTN: BLE stack allows only one GATT send at a time; serialization, not global block.
  bool _bleSendInProgress = false;
  bool get isTransferring => _isTransferring;
  bool _isBtScanning = false;
  bool _p2pDiscoveryActive = false;
  Timer? _periodicDiscoveryTimer; // Таймер для периодического discovery
  /// [WIFI-GUARD] Last time a Wi-Fi Direct start (discovery or connect) was attempted. Used for 20s cooldown.
  DateTime? _lastWifiDirectAttemptTime;
  static const int _wifiDirectCooldownSec = 20;
  /// [WIFI] Connect-failed cooldown (CONNECT_FAILED code 0): no retry until this time. Huawei stabilization.
  DateTime? _wifiConnectFailedCooldownUntil;
  static const int _wifiConnectFailedCooldownSec = 20;
  /// [WIFI] Peer we are currently connected to (target address used when connect succeeded). For state-aware connect.
  String? _lastConnectedPeerAddress;
  /// [WIFI] Target address of the current connect attempt. Set when starting connect, cleared on success/failure.
  String? _connectTargetAddress;
  /// [WIFI] After disconnect, retry connect to this peer. Cleared when onDisconnected fires and we schedule retry.
  String? _pendingConnectAfterDisconnect;
  String? _pendingConnectNetworkName;
  String? _pendingConnectPassphrase;

  /// [MESH-HEALTH] Runtime-only score 0–100 for transport decision layer. Not persisted.
  int _meshHealthScore = _meshHealthDefault;
  DateTime? _meshHealthLastUpdate;
  static const int _meshHealthDefault = 70;
  static const double _meshHealthDecayPerMinute = 0.33;
  static const int _meshHealthMaxDeltaPerEvent = 20;
  int get meshHealthScore => _meshHealthScore;

  /// CRDT reconciliation (above transport). Lazy-init so sendToPeer can reference this.
  CrdtReconciliation? _crdt;
  CrdtReconciliation get _crdtOrCreate =>
      _crdt ??= CrdtReconciliation(
        sendToPeer: _sendToPeerForCrdt,
        log: _log,
        onDiffZero: _onCrdtDiffZero,
        onDiffNonZero: _onCrdtDiffNonZero,
      );

  void _onCrdtDiffZero(String peerAddress) {
    _recordCrdtSyncCompleted(peerAddress, hadDiff: false);
    _activeSyncLastCrdtSyncHadDiff = false;
    _btService.requestGracefulDisconnectForSync(peerAddress);
  }

  void _onCrdtDiffNonZero(String peerAddress) {
    _recordCrdtSyncCompleted(peerAddress, hadDiff: true);
    _activeSyncLastCrdtSyncHadDiff = true;
    _activeSyncIntervalMinutes = _activeSyncBaseIntervalMinutes;
    _relayWindowOpenUntil = DateTime.now().add(const Duration(seconds: 15));
    _relayConnectCountThisWindow = 0;
    _log('[ACTIVE-SYNC] Relay window opened 15s (diff>0 with ${maskMacForLog(peerAddress)})');
    Future.delayed(const Duration(seconds: _relayPauseBetweenConnectsSeconds), () {
      if (_relayWindowOpenUntil != null &&
          DateTime.now().isBefore(_relayWindowOpenUntil!) &&
          _relayConnectCountThisWindow < 1) {
        _tryRelayConnect();
      }
    });
  }

  void _recordCrdtSyncCompleted(String peerAddress, {required bool hadDiff}) {
    final now = DateTime.now();
    _lastCrdtSyncTime = now;
    _lastCrdtSyncPerPeer[peerAddress] = now;
  }

  // --- [ACTIVE-SYNC] Bounded periodic sync & relay (no FSM/role change) ---
  static const int _activeSyncBaseIntervalMinutes = 7;
  static const int _activeSyncMaxIntervalMinutes = 30;
  static const int _activeSyncMinMinutesSinceLastSync = 3;
  static const int _activeSyncSamePeerCooldownMinutes = 2;
  static const int _relayPauseBetweenConnectsSeconds = 2;
  DateTime? _lastCrdtSyncTime;
  final Map<String, DateTime> _lastCrdtSyncPerPeer = {};
  int _activeSyncIntervalMinutes = _activeSyncBaseIntervalMinutes;
  bool _activeSyncLastCrdtSyncHadDiff = false;
  Timer? _activeSyncEpochTimer;
  DateTime? _relayWindowOpenUntil;
  int _relayConnectCountThisWindow = 0;
  String? _lastActiveSyncPeer;
  DateTime? _lastActiveSyncPeerTime;
  bool _activeSyncEpochRunning = false;

  void _scheduleNextActiveSyncEpoch() {
    _activeSyncEpochTimer?.cancel();
    final interval = Duration(minutes: _activeSyncIntervalMinutes.clamp(
        _activeSyncBaseIntervalMinutes, _activeSyncMaxIntervalMinutes));
    _activeSyncEpochTimer = Timer(interval, () async {
      if (!_isMeshEnabled) return;
      await _tryActiveSyncEpoch();
      _scheduleNextActiveSyncEpoch();
    });
    _log('[ACTIVE-SYNC] Next epoch in ${_activeSyncIntervalMinutes} min');
  }

  Future<void> _tryActiveSyncEpoch() async {
    if (_activeSyncEpochRunning) return;
    if (NetworkMonitor().currentRole != MeshRole.GHOST) return;
    if (_btService.bleTransactionState != BleTransactionState.IDLE ||
        _btService.isGattConnecting) return;
    try {
      final battery = Battery();
      final level = await battery.batteryLevel;
      if (level < 15) {
        _log('[ACTIVE-SYNC] Skip: low battery $level%');
        return;
      }
    } catch (_) {}
    final now = DateTime.now();
    final lastSync = _lastCrdtSyncTime;
    if (lastSync != null &&
        now.difference(lastSync).inMinutes < _activeSyncMinMinutesSinceLastSync) {
      return;
    }
    final candidates = _getRecentVisiblePeersForActiveSync();
    if (candidates.isEmpty) return;
    final peerMac = _selectPeerForActiveSync(candidates, forRelay: false);
    if (peerMac == null) return;
    _activeSyncEpochRunning = true;
    try {
      _log('[ACTIVE-SYNC] Epoch: connecting to ${maskMacForLog(peerMac)} for CRDT-only');
      final device = BluetoothDevice.fromId(peerMac);
      final ok = await _btService.runCrdtOnlySession(device);
      _lastActiveSyncPeer = peerMac;
      _lastActiveSyncPeerTime = now;
      if (ok && !_activeSyncLastCrdtSyncHadDiff) {
        _activeSyncIntervalMinutes = (_activeSyncIntervalMinutes * 1.5)
            .ceil()
            .clamp(_activeSyncBaseIntervalMinutes, _activeSyncMaxIntervalMinutes);
        _log('[ACTIVE-SYNC] Diff=0 — backoff next interval to $_activeSyncIntervalMinutes min');
      } else if (ok) {
        _activeSyncIntervalMinutes = _activeSyncBaseIntervalMinutes;
      }
    } catch (e) {
      _log('[ACTIVE-SYNC] Epoch error: $e');
    } finally {
      _activeSyncEpochRunning = false;
    }
  }

  Future<void> _tryRelayConnect() async {
    if (_relayWindowOpenUntil == null ||
        DateTime.now().isAfter(_relayWindowOpenUntil!)) return;
    if (_relayConnectCountThisWindow >= 1) return;
    if (NetworkMonitor().currentRole != MeshRole.GHOST) return;
    if (_btService.bleTransactionState != BleTransactionState.IDLE ||
        _btService.isGattConnecting) return;
    final candidates = _getRecentVisiblePeersForActiveSync();
    final peerMac = _selectPeerForActiveSync(candidates, forRelay: true);
    if (peerMac == null) return;
    _relayConnectCountThisWindow++;
    _log('[ACTIVE-SYNC] Relay: 1 extra connect to ${maskMacForLog(peerMac)} (CRDT-only)');
    await Future.delayed(const Duration(seconds: _relayPauseBetweenConnectsSeconds));
    try {
      final device = BluetoothDevice.fromId(peerMac);
      await _btService.runCrdtOnlySession(device);
    } catch (e) {
      _log('[ACTIVE-SYNC] Relay error: $e');
    }
  }

  List<UplinkCandidate> _getRecentVisiblePeersForActiveSync() {
    const maxAge = Duration(minutes: 5);
    final now = DateTime.now();
    final ctx = locator<DiscoveryContextService>();
    final all = ctx.validCandidates;
    return all
        .where((c) =>
            c.mac.contains(':') &&
            now.difference(c.lastSeen).inMilliseconds < maxAge.inMilliseconds)
        .toList();
  }

  String? _selectPeerForActiveSync(List<UplinkCandidate> candidates,
      {required bool forRelay}) {
    final now = DateTime.now();
    final cooldown = Duration(minutes: _activeSyncSamePeerCooldownMinutes);
    final excluded = forRelay && _lastActiveSyncPeer != null
        ? _lastActiveSyncPeer!
        : null;
    int bestScore = -1;
    UplinkCandidate? best;
    for (final c in candidates) {
      if (excluded != null && c.mac == excluded) continue;
      if (_lastActiveSyncPeerTime != null &&
          c.mac == _lastActiveSyncPeer &&
          now.difference(_lastActiveSyncPeerTime!).inMilliseconds <
              cooldown.inMilliseconds) {
        continue;
      }
      final lastSyncWithPeer = _lastCrdtSyncPerPeer[c.mac];
      final minutesSinceSync = lastSyncWithPeer == null
          ? 999
          : now.difference(lastSyncWithPeer).inMinutes;
      int score = minutesSinceSync.clamp(0, 60);
      if (c.hasOutboxFlag) score += 10;
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best?.mac;
  }

  Future<void> _sendToPeerForCrdt(String peerAddress, String payloadJson) async {
    if (peerAddress.contains(':')) {
      // [ACTIVE-SYNC] When we are Central in a CRDT-only session, write to peer via characteristic.
      final written = await _btService.writeFromCentralToPeer(peerAddress, payloadJson);
      if (!written) {
        await _btService.sendMessageToGattClient(peerAddress, payloadJson);
      }
    } else if (peerAddress.contains('.')) {
      NativeMeshService.sendTcp(payloadJson, host: peerAddress);
    }
  }

  /// Start CRDT digest exchange (call after OUTBOX pull completes). Used by Wi-Fi and BLE.
  void startCrdtDigestExchange(String peerAddress) {
    if (peerAddress.isEmpty) return;
    unawaited(_crdtOrCreate.startDigestExchange(peerAddress));
  }

  /// Reset CRDT session for peer (call on transport disconnect so next meeting runs digest again).
  void resetCrdtSessionForPeer(String peerAddress) {
    _crdt?.resetSessionForPeer(peerAddress);
  }

  void _updateMeshHealthScore(int delta) {
    final now = DateTime.now();
    if (_meshHealthLastUpdate != null) {
      final minutes = now.difference(_meshHealthLastUpdate!).inMinutes;
      if (minutes > 0) {
        final decay = (minutes * _meshHealthDecayPerMinute).floor();
        _meshHealthScore = (_meshHealthScore - decay).clamp(0, 100);
      }
    }
    _meshHealthLastUpdate = now;
    final clampedDelta = delta.clamp(-_meshHealthMaxDeltaPerEvent, _meshHealthMaxDeltaPerEvent);
    _meshHealthScore = (_meshHealthScore + clampedDelta).clamp(0, 100);
    _log("[MESH-HEALTH] Score updated: $_meshHealthScore");
  }

  void reportMeshHealthBleConnectionSuccess() => _updateMeshHealthScore(10);
  void reportMeshHealthBleWriteSuccess() => _updateMeshHealthScore(5);
  void reportMeshHealthBleBusy() => _updateMeshHealthScore(-15);
  void reportMeshHealthBleDisconnect() => _updateMeshHealthScore(-20);
  void reportMeshHealthBlePassiveWindowOk() => _updateMeshHealthScore(5);
  void reportMeshHealthWifiConnectSuccess() => _updateMeshHealthScore(10);
  void reportMeshHealthWifiConnectFailed() => _updateMeshHealthScore(-15);
  void reportMeshHealthWifiCooldownTriggered() => _updateMeshHealthScore(-5);
  void reportMeshHealthWifiOutboxTransferSuccess() => _updateMeshHealthScore(10);

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
  final StreamController<String> _linkRequestController =
      StreamController.broadcast();
  Stream<String> get linkRequestStream => _linkRequestController.stream;

  final StreamController<List<SignalNode>> _discoveryController =
      StreamController.broadcast();
  Stream<List<SignalNode>> get discoveryStream => _discoveryController.stream;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  StreamController<Map<String, dynamic>> get messageController =>
      _messageController;

  // Хранение всех логов для копирования
  final List<String> _allLogs = [];
  static const int _maxLogs =
      10000; // 🔥 Увеличено до 10000 для полной диагностики передачи сообщений

  /// Единый порт Wi-Fi Direct TCP: BRIDGE слушает, GHOST шлёт. 55556 — на Huawei часто слушает только временный сервер.
  static const int meshTcpPort = 55556;

  /// Максимум записей при копировании в буфер обмена (избегает переполнения на Android)
  static const int kMaxLogsToCopy = 1300;

  /// Получить все логи для копирования
  List<String> getAllLogs() => List.unmodifiable(_allLogs);

  /// Получить логи для копирования — последние [kMaxLogsToCopy] записей (макс. 1300 для диагностики BLE/Wi‑Fi)
  String getAllLogsAsString() {
    if (_allLogs.length <= kMaxLogsToCopy) return _allLogs.join('\n');
    return _allLogs.sublist(_allLogs.length - kMaxLogsToCopy).join('\n');
  }

  /// Количество логов, которые будут скопированы (для SnackBar)
  int getLogsCopyCount() =>
      _allLogs.length <= kMaxLogsToCopy ? _allLogs.length : kMaxLogsToCopy;

  Timer? _cleanupTimer;
  bool _isP2pConnected = false;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  String get _baseUrl => SecurityConfig.backendBaseUrl;

  // 🔒 Fix memory leaks: Periodic cleanup timer for cooldowns and timestamps
  Timer? _memoryCleanupTimer;
  Timer? _relayCheckTimer;

  bool autoMesh = true;
  bool autoBT = true;
  bool _isMeshEnabled = true; // Главный тумблер всей системы связи
  bool _isPowerSaving = true;

  // Состояние "Магнита"
  int _myDistanceToBridge = 99; // 0 = инет есть, 1 = вижу инет, 99 = изоляция
  bool _isSearchingUplink = false;
  bool get isSearchingUplink => _isSearchingUplink;

  // 🔄 GHOST-RELAY: призрак поднимает GATT и принимает сообщения при отсутствии BRIDGE
  bool _isRelayMode = false;
  DateTime? _relayStartTime;
  DateTime? _relayLastNoClientTime; // когда последний раз не было клиентов
  DateTime? _relayElectionCooldownUntil; // не пытаться стать релеятором до этого времени
  DateTime? _relayFailedStartUntil; // после неудачного старта GATT не пробовать до этого времени
  static const int _relayNoBridgeSec = 90; // нет BRIDGE в контексте столько сек — можно стать релеятором
  static const int _relayNoClientStopSec = 180; // нет клиентов столько сек — снять режим релеятора
  static const int _relayFailedCooldownSec = 60; // после сбоя не пробовать столько сек
  static const int _relayElectionDelayMinSec = 10;
  static const int _relayElectionDelayRangeSec = 20; // задержка 10..30 сек по hash для tie-break
  bool get isRelayMode => _isRelayMode;

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
        _log(
            "🚜 [Legacy Path] NAN not supported. Using standard Wi-Fi Direct.");
        _startPeriodicDiscovery();
      }
    }

    if (autoBT) {
      _log("🦷 Engaging Bluetooth Control Plane...");
      startDiscovery(SignalType.bluetooth);
    }

    // 5. 🧹 MAINTENANCE: Очистка "призраков"
    _cleanupTimer?.cancel();
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _pruneDeadNodes());

    _log("✅ Grid Core is now autonomous.");
  }

  /// 🔄 Периодический discovery для экономии батареи
  /// Запускает discovery каждые 45 секунд на 15 секунд
  void _startPeriodicDiscovery() {
    _periodicDiscoveryTimer?.cancel();

    // Первый запуск сразу
    startDiscovery(SignalType.mesh);

    // Затем периодически: каждые 45 секунд запускаем discovery на 15 секунд
    _periodicDiscoveryTimer =
        Timer.periodic(const Duration(seconds: 45), (timer) async {
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
          _log(
              "⚠️ [Periodic] Discovery failed, retrying in ${retries * 2}s... (attempt $retries/$maxRetries)");
          await Future.delayed(Duration(seconds: retries * 2));
        } else {
          _log(
              "❌ [Periodic] Discovery failed after $maxRetries attempts, will retry next cycle");
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
    final timestamp =
        DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final fullMsg = "$timestamp > $msg";
    print("[Mesh Log] $msg");

    // Добавляем в _allLogs для копирования (в т.ч. строки с GATT 133)
    _allLogs.add(fullMsg);
    if (_allLogs.length > _maxLogs) _allLogs.removeAt(0);

    // Добавляем в поток для терминала
    _eventBus.bus.fire(StatusEvent(fullMsg));
    _statusController.add(fullMsg);

    notifyListeners();
  }

  Timer? _transferGuardTimer;

  Future<void> connectToNode(String address,
      {String? networkName, String? passphrase}) async {
    if (_isTransferring) {
      _log("⚠️ [Block] Connection already in progress. Wait for timeout.");
      return;
    }

    // [WIFI-GUARD] Block if BLE is active or conditions not met
    final guardStart = await _evaluateWifiDirectGuard();
    if (!guardStart.allowed) {
      _log("[WIFI-GUARD] Conditions evaluated");
      _log("[WIFI-GUARD] Blocked reason: ${guardStart.blockReason}");
      return;
    }
    if (_wifiConnectFailedCooldownUntil != null &&
        DateTime.now().isBefore(_wifiConnectFailedCooldownUntil!)) {
      _log("[WIFI] Cooldown active");
      return;
    }
    _log("[WIFI-GUARD] Conditions evaluated");
    _log("[WIFI] Connect approved by guard");
    _lastWifiDirectAttemptTime = DateTime.now();

    // Resolve passphrase/networkName from DiscoveryContext if not provided
    String? usePassphrase = passphrase;
    String? useNetworkName = networkName;
    if (usePassphrase == null || useNetworkName == null) {
      final candidate =
          locator<DiscoveryContextService>().getCandidateByMac(address);
      if (candidate != null) {
        usePassphrase ??= candidate.wifiDirectPassphrase;
        useNetworkName ??= candidate.wifiDirectNetworkName;
        if (usePassphrase != null && usePassphrase.isNotEmpty) {
          _log(
              "🔑 [WiFi-Direct] Using passphrase from DiscoveryContext for connect");
        }
      }
    }

    // 1) If already connected to this peer, do nothing
    if (_isP2pConnected && _lastConnectedPeerAddress == address) {
      _log("[WIFI] Already connected to peer");
      return;
    }

    // 2) If connected to a different peer: graceful disconnect, then retry after onDisconnected
    final groupInfo = await NativeMeshService.getWifiDirectGroupInfo();
    final hasGroup = groupInfo != null;
    _log("[WIFI] Connect attempt started");
    _log("[WIFI] Existing group state: ${hasGroup ? "exists" : "none"}");

    if (_isP2pConnected && _lastConnectedPeerAddress != null && _lastConnectedPeerAddress != address) {
      if (hasGroup) {
        _log("[WIFI] Graceful disconnect from old peer");
        _pendingConnectAfterDisconnect = address;
        _pendingConnectNetworkName = useNetworkName;
        _pendingConnectPassphrase = usePassphrase;
        await NativeMeshService.removeWifiDirectGroup();
      }
      return;
    }

    _log("[WIFI] No reset required");
    _isTransferring = true;
    _connectTargetAddress = address;
    _transferStartTime = DateTime.now();
    notifyListeners();

    _transferGuardTimer?.cancel();
    _transferGuardTimer = Timer(const Duration(seconds: 20), () {
      if (_isTransferring && !_isP2pConnected) {
        _log("🚨 [WATCHDOG] Connection timed out. Resetting local state.");
        _isTransferring = false;
        _connectTargetAddress = null;
        notifyListeners();
      }
    });

    try {
      // [WIFI-GUARD] BLE has priority: abort Wi-Fi connect only if BLE became active
      final guardBeforeConnect = await _evaluateWifiDirectGuard();
      if (!guardBeforeConnect.allowed) {
        _log("[WIFI] Aborted due to BLE activity");
        _isTransferring = false;
        _transferGuardTimer?.cancel();
        _connectTargetAddress = null;
        notifyListeners();
        return;
      }

      _log(
          "🔗 Engaging Native Connect for $address${usePassphrase != null ? ' (with passphrase)' : ''}");
      await NativeMeshService.connect(address,
          networkName: useNetworkName, passphrase: usePassphrase);
    } catch (e) {
      _log("❌ [Link Fault] $e");
      _isTransferring = false;
      _transferGuardTimer?.cancel();
      _connectTargetAddress = null;
      notifyListeners();
    }
  }

  Future<void> engageSuperiorLink(SignalNode node) async {
    final caps = await NativeMeshService.getHardwareCapabilities();

    if (caps['hasAware'] == true) {
      // 🚀 ВАРИАНТ А: Wi-Fi Aware (NAN)
      // Никаких окон! Полный стелс и авто-линк.
      _log(
          "💎 [Ultra-Link] Hardware supports NAN. Activating Silent Bridge...");
      await NativeMeshService.startAwareSession(node.id);
    } else {
      // 🚜 ВАРИАНТ Б: Wi-Fi Direct
      // Фолбек для старых/дешевых устройств. Будет окно.
      _log(
          "🚜 [Legacy-Link] NAN not supported. Falling back to Wi-Fi Direct...");
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
          [amount]);
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

  // 🔥 ОБНОВЛЯЕМ ЭТОТ МЕТОД: Он теперь "авто-киллер" + магнитное подключение
  void handleNativePeers(List<dynamic> raw) {
    final currentRole = NetworkMonitor().currentRole;
    final isBridge = currentRole == MeshRole.BRIDGE;
    final isGhost = currentRole == MeshRole.GHOST;

    for (var item in raw) {
      final String addr = item['metadata'] ?? item['address'] ?? "";
      final String name = item['name'] ?? "WiFi_Node";
      if (addr.isEmpty) continue;

      // Регистрируем в UI только Wi-Fi ноды
      _registerNode(SignalNode(
          id: addr, name: name, type: SignalType.mesh, metadata: addr));

      // 🔥 МАГНИТНОЕ ПОДКЛЮЧЕНИЕ: Автоматическое соединение GHOST → BRIDGE
      // Если мы GHOST и видим mesh устройство - подключаемся
      // (Wi-Fi Direct discovery уже запускается только когда есть pending messages)
      if (isGhost && !_isP2pConnected && !_isTransferring) {
        _log("🧲 [Wi-Fi Direct] GHOST detected Wi-Fi peer: $name ($addr)");
        _log("   📋 Initiating automatic Wi-Fi Direct connection...");
        connectToNode(addr);
      } else if (isBridge && !_isP2pConnected) {
        // BRIDGE пассивно ждёт подключений, но логируем обнаружение
        _log("🌉 [Wi-Fi Direct] BRIDGE detected Wi-Fi peer: $name ($addr)");
        _log("   📋 Waiting for incoming connection (passive mode)");
      }

      // Если мы в режиме "Охоты" - цепляемся за первую же Wi-Fi ноду
      if (_isEscalating && !_isP2pConnected && !_isTransferring) {
        _log("🏹 Hunt Success: Found Wi-Fi target. Executing Link...");
        connectToNode(addr);
      }
    }
  }

  /// Returns local BLE adapter MAC for tie-breaker (lower MAC = PERIPHERAL). Null if unavailable (fallback to token).
  Future<String?> _getMyBleMacForTieBreaker() async {
    try {
      if (Platform.isAndroid) {
        final mac = await MethodChannel('memento/gatt_server')
            .invokeMethod<String>('getLocalBluetoothAddress');
        return mac;
      }
    } catch (_) {}
    return null;
  }

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
    _transferStartTime = DateTime.now(); // 🔥 FIX: Track start time
    _log("⛓️ Starting Cascade: Wi-Fi -> BLE -> Sonar");

    // --- СТУПЕНЬ 1: WI-FI DIRECT (DATA PLANE) ---
    _log("📡 Stage 1: Attempting Wi-Fi Direct...");
    try {
      final candidate =
          locator<DiscoveryContextService>().getCandidateByMac(mac);
      final passphrase = candidate?.wifiDirectPassphrase;
      final networkName = candidate?.wifiDirectNetworkName;
      if (passphrase != null && passphrase.isNotEmpty) {
        _log("   🔑 Using passphrase from DiscoveryContext for Wi-Fi Direct");
      }
      await NativeMeshService.connect(mac,
          networkName: networkName, passphrase: passphrase);

      // Ждем 10 секунд. Если onNetworkConnected не сработал - Wi-Fi мертв.
      await Future.delayed(const Duration(seconds: 10));
      if (_isP2pConnected) {
        _log("✅ Stage 1 Success: Wi-Fi Direct Linked.");
        _isTransferring = false; // 🔥 FIX: Reset on success!
        notifyListeners();
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
        _isTransferring = false; // 🔥 FIX: Reset on success!
        notifyListeners();
        return;
      } catch (e) {
        _log("⚠️ Stage 2 Failed: GATT 133 or Timeout.");
      }
    }

    // --- СТУПЕНЬ 3: SONAR (ACOUSTIC PLANE) ---
    if (!_isP2pConnected) {
      _log("🔊 Stage 3: Radio silence detected. Escalating to SONAR...");

      try {
        // 🔥 FIX: Sonar отправляет только REQ (запрос), не реальные данные
        // Это сигнал для BRIDGE, что у GHOST есть сообщения для отправки
        // НЕ удаляем из outbox - Sonar только запрос, не доставка
        final msgId = msgData['id'] as String;
        await locator<UltrasonicService>().transmitFrame(
            "REQ:${msgId.substring(0, msgId.length > 8 ? 8 : msgId.length)}");
        _log("✅ Stage 3 Success: Sonar REQ emitted (message ID: $msgId)");
        _log(
            "   📦 Message NOT removed from outbox - waiting for delivery via BLE/TCP");
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
      _log(
          "🚨 TOTAL RADIO SILENCE DETECTED. Escalating to Acoustic Sovereignty...");
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
    final sonar = locator<UltrasonicService>();
    // Ghost: senderId from ApiService when registered, else from Vault
    final String senderId = locator.isRegistered<ApiService>()
        ? locator<ApiService>().meshSenderId
        : (await getCurrentUserIdSafe());

    // 1. УНИФИКАЦИЯ ID: Гарантируем работу через системный Маяк
    final String targetId =
        (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL" || chatId == null)
            ? "THE_BEACON_GLOBAL"
            : chatId;

    print(
        "📤 [SEND] === sendAuto START === target=$targetId length=${content.length}");
    _log(
        "[OUTBOX] sendAuto entered: target=$targetId role=${currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST'} messageId=${messageId ?? 'null'}");
    _log("🚀 Initiating Multi-Channel Uplink for: $targetId");
    _log("📤 [SEND-AUTO] Starting message send:");
    _log("   📋 Content length: ${content.length} chars");
    _log("   📋 Target: $targetId");
    _log("   📋 Receiver: $receiverName");
    _log("   📋 Message ID: ${messageId ?? 'temp (will be generated)'}");

    // 2. КРИПТОГРАФИЯ: Готовим зашифрованный пакет (E2EE)
    final key = await encryption.getChatKey(targetId);
    final encryptedContent = await encryption.encrypt(content, key);
    final String tempId =
        messageId ?? "temp_${DateTime.now().millisecondsSinceEpoch}";
    // Контракт порядка: ts — время создания сообщения, не меняется при ретрансляции
    final int ts = DateTime.now().millisecondsSinceEpoch;
    _log("🔐 [SEND-AUTO] Message encrypted, tempId: $tempId");

    // 🛡️ ANTICENSORSHIP: ephemeral senderId when ApiService; else Ghost id from Vault
    final offlinePacket = jsonEncode({
      'type': 'OFFLINE_MSG',
      'chatId': targetId,
      'content': encryptedContent,
      'isEncrypted': true,
      'senderId': senderId.isNotEmpty ? senderId : "GHOST_NODE",
      'senderUsername':
          _getSenderPseudonym(), // 🛡️ ANTICENSORSHIP: rotatable pseudonym
      'timestamp': ts,
      'ts': ts, // Канонический timestamp создания (mesh-контракт)
      'clientTempId': tempId,
      'h': tempId,
      'ttl': 5, // Начальный TTL для Gossip-паутины
    });

    bool messageDeliveredToNetwork = false;
    bool messageDeliveredToParticipants = false;
    final db = LocalDatabaseService();

    // ==========================================
    // [ROUTER] Resolve exactly ONE delivery path per message.
    // ==========================================
    final bool isEmergency = content.toUpperCase().contains("SOS") ||
        targetId == "THE_BEACON_GLOBAL";
    final routingCtx = MessageRoutingContext(
      targetId: targetId,
      messageId: messageId ?? tempId,
      isEmergency: isEmergency,
      preferOfflineMode: _preferOfflineMode,
    );
    final deliveryPath = MessageRouter.resolvePath(routingCtx);
    _log("[ROUTER] Resolved path: $deliveryPath for $targetId");

    // ==========================================
    // 🛰️ КАНАЛ 0: ROUTER (Wi-Fi Router) — backendDirect only
    // ==========================================
    final routerConnection = RouterConnectionService();
    final connectedRouter = routerConnection.connectedRouter;
    if (connectedRouter != null && connectedRouter.hasInternet) {
      if (!MessageRouter.allowsBackend(deliveryPath)) {
        _log(
            "[ROUTER][SKIP] Channel 0 Router: path=$deliveryPath (backend not allowed)");
      } else {
        try {
          _log("📤 [SEND-AUTO] Channel 0: Router (${connectedRouter.ssid})");
          _log(
              "🛰️ Router: Attempting transmission via ${connectedRouter.ssid}...");
          if (locator.isRegistered<ApiService>()) {
            unawaited(locator<ApiService>().fetchEphemeralTokenIfNeeded());
          }
          await WebSocketService().ensureConnected();
          await WebSocketService().send({
            "type": "message",
            "chatId": targetId,
            "content": encryptedContent,
            "isEncrypted": true,
            "clientTempId": tempId,
          });
          _log("🛰️ Router: Signal delivered via router to Cloud.");
          messageDeliveredToNetwork = true;
          messageDeliveredToParticipants = true;
        } catch (e) {
          _log("⚠️ Router: Transmission failed: $e");
        }
      }
    }

    // ==========================================
    // 🌐 КАНАЛ 1: CLOUD (Uplink) — backendDirect only
    // ==========================================
    if (connectedRouter == null && MessageRouter.allowsBackend(deliveryPath)) {
      try {
        _log("📤 [SEND-AUTO] Channel 1: Cloud (BRIDGE mode)");
        if (locator.isRegistered<ApiService>()) {
          unawaited(locator<ApiService>().fetchEphemeralTokenIfNeeded());
        }
        await WebSocketService().ensureConnected();
        await WebSocketService().send({
          "type": "message",
          "chatId": targetId,
          "content": encryptedContent,
          "isEncrypted": true,
          "clientTempId": tempId,
        });
        _log("☁️ Cloud: Signal delivered to Command Center.");
        messageDeliveredToNetwork = true;
        messageDeliveredToParticipants = true;
      } catch (e) {
        _log("⚠️ Cloud: Relay failed: $e");
      }
    } else if (connectedRouter == null &&
        deliveryPath != DeliveryPath.backendDirect) {
      _log("[ROUTER][SKIP] Channel 1 Cloud: path=$deliveryPath");
    }

    final bluetoothNodes = _nearbyNodes.values
        .where((n) => n.type == SignalType.bluetooth)
        .toList();
    // ==========================================
    // 🦷 КАНАЛ 3 / Channel 2: BLE & Wi-Fi Direct — meshDtn only
    // ==========================================
    if (!MessageRouter.allowsMeshDtn(deliveryPath)) {
      _log(
          "[ROUTER][SKIP] Channel 2/3 (BLE, Wi-Fi Direct): path=$deliveryPath (mesh not selected)");
    } else {
      final hardwareCheck = HardwareCheckService();
      final bleFirst = await hardwareCheck.preferBleOverWifi();

      Future<void> _sendViaBle() async {
        if (bluetoothNodes.isEmpty) {
          _log("⏸️ [SEND-AUTO] Channel 3: Bluetooth - no BLE nodes available");
          return;
        }
        _log(
            "📤 [SEND-AUTO] Channel 3: Bluetooth BLE (${bluetoothNodes.length} node(s))");
        _log(
            "🦷 BT: Injecting packet into Serial Queue for ${bluetoothNodes.length} nodes.");
        for (var node in bluetoothNodes) {
          final macForBle =
              node.metadata.contains(':') ? node.metadata : node.id;
          _log(
              "   📤 [SEND-AUTO] Queuing message to BLE node: ${node.name} (${maskMacForLog(macForBle)})");
          _btService.sendMessage(
              BluetoothDevice.fromId(macForBle), offlinePacket);
        }
        _log("✅ [SEND-AUTO] Channel 3: All BLE messages queued");
      }

      /// [WIFI-PULL] Wi-Fi does not push outbox; only responds to OUTBOX_REQUEST. Same as BLE philosophy.
      Future<bool> _sendViaWifi() async {
        _log(
            "   📋 [Channel 2] _isP2pConnected=$_isP2pConnected isRouteReady=$isRouteReady");
        if (!_isP2pConnected || !isRouteReady) {
          if (_isP2pConnected && !isRouteReady)
            _log("⏳ Mesh: Link detected but route warming up. Skipping TCP.");
          return false;
        }
        _log("   📋 [SEND-AUTO] Channel 2: Wi-Fi is pull-only (no auto-push); outbox via OUTBOX_REQUEST only");
        return false;
      }

      // 🔒 DEDUP: GHOST не ставит сообщения в BLE-очередь из sendAuto — только каскад отправляет по BLE.
      // Иначе одно и то же сообщение уходит и из sendAuto, и из каскада → дубликат у получателя.
      final bool skipBleInSendAuto = currentRole == MeshRole.GHOST;
      if (bleFirst) {
        _log("   📋 [HW] BLE-first mode (weak Wi-Fi Direct hardware)");
        if (!skipBleInSendAuto) {
          await _sendViaBle();
          if (bluetoothNodes.isNotEmpty) messageDeliveredToNetwork = true;
        } else {
          _log("   📋 [SEND-AUTO] GHOST: BLE left to cascade only (avoid duplicate)");
        }
        if (await _sendViaWifi()) messageDeliveredToNetwork = true;
      } else {
        if (await _sendViaWifi()) messageDeliveredToNetwork = true;
        if (!skipBleInSendAuto) {
          await _sendViaBle();
          if (bluetoothNodes.isNotEmpty) messageDeliveredToNetwork = true;
        } else {
          _log("   📋 [SEND-AUTO] GHOST: BLE left to cascade only (avoid duplicate)");
        }
      }

      // GHOST via Router (same LAN): когда нет Wi-Fi Direct, пробуем TCP по подсети к BRIDGE
      if (currentRole == MeshRole.GHOST && !_isP2pConnected) {
        final routerConnection = RouterConnectionService();
        final connectedRouter = routerConnection.connectedRouter;
        if (connectedRouter != null) {
          unawaited(_tryGhostViaRouter(offlinePacket));
        }
      }
    }

    // Обновляем статус сообщения
    if (messageId != null) {
      if (messageDeliveredToParticipants) {
        await db.updateMessageStatus(
            messageId, MessageStatus.deliveredToParticipants);
      } else if (messageDeliveredToNetwork) {
        await db.updateMessageStatus(
            messageId, MessageStatus.deliveredToNetwork);
      }
    }

    // ==========================================
    // 🔊 КАНАЛ 4: SONAR (Acoustic Backup) — meshDtn only
    // ==========================================
    if (MessageRouter.allowsMeshDtn(deliveryPath) &&
        (routingCtx.isEmergency || content.length < 64)) {
      _log("📤 [SEND-AUTO] Channel 4: Sonar (ultrasonic)");
      _log(
          "   📋 Emergency: ${routingCtx.isEmergency}, Content length: ${content.length} chars");
      _log("🔊 Sonar: Escalating to Acoustic Link...");
      unawaited(sonar.transmitFrame(content));
      _log("✅ [SEND-AUTO] Channel 4: Sonar transmission initiated");
    } else {
      _log("⏸️ [SEND-AUTO] Channel 4: Sonar - skipped (path or length)");
    }

    // 🔒 EVOLUTION: наблюдение за каналами (только лог, не меняет решений)
    final channelsUsed = <String>[];
    if (messageDeliveredToParticipants) channelsUsed.add('Cloud');
    if (_isP2pConnected && isRouteReady) channelsUsed.add('WiFiDirect');
    if (bluetoothNodes.isNotEmpty) channelsUsed.add('BLE');
    if (routingCtx.isEmergency || content.length < 64)
      channelsUsed.add('Sonar');
    _observeSendAutoChannelsUsed(channelsUsed);
    _logShadowChannelPreference(bluetoothNodes);

    // 3. ИНКУБАЦИЯ: Сохраняем в Outbox (Для Gossip-паутины)
    // Если мы GHOST или линк нестабилен, сообщение должно "жить" в БД
    // Статус уже установлен в conversation_screen.dart, здесь только сохраняем если нужно
    if (messageId == null) {
      final myMsg = ChatMessage(
          id: tempId,
          content: content,
          senderId: senderId,
          createdAt: DateTime.now(),
          status: messageDeliveredToNetwork
              ? MessageStatus.deliveredToNetwork
              : MessageStatus.sending);

      await db.saveMessage(myMsg, targetId);

      if (currentRole == MeshRole.GHOST) {
        // 🛡️ ANTICENSORSHIP: store encrypted + ephemeral senderId in outbox
        final myMsgEncrypted = ChatMessage(
            id: tempId,
            content: encryptedContent,
            senderId: senderId,
            createdAt: DateTime.now(),
            status: messageDeliveredToNetwork
                ? MessageStatus.deliveredToNetwork
                : MessageStatus.sending);
        await db.addToOutbox(myMsgEncrypted, targetId,
            contentAlreadyEncrypted: true);
        _log("🦠 Virus: Signal incubated in Outbox.");
        _log("[OUTBOX] Message added to outbox (GHOST, messageId=null). id=$tempId");

        // 🔥 FIX: Автоматический триггер scan при добавлении сообщения в outbox
        // Это гарантирует, что GHOST начнет искать BRIDGE сразу после отправки сообщения
        _log(
            "🔍 [AUTO-TRIGGER] Message added to outbox - triggering automatic scan...");
        unawaited(_triggerAutoScanForOutbox());
      }
    } else if (currentRole == MeshRole.GHOST && !messageDeliveredToNetwork) {
      // Если сообщение еще не доставлено и мы GHOST - добавляем в outbox
      // 🛡️ ANTICENSORSHIP: store encrypted + ephemeral senderId in outbox
      final myMsgEncrypted = ChatMessage(
          id: tempId,
          content: encryptedContent,
          senderId: senderId,
          createdAt: DateTime.now(),
          status: MessageStatus.sending);
      await db.addToOutbox(myMsgEncrypted, targetId,
          contentAlreadyEncrypted: true);
      _log("🦠 Virus: Signal incubated in Outbox.");
      _log("[OUTBOX] Message added to outbox (GHOST, not delivered). id=$tempId");
      print(
          "📤 [SEND] Message in outbox (GHOST, not delivered) → triggering auto-scan + Grosii");

      // 🔥 FIX: Автоматический триггер scan при добавлении сообщения в outbox
      _log(
          "🔍 [AUTO-TRIGGER] Message added to outbox - triggering automatic scan...");
      unawaited(_triggerAutoScanForOutbox());
    }

    // 📊 ИТОГОВОЕ ЛОГИРОВАНИЕ: Результат отправки через все каналы
    print(
        "📤 [SEND] === sendAuto DONE === delivered=$messageDeliveredToNetwork role=${currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST'}");
    _log("📊 [SEND-AUTO] Send summary:");
    _log("   ✅ Delivered to network: $messageDeliveredToNetwork");
    _log("   ✅ Delivered to participants: $messageDeliveredToParticipants");
    _log("   📋 Message ID: $tempId");
    _log("   📋 Target: $targetId");
    _log("   📋 Role: ${currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST'}");
    if (messageDeliveredToNetwork || messageDeliveredToParticipants) {
      _log("✅ [SEND-AUTO] Message sent successfully via at least one channel");

      // 🔥 GOSSIP RELAY: BRIDGE должен ретранслировать сообщения GHOST устройствам
      // Это позволяет GHOST получать сообщения даже без прямого подключения к Cloud
      if (currentRole == MeshRole.BRIDGE) {
        try {
          final gossip = locator<GossipManager>();
          final packetData = jsonDecode(offlinePacket) as Map<String, dynamic>;
          packetData['h'] = tempId; // Убеждаемся что packetId установлен
          _log("🔄 [GOSSIP] BRIDGE initiating relay to GHOST devices...");
          unawaited(gossip.attemptRelay(packetData));
          _log(
              "✅ [GOSSIP] Relay initiated - message will be broadcast to nearby GHOST devices");
        } catch (e) {
          _log("⚠️ [GOSSIP] Failed to initiate relay: $e");
        }
      }
    } else {
      _log("⚠️ [SEND-AUTO] Message queued in outbox (no channels available)");
    }
  }

  /// 🔒 EVOLUTION: наблюдение — какие каналы были задействованы в sendAuto (только лог).
  void _observeSendAutoChannelsUsed(List<String> channelsUsed) {
    if (channelsUsed.isEmpty) return;
    _log("   📋 [OBSERVE] sendAuto used channels: ${channelsUsed.join(', ')}");
  }

  /// 🔒 EVOLUTION: теневая оценка — что бы память предложила (только лог, не влияет на выбор канала).
  void _logShadowChannelPreference(List<SignalNode> bluetoothNodes) {
    try {
      final peerCache = locator<PeerCacheService>();
      final peerId = bluetoothNodes.isNotEmpty
          ? bluetoothNodes.first.id
          : (_lastKnownPeerIp.isNotEmpty ? _lastKnownPeerIp : null);
      if (peerId == null) return;
      final metrics = peerCache.getPeer(peerId);
      final preferred = metrics?.bestChannel;
      if (preferred != null) {
        _log("   📋 [SHADOW] memory would prefer channel: $preferred");
      }
    } catch (_) {}
  }

  /// 🔒 EVOLUTION (Вариант A): задержка в мс перед попыткой Wi-Fi Direct, если по PeerCache у peer/channel плохая история.
  /// Не отключает канал, не меняет порядок. Используется только для замедления повторной попытки. BLE не трогаем.
  int _getWifiDirectSoftCooldownMs() {
    if (!kSendAutoWifiDirectSoftCooldownEnabled) return 0;
    if (_lastKnownPeerIp.isEmpty) return 0;
    try {
      final peerCache = locator<PeerCacheService>();
      final metrics = peerCache.getPeer(_lastKnownPeerIp);
      final stats = metrics?.channelStats['wifiDirect'];
      if (stats == null || stats.attempts < 2) return 0;
      if (stats.successRate >= 0.5) return 0;
      // Мягкая задержка: чем ниже successRate, тем дольше пауза (в пределах clamp).
      final rawMs = (1.0 - stats.successRate) * 1000.0;
      final clamped = rawMs.clamp(
        kSendAutoWifiDirectCooldownMinMs.toDouble(),
        kSendAutoWifiDirectCooldownMaxMs.toDouble(),
      );
      return clamped.round();
    } catch (_) {
      return 0;
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

    // 2. Подготовка поискового сигнала (Ghost: senderId без ApiService)
    final senderId = locator.isRegistered<ApiService>()
        ? locator<ApiService>().currentUserId
        : (await getCurrentUserIdSafe());
    final probe = jsonEncode({
      'type': 'MAGNET_QUERY',
      'senderId': senderId.isNotEmpty ? senderId : 'GHOST_NODE',
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

  // 🔥 FIX: Автоматический триггер scan при добавлении сообщения в outbox
  /// Запускает автоматический scan для поиска BRIDGE, если есть pending сообщения
  /// 🔥 FIX: Работает даже когда transfer в процессе (ставит в очередь для запуска после завершения)
  Future<void> _triggerAutoScanForOutbox() async {
    // Проверяем, что мы GHOST
    if (NetworkMonitor().currentRole != MeshRole.GHOST) {
      print("📤 [SEND] AUTO-TRIGGER skip — not GHOST");
      return;
    }

    // Небольшая задержка, чтобы дать время для добавления сообщения в БД
    await Future.delayed(const Duration(milliseconds: 500));

    // Проверяем, есть ли pending сообщения
    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) {
      _log("ℹ️ [AUTO-TRIGGER] No pending messages - skipping scan");
      print("📤 [SEND] AUTO-TRIGGER skip — no pending in outbox");
      return;
    }

    // 🔒 BLE BACKPRESSURE: No scan while a BLE transaction is active (single FSM).
    if (_btService.bleTransactionState != BleTransactionState.IDLE) {
      _log(
          "⏸️ [AUTO-TRIGGER] Scan deferred: BLE transaction active (${_btService.bleTransactionState}) - will retry in 4s");
      _log("[BLE-BLOCK] AUTO-TRIGGER deferred — BLE FSM not IDLE");
      print("📤 [SEND] AUTO-TRIGGER deferred — BLE busy, retry in 4s");
      Future.delayed(const Duration(seconds: 4), () {
        unawaited(_triggerAutoScanForOutbox());
      });
      return;
    }

    // DTN: Do NOT globally block on _isTransferring. Prefer duplication over loss; any Ghost may try any Bridge.
    if (_isBtScanning) {
      _log(
          "⏸️ [AUTO-TRIGGER] Scan deferred: BLE scan already active - will retry in 4s");
      print("📤 [SEND] AUTO-TRIGGER deferred — BLE scan active, retry in 4s");
      Future.delayed(const Duration(seconds: 4), () {
        unawaited(_triggerAutoScanForOutbox());
      });
      return;
    }

    _log(
        "🚀 [AUTO-TRIGGER] Found ${pending.length} pending message(s) - starting automatic scan...");
    print(
        "📤 [SEND] AUTO-TRIGGER: ${pending.length} pending → Grosii pulse + seekInternetUplink");

    // 🔥 GROSII: excitation pulse (fire-and-forget, no transport lock). Spreads "activity" in network.
    _emitGrosiiPulse(ttl: _grosiiTtlHops);

    // Запускаем seekInternetUplink, который вызовет scan и проверку outbox
    unawaited(seekInternetUplink());
  }

  /// Публичный вызов: запросить автоскан для outbox (например из UI после добавления в outbox при ошибке отправки).
  void requestAutoScanForOutbox() {
    unawaited(_triggerAutoScanForOutbox());
  }

  // --- СЕТЕВАЯ ЛОГИКА ---

  /// [WIFI-GUARD] Evaluates whether Wi-Fi Direct may start/run. BLE always has priority.
  /// [requirePendingAndCooldown] when true (discovery/connect): also block on zero pending and 20s cooldown.
  /// [MESH-HEALTH] Score influences: recovery (<20), prefer BLE (≥70 = large payload only), escalation (<40).
  Future<({bool allowed, String? blockReason})> _evaluateWifiDirectGuard(
      {bool requirePendingAndCooldown = true}) async {
    final score = _meshHealthScore;

    // Active BLE GATT connection (server or client) or BLE transaction in progress
    if (_btService.isInGattLifecycle) {
      return (allowed: false, blockReason: 'active BLE GATT session');
    }
    if (_btService.bleTransactionState != BleTransactionState.IDLE) {
      return (allowed: false, blockReason: 'BLE transfer in progress');
    }
    if (!_btService.canStartScan) {
      return (allowed: false, blockReason: 'BLE GATT session or scan blocked');
    }
    if (FlutterBluePlus.isScanningNow) {
      return (allowed: false, blockReason: 'BLE scan running');
    }
    if (!requirePendingAndCooldown) return (allowed: true, blockReason: null);

    // [MESH-HEALTH] Recovery mode: do not spam reconnect
    if (score < 20) {
      _log("[MESH-HEALTH] Recovery mode");
      return (allowed: false, blockReason: 'recovery mode (score < 20)');
    }

    final pendingCount = await _db.getOutboxCount();
    if (pendingCount == 0) {
      return (allowed: false, blockReason: 'zero pending messages for large transport');
    }

    // [MESH-HEALTH] Score ≥ 70: prefer BLE, Wi-Fi only for large payload
    if (score >= 70) {
      if (pendingCount < 2) {
        _log("[MESH-HEALTH] BLE stable");
        return (allowed: false, blockReason: 'large payload required when BLE stable');
      }
    } else if (score < 40) {
      _log("[MESH-HEALTH] BLE unstable");
      _log("[MESH-HEALTH] Wi-Fi escalation allowed");
    }

    if (_lastWifiDirectAttemptTime != null) {
      final elapsed = DateTime.now().difference(_lastWifiDirectAttemptTime!).inSeconds;
      if (elapsed < _wifiDirectCooldownSec) {
        return (allowed: false, blockReason: 'Wi-Fi cooldown (${_wifiDirectCooldownSec}s)');
      }
    }
    return (allowed: true, blockReason: null);
  }

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

    if (type == SignalType.mesh || type == SignalType.wifiDirect) {
      if (!locator.isRegistered<NetworkPhaseContext>()) return false;
      final phaseCtx = locator<NetworkPhaseContext>();
      if (!phaseCtx.allowsWifiDirectSetup) {
        _log("[WiFi-Direct][SKIP] discovery skipped (phase=${phaseCtx.phase})");
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

      // [WIFI-GUARD] Block Wi-Fi Direct if BLE is active or transport conditions not met
      final guard = await _evaluateWifiDirectGuard();
      if (!guard.allowed) {
        _log("[WIFI-GUARD] Conditions evaluated");
        _log("[WIFI-GUARD] Blocked reason: ${guard.blockReason}");
        return false;
      }
      _log("[WIFI-GUARD] Conditions evaluated");
      _log("[WIFI-GUARD] Approved → Starting Wi-Fi Direct");
      _lastWifiDirectAttemptTime = DateTime.now();

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
        _log(
            "☢️ [P2P-CRITICAL] Stack Deadlock detected (Error 2). Executing Force Reset...");
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
            metadata: 'STABLE'));
      }
    } catch (e) {
      _log("❌ Cloud frequency scan failed.");
    }
  }

  // 🔥 GROSII: excitation pulse (signal, not transport). Damping state.
  static const int _grosiiTtlHops = 2;
  static const int _grosiiCooldownSec = 8;
  final Map<String, DateTime> _grosiiLastSeen =
      {}; // id -> last reaction (for damping)

  // Добавь это поле в начало класса MeshService для контроля повторных попыток
  // 🔥 FIX: Cooldown по ТОКЕНУ, а не по MAC (из-за MAC rotation на Android)
  final Map<String, DateTime> _linkCooldowns = {};

  // 🔥 FIX: Маппинг token → последний известный MAC (для логирования)
  final Map<String, String> _tokenToMacMapping = {};

  // 🔥 AUDIT FIX: Timing constants для согласования cooldown и GATT timeout
  // 🔥 FIX: Cooldown уменьшен до 20s (было 45s - слишком блокировало попытки)
  // Cooldown теперь ставится ТОЛЬКО после НЕУДАЧНОЙ попытки, не до!
  static const int _defaultCooldownSeconds = 20; // Уменьшено с 45 до 20
  static const int _quickRescanDurationSeconds = 5; // Увеличено с 3 до 5
  static const Duration _scanResultMaxAgeForConnect =
      Duration(seconds: 15); // Строже для connect

  /// 🔥 CRITICAL FIX: Извлекает токен из manufacturerData
  /// Токен уникален для BRIDGE, а MAC меняется каждые 200-500ms (Android randomization)
  /// Используем токен как ключ для cooldown вместо MAC
  /// Извлекает стабильный device UUID (8-byte hash в hex) из manufacturerData GH/RL для подключения по UUID при ротации MAC.
  String? _extractDeviceUuidFromScanResult(ScanResult r) {
    try {
      final mfMap = r.advertisementData.manufacturerData;
      final mfData = mfMap[0xFFFF] ?? mfMap[65535];
      if (mfData != null && mfData.length >= 10 &&
          ((mfData[0] == 0x47 && mfData[1] == 0x48) || (mfData[0] == 0x52 && mfData[1] == 0x4C))) {
        return mfData.sublist(2, 10).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
    } catch (_) {}
    return null;
  }

  String? _extractTokenFromScanResult(ScanResult r) {
    try {
      final mfData = r.advertisementData.manufacturerData[0xFFFF];
      if (mfData != null && mfData.length > 2) {
        // Первые 2 байта = role indicator (BR для BRIDGE, GH для GHOST)
        // Остальные байты = токен (BRIDGE) или deviceUuid hash (GHOST — 8 байт), не UTF-8 токен
        if ((mfData[0] == 0x42 && mfData[1] == 0x52)) {
          // "BR" - BRIDGE: байты 2+ = token
          final tokenBytes = mfData.sublist(2);
          return String.fromCharCodes(tokenBytes);
        }
        // GH/RL — не токен, пропускаем
      }

      // Fallback: извлекаем токен из тактического имени
      final name = r.advertisementData.localName;
      if (name.isNotEmpty && name.contains('_')) {
        final parts = name.split('_');
        if (parts.length >= 4) {
          return parts.last; // Последняя часть = токен
        }
      }
    } catch (e) {
      // Ignore parsing errors
    }
    return null;
  }

  /// 🔥 FIX: Получает ключ для cooldown (токен если есть, иначе MAC)
  String _getCooldownKey(ScanResult r) {
    final token = _extractTokenFromScanResult(r);
    final mac = r.device.remoteId.str;

    if (token != null && token.isNotEmpty) {
      // Обновляем маппинг token → MAC
      _tokenToMacMapping[token] = mac;
      return "TOKEN:$token";
    }
    return "MAC:$mac";
  }

  /// 🔥 FIX: Проверяет cooldown по токену или MAC
  /// cooldownSeconds по умолчанию = _defaultCooldownSeconds (45s)
  bool _isCooldownExpired(ScanResult r, {int? cooldownSeconds}) {
    final cd = cooldownSeconds ?? _defaultCooldownSeconds;
    final key = _getCooldownKey(r);
    if (!_linkCooldowns.containsKey(key)) return true;

    final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
    // 🔥 FIX: Используем >= для корректного поведения на границе (0s remaining)
    return age >= cd;
  }

  /// 🔥 FIX: Устанавливает cooldown по токену или MAC
  void _setCooldown(ScanResult r) {
    final key = _getCooldownKey(r);
    _linkCooldowns[key] = DateTime.now();
    _log(
        "🔒 [Cooldown] Set for $key (will expire in ${_defaultCooldownSeconds}s)");
  }

  /// 🔥 FIX: Получает оставшееся время cooldown
  int _getCooldownRemaining(ScanResult r, {int? cooldownSeconds}) {
    final cd = cooldownSeconds ?? _defaultCooldownSeconds;
    final key = _getCooldownKey(r);
    if (!_linkCooldowns.containsKey(key)) return 0;

    final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
    return (cd - age).clamp(0, cd);
  }

  /// 🔥 FIX: Устанавливает cooldown по MAC (fallback когда нет ScanResult)
  /// Пытается найти токен по маппингу, иначе использует MAC
  void _setCooldownByMac(String mac) {
    // Ищем токен в обратном маппинге
    String? tokenForMac;
    for (final entry in _tokenToMacMapping.entries) {
      if (entry.value == mac) {
        tokenForMac = entry.key;
        break;
      }
    }

    final key = tokenForMac != null ? "TOKEN:$tokenForMac" : "MAC:$mac";
    _linkCooldowns[key] = DateTime.now();
  }

  /// 🔥 FIX: Проверяет cooldown по MAC (fallback когда нет ScanResult)
  bool _isCooldownExpiredByMac(String mac, {int? cooldownSeconds}) {
    final cd = cooldownSeconds ?? _defaultCooldownSeconds;
    // Сначала проверяем по токену (если есть маппинг)
    for (final entry in _tokenToMacMapping.entries) {
      if (entry.value == mac) {
        final key = "TOKEN:${entry.key}";
        if (_linkCooldowns.containsKey(key)) {
          final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
          return age >= cd;
        }
      }
    }

    // Fallback на MAC
    final key = "MAC:$mac";
    if (!_linkCooldowns.containsKey(key)) return true;

    final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
    return age >= cd;
  }

  /// 🔥 FIX: Получает оставшееся время cooldown по MAC
  int _getCooldownRemainingByMac(String mac, {int? cooldownSeconds}) {
    final cd = cooldownSeconds ?? _defaultCooldownSeconds;
    // Сначала проверяем по токену
    for (final entry in _tokenToMacMapping.entries) {
      if (entry.value == mac) {
        final key = "TOKEN:${entry.key}";
        if (_linkCooldowns.containsKey(key)) {
          final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
          return (cd - age).clamp(0, cd);
        }
      }
    }

    // Fallback на MAC
    final key = "MAC:$mac";
    if (!_linkCooldowns.containsKey(key)) return 0;

    final age = DateTime.now().difference(_linkCooldowns[key]!).inSeconds;
    return (cd - age).clamp(0, cd);
  }

  bool _isEscalating = false; // Флаг режима "Охоты по Wi-Fi"
  bool _isHuaweiBreakGlassThisCascade = false; // ADAPTIVE: set from strategy when BLE-only GHOST↔GHOST
  BleWriteStrategy? _writeStrategyThisCascade; // ADAPTIVE: pair-specific write/notify when BLE-only GHOST↔GHOST

  String? _targetIdToHunt;

  Future<void> _scanBluetooth() async {
    if (!_isMeshEnabled) {
      _log("⚠️ [BT-SCAN] Scan blocked: Mesh not enabled");
      return;
    }
    if (!locator.isRegistered<NetworkPhaseContext>()) return;
    final phaseCtx = locator<NetworkPhaseContext>();
    if (!phaseCtx.allowsBleScan) {
      _log("[BLE][SKIP] scan skipped (phase=${phaseCtx.phase})");
      return;
    }
    if (_isBtScanning) {
      _log("⚠️ [BT-SCAN] Scan already in progress, skipping");
      return;
    }

    // 🔥 FIX: БЛОКИРОВКА SCAN ВО ВРЕМЯ GATT CONNECT
    // Это критично - scan и GATT connect конфликтуют на Android BLE стеке!
    // 🔥 FIX #6: Разрешаем scan если GATT state == FAILED (это завершённое состояние)
    // 🔥 FIX #7: GATT завис >12s — force reset, иначе scan блокируется навсегда (Huawei hang)
    if (_btService.isGattConnecting) {
      final gattState = _btService.gattConnectionState;
      final elapsed = _btService.gattConnectElapsedSeconds;
      if (elapsed > 12) {
        _log(
            "⚠️ [BT-SCAN] GATT stuck $elapsed s — forcing reset to unblock scan");
        _btService.forceResetGattState("scan unblock (stuck ${elapsed}s)");
      } else if (gattState != 'FAILED' && gattState != 'IDLE') {
        _log(
            "[TIMER][SKIP] scan skipped (state=$gattState, GATT connect in progress ${elapsed}s)");
        _log(
            "🚫 [BT-SCAN] Scan BLOCKED: GATT connection in progress (state: $gattState, ${elapsed}s)");
        return;
      } else {
        _log(
            "ℹ️ [BT-SCAN] GATT state is $gattState - allowing scan to proceed");
      }
    }

    _isBtScanning = true;
    final currentRole = NetworkMonitor().currentRole;
    final isGhost = currentRole ==
        MeshRole.GHOST; // 🔥 FIX: Сохраняем для использования в finally
    final scanDuration = isGhost
        ? const Duration(seconds: 30)
        : const Duration(seconds: 10); // 🔥 FIX: Определяем здесь для finally
    _log(
        "🔍 [BT-SCAN] Starting BLE scan (role: ${isGhost ? 'GHOST' : 'BRIDGE'})");

    try {
      final orchestrator = locator<TacticalMeshOrchestrator>();
      final pendingCount = await _db.getOutboxCount();

      // 1. ВЕЩАНИЕ (Маяк)
      final String rawUserId = _apiService.currentUserId;
      // Безопасное извлечение короткого ID (максимум 4 символа, но не падаем если короче)
      final String myShortId = rawUserId.isNotEmpty && rawUserId.length >= 4
          ? rawUserId.substring(0, 4)
          : (rawUserId.isNotEmpty ? rawUserId : "GHST");

      // 🔥 FIX: BRIDGE не перезаписывает advertising при scan! Иначе M_255_0_GHST убивает M_0_0_BRIDGE_TOKEN
      // BRIDGE advertising задаётся emitInternetMagnetWave (token). Scan только читает, не пишет.
      if (!isGhost) {
        _log(
            "📡 [ADV] BRIDGE scan — keeping existing advertising (token from init)");
      } else {
        final String myTacticalName =
            "M_${orchestrator.myHops}_${pendingCount > 0 ? '1' : '0'}_$myShortId";
        _log(
            "📡 [ADV] Setting tactical name: '$myTacticalName' (length: ${myTacticalName.length})");
        await _btService.stopAdvertising(keepGattServer: true);
        await _btService.startAdvertising(myTacticalName);
      }

      // 2. СКАНИРОВАНИЕ
      await _scanSub?.cancel();
      await FlutterBluePlus.stopScan();

      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        // 🔥 Discovery Context: Обновляем контекст, НЕ принимаем решения напрямую
        final discoveryContext = locator<DiscoveryContextService>();
        final isGhost = NetworkMonitor().currentRole == MeshRole.GHOST;
        int meshDevicesCount = 0;

        if (results.isNotEmpty) {
          _log(
              "🔍 [BT-SCAN] Received ${results.length} scan result(s), updating discovery context...");
        }

        for (ScanResult r in results) {
          // 🔥 Discovery Context: Обновляем контекст из BLE scan (внутри сервис сам фильтрует только mesh)
          discoveryContext.updateFromBleScan(r);
          final String advName = r.advertisementData.localName ?? "";
          final String platformName = r.device.platformName;
          final String mac = r.device.remoteId.str;

          // 🔥 FIX: Если localName пустое, используем platformName как fallback
          final String effectiveName = advName.isEmpty ? platformName : advName;

          // 🔍 ФИЛЬТР: Только устройства мессенджера — наушники/колонки/ПК/часы не учитываем
          final bool hasServiceUuid = r.advertisementData.serviceUuids.any(
              (uuid) =>
                  uuid.toString().toLowerCase() ==
                  _btService.SERVICE_UUID.toLowerCase());

          final mfData = r.advertisementData.manufacturerData[0xFFFF];
          final bool isBridgeByMfData = mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x42 &&
              mfData[1] == 0x52; // "BR" = BRIDGE
          final bool isGhostByMfData = mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x47 &&
              mfData[1] == 0x48; // "GH" = GHOST
          final bool isRelayByMfData = mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x52 &&
              mfData[1] == 0x4C; // "RL" = RELAY

          // 🔒 Только телефоны меша: подключаемся ТОЛЬКО к устройствам с нашим Service UUID или
          // manufacturerData BR/GH/RL. Имя "M_..." без UUID/mfData НЕ считаем — в эфире есть колонки,
          // наушники, часы с BLE, их не подключаем и не логируем.
          final bool isOurNode = hasServiceUuid ||
              isBridgeByMfData ||
              isGhostByMfData ||
              isRelayByMfData;

          if (!isOurNode) {
            continue; // Пропускаем всё, что не наш меш (нет UUID и нет BR/GH/RL в mfData)
          }

          // 🔍 ДИАГНОСТИКА: RAW только по устройствам меша (не засоряем лог наушниками/колонками/ПК)
          _log("🔍 [DEBUG] RAW SCAN DATA:");
          _log("   MAC: ${maskMacForLog(mac)}");
          _log("   localName: '${advName.isEmpty ? 'EMPTY' : advName}'");
          _log(
              "   platformName: '${platformName.isEmpty ? 'EMPTY' : platformName}'");
          _log(
              "   effectiveName: '${effectiveName.isEmpty ? 'EMPTY' : effectiveName}'");
          _log("   serviceUUIDs: ${r.advertisementData.serviceUuids}");
          _log("   manufacturerData: ${r.advertisementData.manufacturerData}");

          final bool hasTacticalName = effectiveName.startsWith("M_");

          meshDevicesCount++;

          int nodeBridgeDistance = 99;
          if (isBridgeByMfData) {
            nodeBridgeDistance = 0;
          } else if (effectiveName.startsWith("M_")) {
            final parts = effectiveName.split("_");
            if (parts.length >= 4)
              nodeBridgeDistance = int.tryParse(parts[1]) ?? 99;
          }

          // 🔥 DEDUP: Android BLE MAC randomization — один телефон даёт несколько MAC.
          // BRIDGE: объединяем по токену (id = BRIDGE:token, metadata = последний MAC).
          // GHOST / прочие: id = mac.
          String nodeId = mac;
          String nodeMetadata = mac;
          if (isBridgeByMfData && mfData != null && mfData.length > 2) {
            try {
              final tokenFromMf =
                  utf8.decode(mfData.sublist(2), allowMalformed: true);
              if (tokenFromMf.isNotEmpty) {
                nodeId =
                    'BRIDGE:${tokenFromMf.length > 12 ? tokenFromMf.substring(0, 12) : tokenFromMf}';
                nodeMetadata = mac; // MAC для отправки (последний известный)
              }
            } catch (_) {}
          }

          _log(
              "🔍 [BT-SCAN] ✅ Mesh device: '$effectiveName' (${nodeId.contains('BRIDGE') ? 'dedup' : 'MAC'}: ${maskMacForLog(mac)}, hops=$nodeBridgeDistance)");

          _registerNode(SignalNode(
            id: nodeId,
            name: effectiveName.isNotEmpty
                ? effectiveName
                : 'BLE_${mac.length >= 4 ? mac.substring(mac.length - 4) : '••••'}',
            type: SignalType.bluetooth,
            metadata: nodeMetadata,
            bridgeDistance: nodeBridgeDistance,
          ));

          // 🧲 ДЕТАЛЬНОЕ ЛОГИРОВАНИЕ для отладки BRIDGE обнаружения
          if (hasTacticalName) {
            _log(
                "🔍 [BT-SCAN] ✅ Found tactical node: '$effectiveName' (MAC: ${maskMacForLog(mac)})");
          }

          // Логируем найденное устройство для отладки
          if (hasTacticalName && !hasServiceUuid) {
            _log(
                "🔍 [BT-SCAN] Found tactical node '$effectiveName' but service UUID missing (Huawei/Tecno quirk?)");
          }

          // 🔥 FIX: Если BRIDGE обнаружен через manufacturerData
          if (isBridgeByMfData) {
            _log(
                "🧲 [Ghost] ⚡ BRIDGE detected via manufacturerData! (MAC: ${maskMacForLog(mac)})");

            // 🔥 REPEATER: Уведомляем о обнаружении BRIDGE
            try {
              final mfDataForToken =
                  r.advertisementData.manufacturerData[0xFFFF];
              String? tokenFromMf;
              if (mfDataForToken != null && mfDataForToken.length > 2) {
                try {
                  tokenFromMf = utf8.decode(mfDataForToken.sublist(2),
                      allowMalformed: true);
                } catch (_) {}
              }
              locator<RepeaterService>().onDeviceDiscovered(
                mac,
                tokenFromMf,
                ChannelType.bleGatt,
              );
            } catch (_) {}

            // 🔥 GHOST TRANSFER MANAGER: Регистрируем BRIDGE
            try {
              final mfDataForToken =
                  r.advertisementData.manufacturerData[0xFFFF];
              String? tokenFromMf;
              if (mfDataForToken != null && mfDataForToken.length > 2) {
                try {
                  tokenFromMf = utf8.decode(mfDataForToken.sublist(2),
                      allowMalformed: true);
                } catch (_) {}
              }
              locator<GhostTransferManager>().onBridgeDiscovered(
                r,
                token: tokenFromMf,
                hops: 0,
              );
            } catch (_) {}
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
                _log(
                    "🧲 [Ghost] ⚡ BRIDGE DETECTED! Hops=0, Name: '$effectiveName', MAC: ${maskMacForLog(mac)}");
              }

              // 🧲 ОБРАБОТКА BRIDGE: Извлекаем зашифрованный токен из имени
              // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN или M_0_0_BRIDGE_ENCRYPTED_TOKEN
              // 🔒 SECURITY: Token is now HMAC-encrypted, not plaintext
              if (parts.length >= 5 && parts[3] == "BRIDGE") {
                final encryptedToken =
                    parts[4]; // Encrypted token from advertising name
                final tokenPreview = encryptedToken.length > 8
                    ? encryptedToken.substring(0, 8)
                    : encryptedToken;
                _log(
                    "🧲 [Ghost] BRIDGE detected in BLE advertising! Encrypted token: $tokenPreview..., Hops: $peerHops");

                // Если мы GHOST и есть зашифрованный токен - обрабатываем как MAGNET_WAVE
                // Note: We'll need the actual token from TCP connection, not from BLE
                // BLE only provides encrypted hint for discovery
                if (NetworkMonitor().currentRole == MeshRole.GHOST &&
                    encryptedToken.isNotEmpty) {
                  // 🔒 SECURITY: Encrypted token in BLE is just a hint for discovery
                  // Actual token verification happens during TCP connection
                  // 🔥 ШАГ 3: Токен валиден 60 секунд (MAC RANDOMIZATION FIX)
                  final expiresAt = DateTime.now()
                      .add(const Duration(seconds: 60))
                      .millisecondsSinceEpoch;
                  _log(
                      "🧲 [Ghost] Processing MAGNET_WAVE hint from BLE advertising (encrypted: $tokenPreview...)");
                  // Note: We can't decrypt token from BLE alone - need full MAGNET_WAVE packet via TCP
                  // This is just for discovery - actual connection uses TCP with full signed packet
                }
              } else if (peerHops == 0) {
                // 🔥 КРИТИЧНО: BRIDGE может рекламировать без токена в имени (старый формат или до emitInternetMagnetWave)
                // Но hops=0 означает BRIDGE - обрабатываем немедленно
                _log(
                    "🧲 [Ghost] ⚡ BRIDGE DETECTED (hops=0)! Name: '$effectiveName', MAC: ${maskMacForLog(mac)}");

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
                  if (mfData != null &&
                      mfData.length > 2 &&
                      mfData[0] == 0x42 &&
                      mfData[1] == 0x52) {
                    try {
                      final tokenBytes = mfData.sublist(2);
                      extractedToken = utf8.decode(tokenBytes);
                    } catch (e) {
                      // Не удалось декодировать token
                    }
                  }
                }

                if (extractedToken == null) {
                  // 🔥 ШАГ 2.2: Токен не найден - проверяем TCP fallback
                  _log("⚠️ [ARCHITECTURE] BRIDGE without token in advertising");
                  _log("   📋 Effective name: '$effectiveName'");
                  _log("   📋 Platform name: '$platformName'");
                  _log("   📋 MAC: ${maskMacForLog(mac)}");
                  _log(
                      "   ⚠️ Token not found in advertising - possible reasons:");
                  _log(
                      "      1. BRIDGE hasn't updated advertising yet (timing issue)");
                  _log("      2. Token expired (>30s old)");
                  _log(
                      "      3. BLE stack delay on BRIDGE device (Huawei/Android)");

                  // 🔥 КРИТИЧНО: Проверяем TCP fallback даже без токена
                  final discoveryContext = locator<DiscoveryContextService>();
                  final candidate = discoveryContext.getCandidateByMac(mac);

                  if (candidate != null &&
                      candidate.ip != null &&
                      candidate.port != null) {
                    _log(
                        "   ✅ TCP fallback available: ${candidate.ip}:${candidate.port}");
                    _log(
                        "   💡 Will attempt TCP fallback in Cascade (token not required for TCP)");
                    // Не ставим cooldown - это не ошибка, а нормальная ситуация
                    // Продолжаем в Cascade, где будет попытка TCP fallback
                  } else {
                    _log(
                        "   ⚠️ No TCP info available (ip: ${candidate?.ip}, port: ${candidate?.port})");
                    _log("   💡 Will escalate to Sonar if TCP also fails");

                    // 🔥 ШАГ 4.1: Повторное сканирование через 1-2 секунды, если токен не найден
                    _pendingBridgeConnections[mac] = DateTime.now();
                    Future.delayed(const Duration(seconds: 2), () async {
                      _log(
                          "🔄 [GHOST] Retry scan for BRIDGE token (MAC: ${maskMacForLog(mac)})...");
                      try {
                        await startDiscovery(SignalType.bluetooth);
                        await Future.delayed(
                            const Duration(seconds: 5)); // Сканируем 5 секунд
                        await stopDiscovery();

                        // 🔥 ШАГ 4.2: После получения токена - сразу инициировать подключение
                        // Проверяем, появился ли токен в DiscoveryContext
                        final updatedCandidate =
                            discoveryContext.getCandidateByMac(mac);
                        if (updatedCandidate != null &&
                            updatedCandidate.bridgeToken != null) {
                          _log(
                              "✅ [GHOST] Token found after retry scan - initiating connection...");
                          _pendingBridgeConnections.remove(mac);
                          // Инициируем подключение через Cascade
                          final lastScanResults =
                              await FlutterBluePlus.lastScanResults;
                          for (final result in lastScanResults) {
                            if (result.device.remoteId.str == mac) {
                              unawaited(_executeCascadeRelay(result, 0));
                              break;
                            }
                          }
                        } else {
                          _log(
                              "⚠️ [GHOST] Token still not found after retry scan");
                        }
                      } catch (e) {
                        _log("⚠️ [GHOST] Retry scan failed: $e");
                      }
                    });
                  }

                  // 🔥 КРИТИЧНО: НЕ ставим cooldown и НЕ помечаем как GATT forbidden
                  // Это не ошибка, а нормальная ситуация - токен может появиться позже
                  // или можно использовать TCP fallback
                  _log(
                      "   💡 Not marking as GATT forbidden - will retry or use TCP fallback");

                  // Сразу переходим к Sonar
                  if (pendingCount > 0) {
                    var pending = <Map<String, dynamic>>[];
                    try {
                      pending = await _db.getPendingFromOutbox();
                      if (pending.isNotEmpty) {
                        final msgId = pending.first['id'] as String;
                        // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
                        if (_sentPayloads.containsKey(msgId)) {
                          _log(
                              "🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
                          return;
                        }

                        final messageData = jsonEncode({
                          'type': 'OFFLINE_MSG',
                          'content': pending.first['content'],
                          'senderId': _apiService.currentUserId,
                          'h': msgId,
                          'ttl': 5,
                        });
                        final sonarPayload = messageData.length > 200
                            ? messageData.substring(0, 200)
                            : messageData;
                        await locator<UltrasonicService>()
                            .transmitFrame("DATA:$sonarPayload");

                        // 🔒 АРХИТЕКТУРА: Sonar только для рукопожатия/SOS, не транспорт доставки — не помечаем как SENT, не удаляем из outbox
                        _log(
                            "📦 [ARCHITECTURE] Sonar hint emitted for $msgId (BRIDGE without token). Message stays in outbox for BLE/TCP retry.");
                        _log(
                            "✅ Sonar Packet Emitted (hint only). Cycle NOT closed.");
                      }
                    } catch (e) {
                      final msgId = pending.isNotEmpty
                          ? pending.first['id'] as String
                          : 'unknown';
                      _log(
                          "📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
                      _log("❌ Sonar failed: $e");
                    }
                  }
                  return; // Прерываем - не запускаем Cascade
                }

                // Запускаем каскадное подключение для BRIDGE с token
                // 🔥 FIX #1: Cooldown по ТОКЕНУ, не по MAC (MAC rotation на Android)
                final cooldownExpired = _isCooldownExpired(r);
                // 🔥 BLE STABILIZATION: Transfer timeout должен быть > batch timeout (30s)
                // Используем _transferTtlSeconds (40s) чтобы не прерывать batch mid-flight
                final transferAge = _isTransferring &&
                        _transferStartTime != null
                    ? DateTime.now().difference(_transferStartTime!).inSeconds
                    : 0;
                final transferStuck = transferAge > _transferTtlSeconds;
                if (transferStuck) {
                  _log(
                      "⚠️ [WATCHDOG] Transfer stuck for ${transferAge}s (>${_transferTtlSeconds}s), forcing reset!");
                  _isTransferring = false;
                  _transferStartTime = null;
                }

                if (pendingCount > 0 && cooldownExpired && !_isTransferring) {
                  // 🔥 FIX: НЕ ставим cooldown здесь! Cooldown ставится ПОСЛЕ попытки connect
                  // Раньше cooldown ставился ДО connect, что блокировало следующие попытки
                  _log(
                      "🧲 [Ghost] Initiating connection to BRIDGE (hops=0, token: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}...) with $pendingCount pending messages...");
                  unawaited(_executeCascadeRelay(r, peerHops));
                  continue; // 🔥 FIX: Пропускаем Final connection check - cascade уже запущен
                } else if (pendingCount == 0) {
                  _log(
                      "ℹ️ [Ghost] BRIDGE detected but no pending messages to upload");
                }
              }
            }
          } else if (isBridgeByMfData) {
            // 🔥 FALLBACK: Если имя пустое, но manufacturerData указывает на BRIDGE
            peerHops = 0;
            _log(
                "🧲 [Ghost] ⚡ BRIDGE detected via manufacturerData fallback! (MAC: ${maskMacForLog(mac)})");

            // 🔥 КРИТИЧНО: Детальное логирование для диагностики
            _log(
                "🔍 [Ghost] Connection decision for BRIDGE ${maskMacForLog(mac)}:");
            _log("   📋 Pending messages: $pendingCount");

            // 🔥 FIX #1: Cooldown по ТОКЕНУ, не по MAC (MAC rotation на Android)
            final cooldownExpired = _isCooldownExpired(r);
            final cooldownRemaining = _getCooldownRemaining(r);
            final cooldownKey = _getCooldownKey(r);
            _log(
                "   📋 Cooldown: ${cooldownExpired ? 'EXPIRED' : 'ACTIVE'} (key: $cooldownKey, remaining: ${cooldownRemaining}s)");

            // 🔥 BLE STABILIZATION: Transfer timeout должен быть > batch timeout (30s)
            // Используем _transferTtlSeconds (40s) чтобы не прерывать batch mid-flight
            final transferAge = _isTransferring && _transferStartTime != null
                ? DateTime.now().difference(_transferStartTime!).inSeconds
                : 0;
            final transferStuck = transferAge > _transferTtlSeconds;
            if (transferStuck) {
              _log(
                  "⚠️ [WATCHDOG] Transfer stuck for ${transferAge}s (>${_transferTtlSeconds}s), forcing reset!");
              _isTransferring = false;
              _transferStartTime = null;
            }
            _log(
                "   📋 Transfer active: $_isTransferring${_isTransferring ? ' (${transferAge}s)' : ''}");

            // Запускаем каскадное подключение для BRIDGE
            if (pendingCount > 0 && cooldownExpired && !_isTransferring) {
              // 🔥 FIX: НЕ ставим cooldown здесь! Cooldown ставится в _executeCascadeRelay ПОСЛЕ попытки
              _log(
                  "🧲 [Ghost] Initiating connection to BRIDGE (via manufacturerData) with $pendingCount pending messages...");
              unawaited(_executeCascadeRelay(r, peerHops));
              continue; // 🔥 FIX: Пропускаем остальные проверки - cascade уже запущен
            } else {
              if (pendingCount == 0) {
                _log(
                    "⏸️ [Ghost] BRIDGE detected but no pending messages to upload");
              }
              if (!cooldownExpired) {
                _log(
                    "⏸️ [Ghost] BRIDGE in cooldown (${cooldownRemaining}s remaining)");
              }
              if (_isTransferring) {
                _log(
                    "⏸️ [Ghost] Transfer already in progress, skipping connection");
              }
            }
          } else if (isGhostByMfData) {
            // 🔥 FALLBACK: Если имя пустое, но manufacturerData указывает на GHOST
            // Используем hops из Orchestrator (если есть сосед с меньшими hops)
            peerHops = 99; // По умолчанию
            _log(
                "🧲 [Ghost] GHOST detected via manufacturerData fallback! (MAC: ${maskMacForLog(mac)})");
          }

          // ТИХОЕ ОБНОВЛЕНИЕ ГРАДИЕНТА (БЕЗ UI)
          orchestrator.processRoutingPulse(RoutingPulse(
            nodeId: peerId,
            hopsToInternet: peerHops,
            batteryLevel: 1.0,
            queuePressure: peerHasData ? 1 : 0,
          ));

          // 🔥 КРИТИЧНО: GHOST должен подключаться к BRIDGE (hops=0) независимо от своих hops
          // Если мы GHOST и нашли BRIDGE (hops=0) - подключаемся немедленно
          final isBridge = peerHops == 0;
          final shouldConnect =
              isBridge || (pendingCount > 0 && peerHops < orchestrator.myHops);

          if (shouldConnect) {
            // 🔥 КРИТИЧНО: Детальное логирование для диагностики
            _log(
                "🔍 [Ghost] Final connection check for ${isBridge ? 'BRIDGE' : 'GHOST'} ${maskMacForLog(mac)}:");
            _log(
                "   📋 Should connect: $shouldConnect (isBridge: $isBridge, pending: $pendingCount, peerHops: $peerHops, myHops: ${orchestrator.myHops})");

            // 🔥 FIX #3: НЕ запускать cascade без pending messages!
            if (pendingCount == 0) {
              _log(
                  "⏸️ [Ghost] Skipping connection: no pending messages to upload");
              continue; // 🔥 Пропускаем этот BRIDGE, идём к следующему
            }

            // 🔥 FIX #1: Cooldown по ТОКЕНУ, не по MAC (MAC rotation на Android)
            final cooldownExpired = _isCooldownExpired(r);
            final cooldownRemaining = _getCooldownRemaining(r);
            final cooldownKey = _getCooldownKey(r);
            _log(
                "   📋 Cooldown: ${cooldownExpired ? 'EXPIRED' : 'ACTIVE'} (key: $cooldownKey, remaining: ${cooldownRemaining}s)");

            // 🔥 BLE STABILIZATION: Transfer timeout должен быть > batch timeout (30s)
            // Используем _transferTtlSeconds (40s) чтобы не прерывать batch mid-flight
            final transferAge2 = _isTransferring && _transferStartTime != null
                ? DateTime.now().difference(_transferStartTime!).inSeconds
                : 0;
            final transferStuck = transferAge2 > _transferTtlSeconds;
            if (transferStuck) {
              _log(
                  "⚠️ [WATCHDOG] Transfer stuck for ${transferAge2}s (>${_transferTtlSeconds}s), forcing reset!");
              _isTransferring = false;
              _transferStartTime = null;
            }
            _log(
                "   📋 Transfer active: $_isTransferring${_isTransferring ? ' (${transferAge2}s)' : ''}");

            if (cooldownExpired && !_isTransferring) {
              // 🔥 FIX: НЕ ставим cooldown здесь! Cooldown ставится ПОСЛЕ попытки connect
              if (isBridge) {
                _log(
                    "🧲 [Ghost] BRIDGE detected (hops=0)! Initiating connection immediately...");
              }
              _executeCascadeRelay(r, peerHops); // Вызываем наш каскад
              break;
            } else {
              if (!cooldownExpired) {
                _log(
                    "⏸️ [Ghost] Connection blocked: BRIDGE in cooldown (${cooldownRemaining}s remaining)");
              }
              if (_isTransferring) {
                _log(
                    "⏸️ [Ghost] Connection blocked: Transfer already in progress");
              }
            }
          } else {
            _log(
                "⏸️ [Ghost] Should not connect: isBridge=$isBridge, pending=$pendingCount, peerHops=$peerHops, myHops=${orchestrator.myHops}");
          }
        }

        // Логируем итоговое количество найденных устройств мессенджера
        if (meshDevicesCount > 0) {
          _log("🔍 [BT-SCAN] Summary: Found $meshDevicesCount mesh device(s)");
        }

        // 🔥 КРИТИЧНО: После сканирования проверяем, есть ли BRIDGE для forced send
        // ⚡ OPTIMIZATION: Event-driven проверка - запускаем cascade сразу при обнаружении BRIDGE
        // Это ускоряет передачу на ~1-5 секунд по сравнению с ожиданием окончания scan
        // 🔥 SELF-GROWING NETWORK: Также проверяем возможность стать BRIDGE
        if (NetworkMonitor().currentRole == MeshRole.GHOST &&
            pendingCount > 0) {
          // Проверяем, есть ли уже BRIDGE в DiscoveryContext
          final discoveryContext = locator<DiscoveryContextService>();
          final bestBridge = discoveryContext.bestBridge;

          // Если BRIDGE уже найден и валиден - запускаем cascade немедленно
          if (bestBridge != null &&
              bestBridge.isValid &&
              bestBridge.confidence >= 0.3) {
            _log(
                "⚡ [OPTIMIZATION] BRIDGE found during scan - initiating cascade immediately");
            // Используем unawaited чтобы не блокировать обработку других scan results
            unawaited(_checkForBridgeAndForceSend());
          } else {
            // Если BRIDGE еще не найден - проверка будет выполнена после scan
            // Это безопасный fallback на случай, если BRIDGE появится позже
          }
        }

        // 🔥 SELF-GROWING NETWORK: Проверяем возможность стать BRIDGE при обнаружении интернета
        // Это позволяет сети автоматически расти при появлении новых BRIDGE узлов
        if (NetworkMonitor().currentRole == MeshRole.GHOST) {
          final routerService = RouterConnectionService();
          final connectedRouter = routerService.connectedRouter;

          // Если роутер имеет интернет - уведомляем Orchestrator о возможности продвижения
          if (connectedRouter != null && connectedRouter.hasInternet) {
            _log(
                "🌐 [SELF-GROWING] Router with internet detected - Orchestrator will evaluate auto-promotion");
            // Orchestrator проверит это в heartbeat цикле
          }
        }
      });

      // 🔥 КРИТИЧНОЕ ИСПРАВЛЕНИЕ: И BRIDGE, и GHOST сканируют БЕЗ фильтра SERVICE_UUID
      // Причина: GHOST устройства НЕ имеют GATT server, поэтому они не видны через фильтр SERVICE_UUID
      // BRIDGE должен видеть GHOST устройства по тактическому имени (M_Hops_HasData_ID)
      // GHOST должен видеть BRIDGE по тактическому имени
      // Фильтр SERVICE_UUID блокирует обнаружение GHOST устройств на BRIDGE!

      _log(
          "🔍 [BT-SCAN] Configuring scan: duration=${scanDuration.inSeconds}s, role=${isGhost ? 'GHOST' : 'BRIDGE'}, filter=NONE (check tactical names for both BRIDGE and GHOST)");

      if (!_btService.canStartScan) {
        _log(
            "[BLE][SKIP] scan blocked: active GATT session (state: ${_btService.gattSessionState})");
        _isBtScanning = false;
        return;
      }
      try {
        // 🔥 FIX: Все устройства сканируют БЕЗ фильтра, чтобы видеть друг друга по тактическому имени
        // 🔍 OUTBOX-BOOST: в течение 8s после 0→1 в outbox — lowLatency для быстрого discovery
        await FlutterBluePlus.startScan(
          timeout: scanDuration,
          androidScanMode: _btService.isOutboxBoostActive
              ? AndroidScanMode.lowLatency
              : AndroidScanMode.balanced,
        );
        _log(
            "✅ [BT-SCAN] BLE scan started successfully (no filter - can see both BRIDGE and GHOST by tactical name)");
      } catch (e) {
        _log("❌ [BT-SCAN] Failed to start scan: $e");
        _isBtScanning = false;
        return;
      }
    } catch (e) {
      _log("❌ [BT-SCAN] BT Radar Error: $e");
      _isBtScanning = false;
    } finally {
      // 🔥 FIX: После завершения сканирования проверяем outbox и инициируем подключение к BRIDGE
      // Это критично для автоматического цикла - без этого сообщения не отправляются!
      // ⚡ OPTIMIZATION: Уменьшен буфер с 2 секунд до 1 секунды
      // 1 секунды достаточно для завершения обработки результатов scan
      Future.delayed(scanDuration + const Duration(seconds: 1), () async {
        _isBtScanning = false;
        _log("🔍 [BT-SCAN] Scan session ended");

        // 🔥 КРИТИЧНО: Проверяем outbox ПОСЛЕ завершения сканирования
        // Это гарантирует, что все результаты сканирования обработаны и DiscoveryContext обновлен
        // Это ключевое отличие от ручного сканирования - автоматический цикл теперь тоже проверяет outbox!
        if (NetworkMonitor().currentRole == MeshRole.GHOST) {
          final pending = await _db.getPendingFromOutbox();
          if (pending.isNotEmpty) {
            _log(
                "📦 [AUTO-SCAN] Found ${pending.length} pending message(s) after scan - checking for BRIDGE...");
            await _checkForBridgeAndForceSend();
          } else {
            _log("📦 [AUTO-SCAN] No pending messages in outbox");
          }
        }
      });
    }
  }

  // ============================================================
  // ⛓️ КАСКАДНЫЙ ПРОТОКОЛ (WiFi -> BLE -> Sonar)
  // ============================================================

  // 🔥 Улучшение: Счётчики попыток для агрессивного fallback на TCP
  final Map<String, int> _bleGattAttempts =
      {}; // MAC -> количество неудачных попыток BLE GATT
  final Map<String, DateTime> _pendingConnections =
      {}; // MAC -> время добавления в очередь

  // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Трекинг отправленных payload в текущем цикле
  // Ключ: messageId, Значение: транспорт (BLE/TCP/SONAR)
  // Очищается периодически (каждые 10 минут) для предотвращения утечек памяти
  final Map<String, String> _sentPayloads = {}; // messageId -> transport

  // 🔥 МАСШТАБИРУЕМОСТЬ: Ограничение активных payload (10-20 на узел)
  static const int _maxActivePayloads =
      15; // Максимальное количество одновременно активных payload
  final Set<String> _activePayloads =
      {}; // messageId -> активные payload в обработке

  // 🔥 МАСШТАБИРУЕМОСТЬ: Retry strategy с ограничением попыток
  final Map<String, PayloadRetryInfo> _payloadRetries =
      {}; // messageId -> информация о попытках

  // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивные таймауты на основе предыдущих успехов/неудач
  final Map<String, TransportLatency> _transportLatencies =
      {}; // MAC -> статистика задержек транспорта

  // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельные таймеры для каждого транспорта
  Timer? _gattTimeoutTimer;
  Timer? _tcpTimeoutTimer;
  Timer? _sonarTimeoutTimer;

  // 🔥 ШАГ 1.3: Поддержка стабильного токена
  // 🔥 MAC RANDOMIZATION FIX: Увеличено с 10s до 30s
  // Каждая ротация токена вызывает смену MAC на Android!
  // 30s стабильности даёт GHOST достаточно времени на quick rescan + GATT connect
  DateTime? _lastTokenUpdate;
  static const Duration _minTokenStability =
      Duration(seconds: 30); // Минимум 30 секунд стабильности

  // 🔥 ШАГ 4.2: Очередь сообщений - если GATT/TCP заблокированы, payload остаются в outbox
  // После получения токена - сразу инициировать подключение
  final Map<String, DateTime> _pendingBridgeConnections =
      {}; // MAC -> время обнаружения BRIDGE без токена

  // 🔥 КРИТИЧНО: Per-BRIDGE lock для предотвращения race condition при одновременных подключениях
  final Map<String, DateTime> _activeBridgeConnections =
      {}; // MAC -> время начала подключения

  // 🔒 SECURITY FIX: Сохраняем ScanResult СРАЗУ при обнаружении BRIDGE
  // Это решает race condition когда scan останавливается до Stage 2
  ScanResult? _cascadeSavedScanResult;
  DateTime? _cascadeSavedScanResultTime;
  // 🔥 MAC RANDOMIZATION FIX: Увеличено с 30s до 45s
  // ScanResult может устареть если MAC изменился, но quick rescan найдёт новый
  static const Duration _scanResultMaxAge =
      Duration(seconds: 45); // Max age for saved scan result

  /// Публичный метод для Connection Stabilizer
  /// Публичный метод для выполнения каскадной ретрансляции (для ConnectionStabilizer)
  Future<void> executeCascadeRelay(ScanResult target, int peerHops) async {
    await _executeCascadeRelay(target, peerHops);
  }

  /// Публичный метод для подключения к BRIDGE (альтернатива executeCascadeRelay)
  /// Используется ConnectionStabilizer для стабилизации подключения
  Future<void> connectToBridge(ScanResult bridgeScanResult, {int? hops}) async {
    final peerHops = hops ?? 0;
    _log("🔗 [MeshService] connectToBridge called (hops: $peerHops)");
    await _executeCascadeRelay(bridgeScanResult, peerHops);
  }

  // 🔥 BLE STABILIZATION: Hard limit ожидания batch (должен быть >= bluetooth_service._batchHardLimitSeconds 35s)
  static const int _bleBatchHardLimitSeconds = 40;
  // 🔥 BLE STABILIZATION: Watchdog > batch(40s); cooldown 20s
  static const int _cascadeWatchdogSeconds = 45;
  // 🔥 BLE STABILIZATION: TTL для _isTransferring — должен быть > watchdog(45s), иначе сброс mid-batch
  static const int _transferTtlSeconds = 50;
  // DTN: Timeout ordering — connect(20s) + discover+notify+transfer ≤ 35s < batch wait 40s < watchdog 45s; cooldown 20s after fail.

  /// DTN: Decrement cascade count and update _isTransferring. Call on every cascade exit (no global block of other candidates).
  void _exitCascade() {
    _cascadeInProgressCount = (_cascadeInProgressCount - 1).clamp(0, 999);
    _isTransferring = _cascadeInProgressCount > 0;
    _transferStartTime = null;
    notifyListeners();
  }

  Future<void> _executeCascadeRelay(ScanResult target, int peerHops) async {
    // 🔒 BLE BACKPRESSURE: Do not start a new cascade while a BLE transaction is in progress.
    if (_btService.bleTransactionState != BleTransactionState.IDLE) {
      _log(
          "[BLE-BLOCK] Cascade deferred — BLE transaction in progress (${_btService.bleTransactionState}), will retry in 4s");
      Future.delayed(const Duration(seconds: 4), () {
        unawaited(_executeCascadeRelay(target, peerHops));
      });
      return;
    }

    // 🔥 CRITICAL FIX: Проверка ДОЛЖНА быть ПЕРВОЙ СТРОКОЙ!
    // Race condition: unawaited() вызывает функцию асинхронно, и два вызова
    // могут войти в функцию до того как первый установит _isTransferring = true
    // Это вызывало параллельные GATT connections которые блокируют BLE stack

    // 🔥 BLE STABILIZATION: TTL для _isTransferring — автоматический сброс при зависании
    // DTN: Reset stuck state; no cooldown. Does not block other candidates.
    if (_isTransferring && _transferStartTime != null) {
      final transferAge =
          DateTime.now().difference(_transferStartTime!).inSeconds;
      if (transferAge > _transferTtlSeconds) {
        _log(
            "🚨 [TTL] _isTransferring stuck for ${transferAge}s (>${_transferTtlSeconds}s), forcing reset WITHOUT cooldown");
        _cascadeInProgressCount = 0;
        _isTransferring = false;
        _transferStartTime = null;
        notifyListeners();
      }
    }

    // 🔒 STRICT ROLE ARBITRATION: Only ONE cascade at a time. Prevents parallel BLE Central sessions and FSM oscillations (Huawei).
    if (_cascadeInProgressCount > 0) {
      _log(
          "⏸️ [CASCADE] Blocked — one cascade already active (count: $_cascadeInProgressCount). Single BLE session only.");
      return;
    }

    _cascadeInProgressCount++;
    _isTransferring = _cascadeInProgressCount > 0;
    _transferStartTime = DateTime.now();
    notifyListeners();

    // 🔥 MAC RANDOMIZATION FIX: var вместо final - MAC может измениться после quick rescan!
    var targetMac = target.device.remoteId.str;
    _log(
        "🔒 [CASCADE] Starting cascade to ${targetMac.substring(targetMac.length - 8)} (active cascades: $_cascadeInProgressCount)");

    // 🔒 SECURITY FIX #1: СРАЗУ сохраняем ScanResult при старте cascade
    // Это КРИТИЧНО! Scan может быть остановлен во время Stage 1 (Wi-Fi),
    // и когда Stage 2 (BLE GATT) начнётся - lastScanResults будет пуст.
    // Сохраняем ScanResult ДО любых операций со scan.
    _cascadeSavedScanResult = target;
    _cascadeSavedScanResultTime = DateTime.now();
    _log(
        "💾 [CASCADE-FIX] ScanResult saved IMMEDIATELY at cascade start (MAC: ${targetMac.substring(targetMac.length - 8)})");

    // 🔥 Улучшение: Проверяем, не превышен ли лимит попыток BLE GATT
    final gattAttempts = _bleGattAttempts[targetMac] ?? 0;
    if (gattAttempts >= 2 && peerHops == 0) {
      // Если BLE GATT не удался >2 раз для BRIDGE, сразу пробуем TCP
      _log(
          "🔄 [Cascade] BLE GATT failed $gattAttempts times, trying TCP fallback immediately");
      final candidate =
          locator<DiscoveryContextService>().getCandidateByMac(targetMac);
      if (candidate != null && candidate.ip != null && candidate.port != null) {
        try {
          if (candidate.bridgeToken != null) {
            // 🔥 MAC RANDOMIZATION FIX: Токен теперь валиден 60 секунд
            // Синхронизировано с heartbeat интервалом (60s)
            await _handleMagnetWave(
                candidate.bridgeToken!,
                candidate.port!,
                DateTime.now()
                    .add(const Duration(seconds: 60))
                    .millisecondsSinceEpoch);
            _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе
            _exitCascade();
            _log("🔓 [CASCADE] TCP fallback success");
            return;
          }
        } catch (e) {
          _log("❌ [Cascade] TCP fallback also failed: $e");
        }
      }
    }

    // 🔥 FIX: Cooldown теперь ставится ТОЛЬКО после НЕУДАЧНОЙ попытки, не ДО!
    // Раньше cooldown ставился здесь и блокировал все последующие попытки даже если первая ещё не завершилась
    final cooldownKey = _getCooldownKey(target);
    _log("⛓️ Engaging Cascade for node ${target.device.remoteId}");
    _log("   📋 Cooldown will be set ONLY after failed attempt (not before!)");

    // 🔥 BLE STABILIZATION: Watchdog срабатывает РАНЬШЕ cooldown (15s < 20s)
    // Это гарантирует, что зависший batch будет сброшен до истечения cooldown
    // При срабатывании watchdog НЕ ставим cooldown — это зависание, не ошибка peer
    Timer? transferTimeoutTimer;
    transferTimeoutTimer =
        Timer(Duration(seconds: _cascadeWatchdogSeconds), () {
      if (_isTransferring) {
        _log(
            "🚨 [WATCHDOG] Transfer timeout (${_cascadeWatchdogSeconds}s). Resetting WITHOUT cooldown.");
        _cascadeInProgressCount = 0;
        _isTransferring = false;
        _transferStartTime = null;
        // 🔥 Unblock scan if GATT mutex stuck (batch может зависнуть на connect/discover)
        _btService.forceResetGattState("watchdog timeout - unblock BLE scan");
        notifyListeners();
      }
    });

    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) {
      transferTimeoutTimer?.cancel();
      _exitCascade();
      return;
    }

    // 🔥 МАСШТАБИРУЕМОСТЬ: Ограничение активных payload (10-20 на узел)
    // Обрабатываем только первые _maxActivePayloads сообщений
    final activePending = pending.take(_maxActivePayloads).toList();
    if (activePending.isEmpty) {
      _log("⏸️ [Scalability] No active payloads available (all in processing)");
      transferTimeoutTimer?.cancel();
      _exitCascade();
      return;
    }

    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Извлекаем messageId из первого активного pending сообщения
    final messageId = activePending.first['id'] as String;

    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем, не превышен ли лимит попыток для этого payload
    final retryInfo =
        _payloadRetries.putIfAbsent(messageId, () => PayloadRetryInfo());
    if (retryInfo.maxRetriesReached) {
      _log(
          "⏸️ [Scalability] Payload $messageId exceeded max retries (GATT: ${retryInfo.gattAttempts}, TCP: ${retryInfo.tcpAttempts}, Sonar: ${retryInfo.sonarAttempts})");
      _activePayloads.remove(messageId);
      transferTimeoutTimer?.cancel();
      _exitCascade();
      return;
    }

    // 🔥 МАСШТАБИРУЕМОСТЬ: Отмечаем payload как активный и записываем время начала цикла
    if (!_activePayloads.contains(messageId)) {
      _activePayloads.add(messageId);
      retryInfo.cycleStartTime = DateTime.now();
      retryInfo.outboxSizeAtStart = pending.length;
      retryInfo.hopsToBridge = peerHops; // Сохраняем hops для логирования
      _log(
          "📊 [Scalability] Starting cycle for payload $messageId (outbox size: ${pending.length}, active: ${_activePayloads.length}/${_maxActivePayloads}, hops: $peerHops)");
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

    _log(
        "🔍 [ROLE-CHECK] My role: ${myRole == MeshRole.GHOST ? 'GHOST' : 'BRIDGE'}, My hops: $myHops, My pending: $myPendingCount");
    _log(
        "🔍 [ROLE-CHECK] Peer role: ${peerIsBridge ? 'BRIDGE' : (peerIsGhost ? 'GHOST' : 'UNKNOWN')}, Peer hops: $peerHops");

    // 🔥 КРИТИЧНО: Если мы GHOST и нашли BRIDGE (hops=0) - подключаемся немедленно, ИГНОРИРУЯ hops сравнение
    if (myRole == MeshRole.GHOST && peerIsBridge) {
      _log(
          "🧲 [Ghost→Bridge] ⚡ BRIDGE DETECTED (hops=0)! Connecting immediately to upload messages...");
      _log("🧲 [Ghost→Bridge] Ignoring hops comparison - BRIDGE has priority!");
      // Продолжаем подключение - НЕ проверяем hops для BRIDGE
    } else if (myRole == MeshRole.GHOST && peerIsGhost) {
      final ghostMeta = GhostRoleMetadata.fromScanResult(target);
      final myIntent =
          myPendingCount > 0 ? GhostRoleIntent.client : GhostRoleIntent.server;
      final myToken = _apiService.currentUserId.isNotEmpty
          ? _apiService.currentUserId
          : "ghost-${hashCode.toRadixString(16)}";
      final peerMac = target.device.remoteId.str;
      final myMac = await _getMyBleMacForTieBreaker();
      // Jitter 0–500 ms по hash(peerMac+myMac) чтобы снизить вероятность «оба CENTRAL» при гонке
      final jitterMs = ((peerMac.hashCode + (myMac?.hashCode ?? 0)).abs() % 501);
      if (jitterMs > 0) {
        await Future.delayed(Duration(milliseconds: jitterMs));
      }
      final decision = GhostRoleSelector.decide(
        myIntent: myIntent,
        peerIntent: ghostMeta.intent,
        myHops: myHops,
        peerHops: peerHops,
        myPending: myPendingCount,
        myToken: myToken,
        peerToken: ghostMeta.token,
        myMac: myMac,
        peerMac: peerMac,
      );

      _log(
          "📤 [GHOST↔GHOST] roleDecision=${decision.reason}, shouldConnect=${decision.shouldConnect}");
      if (!decision.shouldConnect) {
        transferTimeoutTimer?.cancel();
        _exitCascade();
        notifyListeners();
        return;
      }
      // 🔥 Hardware-aware BLE strategy. Default path unchanged; ADAPTIVE only when BLE-only, no relay, peerCount ≤ 1.
      final localProfile = await HardwareCapabilityProfile.forLocal();
      final peerProfile = HardwareCapabilityProfile.fromScanResult(target);
      final hasRelayNearby = _nearbyNodes.values.any((n) =>
          n.id.contains('BRIDGE') || n.id.contains('RELAY'));
      final bleOnly = !_isP2pConnected && !hasRelayNearby;
      final ctx = BleAdaptiveContext(
        hasRelayNearby: hasRelayNearby,
        hasWifiDirect: _isP2pConnected,
        bleOnly: bleOnly,
        peerCount: _nearbyNodes.length,
        localPeerId: myMac ?? 'local-${hashCode}',
        remotePeerId: peerMac,
        outboxNonEmpty: activePending.isNotEmpty,
      );
      final strategy = ctx.useAdaptiveMode
          ? BleLinkStrategyResolver.resolveAdaptive(
              localProfile, peerProfile, ctx, _log)
          : BleLinkStrategyResolver.resolve(localProfile, peerProfile);
      _log(
          "[BLE-STRATEGY] local=${localProfile.vendorLabel} peer=${peerProfile.vendorLabel} → ${strategy.localInitiatesGatt ? 'localInitiates' : 'peerInitiates'}${strategy.isHuaweiBreakGlass ? ' (break-glass)' : ''}");
      _isHuaweiBreakGlassThisCascade = strategy.isHuaweiBreakGlass;
      _writeStrategyThisCascade = getWriteStrategyForPair(localProfile, peerProfile);
      if (!strategy.localInitiatesGatt) {
        if (strategy.passiveWaitOnly) {
          _log(
              "[BLE-STRATEGY] passiveWaitOnly (e.g. HUAWEI↔HUAWEI) — use Wi‑Fi Direct / Repeater / passive BLE");
        }
        _log(
            "📤 [GHOST↔GHOST] Strategy: not initiating GATT (restrictive vendor or passive), waiting for peer to connect");
        transferTimeoutTimer?.cancel();
        _exitCascade();
        notifyListeners();
        return;
      }
      // Adaptive (non-Huawei only): prefer wait as PERIPHERAL if recent GATT failures with this peer.
      // Huawei/Honor never enter this path; Tecno→Huawei unchanged.
      if (localProfile.vendor != BleVendor.huawei &&
          localProfile.vendor != BleVendor.honor &&
          peerProfile.vendor != BleVendor.huawei &&
          peerProfile.vendor != BleVendor.honor &&
          adaptivePreferNotToInitiateToPeer(target.device.remoteId.str)) {
        _log(
            "[BLE-STRATEGY] Adaptive: prefer wait (recent failures with peer), not initiating GATT this cycle");
        transferTimeoutTimer?.cancel();
        _exitCascade();
        notifyListeners();
        return;
      }
    }

    // --- STAGE 1: WI-FI DIRECT HUNT ---
    _log("📡 Stage 1: Wi-Fi Hunt initiated...");
    _isEscalating = true;
    _targetIdToHunt = target.device.remoteId.str
        .substring(target.device.remoteId.str.length - 4);

    // Запускаем discovery и ждем появления пиров
    await NativeMeshService.startDiscovery();

    // 🔥 Wi-Fi Direct Fix: MESH_TIMING_AUDIT — 5+3 s total for P2P (was 4+2)
    bool peerFound = false;
    bool connectionEstablished = false;

    for (int i = 0; i < 5; i++) {
      await Future.delayed(const Duration(seconds: 1));

      if (_isP2pConnected) {
        connectionEstablished = true;
        break;
      }

      final wifiNodes =
          _nearbyNodes.values.where((n) => n.type == SignalType.mesh).toList();
      if (wifiNodes.isNotEmpty && !peerFound) {
        final targetNode = wifiNodes.first;
        _log("🔗 Found Wi-Fi peer: ${targetNode.id}, attempting connection...");
        unawaited(connectToNode(targetNode.id));
        peerFound = true;
      }
    }

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
      _log("   📋 P2P connected: $_isP2pConnected");
      _log("   📋 Connection established: $connectionEstablished");

      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
      final msgId = activePending.isNotEmpty
          ? activePending.first['id'] as String
          : messageId;
      if (_sentPayloads.containsKey(msgId)) {
        _log(
            "🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
        transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
        _exitCascade();
        _isEscalating = false;
        return;
      }

      // [WIFI-PULL] Stage 1 Wi-Fi: no push. Outbox over Wi-Fi only via OUTBOX_REQUEST response (pull-only, same as BLE).
      _log("📤 [GHOST→BRIDGE] Stage 1: Wi-Fi Direct — pull-only (no cascade push); ${activePending.length} in outbox");
      int sentCount = 0;
      for (var msgData in activePending) {
        final currentMsgId = msgData['id'] as String;
        if (_sentPayloads.containsKey(currentMsgId)) {
          _log("   ⏭️ Skipping already sent message: $currentMsgId");
          continue;
        }
        try {
          // Wi-Fi does not push outbox here; skip TCP burst. Cascade continues to Stage 2 (BLE) if needed.
          final bool actuallySent = false;
          if (actuallySent) {
            _sentPayloads[currentMsgId] = 'WIFI_DIRECT';
            await _db.removeFromOutbox(currentMsgId);
            sentCount++;
            _log("   ✅ Message $currentMsgId sent and removed from outbox");
            try {
              locator<PeerCacheService>().recordSuccess(
                  peerId: _lastKnownPeerIp,
                  latency: Duration.zero,
                  channel: 'wifiDirect');
            } catch (_) {}

            if (sentCount < activePending.length) {
              await Future.delayed(const Duration(milliseconds: 50));
            }
          } else {
            _log("   ⏭️ Wi-Fi pull-only: not pushing $currentMsgId (outbox via OUTBOX_REQUEST only)");
          }
        } catch (e) {
          try {
            locator<PeerCacheService>().recordFailure(
                peerId: _lastKnownPeerIp,
                channel: 'wifiDirect',
                reason: e.toString());
          } catch (_) {}
          _log("   ⚠️ Failed to send message $currentMsgId: $e");
        }
      }

      _log(
          "   ✅ Sent $sentCount/${activePending.length} message(s) via Wi-Fi Direct TCP");

      // 🔥 FIX: Выходим из каскада только если хотя бы одно сообщение реально отправлено.
      // Иначе (GO skip / no peer) — переходим в Stage 2 (BLE GATT), не удаляя сообщения из outbox.
      if (sentCount == 0) {
        _log("   ⚠️ [Stage 1] No messages actually sent (e.g. GO would send to self) — falling through to Stage 2 BLE");
        _isEscalating = false;
        // не делаем _exitCascade и return — продолжаем ниже в Stage 2
      } else {
        final firstSentMsgId = activePending.isNotEmpty
            ? activePending.first['id'] as String
            : msgId;
        _log(
            "📦 [ARCHITECTURE] Payload $firstSentMsgId marked as SENT_OK (WIFI_DIRECT), removed from outbox");

        final retryInfo = _payloadRetries[msgId];
        final cycleDuration = retryInfo?.cycleDuration;
        final hops = retryInfo?.hopsToBridge ?? peerHops;
        final outboxSize = retryInfo?.outboxSizeAtStart ?? activePending.length;
        _log(
            "🔄 [ARCHITECTURE] Cycle CLOSED via WIFI_DIRECT (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");

        _activePayloads.remove(msgId);
        _payloadRetries.remove(msgId);

        transferTimeoutTimer?.cancel();
        _exitCascade();
        _isEscalating = false;
        return;
      }
    }

    // --- STAGE 2: BLE GATT ATTACK ---
    _log("⚠️ Stage 1 Failed (Wi-Fi silent). Stage 2: BLE GATT...");
    _log("   📋 P2P connected: $_isP2pConnected");
    _log("   📋 P2P discovery active: $_p2pDiscoveryActive");
    _log("   💡 Wi-Fi Direct not connected - will try BLE GATT");
    _isEscalating = false;

    // 🔥 CRITICAL FIX: Делаем БЫСТРЫЙ RESCAN перед GATT connect
    // Это гарантирует что мы получаем СВЕЖИЙ ScanResult с актуальным MAC
    // 🔥 MAC RANDOMIZATION FIX: Ищем по ТОКЕНУ, а не по MAC!
    // Android меняет MAC при каждой ротации advertising, но токен остаётся тем же
    _log(
        "🔄 [STAGE 2] Starting quick rescan (${_quickRescanDurationSeconds}s) to get fresh BRIDGE...");

    // 🔥 КРИТИЧНО: Извлекаем ТОКЕН из оригинального target для поиска
    // Используем targetTokenForSearch чтобы не конфликтовать с originalToken ниже
    final targetTokenForSearch = _extractTokenFromScanResult(target);
    final targetTokenPreview =
        targetTokenForSearch != null && targetTokenForSearch.length > 8
            ? targetTokenForSearch.substring(0, 8)
            : (targetTokenForSearch ?? 'none');
    _log(
        "🔑 [STAGE 2] Target token for search: $targetTokenPreview... (will search by token, not MAC!)");
    _log(
        "   📋 Original MAC: ${targetMac.substring(targetMac.length - 8)} (may change due to randomization)");
    final targetDeviceUuid = _extractDeviceUuidFromScanResult(target);
    if (targetDeviceUuid != null) {
      _log("   📋 Target device UUID: $targetDeviceUuid (connect by UUID when MAC rotates)");
    }

    ScanResult? freshScanResult;
    String? freshMac; // Новый MAC если изменился
    try {
      // 🔥 UUID-FIX: Сначала пробуем scan с SERVICE_UUID — устройства с UUID надёжнее для GATT connect
      List<ScanResult> freshResults = [];
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 3),
          withServices: [Guid(_btService.SERVICE_UUID)],
          androidScanMode: AndroidScanMode.lowLatency,
        );
        await Future.delayed(const Duration(seconds: 3));
        await FlutterBluePlus.stopScan();
        freshResults = await FlutterBluePlus.lastScanResults;
        if (freshResults.isNotEmpty) {
          _log(
              "🔍 [STAGE 2] UUID scan found ${freshResults.length} device(s) with SERVICE_UUID");
        }
      } catch (e) {
        _log("⚠️ [STAGE 2] UUID scan failed or empty: $e");
      }

      // Если UUID scan пуст — делаем обычный scan (Huawei/Techno часто не рекламируют UUID)
      if (freshResults.isEmpty) {
        await FlutterBluePlus.startScan(
          timeout: Duration(seconds: _quickRescanDurationSeconds),
          androidScanMode: AndroidScanMode.lowLatency,
        );
        await Future.delayed(Duration(seconds: _quickRescanDurationSeconds));
        await FlutterBluePlus.stopScan();
        freshResults = await FlutterBluePlus.lastScanResults;
      }
      _log("🔍 [STAGE 2] Quick rescan found ${freshResults.length} devices");

      // Собираем BRIDGE и GHOST для fallback. 🔥 UUID-FIX: Приоритет — устройства с SERVICE_UUID.
      ScanResult? singleBridgeFallback;
      ScanResult?
          bestUuidFallback; // Лучший fallback — устройство с SERVICE_UUID
      final bridgeTokensSeen = <String>{};

      // 🔥 MAC RANDOMIZATION + GHOST FIX: Ищем BRIDGE по ТОКЕНУ, GHOST по MAC; включаем hasService
      // 🔥 HUAWEI/TECNO: manufacturerData может быть под ключом 0xFFFF или 65535
      for (final result in freshResults) {
        final mfMapR = result.advertisementData.manufacturerData;
        List<int>? mfData = mfMapR[0xFFFF] ?? mfMapR[65535];
        if (mfData == null && mfMapR.isNotEmpty) {
          for (final e in mfMapR.entries) {
            final v = e.value;
            if (v.length >= 2 &&
                ((v[0] == 0x47 && v[1] == 0x48) ||
                    (v[0] == 71 && v[1] == 72) ||
                    (v[0] == 0x42 && v[1] == 0x52) ||
                    (v[0] == 66 && v[1] == 82))) {
              mfData = v;
              break;
            }
          }
        }
        final isBridgeByMfData = mfData != null &&
            mfData.length >= 2 &&
            (mfData[0] == 0x42 || mfData[0] == 66) &&
            (mfData[1] == 0x52 || mfData[1] == 82); // "BR" = BRIDGE
        final isGhostByMfData = mfData != null &&
            mfData.length >= 2 &&
            (mfData[0] == 0x47 || mfData[0] == 71) &&
            (mfData[1] == 0x48 || mfData[1] == 72); // "GH" = GHOST
        final hasService = result.advertisementData.serviceUuids.any((uuid) =>
            uuid.toString().toLowerCase() ==
            _btService.SERVICE_UUID.toLowerCase());

        if (isBridgeByMfData || isGhostByMfData || hasService) {
          final resultMac = result.device.remoteId.str;
          final resultToken = _extractTokenFromScanResult(result);
          if (resultToken != null) bridgeTokensSeen.add(resultToken);
          final resultTokenPreview =
              resultToken != null && resultToken.length > 8
                  ? resultToken.substring(0, 8)
                  : (resultToken ?? 'none');

          // 🔥 КРИТИЧНО: Сравниваем по ТОКЕНУ, а не по MAC!
          final tokenMatches = targetTokenForSearch != null &&
              resultToken != null &&
              (resultToken == targetTokenForSearch ||
                  resultToken.startsWith(targetTokenForSearch) ||
                  targetTokenForSearch.startsWith(resultToken));
          final macMatches = resultMac == targetMac;
          final resultDeviceUuid = _extractDeviceUuidFromScanResult(result);
          final deviceUuidMatches = targetDeviceUuid != null &&
              resultDeviceUuid != null &&
              targetDeviceUuid == resultDeviceUuid;

          if (tokenMatches) {
            // Токен совпал - это наш BRIDGE, даже если MAC изменился!
            freshScanResult = result;
            freshMac = resultMac;
            _log("✅ [STAGE 2] 🎯 BRIDGE found by TOKEN match!");
            _log("   📋 Token: $resultTokenPreview... (matches original)");
            _log("   📋 New MAC: ${resultMac.substring(resultMac.length - 8)}");
            if (!macMatches) {
              _log(
                  "   ⚠️ MAC CHANGED: ${targetMac.substring(targetMac.length - 8)} → ${resultMac.substring(resultMac.length - 8)}");
              _log(
                  "   ✅ This is normal - Android randomizes MAC on advertising rotation");
            }
            break; // Нашли по токену - это точно наш BRIDGE
          } else if (macMatches) {
            // MAC совпал — подходит для BRIDGE и GHOST
            freshScanResult = result;
            freshMac = resultMac;
            _log(
                "✅ [STAGE 2] Mesh device found by MAC match: ${resultMac.substring(resultMac.length - 8)}, token: $resultTokenPreview");
            if (isGhostByMfData) {
              _log(
                  "   📋 GHOST target matched by MAC (UUID-based connect preferred)");
            }
            // Не break - продолжаем искать по токену (более надёжно для BRIDGE)
          } else if (deviceUuidMatches && peerHops > 0) {
            // GHOST: совпадение по стабильному device UUID — MAC мог смениться
            freshScanResult = result;
            freshMac = resultMac;
            _log("✅ [STAGE 2] GHOST found by device UUID (MAC may have rotated)");
            _log("   📋 Device UUID: $resultDeviceUuid");
            _log("   📋 Current MAC: ${resultMac.substring(resultMac.length - 8)}");
            break;
          } else if (singleBridgeFallback == null && isBridgeByMfData) {
            singleBridgeFallback = result;
          }
          // 🔥 UUID-FIX: Сохраняем первое устройство с SERVICE_UUID для fallback
          if (hasService && bestUuidFallback == null) {
            bestUuidFallback = result;
          }
        }
      }

      // 🔒 UUID-FIX: Если целевое устройство не найдено, но есть устройство с SERVICE_UUID — используем его
      if (freshScanResult == null && bestUuidFallback != null && peerHops > 0) {
        freshScanResult = bestUuidFallback;
        freshMac = bestUuidFallback!.device.remoteId.str;
        _log(
            "✅ [STAGE 2] Using device with SERVICE_UUID for GATT connect (MAC: ${freshMac.substring(freshMac.length - 8)})");
        _log("   💡 Prefer UUID-based connection for reliable BLE GATT");
      }

      // 🔒 Безопасный fallback: только если не нашли по token/MAC И в зоне РОВНО 1 BRIDGE
      if (freshScanResult == null &&
          singleBridgeFallback != null &&
          bridgeTokensSeen.length == 1) {
        freshScanResult = singleBridgeFallback;
        freshMac = singleBridgeFallback.device.remoteId.str;
        _log(
            "ℹ️ [STAGE 2] BRIDGE found (safe fallback - only 1 BRIDGE in range): ${freshMac.substring(freshMac.length - 8)}");
      } else if (freshScanResult == null && bridgeTokensSeen.length > 1) {
        _log(
            "⚠️ [STAGE 2] Multiple BRIDGEs in range (${bridgeTokensSeen.length} tokens) - NOT switching, using saved target");
      }

      // 🔥 Обновляем targetMac если MAC изменился
      if (freshMac != null && freshMac != targetMac) {
        _log(
            "🔄 [STAGE 2] Updating target MAC: ${targetMac.substring(targetMac.length - 8)} → ${freshMac.substring(freshMac.length - 8)}");
        // targetMac будет обновлён через savedScanResult
      }
    } catch (e) {
      _log("⚠️ [STAGE 2] Quick rescan failed: $e - using saved result");
    }

    // 🔒 SECURITY FIX #2: Используем СВЕЖИЙ ScanResult если есть, иначе сохранённый
    ScanResult? savedScanResult = freshScanResult ?? _cascadeSavedScanResult;

    // 🔥 MAC RANDOMIZATION FIX: Обновляем targetMac если он изменился!
    // Это критично - без этого GATT connect будет идти на старый несуществующий MAC
    if (freshScanResult != null) {
      final newMac = freshScanResult.device.remoteId.str;
      if (newMac != targetMac) {
        _log("🔄 [MAC-UPDATE] Target MAC updated after quick rescan:");
        _log("   📋 Old MAC: ${targetMac.substring(targetMac.length - 8)}");
        _log("   📋 New MAC: ${newMac.substring(newMac.length - 8)}");
        _log("   ✅ GATT connect will use NEW MAC (fresh from advertising)");
        targetMac = newMac; // 🔥 КРИТИЧНО: Обновляем targetMac!
      }
    }

    // 🔒 Проверяем, что сохранённый ScanResult не слишком старый (только если не свежий)
    if (freshScanResult == null &&
        savedScanResult != null &&
        _cascadeSavedScanResultTime != null) {
      final age = DateTime.now().difference(_cascadeSavedScanResultTime!);
      if (age > _scanResultMaxAge) {
        _log(
            "⚠️ [CASCADE-FIX] Saved ScanResult too old (${age.inSeconds}s > ${_scanResultMaxAge.inSeconds}s), clearing");
        savedScanResult = null;
        _cascadeSavedScanResult = null;
      } else {
        _log(
            "✅ [CASCADE-FIX] Using saved ScanResult from cascade start (age: ${age.inSeconds}s, MAC: ${savedScanResult.device.remoteId.str.substring(savedScanResult.device.remoteId.str.length - 8)})");
      }
    } else if (freshScanResult != null) {
      // Обновляем сохранённый ScanResult свежим
      _cascadeSavedScanResult = freshScanResult;
      _cascadeSavedScanResultTime = DateTime.now();
      _log("✅ [STAGE 2] Updated saved ScanResult with fresh data");
    }

    // 🔒 SECURITY FIX #3: Только если savedScanResult всё ещё null - пробуем lastScanResults
    // Но это fallback - основной источник это _cascadeSavedScanResult
    if (savedScanResult == null) {
      try {
        final lastScanResults = await FlutterBluePlus.lastScanResults;
        _log(
            "🔍 [STAGE 2] No saved ScanResult, checking lastScanResults (${lastScanResults.length} results)...");

        // 🔥 FIX: Сначала ищем BRIDGE С токеном (mfData.length > 2)
        ScanResult? bestResultWithToken;
        ScanResult? fallbackResult;

        for (final result in lastScanResults) {
          final mfData = result.advertisementData.manufacturerData[0xFFFF];
          final isBridgeByMfData = mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x42 &&
              mfData[1] == 0x52; // "BR" = BRIDGE
          final hasToken = mfData != null && mfData.length > 2;
          final hasService = result.advertisementData.serviceUuids.any((uuid) =>
              uuid.toString().toLowerCase() ==
              _btService.SERVICE_UUID.toLowerCase());

          if (isBridgeByMfData || hasService) {
            if (hasToken && bestResultWithToken == null) {
              bestResultWithToken = result;
              _log(
                  "✅ [STAGE 2] Found BRIDGE WITH TOKEN (MAC: ${result.device.remoteId.str.substring(result.device.remoteId.str.length - 8)}, mfData: ${mfData?.length ?? 0} bytes)");
            } else if (fallbackResult == null) {
              fallbackResult = result;
              _log(
                  "📋 [STAGE 2] Found BRIDGE without token (MAC: ${result.device.remoteId.str.substring(result.device.remoteId.str.length - 8)}, mfData: ${mfData?.length ?? 0} bytes)");
            }
          }
        }

        if (bestResultWithToken != null) {
          savedScanResult = bestResultWithToken;
          _log("✅ [STAGE 2] Using BRIDGE WITH TOKEN from lastScanResults");
        } else if (fallbackResult != null) {
          savedScanResult = fallbackResult;
          _log(
              "⚠️ [STAGE 2] Using BRIDGE WITHOUT TOKEN as fallback from lastScanResults");
        }
        // GHOST: ищем по стабильному device UUID (MAC мог смениться)
        if (savedScanResult == null && targetDeviceUuid != null && peerHops > 0) {
          for (final result in lastScanResults) {
            if (_extractDeviceUuidFromScanResult(result) == targetDeviceUuid) {
              savedScanResult = result;
              _log("✅ [STAGE 2] Using device UUID match from lastScanResults (MAC: ${result.device.remoteId.str.substring(result.device.remoteId.str.length - 8)})");
              break;
            }
          }
        }
        if (savedScanResult == null && targetMac.isNotEmpty) {
          for (final result in lastScanResults) {
            if (result.device.remoteId.str != targetMac) continue;
            // 🔒 Только mesh: не подключаться к устройству по MAC, если нет нашего UUID/mfData
            final mf = result.advertisementData.manufacturerData[0xFFFF];
            final hasMf = mf != null && mf.length >= 2 && ((mf[0] == 0x42 && mf[1] == 0x52) || (mf[0] == 0x47 && mf[1] == 0x48) || (mf[0] == 0x52 && mf[1] == 0x4C));
            final hasUuid = result.advertisementData.serviceUuids.any((u) => u.toString().toLowerCase().contains("bf27730d"));
            if (!hasUuid && !hasMf) continue;
            savedScanResult = result;
            _log("⚠️ [STAGE 2] Using targetMac fallback from lastScanResults (mesh UUID/mfData confirmed)");
            break;
          }
        }
      } catch (e) {
        _log("⚠️ [STAGE 2] Could not search lastScanResults: $e");
      }
    }

    // 🔥 HUAWEI FIX: НЕ останавливаем scan на Huawei - это может привести к потере устройства
    // Вместо этого сохраняем ScanResult и используем его для подключения
    _log("🛑 [GHOST] Preparing for GATT connect (saving ScanResult first)...");

    // 🔥 КРИТИЧНО: Сохраняем ScanResult ПЕРЕД остановкой scan (если scan активен)
    // Это решает проблему "Target device not found" на Huawei
    if (_isBtScanning) {
      try {
        // 🔥 FIX: Если у нас уже есть savedScanResult с токеном - не перезаписываем
        // Это важно, потому что Huawei меняет MAC и некоторые пакеты без токена
        final currentMfData =
            savedScanResult?.advertisementData.manufacturerData[0xFFFF];
        final currentHasToken =
            currentMfData != null && currentMfData.length > 2;

        if (!currentHasToken) {
          // Только если текущий savedScanResult без токена - пытаемся найти лучший
          final lastScanResults = await FlutterBluePlus.lastScanResults;

          for (final result in lastScanResults) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBridgeByMfData = mfData != null &&
                mfData.length >= 2 &&
                mfData[0] == 0x42 &&
                mfData[1] == 0x52; // "BR" = BRIDGE
            final hasToken = mfData != null && mfData.length > 2;
            final hasService = result.advertisementData.serviceUuids.any(
                (uuid) =>
                    uuid.toString().toLowerCase() ==
                    _btService.SERVICE_UUID.toLowerCase());

            // 🔥 ПРИОРИТЕТ: Ищем BRIDGE с токеном
            if ((isBridgeByMfData || hasService) && hasToken) {
              savedScanResult = result;
              final mac = result.device.remoteId.str;
              _log(
                  "✅ [STAGE 2] Found better ScanResult WITH TOKEN (MAC: ${maskMacForLog(mac)}, mfData: ${mfData?.length ?? 0} bytes)");
              break; // Нашли с токеном - выходим
            }
          }
        } else {
          _log("ℹ️ [STAGE 2] Already have ScanResult with token - keeping it");
        }

        // 🔥 FIX: ПРИНУДИТЕЛЬНАЯ ОСТАНОВКА SCAN ПЕРЕД GATT CONNECT
        // КРИТИЧНО: scan и connectGatt конфликтуют на Android BLE стеке!
        // Старый "Huawei optimization" держал scan активным - это причина неудачных connect!
        _log(
            "🛑 [GHOST] FORCE stopping scan before GATT connect (Android BLE requirement)");
        try {
          await FlutterBluePlus.stopScan();
          _isBtScanning = false;
          _log("✅ [GHOST] Scan STOPPED - ready for GATT connect");
        } catch (e) {
          _log("⚠️ [GHOST] Error stopping scan: $e - proceeding anyway");
        }
      } catch (e) {
        _log("⚠️ [GHOST] Failed to save ScanResult: $e");
      }
    }

    // Останавливаем advertising (если было), но GATT сервер оставляем включённым.
    // Иначе второй пир при подключении к нам (пока мы пытаемся подключиться к нему) не найдёт
    // наш сервис bf27730d-... → "Service not found after retry".
    try {
      if (_btService.state == BleAdvertiseState.advertising) {
        await _btService.stopAdvertising(keepGattServer: true);
        _log("✅ [GHOST] Advertising stopped");
      }
    } catch (e) {
      _log("⚠️ [GHOST] Failed to stop advertising: $e");
    }

    // 🔥 Peer settle: короткая пауза перед connect; MAC peer'а может ротироваться — не затягивать (short quiet в BT ~700ms).
    await Future.delayed(const Duration(milliseconds: 200));
    _log("📡 [GHOST] Proceeding to GATT connect (peer settle 200ms done)");

    String? originalAdvName;
    bool originalHasService = false;
    int originalPeerHops = peerHops;
    String? originalToken;
    String originalEffectiveName = '';
    bool originalIsBridgeByMfData = false;
    bool originalIsGhostByMfData = false;
    UplinkCandidate? discoveryCandidate;

    // 🔥 FIX: Используем данные из СОХРАНЁННОГО ScanResult напрямую
    // Без повторного поиска по MAC (MAC может измениться из-за рандомизации)
    if (savedScanResult != null) {
      originalAdvName = savedScanResult.advertisementData.localName ?? "";
      originalHasService = savedScanResult.advertisementData.serviceUuids.any(
          (uuid) =>
              uuid.toString().toLowerCase() ==
              _btService.SERVICE_UUID.toLowerCase());

      // Извлекаем токен из advertising name или manufacturerData
      if (originalAdvName.contains("BRIDGE") &&
          originalAdvName.split("_").length >= 5) {
        originalToken = originalAdvName.split("_")[4];
      } else {
        // Пробуем извлечь токен из manufacturerData (ключ может быть 0xFFFF или 65535)
        final mfMap = savedScanResult.advertisementData.manufacturerData;
        List<int>? mfData = mfMap[0xFFFF] ?? mfMap[65535];
        if (mfData != null && mfData.length > 2) {
          originalToken = utf8.decode(mfData.sublist(2), allowMalformed: true);
        }
      }

      _log("✅ [GHOST] Using saved ScanResult directly:");
      _log("   📋 advName: '$originalAdvName'");
      _log("   📋 hasService: $originalHasService");
      _log(
          "   📋 token: ${originalToken != null ? '${originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken}...' : 'none'}");
    } else {
      _log("⚠️ [GHOST] No saved ScanResult - will use target directly");
    }

    // 🔥 КРИТИЧНО: Проверяем, что целевое устройство все еще рекламирует перед подключением
    // 🔥 КРИТИЧНО: Объявляем targetScanResult вне try блоков, чтобы он был доступен во всех блоках
    ScanResult? targetScanResult = savedScanResult;

    // 🔥 FIX: Если есть savedScanResult - используем его НАПРЯМУЮ
    // НЕ ищем в lastScanResults - они пустые после stopScan!
    if (targetScanResult != null) {
      _log(
          "✅ [STAGE 2] Using saved ScanResult (MAC: ${targetScanResult.device.remoteId.str.substring(targetScanResult.device.remoteId.str.length - 8)})");
    } else {
      // 🔥 FIX: Если savedScanResult null - используем target напрямую
      // НЕ ищем в lastScanResults - scan уже остановлен!
      _log("⚠️ [STAGE 2] No savedScanResult - using original target directly");
      _log("   📋 This may fail if MAC changed due to randomization");
    }

    try {
      // 🔥 FIX: Используем savedScanResult напрямую БЕЗ поиска в lastScanResults
      // lastScanResults пуст после stopScan - поиск там бессмысленен

      if (targetScanResult == null) {
        _log("❌ [STAGE 2] No saved ScanResult - cannot proceed");
        _log(
            "   💡 Device was detected but ScanResult was not saved before stopScan");
        throw Exception("No ScanResult available for GATT connect");
      }

      _log("✅ [STAGE 2] Using saved ScanResult for GATT connect");

      originalHasService = targetScanResult.advertisementData.serviceUuids.any(
          (uuid) =>
              uuid.toString().toLowerCase() ==
              _btService.SERVICE_UUID.toLowerCase());
      originalAdvName = targetScanResult.advertisementData.localName ?? '';
      final originalPlatformName = targetScanResult.device.platformName;
      originalEffectiveName =
          originalAdvName.isEmpty ? originalPlatformName : originalAdvName;

      // 🔥 HUAWEI/TECNO FIX: manufacturerData — надёжное извлечение (ключ может быть 0xFFFF или 65535)
      final mfMap = targetScanResult.advertisementData.manufacturerData;
      List<int>? originalMfData = mfMap[0xFFFF] ?? mfMap[65535];
      if (originalMfData == null && mfMap.isNotEmpty) {
        for (final entry in mfMap.entries) {
          final v = entry.value;
          if (v.length >= 2 &&
              ((v[0] == 0x47 && v[1] == 0x48) ||
                  (v[0] == 71 && v[1] == 72) ||
                  (v[0] == 0x42 && v[1] == 0x52) ||
                  (v[0] == 66 && v[1] == 82))) {
            originalMfData = v;
            break;
          }
        }
      }
      originalIsBridgeByMfData = originalMfData != null &&
          originalMfData.length >= 2 &&
          (originalMfData[0] == 0x42 || originalMfData[0] == 66) &&
          (originalMfData[1] == 0x52 ||
              originalMfData[1] == 82); // "BR" = BRIDGE
      originalIsGhostByMfData = originalMfData != null &&
          originalMfData.length >= 2 &&
          (originalMfData[0] == 0x47 || originalMfData[0] == 71) &&
          (originalMfData[1] == 0x48 ||
              originalMfData[1] == 72); // "GH" = GHOST

      // Извлекаем hops и токен из advertising name для проверки
      if (originalEffectiveName.isNotEmpty &&
          originalEffectiveName.startsWith("M_")) {
        final parts = originalEffectiveName.split("_");
        if (parts.length >= 2) {
          originalPeerHops = int.tryParse(parts[1]) ?? 99;
        }
        // 🔥 ШАГ 2.2: Извлечение токена из тактического имени (формат: M_0_0_BRIDGE_TOKEN)
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          originalToken = parts[4];

          // 🔥 ШАГ 2.3: Логирование извлечения токена
          final tokenPreview = originalToken.length > 16
              ? originalToken.substring(0, 16)
              : originalToken;
          _log(
              "🔑 [GHOST] Token extracted from advertising: $tokenPreview... (length: ${originalToken.length})");
          _log("   ✅ Token found - BLE GATT / TCP allowed");
        } else {
          // 🔥 ШАГ 2.2: Токен не найден - логирование для отладки
          _log(
              "⚠️ [GHOST] Token NOT found in advertising name: '$originalAdvName'");
          _log("   📋 Parts count: ${parts.length}, expected: >=5");
          if (parts.length >= 4) {
            _log("   📋 Part[3]: '${parts[3]}', expected: 'BRIDGE'");
          }
          _log(
              "   ⚠️ Token not found in name - trying manufacturerData fallback");
        }
      } else if (originalIsBridgeByMfData) {
        // Если имя пустое, но есть manufacturerData - это BRIDGE
        originalPeerHops = 0;
        _log(
            "✅ [STAGE 2] BRIDGE detected via manufacturerData (empty localName)");
      }

      // 🔥 КРИТИЧНО: Извлекаем токен из manufacturerData (fallback для Huawei, даже если имя не пустое)
      // Это важно, потому что на некоторых устройствах имя может быть пустым или не содержать токен
      // Проверяем manufacturerData независимо от того, пустое ли имя или нет
      if (originalToken == null &&
          originalMfData != null &&
          originalMfData.length > 2) {
        // Проверяем, что это BRIDGE (первые 2 байта = "BR")
        final isBridgeByMfData =
            (originalMfData[0] == 0x42 || originalMfData[0] == 66) &&
                (originalMfData[1] == 0x52 || originalMfData[1] == 82);
        if (isBridgeByMfData) {
          try {
            final tokenBytes = originalMfData.sublist(2); // Пропускаем "BR"
            _log(
                "🔍 [GHOST] Extracting token from manufacturerData: ${originalMfData.length} bytes total, ${tokenBytes.length} bytes after 'BR'");
            _log(
                "   📋 Token bytes: ${tokenBytes.map((b) => b.toString()).join(', ')}");

            final tokenFromMf = utf8.decode(tokenBytes);
            _log(
                "   📋 Decoded token string: '$tokenFromMf' (length: ${tokenFromMf.length})");

            if (tokenFromMf.isNotEmpty && tokenFromMf.length >= 4) {
              originalToken = tokenFromMf;
              _log(
                  "🔑 [GHOST] Token extracted from manufacturerData: ${tokenFromMf.length > 8 ? tokenFromMf.substring(0, 8) : tokenFromMf}... (length: ${tokenFromMf.length}, may be truncated)");
              _log(
                  "   ✅ Token found in manufacturerData - BLE GATT / TCP allowed");
            } else {
              _log(
                  "⚠️ [GHOST] Token from manufacturerData too short: ${tokenFromMf.length} chars (minimum: 4)");
              _log("   📋 Token content: '$tokenFromMf'");
            }
          } catch (e) {
            _log("⚠️ [GHOST] Failed to decode token from manufacturerData: $e");
            _log(
                "   📋 manufacturerData bytes: ${originalMfData.sublist(2).map((b) => b.toString()).join(', ')}");
            _log(
                "   📋 manufacturerData hex: ${originalMfData.sublist(2).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
          }
        }
      } else if (originalToken == null && originalIsBridgeByMfData) {
        _log(
            "⚠️ [GHOST] BRIDGE detected via manufacturerData but no token (mfData length: ${originalMfData?.length ?? 0})");
      } else if (originalToken == null &&
          originalMfData != null &&
          originalMfData.length > 2) {
        // Проверяем, не является ли это BRIDGE без токена (только "BR")
        final isBridgeByMfDataCheck =
            (originalMfData[0] == 0x42 || originalMfData[0] == 66) &&
                (originalMfData[1] == 0x52 || originalMfData[1] == 82);
        if (isBridgeByMfDataCheck && originalMfData.length == 2) {
          _log(
              "⚠️ [GHOST] BRIDGE detected via manufacturerData but no token (only 'BR' prefix, no token bytes)");
        }
      }

      // 🔥 КРИТИЧНО: Также проверяем токен в DiscoveryContext (может быть обновлен из BLE scan или MAGNET_WAVE)
      // DiscoveryContext может содержать полный токен (из MAGNET_WAVE), даже если в manufacturerData он обрезан
      if (originalToken == null) {
        final discoveryContext = locator<DiscoveryContextService>();
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (discoveryCandidate == null && candidate != null) {
          discoveryCandidate = candidate;
        }
        if (candidate != null && candidate.bridgeToken != null) {
          originalToken = candidate.bridgeToken;
          final tokenValue = originalToken!; // Уже проверили на null выше
          final tokenPreview =
              tokenValue.length > 8 ? tokenValue.substring(0, 8) : tokenValue;
          _log(
              "🔑 [GHOST] Token found in DiscoveryContext: $tokenPreview... (length: ${tokenValue.length})");
          _log(
              "   ✅ Using full token from DiscoveryContext (may be longer than manufacturerData token)");
        } else {
          _log(
              "⚠️ [GHOST] No token in DiscoveryContext for MAC: ${targetMac.substring(targetMac.length - 8)}");
        }
      } else {
        // 🔥 CRITICAL FIX: originalToken из quick rescan - это СВЕЖИЙ токен!
        // DiscoveryContext может содержать УСТАРЕВШИЙ токен от предыдущего scan.
        // Приоритет: свежий токен из scan > устаревший токен из DiscoveryContext
        final discoveryContext = locator<DiscoveryContextService>();
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (discoveryCandidate == null && candidate != null) {
          discoveryCandidate = candidate;
        }
        if (candidate != null && candidate.bridgeToken != null) {
          final contextToken = candidate.bridgeToken!;
          final originalTokenPreview = originalToken!.length > 8
              ? originalToken!.substring(0, 8)
              : originalToken;
          final contextTokenPreview = contextToken.length > 8
              ? contextToken.substring(0, 8)
              : contextToken;

          // Если токен из DiscoveryContext длиннее, значит это полный токен (из MAGNET_WAVE)
          // ТОЛЬКО в этом случае заменяем - полный токен лучше обрезанного
          if (contextToken.length > originalToken!.length &&
              contextToken.startsWith(originalToken!)) {
            _log(
                "🔑 [GHOST] Replacing truncated token ($originalTokenPreview...) with full token from DiscoveryContext ($contextTokenPreview...)");
            originalToken = contextToken;
          } else if (contextToken != originalToken) {
            // 🔥 CRITICAL: Токены РАЗНЫЕ - это значит BRIDGE сменил токен!
            // Используем СВЕЖИЙ токен из scan result, НЕ устаревший из DiscoveryContext!
            _log("⚠️ [GHOST] Token mismatch detected:");
            _log("   📋 Fresh scan token: $originalTokenPreview...");
            _log("   📋 Stale context token: $contextTokenPreview...");
            _log("   ✅ Using FRESH token from scan (not stale context token)");
            // НЕ заменяем originalToken - он свежий!
          }
        }
      }

      final discoveryCandidateForLog = discoveryCandidate ??
          locator<DiscoveryContextService>().getCandidateByMac(targetMac);
      final bool discoveryMarksMesh = discoveryCandidateForLog != null &&
          (discoveryCandidateForLog.isBridge ||
              discoveryCandidateForLog.isGhost);

      _log("🔍 [STAGE 2] Pre-connect check:");
      _log("   Device: ${targetScanResult.device.remoteId}");
      _log("   Local name: '$originalAdvName'");
      _log("   Has SERVICE_UUID: $originalHasService");
      _log("   Is BRIDGE by manufacturerData: $originalIsBridgeByMfData");
      _log("   Is GHOST by manufacturerData: $originalIsGhostByMfData");
      if (discoveryCandidateForLog != null) {
        _log(
            "   Discovery context: role=${discoveryCandidateForLog.role}, hops=${discoveryCandidateForLog.hops}, age=${discoveryCandidateForLog.ageSeconds}s");
      } else {
        _log("   Discovery context: none");
      }
      _log("   Peer hops: $originalPeerHops");
      if (originalToken != null) {
        final tokenPreview = originalToken.length > 8
            ? originalToken.substring(0, 8)
            : originalToken;
        _log("   Token: $tokenPreview...");
      } else {
        _log("   Token: none");
      }
      _log(
          "   Available UUIDs: ${targetScanResult.advertisementData.serviceUuids.map((u) => u.toString()).join(', ')}");

      // 🔥 Улучшение: Подтверждение доступности advertising перед GATT с fallback на manufacturerData
      // Проверяем не только наличие, но и валидность токена (если BRIDGE)
      // Используем уже вычисленные значения

      // Проверяем, что устройство рекламирует (через имя, service UUID или manufacturerData BR/GH)
      final isAdvertising = originalHasService ||
          (originalEffectiveName.isNotEmpty &&
              originalEffectiveName.startsWith("M_")) ||
          originalIsBridgeByMfData ||
          originalIsGhostByMfData ||
          discoveryMarksMesh;

      if (!isAdvertising) {
        _log(
            "❌ [CRITICAL] Target device does not advertise SERVICE_UUID or manufacturerData (BR/GH/RL) — skip (not mesh)");
        _log(
            "   Cannot connect via BLE GATT - device is not advertising correctly");
        transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
        _isTransferring = false;
        notifyListeners();
        return;
      }

      // Если имя пустое, но есть manufacturerData - это валидный BRIDGE
      if (originalEffectiveName.isEmpty && originalIsBridgeByMfData) {
        _log(
            "✅ [STAGE 2] BRIDGE detected via manufacturerData fallback (empty localName)");
        originalPeerHops = 0; // Устанавливаем hops для BRIDGE
      }

      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: BRIDGE без token = GATT ЗАПРЕЩЕН
      if (originalPeerHops == 0) {
        final isDirectMode = originalEffectiveName.contains("BRIDGE_DIRECT");

        if (isDirectMode) {
          _log(
              "🚫 [ARCHITECTURE] BRIDGE in DIRECT mode (no GATT server) - GATT FORBIDDEN");

          // BRIDGE в direct mode не принимает GATT - используем Sonar с реальными данными
          try {
            final msgId = pending.first['id'] as String;
            // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
            if (_sentPayloads.containsKey(msgId)) {
              _log(
                  "🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
              transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
              _isTransferring = false;
              notifyListeners();
              return;
            }

            final firstPending = pending.first;
            final int tsSonar2 = (firstPending['createdAt'] as int?) ??
                DateTime.now().millisecondsSinceEpoch;
            final messageData = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': firstPending['content'],
              'senderId': _apiService.currentUserId,
              'h': msgId,
              'ts': tsSonar2,
              'ttl': 5,
            });
            final sonarPayload = messageData.length > 200
                ? messageData.substring(0, 200)
                : messageData;
            await locator<UltrasonicService>()
                .transmitFrame("DATA:$sonarPayload");

            // 🔒 АРХИТЕКТУРА: Sonar только для рукопожатия/SOS — не помечаем как SENT, не удаляем из outbox
            _log(
                "📦 [ARCHITECTURE] Sonar hint emitted for $msgId (BRIDGE direct). Message stays in outbox for BLE/TCP retry.");
            _log("✅ Stage 3: Sonar emitted (hint only). Cycle NOT closed.");
          } catch (e) {
            final msgId = activePending.isNotEmpty
                ? activePending.first['id'] as String
                : messageId;
            _log(
                "📦 [ARCHITECTURE] Payload $msgId marked as SENT_FAIL (SONAR), keeping in outbox");
            _log("❌ Total isolation.");
          }
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _isTransferring = false;
          notifyListeners();
          return; // Прерываем попытки BLE GATT
        }

        if (originalToken == null) {
          // 🔥 FIX: РАЗРЕШАЕМ GATT ДАЖЕ БЕЗ ТОКЕНА (для отладки)
          // Token validation был главным блокером коннектов
          _log(
              "⚠️ [FIX] BRIDGE without token — TRYING GATT ANYWAY (debug mode)");
          _log("   📋 Advertising name: '$originalAdvName'");
          _log("   📋 MAC: ${targetMac.substring(targetMac.length - 8)}");
          _log("   💡 Token validation DISABLED for debugging");
          // НЕ прерываем - продолжаем к GATT
        } else {
          _log(
              "✅ [STAGE 2] BRIDGE token found: ${originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken}...");
        }
      }

      // 🔥 ПРОВЕРКА: Если оба GHOST, проверяем, что роль не изменилась
      // Используем effectiveName и manufacturerData для определения роли
      final peerIsBridge = originalPeerHops == 0 ||
          originalEffectiveName.contains('BRIDGE') ||
          originalIsBridgeByMfData;

      if (myRole == MeshRole.GHOST && !peerIsBridge) {
        if (myHops >= originalPeerHops && myPendingCount == 0) {
          _log(
              "⏸️ [GHOST↔GHOST] Peer has better or equal route, and I have no pending - aborting");
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _isTransferring = false;
          notifyListeners();
          return;
        }
      }

      if (!originalHasService && originalAdvName.startsWith("M_")) {
        _log(
            "⚠️ [WARNING] Device has tactical name but no SERVICE_UUID (Huawei/Tecno quirk?)");
        _log("   Will attempt connection, but service discovery may fail");
      }
    } catch (e) {
      _log("❌ [CRITICAL] Could not verify target device before BLE GATT: $e");
      _log(
          "   Aborting connection - device may have changed or stopped advertising");
      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
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
          // Если и по MAC не нашли, пробуем найти по manufacturerData (BRIDGE или GHOST)
          for (final result in lastScanResults) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBridgeByMfData = mfData != null &&
                mfData.length >= 2 &&
                mfData[0] == 0x42 &&
                mfData[1] == 0x52; // "BR" = BRIDGE
            final isGhostByMfData = mfData != null &&
                mfData.length >= 2 &&
                mfData[0] == 0x47 &&
                mfData[1] == 0x48; // "GH" = GHOST

            if ((isBridgeByMfData || isGhostByMfData) &&
                result.device.remoteId.str == targetMac) {
              currentScanResult = result;
              break;
            }
          }
        }
      }

      if (currentScanResult != null) {
        final currentAdvName =
            currentScanResult.advertisementData.localName ?? '';
        final currentHasService =
            currentScanResult.advertisementData.serviceUuids.any((uuid) =>
                uuid.toString().toLowerCase() ==
                _btService.SERVICE_UUID.toLowerCase());

        // 🔥 Улучшение: Проверяем не только имя, но и токен (для BRIDGE) с fallback на manufacturerData
        final currentPlatformName = currentScanResult.device.platformName;
        final currentEffectiveName =
            currentAdvName.isEmpty ? currentPlatformName : currentAdvName;
        final currentMfData =
            currentScanResult.advertisementData.manufacturerData[0xFFFF];
        final currentIsBridgeByMfData = currentMfData != null &&
            currentMfData.length >= 2 &&
            currentMfData[0] == 0x42 &&
            currentMfData[1] == 0x52; // "BR" = BRIDGE
        final currentIsGhostByMfData = currentMfData != null &&
            currentMfData.length >= 2 &&
            currentMfData[0] == 0x47 &&
            currentMfData[1] == 0x48; // "GH" = GHOST

        String? currentToken;
        if (currentEffectiveName.startsWith("M_") &&
            currentEffectiveName.contains("BRIDGE")) {
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
          if (originalPeerHops == 0 &&
              originalToken != null &&
              currentToken != null) {
            if (originalToken != currentToken) {
              final oldTokenPreview = originalToken.length > 8
                  ? originalToken.substring(0, 8)
                  : originalToken;
              final newTokenPreview = currentToken.length > 8
                  ? currentToken.substring(0, 8)
                  : currentToken;
              _log(
                  "⚠️ [WARNING] BRIDGE token changed during connection: $oldTokenPreview... -> $newTokenPreview...");
              _log(
                  "   Token mismatch - aborting connection to prevent GATT failure");
              transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
              _isTransferring = false;
              notifyListeners();
              return;
            }
          } else {
            _log(
                "⚠️ [WARNING] Device advertising name changed during connection: '$originalEffectiveName' -> '$currentEffectiveName'");
            _log("   Role or identity may have changed - aborting connection");
            transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
            _isTransferring = false;
            notifyListeners();
            return;
          }
        }

        // 🔥 Улучшение: Проверяем, что advertising всё ещё активно (с fallback на manufacturerData)
        // 🔥 GHOST-FIX: Включаем currentIsGhostByMfData для GHOST↔GHOST соединений
        final isStillAdvertising = currentHasService ||
            (currentEffectiveName.isNotEmpty &&
                currentEffectiveName.startsWith("M_")) ||
            currentIsBridgeByMfData ||
            currentIsGhostByMfData;

        if (!isStillAdvertising) {
          _log(
              "❌ [CRITICAL] Device stopped advertising during connection preparation");
          _log("   Advertising is no longer active - aborting connection");
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _isTransferring = false;
          notifyListeners();
          return;
        }

        // 🔥 FIX: НЕ прерываем соединение если BRIDGE валиден через manufacturerData
        // SERVICE_UUID может отсутствовать в некоторых advertising strategies на Huawei/Honor
        // manufacturerData - более надёжный индикатор BRIDGE чем SERVICE_UUID
        if (originalHasService &&
            !currentHasService &&
            !currentIsBridgeByMfData) {
          _log(
              "⚠️ [WARNING] Device stopped advertising SERVICE_UUID during connection");
          _log(
              "   Device may have changed role or stopped advertising - aborting connection");
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _isTransferring = false;
          notifyListeners();
          return;
        } else if (originalHasService &&
            !currentHasService &&
            currentIsBridgeByMfData) {
          _log(
              "ℹ️ [HUAWEI-FIX] SERVICE_UUID missing but BRIDGE valid via manufacturerData - continuing");
          _log(
              "   💡 This is normal for Huawei/Honor devices with multiple advertising strategies");
        }
      } else {
        // 🔥 КРИТИЧНО: Если устройство не найдено в scan results, используем сохраненный ScanResult
        if (savedScanResult != null) {
          _log(
              "⚠️ [WARNING] Device no longer found in scan results - using saved ScanResult");
          targetScanResult = savedScanResult;
          // Обновляем данные из сохраненного ScanResult
          originalAdvName = savedScanResult.advertisementData.localName ?? '';
          originalHasService = savedScanResult.advertisementData.serviceUuids
              .any((uuid) =>
                  uuid.toString().toLowerCase() ==
                  _btService.SERVICE_UUID.toLowerCase());
          final savedMfData =
              savedScanResult.advertisementData.manufacturerData[0xFFFF];
          originalIsBridgeByMfData = savedMfData != null &&
              savedMfData.length >= 2 &&
              savedMfData[0] == 0x42 &&
              savedMfData[1] == 0x52;
          if (originalAdvName.isEmpty) {
            originalEffectiveName = savedScanResult.device.platformName;
          } else {
            originalEffectiveName = originalAdvName;
          }
          _log("   ✅ Using saved ScanResult data for connection");
        } else {
          _log(
              "⚠️ [WARNING] Device no longer found in scan results and no saved ScanResult");
          _log("   Aborting connection - device may have stopped advertising");
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _isTransferring = false;
          notifyListeners();
          return;
        }
      }

      // 🔥 FIX: Отправляем ВСЕ сообщения из outbox через BLE GATT, а не только первое
      // Используем activePending для ограничения количества одновременно активных payload
      _log(
          "📤 [BLE-GATT] Preparing to send ${activePending.length} message(s) via BLE GATT...");

      // Формируем payload для первого сообщения (для обратной совместимости)
      final firstMsg = activePending.isNotEmpty ? activePending.first : null;
      final int firstTs = firstMsg != null
          ? ((firstMsg['createdAt'] as int?) ??
              DateTime.now().millisecondsSinceEpoch)
          : DateTime.now().millisecondsSinceEpoch;
      final String payload = jsonEncode({
        'type': 'OFFLINE_MSG',
        'content': firstMsg?['content'] ?? '',
        'senderId': _apiService.currentUserId,
        'h': messageId,
        'ts': firstTs,
        'ttl': 5,
      });

      // 🔥 КРИТИЧНО: Используем сохраненный ScanResult для создания правильного BluetoothDevice
      // targetScanResult определен выше в try блоке, используем его или savedScanResult
      final finalTargetScanResult = targetScanResult ?? savedScanResult;
      final targetDevice = finalTargetScanResult?.device ?? target.device;
      _log(
          "🔗 [STAGE 2] Connecting to device: ${targetDevice.remoteId} (from ${finalTargetScanResult != null ? 'saved' : 'original'} ScanResult)");

      // 🔥 КРИТИЧНО: Per-BRIDGE lock - предотвращение race condition при одновременных подключениях
      if (originalPeerHops == 0 &&
          _activeBridgeConnections.containsKey(targetMac)) {
        final connectionStart = _activeBridgeConnections[targetMac]!;
        final connectionAge =
            DateTime.now().difference(connectionStart).inSeconds;
        if (connectionAge < 10) {
          _log(
              "⏸️ [GHOST] Another connection to BRIDGE $targetMac in progress (${connectionAge}s old) - skipping to avoid conflict");
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
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
          final tokenAge =
              candidate.lastSeen.difference(DateTime.now()).inSeconds.abs();
          if (tokenAge > 35) {
            // Токен валиден 30 секунд + буфер 5 секунд
            _log(
                "⏰ [GHOST] Token likely expired (token age: ${tokenAge}s, max: 30s)");
            _log("   → Skipping GATT/TCP, escalating to Sonar");
            _activeBridgeConnections.remove(targetMac);
            // Переход к Sonar (будет выполнен ниже)
            originalToken = null; // Помечаем как невалидный
          }
        }
      }

      // 🔥 FIX: Token validation ОТКЛЮЧЕН - пробуем GATT даже без токена
      if (originalPeerHops == 0 && originalToken == null) {
        _log("⚠️ [FIX] BRIDGE without token — TRYING GATT ANYWAY (debug mode)");
        _log("   📋 MAC: ${targetMac.substring(targetMac.length - 8)}");
        _log("   💡 Token validation DISABLED - continuing to GATT");
        // НЕ прерываем - продолжаем к GATT
      }

      // 🔥 FIX: Второй блок token validation также отключен
      if (false && originalPeerHops == 0 && originalToken == null) {
        // DISABLED
        _log("🚫 [ARCHITECTURE] BRIDGE without token — BLE GATT FORBIDDEN");
        _log("   This should have been caught earlier. Escalating to Sonar.");
        _exitCascade();

        // Помечаем BRIDGE как запрещенный для GATT
        final discoveryContext = locator<DiscoveryContextService>();
        final candidate = discoveryContext.getCandidateByMac(targetMac);
        if (candidate != null) {
          discoveryContext.markBridgeAsGattForbidden(candidate.id);
        }

        // 🔥 FIX: Sonar отправляет только REQ (запрос), НЕ удаляет из outbox
        // Удаление происходит только после успешной доставки через другой канал
        try {
          final msgId = activePending.isNotEmpty
              ? activePending.first['id'] as String
              : messageId;
          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
          if (_sentPayloads.containsKey(msgId)) {
            _log(
                "🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
            _exitCascade();
            return;
          }

          // 🔥 FIX: Sonar отправляет только REQ (запрос), не реальные данные
          // Это сигнал для BRIDGE, что у GHOST есть сообщения для отправки
          await locator<UltrasonicService>().transmitFrame(
              "REQ:${msgId.substring(0, msgId.length > 8 ? 8 : msgId.length)}");

          // 🔥 FIX: НЕ удаляем из outbox - Sonar только запрос, не доставка
          _log(
              "📦 [ARCHITECTURE] Sonar REQ sent for $msgId - NOT removing from outbox (waiting for delivery confirmation)");
          _log(
              "✅ Sonar REQ emitted (BLE GATT without token) - BRIDGE should respond via BLE/TCP");
        } catch (e) {
          final msgId = activePending.isNotEmpty
              ? activePending.first['id'] as String
              : messageId;
          _log(
              "📦 [ARCHITECTURE] Sonar REQ failed for $msgId, keeping in outbox");
          _log("❌ Sonar failed: $e");
        }
        _exitCascade();
        return; // Прерываем попытку BLE GATT
      }

      // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивный таймаут BLE GATT на основе предыдущих успехов/неудач
      final transportLatency =
          _transportLatencies.putIfAbsent(targetMac, () => TransportLatency());
      final bleTimeout = transportLatency.adaptiveTimeout;
      // Логирование уже добавлено выше

      _log("🔗 [STAGE 2] Attempting BLE GATT connection:");
      _log("   📋 Target device: ${targetDevice.remoteId}");
      _log(
          "   📋 Token: ${originalToken != null ? '${originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken}...' : 'none'}");
      _log("   ⏱️ Timeout: ${bleTimeout.inSeconds}s");

      // DTN: BLE stack allows only one GATT at a time; _bleSendInProgress used to skip BLE if busy (serialization, not global block).
      bool success = false;
      String? failReason;
      if (_bleSendInProgress) {
        _log(
            "⏸️ [BLE] GATT busy (serialization); skipping BLE for this target, will try TCP fallback");
      } else {
        _bleSendInProgress = true;
        // 🔥 FIX: Устанавливаем _isTransferring ТОЛЬКО перед реальным GATT connect
        _isTransferring = true;
        _transferStartTime = DateTime.now();
        notifyListeners();
        _log("🔒 [GATT] _isTransferring = true (GATT connect starting NOW)");

        // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельный таймер для BLE GATT
        final gattStartTime = DateTime.now();
        bool gattAborted = false;
        _gattTimeoutTimer?.cancel();
        _gattTimeoutTimer = Timer(bleTimeout, () {
          gattAborted = true;
          _log(
              "⏱️ [GATT-TIMER] BLE GATT timeout after ${bleTimeout.inSeconds}s - aborting");
        });

        bool timeoutOccurred = false;
        // 🔥 FIX: Определяем sentCount вне try блока для доступа в области видимости
        int sentCount = 0;
        bool allSent = true;

        try {
          // 🔍🔍🔍 CRITICAL DIAGNOSTIC: Максимум логов для диагностики
          _log("🔴🔴🔴 [MESH-CRITICAL] STAGE 2 - About to call sendMessage");
          _log("🔴 targetDevice.remoteId: ${targetDevice.remoteId}");
          _log("🔴 payload.length: ${payload.length}");
          _log("🔴 _btService.runtimeType: ${_btService.runtimeType}");
          _log("🔴 _btService.hashCode: ${_btService.hashCode}");

          _log("🔍 [STAGE 2] About to call sendMessage...");
          _log("   📋 targetDevice: ${targetDevice.remoteId}");
          _log("   📋 payload length: ${payload.length}");
          _log("   📋 _btService: ${_btService.runtimeType}");

          _log(
              "🔴🔴🔴 [MESH-CRITICAL] NOW calling _btService.sendMessage()...");

          // 🔥 FIX: Отправляем ВСЕ сообщения из activePending через BLE GATT в рамках одного подключения
          // ⚡ OPTIMIZATION: Используем batch отправку для всех сообщений без переподключения

          // Фильтруем уже отправленные сообщения; собираем sentFragmentIndex для BLE resume (§6.19)
          final messagesToSend = <String>[];
          final messageIds = <String>[];
          final sentFragmentIndices = <int>[];

          for (var msgData in activePending) {
            final currentMsgId = msgData['id'] as String;
            if (_sentPayloads.containsKey(currentMsgId)) {
              _log("   ⏭️ Skipping already sent message: $currentMsgId");
              continue;
            }

            final int ts = (msgData['createdAt'] as int?) ??
                DateTime.now().millisecondsSinceEpoch;
            final currentPayload = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': msgData['content'],
              'senderId': _apiService.currentUserId,
              'h': currentMsgId,
              'ts': ts,
              'ttl': 5,
            });

            messagesToSend.add(currentPayload);
            messageIds.add(currentMsgId);
            final raw = msgData['sentFragmentIndex'];
            sentFragmentIndices.add(raw is int ? raw : -1);
          }

          if (messagesToSend.isEmpty) {
            _log("   ⏸️ No new messages to send (all already sent)");
            // 🔥 FIX: BLE attempt sent 0 messages (all skipped). Clear _sentPayloads for these IDs
            // so the next cascade will retry them instead of skipping forever.
            for (var msgData in activePending) {
              final id = msgData['id'] as String;
              if (_sentPayloads.containsKey(id)) {
                _sentPayloads.remove(id);
                _log(
                    "   🔄 Cleared _sentPayloads for $id — will retry on next cascade");
              }
            }
            success = false;
          } else {
            _log(
                "📤 [BATCH] Sending ${messagesToSend.length} message(s) via BLE GATT in single connection...");

            try {
              // 🔥 GHOST→GHOST: use short quiet so we connect before peer's BLE MAC rotates (Android random address).
              _btService.setShortQuietForNextConnect(true);
              // 🔥 CRITICAL FIX: Используем новый метод sendMultipleMessages для batch отправки
              // Это отправляет все сообщения в рамках одного подключения
              // 🔥 BLE STABILIZATION: Жёсткий лимит ожидания batch = 40s (внутри BT batch до 35s)
              // Это гарантирует: batch wait (40s) < watchdog (45s) < cooldown (20s после fail)
              final batchTimeout = Duration(seconds: _bleBatchHardLimitSeconds);

              _log(
                  "   ⏱️ Starting batch send with HARD LIMIT ${batchTimeout.inSeconds}s for ${messagesToSend.length} message(s)...");

              final batchFuture = _btService.enqueue(
                targetDevice.remoteId.str,
                messagesToSend,
                messageIds: messageIds,
                sentFragmentIndices: sentFragmentIndices,
                isHuaweiBreakGlass: _isHuaweiBreakGlassThisCascade,
                writeStrategy: _writeStrategyThisCascade,
                onFragmentSent: (msgId, index, total) {
                  unawaited(_db.updateOutboxSentFragmentIndex(msgId, index));
                  if (index == total - 1) {
                    unawaited(_db.removeFromOutbox(msgId));
                    _sentPayloads[msgId] = 'BLE';
                    _activePayloads.remove(msgId);
                  }
                },
              );
              final batchResult =
                  await batchFuture.timeout(batchTimeout, onTimeout: () {
                _log(
                    "   ⏱️ [HARD-LIMIT] Batch send timeout after ${batchTimeout.inSeconds}s - aborting");
                return 0;
              });

              if (batchResult > 0) {
                sentCount += batchResult;
                // При resume (onFragmentSent) полная отправка и удаление из outbox делаются в колбэке.
                // Без resume помечаем все batchResult сообщений как отправленные (как раньше).
                if (sentFragmentIndices.isEmpty) {
                  for (int i = 0; i < batchResult && i < messageIds.length; i++) {
                    final msgId = messageIds[i];
                    _sentPayloads[msgId] = 'BLE';
                    _activePayloads.remove(msgId);
                    _log(
                        "   ✅ Message $msgId sent via BLE GATT (NOT removed from outbox - will retry if not delivered)");
                  }
                } else {
                  _log(
                      "   ✅ [BATCH] Resume path: full sends and outbox removal handled in onFragmentSent callback");
                }

                _log(
                    "✅ [BATCH] Batch send completed: $sentCount/${messagesToSend.length} message(s) sent");
              } else {
                allSent = false;
                _log("   ⚠️ Batch send failed - no messages sent");
              }
            } catch (e) {
              allSent = false;
              _log("   ❌ Error in batch send: $e");
              // ⚡ OPTIMIZATION: Не прерываем - продолжаем с fallback на индивидуальную отправку
              _log("   🔄 Falling back to individual message sending...");

              // Fallback: отправляем сообщения по одному (старый метод)
              for (int i = 0; i < messagesToSend.length; i++) {
                if (gattAborted) {
                  _log(
                      "   ⏸️ Batch aborted due to global timeout - stopping message loop");
                  break;
                }

                final currentMsgId = messageIds[i];
                final currentPayload = messagesToSend[i];

                try {
                  final perMessageTimeout = const Duration(seconds: 28);
                  final sendFuture =
                      _btService.sendMessage(targetDevice, currentPayload);
                  final currentSuccess = await sendFuture
                      .timeout(perMessageTimeout, onTimeout: () {
                    _log(
                        "   ⏱️ Message $currentMsgId timeout after ${perMessageTimeout.inSeconds}s (continuing with next message)");
                    return false;
                  });

                  if (currentSuccess) {
                    _sentPayloads[currentMsgId] = 'BLE';
                    // 🔥 FIX: НЕ удаляем из outbox сразу после отправки через BLE GATT (fallback)
                    // await _db.removeFromOutbox(currentMsgId);
                    _activePayloads.remove(currentMsgId);
                    sentCount++;
                    _log(
                        "   ✅ Message $currentMsgId sent via BLE GATT (fallback) (NOT removed from outbox - will retry if not delivered)");

                    if (sentCount < messagesToSend.length) {
                      await Future.delayed(const Duration(milliseconds: 200));
                    }
                  } else {
                    allSent = false;
                    _log(
                        "   ⚠️ Failed to send message $currentMsgId (fallback)");
                  }
                } catch (e) {
                  allSent = false;
                  _log(
                      "   ❌ Error sending message $currentMsgId (fallback): $e");
                }
              }
            }
          }

          // Успех если хотя бы одно сообщение отправлено
          success = sentCount > 0;
          _log(
              "🔴🔴🔴 [MESH-CRITICAL] sendMessage batch completed! success=$success, sent=$sentCount/${activePending.length}");
          _log(
              "🔍 [STAGE 2] BLE GATT batch result: $success ($sentCount/${activePending.length} sent)");
        } catch (e, stack) {
          _log("🔴🔴🔴 [MESH-CRITICAL] sendMessage EXCEPTION: $e");
          _log("❌ [STAGE 2] sendMessage threw exception: $e");
          _log(
              "   📋 Stack trace: ${stack.toString().split('\n').take(5).join('\n')}");
          failReason = e.toString();
          success = false;
        }

        _gattTimeoutTimer?.cancel();

        // 🔥 CRITICAL FIX: После timeout принудительно сбрасываем GATT state
        // Без этого _gattConnectionState остаётся CONNECTING и блокирует все scan!
        if (gattAborted || (!success && sentCount == 0)) {
          _btService.forceResetGattState(
              "mesh_service timeout/failure (success=$success, sent=$sentCount/${activePending.length}, aborted=$gattAborted)");
        }
        final gattLatency = DateTime.now().difference(gattStartTime);

        // ⚡ OPTIMIZATION: Успех если хотя бы одно сообщение отправлено
        // Не требуем отправки всех сообщений для успеха
        if (sentCount > 0) {
          success =
              true; // Считаем успехом, если хотя бы одно сообщение отправлено
          _log(
              "✅ [STAGE 2] Partial success: $sentCount/${activePending.length} messages sent");
        }

        if (success && !gattAborted) {
          // 🔥 ШАГ 2.3: Логирование успешного подключения
          _log("✅ [GHOST] Connected via BLE GATT - message delivered");

          // 🔥 ЛОГИРОВАНИЕ: Детальная информация о передаче через BLE GATT
          _log("📤 [GHOST→BRIDGE] Stage 2: BLE GATT transmission");
          _log("   📋 Message ID: $messageId");
          _log(
              "   📋 Target MAC: ${targetMac.length >= 8 ? targetMac.substring(targetMac.length - 8) : targetMac}");
          _log("   📋 Transport: BLE GATT");
          _log(
              "   📋 Token: ${originalToken != null ? '${originalToken.length > 8 ? originalToken.substring(0, 8) : originalToken}...' : 'none'}");
          _log("   📋 Latency: ${gattLatency.inMilliseconds}ms");
          _log("   ✅ Message delivered successfully via BLE GATT");
          _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе

          // 🔥 REPEATER: Регистрируем успешное BLE GATT соединение
          try {
            final repeater = locator<RepeaterService>();
            repeater.registerConnection(
              deviceId: targetMac,
              deviceToken: originalToken,
              channelType: ChannelType.bleGatt,
            );
            repeater.updateConnectionActivity(targetMac);
            _log(
                "🔄 [REPEATER] BLE GATT connection registered: ${targetMac.length >= 8 ? targetMac.substring(targetMac.length - 8) : targetMac}");
          } catch (e) {
            _log("⚠️ [REPEATER] Failed to register GATT connection: $e");
          }

          // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем успешную задержку для адаптивного таймаута
          transportLatency.recordSuccess(gattLatency);
          // 🔒 P1: Единый контракт метрик — доставка по GATT пишет в PeerCache (Gossip, GhostTransfer, Sync, Orchestrator используют те же данные)
          try {
            locator<PeerCacheService>().recordSuccess(
                peerId: targetMac, latency: gattLatency, channel: 'bleGatt');
          } catch (_) {}

          // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info (с null-safety)
          final retryInfo = _payloadRetries[messageId];
          if (retryInfo != null) {
            retryInfo.gattAttempts++;

            // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
            final cycleDuration = retryInfo.cycleDuration;
            final hops = retryInfo.hopsToBridge ?? peerHops;
            final outboxSize = retryInfo.outboxSizeAtStart ?? pending.length;
            _log(
                "🔄 [ARCHITECTURE] Cycle CLOSED via BLE GATT (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");
          }

          // 🔥 FIX: Очищаем retry info для всех отправленных сообщений
          for (var msgData in activePending) {
            final msgId = msgData['id'] as String;
            if (_sentPayloads.containsKey(msgId)) {
              _activePayloads.remove(msgId);
              _payloadRetries.remove(msgId);
            }
          }

          // Используем первый отправленный messageId для логирования
          _log(
              "📦 [ARCHITECTURE] ${sentCount} payload(s) marked as SENT_OK (BLE), removed from outbox");

          // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после успешной передачи
          _activeBridgeConnections.remove(targetMac);

          // 🔥 КРИТИЧНО: Очищаем cooldown после успешной передачи через BLE GATT
          // Это позволяет сразу пытаться подключиться к другим BRIDGE
          _linkCooldowns.remove(targetMac);
          _bleGattAttempts
              .remove(targetMac); // Сбрасываем счетчик неудачных попыток

          _log(
              "🧹 [CLEANUP] Cleared cooldown and connection locks for $targetMac after successful BLE GATT transmission");

          // 🔥🔥🔥 CRITICAL FIX: Сбрасываем флаг СРАЗУ и синхронно!
          transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
          _transferStartTime = null; // Сбрасываем таймер

          // 🔥 FIX: Проверяем, есть ли еще сообщения в outbox для отправки
          // 🔥 CRITICAL FIX: Проверяем remainingPending СРАЗУ после успешной отправки
          // Это гарантирует, что все сообщения, добавленные во время передачи, будут обработаны
          final remainingPending = await _db.getPendingFromOutbox();
          if (remainingPending.isNotEmpty) {
            _log(
                "📦 [OUTBOX] ${remainingPending.length} message(s) still in outbox, continuing transmission...");
            // 🔥 CRITICAL FIX: Сбрасываем флаг ПЕРЕД продолжением
            _exitCascade();

            // 🔥 CRITICAL FIX: Используем сохраненный ScanResult для немедленной отправки оставшихся сообщений
            // Не ждем задержки - сразу продолжаем отправку, если ScanResult еще актуален
            if (_cascadeSavedScanResult != null) {
              final age = DateTime.now()
                  .difference(_cascadeSavedScanResultTime ?? DateTime.now());
              if (age < _scanResultMaxAge) {
                _log(
                    "🔄 [OUTBOX] Continuing immediately with saved ScanResult (age: ${age.inSeconds}s)...");
                // 🔥 CRITICAL FIX: Немедленно продолжаем отправку без задержки
                // Это гарантирует, что второе сообщение не зависнет
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (remainingPending.isNotEmpty && !_isTransferring) {
                    unawaited(_executeCascadeRelay(
                        _cascadeSavedScanResult!, peerHops));
                  }
                });
              } else {
                _log(
                    "⚠️ [OUTBOX] Saved ScanResult expired (age: ${age.inSeconds}s), triggering scan...");
                // 🔥 FIX: Если ScanResult устарел - запускаем автоматический scan
                Future.delayed(const Duration(milliseconds: 200), () {
                  unawaited(_triggerAutoScanForOutbox());
                });
              }
            } else {
              // 🔥 FIX: Если нет сохраненного ScanResult - запускаем автоматический scan
              _log(
                  "🔄 [OUTBOX] No saved ScanResult - triggering automatic scan...");
              Future.delayed(const Duration(milliseconds: 200), () {
                unawaited(_triggerAutoScanForOutbox());
              });
            }
          } else {
            _exitCascade();
            _log("🔓 [GATT] Cascade exit (GATT success - outbox empty)");
          }

          // 🔥 Улучшение: Проверяем очередь подключений после успешной передачи
          _processPendingConnections();

          // 🔥 GHOST: Вернуться в scan после успешной передачи (для поиска других BRIDGE)
          _log(
              "🔄 [GHOST] Returning to scan mode after successful GATT transfer");

          // 🔥 FIX: После завершения transfer проверяем, нет ли новых сообщений в outbox
          // Это гарантирует автоматическую отправку сообщений, добавленных во время transfer
          Future.delayed(const Duration(milliseconds: 500), () {
            final newPending = _db.getPendingFromOutbox();
            newPending.then((pending) {
              if (pending.isNotEmpty && !_isTransferring) {
                _log(
                    "🔄 [AUTO-TRIGGER] New messages detected after transfer - triggering scan...");
                unawaited(_triggerAutoScanForOutbox());
              }
            });
          });

          // Scan будет запущен автоматически через MeshOrchestrator
          _bleSendInProgress = false;
          return;
        } else {
          // ⚡ OPTIMIZATION: Если хотя бы одно сообщение отправлено - это частичный успех
          if (sentCount > 0) {
            _log(
                "⚠️ [STAGE 2] Partial success: $sentCount/${activePending.length} messages sent");
            _log("   ✅ Continuing with remaining messages...");

            // Проверяем, есть ли еще сообщения в outbox
            final remainingPending = await _db.getPendingFromOutbox();
            if (remainingPending.isNotEmpty) {
              _log(
                  "📦 [OUTBOX] ${remainingPending.length} message(s) still in outbox, will retry...");
              // Сбрасываем флаг для следующей попытки
              _exitCascade();

              // Продолжаем отправку через небольшую задержку
              Future.delayed(const Duration(milliseconds: 500), () {
                if (remainingPending.isNotEmpty && !_isTransferring) {
                  _log("🔄 [OUTBOX] Retrying remaining messages...");
                  if (_cascadeSavedScanResult != null) {
                    final age = DateTime.now().difference(
                        _cascadeSavedScanResultTime ?? DateTime.now());
                    if (age < _scanResultMaxAge) {
                      unawaited(_executeCascadeRelay(
                          _cascadeSavedScanResult!, peerHops));
                    } else {
                      _log(
                          "⚠️ [OUTBOX] Saved ScanResult expired - triggering automatic scan...");
                      unawaited(_triggerAutoScanForOutbox());
                    }
                  } else {
                    _log(
                        "🔄 [OUTBOX] No saved ScanResult - triggering automatic scan...");
                    unawaited(_triggerAutoScanForOutbox());
                  }
                }
              });
              _bleSendInProgress = false;
              return; // Выходим, чтобы не делать fallback на Sonar
            }
          }

          _log("⚠️ Stage 2 Failed: BLE delivery returned false or timed out.");
          if (failReason != null) {
            _log("   💡 Fail reason: $failReason");
          }
          if (sentCount > 0) {
            _log(
                "   📊 Partial success: $sentCount/${activePending.length} messages sent before failure");
          }

          // 🔥 FIX: Сбрасываем при GATT failure
          _log("🔓 [GATT] Cascade exit (GATT failed)");
          _bleSendInProgress = false;
          _exitCascade();

          // 🔥 FIX: После завершения transfer (даже при failure) проверяем, нет ли новых сообщений в outbox
          // Это гарантирует автоматическую отправку сообщений, добавленных во время transfer
          Future.delayed(const Duration(milliseconds: 500), () {
            final newPending = _db.getPendingFromOutbox();
            newPending.then((pending) {
              if (pending.isNotEmpty && !_isTransferring) {
                _log(
                    "🔄 [AUTO-TRIGGER] New messages detected after transfer failure - triggering scan...");
                unawaited(_triggerAutoScanForOutbox());
              }
            });
          });

          // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем неудачу для адаптивного таймаута
          transportLatency.recordFailure();
          try {
            locator<PeerCacheService>().recordFailure(
                peerId: targetMac, channel: 'bleGatt', reason: failReason);
          } catch (_) {}

          // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info (с null-safety)
          final retryInfo = _payloadRetries[messageId];
          final gattAttemptCount = retryInfo?.gattAttempts ?? 0;
          if (retryInfo != null) {
            retryInfo.gattAttempts++;
          }

          // 🔥 FIX: Cooldown уменьшен до 15 секунд (было 60)
          _log(
              "📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (BLE), setting cooldown 15s (attempt ${gattAttemptCount + 1}/3)");
          _setCooldownByMac(targetMac);
          _bleGattAttempts[targetMac] = (_bleGattAttempts[targetMac] ?? 0) + 1;

          // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при неудаче (после cooldown)
          // Lock будет автоматически освобожден через 10 секунд или при следующей попытке
          Future.delayed(const Duration(seconds: 10), () {
            _activeBridgeConnections.remove(targetMac);
          });
        }
      } // end else (BLE attempt block)
    } catch (e) {
      _log("⚠️ Stage 2 Failed: $e");

      // 🔥 FIX: Сбрасываем при исключении
      _log("🔓 [GATT] Cascade exit (GATT exception)");
      _bleSendInProgress = false;
      _exitCascade();

      // 🔥 Улучшение: Увеличиваем счётчик неудачных попыток
      _bleGattAttempts[targetMac] = (_bleGattAttempts[targetMac] ?? 0) + 1;

      // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при ошибке
      _activeBridgeConnections.remove(targetMac);
    }

    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не делаем fallback если payload уже отправлен через Sonar
    if (_sentPayloads.containsKey(messageId) &&
        _sentPayloads[messageId] == 'SONAR') {
      _log(
          "🚫 [ARCHITECTURE] Payload $messageId already sent via SONAR — skipping fallback");
      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
      _bleSendInProgress = false;
      return; // Цикл закрыт, не делаем fallback
    }
    _bleSendInProgress = false;

    // 🔥 КРИТИЧНО: Агрессивный fallback на TCP после неудачи BLE GATT
    // НО: Только если есть bridgeToken - без токена TCP тоже не работает
    final gattAttemptsCount = _bleGattAttempts[targetMac] ?? 0;
    final retryInfoForTcp = _payloadRetries[messageId];
    if (retryInfoForTcp == null) {
      _log("⚠️ [Cascade] No retry info for $messageId - skipping TCP fallback");
      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
      return;
    }

    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем лимит попыток TCP (максимум 2)
    if (gattAttemptsCount >= 1 &&
        peerHops == 0 &&
        retryInfoForTcp.tcpAttempts < 2) {
      _log(
          "🔄 [Cascade] BLE GATT failed, checking TCP fallback (GATT attempt: $gattAttemptsCount, TCP attempt: ${retryInfoForTcp.tcpAttempts + 1}/2)");
      final candidate =
          locator<DiscoveryContextService>().getCandidateByMac(targetMac);

      // 🔥 КРИТИЧНО: TCP fallback только если есть IP/порт (токен не обязателен для TCP)
      if (candidate != null && candidate.ip != null && candidate.port != null) {
        try {
          // 🔥 МАСШТАБИРУЕМОСТЬ: Адаптивный таймаут TCP
          final tcpLatency = _transportLatencies.putIfAbsent(
              '${targetMac}_tcp', () => TransportLatency());
          final tcpTimeout = tcpLatency.consecutiveFailures >= 2
              ? const Duration(seconds: 10)
              : const Duration(seconds: 5);

          // 🔥 ШАГ 2.3: Логирование подключения через TCP
          _log("🌐 [GHOST] Connecting via TCP");
          if (candidate.bridgeToken != null) {
            final tcpTokenPreview = candidate.bridgeToken!.length > 16
                ? candidate.bridgeToken!.substring(0, 16)
                : candidate.bridgeToken!;
            _log("   🔑 Token: $tcpTokenPreview...");
          } else {
            _log("   🔑 Token: none (TCP fallback without token)");
          }
          _log("   📋 IP: ${candidate.ip}:${candidate.port}");
          _log("   ⏱️ Timeout: ${tcpTimeout.inSeconds}s");

          // 🔥 МАСШТАБИРУЕМОСТЬ: Отдельный таймер для TCP
          final tcpStartTime = DateTime.now();
          bool tcpAborted = false;
          _tcpTimeoutTimer?.cancel();
          _tcpTimeoutTimer = Timer(tcpTimeout, () {
            tcpAborted = true;
            _log(
                "⏱️ [TCP-TIMER] TCP timeout after ${tcpTimeout.inSeconds}s - aborting");
          });

          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: TCP таймаут адаптивный
          // 🔥 КРИТИЧНО: TCP может работать без токена (токен нужен только для GATT)
          bool tcpSuccess = false;
          if (candidate.bridgeToken != null) {
            // 🔥 ШАГ 3: Токен валиден 30 секунд - используем _handleMagnetWave
            try {
              // 🔥 MAC RANDOMIZATION FIX: Токен валиден 60 секунд
              await _handleMagnetWave(
                      candidate.bridgeToken!,
                      candidate.port!,
                      DateTime.now()
                          .add(const Duration(seconds: 60))
                          .millisecondsSinceEpoch)
                  .timeout(tcpTimeout, onTimeout: () {
                throw TimeoutException(
                    "TCP connection timeout after ${tcpTimeout.inSeconds}s");
              });
              tcpSuccess = true;
            } catch (e) {
              _log("⚠️ [TCP] _handleMagnetWave failed: $e");
            }
          } else {
            // 🔥 КРИТИЧНО: TCP fallback без токена - отправляем сообщение напрямую
            try {
              final firstPending = pending.first;
              final int tsTcp = (firstPending['createdAt'] as int?) ??
                  DateTime.now().millisecondsSinceEpoch;
              final messageData = jsonEncode({
                'type': 'GHOST_UPLOAD',
                'messages': [
                  {
                    'type': 'OFFLINE_MSG',
                    'content': firstPending['content'],
                    'senderId': _apiService.currentUserId,
                    'h': messageId,
                    'ts': tsTcp,
                    'ttl': 5,
                  }
                ],
              });

              await NativeMeshService.sendTcp(
                messageData,
                host: candidate.ip!,
                port: candidate.port!,
              ).timeout(tcpTimeout, onTimeout: () {
                throw TimeoutException(
                    "TCP connection timeout after ${tcpTimeout.inSeconds}s");
              });
              tcpSuccess = true;
            } catch (e) {
              _log("⚠️ [TCP] Direct TCP send failed: $e");
            }
          }

          _tcpTimeoutTimer?.cancel();
          final tcpLatencyDuration = DateTime.now().difference(tcpStartTime);

          if (!tcpAborted && tcpSuccess) {
            // 🔥 ШАГ 2.3: Логирование успешного подключения через TCP
            _log("✅ [GHOST] Connected via TCP - message delivered");

            // 🔥 ЛОГИРОВАНИЕ: Детальная информация о передаче через TCP
            _log("📤 [GHOST→BRIDGE] TCP Fallback: TCP transmission");
            _log("   📋 Message ID: $messageId");
            _log("   📋 Target IP: ${candidate.ip}:${candidate.port}");
            _log(
                "   📋 Target MAC: ${targetMac.length >= 8 ? targetMac.substring(targetMac.length - 8) : targetMac}");
            _log("   📋 Transport: TCP");
            if (candidate.bridgeToken != null) {
              final t = candidate.bridgeToken!;
              _log("   📋 Token: ${t.length > 8 ? t.substring(0, 8) : t}...");
            } else {
              _log("   📋 Token: none (TCP fallback without token)");
            }
            _log("   📋 Latency: ${tcpLatencyDuration.inMilliseconds}ms");
            _log("   ✅ Message delivered successfully via TCP");

            // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем успешную задержку TCP
            tcpLatency.recordSuccess(tcpLatencyDuration);
            try {
              locator<PeerCacheService>().recordSuccess(
                  peerId: targetMac,
                  latency: tcpLatencyDuration,
                  channel: 'tcp');
            } catch (_) {}

            // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
            retryInfoForTcp.tcpAttempts++;

            // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_OK - очищаем pending
            _sentPayloads[messageId] = 'TCP';
            await _db.removeFromOutbox(messageId);
            _log(
                "📦 [ARCHITECTURE] Payload $messageId marked as SENT_OK (TCP), removed from outbox");

            // 🔥 МАСШТАБИРУЕМОСТЬ: Расширенное логирование цикла
            final cycleDuration = retryInfoForTcp.cycleDuration;
            final hops = retryInfoForTcp.hopsToBridge ?? peerHops;
            final outboxSize =
                retryInfoForTcp.outboxSizeAtStart ?? activePending.length;
            _log(
                "🔄 [ARCHITECTURE] Cycle CLOSED via TCP (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize)");

            _bleGattAttempts.remove(targetMac); // Сбрасываем счётчик при успехе

            // Очищаем активный payload и retry info
            _activePayloads.remove(messageId);
            _payloadRetries.remove(messageId);

            // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после успешной передачи
            _activeBridgeConnections.remove(targetMac);

            // 🔥 КРИТИЧНО: Очищаем cooldown после успешной передачи через TCP
            // Это позволяет сразу пытаться подключиться к другим BRIDGE
            _linkCooldowns.remove(targetMac);

            _log(
                "🧹 [CLEANUP] Cleared cooldown and connection locks for $targetMac after successful TCP transmission");

            transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
            _isTransferring = false;
            notifyListeners();
            return;
          }
        } catch (e) {
          // 🔥 МАСШТАБИРУЕМОСТЬ: Записываем неудачу TCP
          final tcpLatency = _transportLatencies.putIfAbsent(
              '${targetMac}_tcp', () => TransportLatency());
          tcpLatency.recordFailure();
          try {
            locator<PeerCacheService>().recordFailure(
                peerId: targetMac, channel: 'tcp', reason: e.toString());
          } catch (_) {}

          // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info
          retryInfoForTcp.tcpAttempts++;

          // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_FAIL - cooldown транспорта 1-2 минуты, но НЕ удаляем из outbox
          _log(
              "📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (TCP), keeping in outbox (attempt ${retryInfoForTcp.tcpAttempts}/2)");
          _log("❌ [Cascade] TCP fallback also failed: $e");
          _setCooldownByMac(targetMac); // Cooldown 15 секунд для TCP (было 60)
          _log("⏸️ [Cascade] TCP cooldown set for 15s");

          // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock при неудаче TCP
          _activeBridgeConnections.remove(targetMac);
        }
      } else {
        // 🔥 КРИТИЧНО: Если нет token или IP/порта - TCP fallback невозможен
        if (candidate == null) {
          _log(
              "❌ [Cascade] No candidate found in DiscoveryContext for MAC: ${targetMac.substring(targetMac.length - 8)}");
          _log(
              "   💡 BRIDGE may not be in DiscoveryContext or MAC address mismatch");
        } else if (candidate.ip == null || candidate.port == null) {
          _log(
              "⚠️ [Cascade] No TCP info in candidate (ip: ${candidate.ip}, port: ${candidate.port})");
          _log("   💡 Possible reasons:");
          _log("      1. BRIDGE hasn't sent MAGNET_WAVE packet yet");
          _log(
              "      2. MAGNET_WAVE not received by GHOST (Wi-Fi Direct not connected)");
          _log("      3. BRIDGE TCP server not started");
          _log(
              "      4. DiscoveryContext not updated with IP/port from MAGNET_WAVE");
        } else {
          _log("⚠️ [Cascade] TCP fallback check failed for unknown reason");
        }
      }
    }

    // --- STAGE 3: SONAR (ГАРАНТИРОВАННЫЙ маршрут) ---
    // 🔥 ШАГ 2.2: Если токен не найден или просрочен → fallback на Sonar
    // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Sonar всегда доступен, работает как последний шаг
    final retryInfoForSonar = _payloadRetries[messageId];
    if (retryInfoForSonar == null) {
      _log(
          "⚠️ [Cascade] No retry info for $messageId - skipping Sonar fallback");
      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
      return;
    }

    // 🔥 МАСШТАБИРУЕМОСТЬ: Проверяем лимит попыток Sonar (максимум 1)
    if (retryInfoForSonar.sonarAttempts >= 1) {
      _log(
          "⏸️ [Scalability] Payload $messageId already attempted via Sonar - skipping");
      _activePayloads.remove(messageId);
      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
      return;
    }

    _log("🔊 [GHOST] Escalating to SONAR (token not found or expired)");
    try {
      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Проверка - не отправляем payload дважды
      if (_sentPayloads.containsKey(messageId)) {
        _log(
            "🚫 [ARCHITECTURE] Payload $messageId already sent via ${_sentPayloads[messageId]} — skipping duplicate");
        _activePayloads.remove(messageId);
        transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
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
      final firstForSonar = activePending.first;
      final int tsSonar = (firstForSonar['createdAt'] as int?) ??
          DateTime.now().millisecondsSinceEpoch;
      final messageData = jsonEncode({
        'type': 'OFFLINE_MSG',
        'content': firstForSonar['content'],
        'senderId': _apiService.currentUserId,
        'h': messageId,
        'ts': tsSonar,
        'ttl': 5,
      });
      final sonarPayload = messageData.length > 200
          ? messageData.substring(0, 200)
          : messageData;

      // 🔥 ЛОГИРОВАНИЕ: Детальная информация о передаче через Sonar
      _log("📤 [GHOST→BRIDGE] Stage 3: Sonar transmission");
      _log("   📋 Message ID: $messageId");
      _log("   📋 Transport: Sonar (ultrasonic)");
      _log(
          "   📋 Payload length: ${sonarPayload.length} bytes (truncated from ${messageData.length} bytes)");
      _log("   📤 Transmitting via Sonar...");

      await locator<UltrasonicService>().transmitFrame("DATA:$sonarPayload");

      _sonarTimeoutTimer?.cancel();
      final sonarLatency = DateTime.now().difference(sonarStartTime);
      _log(
          "   ✅ Sonar transmission completed (latency: ${sonarLatency.inMilliseconds}ms)");

      // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info (одна попытка Sonar на сообщение, чтобы не спамить)
      retryInfoForSonar.sonarAttempts++;

      // 🔒 АРХИТЕКТУРА: Sonar только для рукопожатия/SOS, не транспорт — не помечаем как SENT, не удаляем из outbox
      _log(
          "📦 [ARCHITECTURE] Sonar hint emitted for $messageId. Message stays in outbox for BLE/TCP retry.");
      _log("✅ Stage 3: Sonar emitted (hint only). Cycle NOT closed.");

      final cycleDuration = retryInfoForSonar.cycleDuration;
      final hops = retryInfoForSonar.hopsToBridge ?? peerHops;
      final outboxSize =
          retryInfoForSonar.outboxSizeAtStart ?? activePending.length;
      _log(
          "🔄 [ARCHITECTURE] Cycle ended via Sonar hint (duration: ${cycleDuration?.inSeconds ?? 0}s, hops: $hops, outbox: $outboxSize, latency: ${sonarLatency.inMilliseconds}ms)");

      // Очищаем только активный payload; retry info и outbox не трогаем — сообщение будет повторно в каскаде по BLE/TCP
      _activePayloads.remove(messageId);

      // Cooldown сбрасываем, чтобы следующий цикл мог снова попробовать BLE/TCP
      _linkCooldowns.remove(targetMac);
      _activeBridgeConnections.remove(targetMac);
      _bleGattAttempts.remove(targetMac);

      _log(
          "🧹 [CLEANUP] Cleared cooldown/locks for $targetMac; message $messageId remains in outbox for retry");

      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _isTransferring = false;
      notifyListeners();
    } catch (e) {
      // 🔥 МАСШТАБИРУЕМОСТЬ: Обновляем retry info при неудаче
      retryInfoForSonar.sonarAttempts++;

      // 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: SENT_FAIL - оставляем в pending, но не повторяем
      _log(
          "📦 [ARCHITECTURE] Payload $messageId marked as SENT_FAIL (SONAR), keeping in outbox");
      _log("❌ Total isolation.");

      // Очищаем активный payload, но оставляем retry info для анализа
      _activePayloads.remove(messageId);

      // 🔥 КРИТИЧНО: Освобождаем per-BRIDGE lock после завершения цикла
      if (originalPeerHops == 0) {
        _activeBridgeConnections.remove(targetMac);
      }

      transferTimeoutTimer?.cancel(); // 🔥 FIX: Cancel timer!
      _exitCascade();
    }
  }

  /// 🔥 Улучшение: Обработка очереди подключений после завершения transfer
  void _processPendingConnections() {
    if (_pendingConnections.isEmpty) return;

    _log(
        "🔄 [Cascade] Processing ${_pendingConnections.length} pending connection(s)...");

    // Очищаем истёкшие подключения (старше 30 секунд)
    final now = DateTime.now();
    _pendingConnections
        .removeWhere((mac, time) => now.difference(time).inSeconds > 30);

    // Пытаемся подключиться к первому в очереди
    if (_pendingConnections.isNotEmpty && !_isTransferring) {
      final nextMac = _pendingConnections.keys.first;
      _pendingConnections.remove(nextMac);

      _log("🔄 [Cascade] Attempting queued connection to $nextMac");
      // Находим кандидата и пытаемся подключиться
      final candidate =
          locator<DiscoveryContextService>().getCandidateByMac(nextMac);
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
    _transferGuardTimer?.cancel();
    if (_connectTargetAddress != null) {
      _lastConnectedPeerAddress = _connectTargetAddress;
      _connectTargetAddress = null;
    }
    reportMeshHealthWifiConnectSuccess();

    if (kMeshDiagnostics) {
      _log(meshDiagLog('p2p_state_transition', {
        '_isP2pConnected': 'true',
        'isRouteReady': 'true',
        'trigger': 'onNetworkConnected',
        'role': isHost ? 'GO' : 'client',
        'hostAddress': hostAddress,
      }));
      if (!isHost) {
        _log(meshDiagLog('resolved_peer_ip', {
          'peerIp': hostAddress,
          'port': '${MeshService.meshTcpPort}',
        }));
      }
    }
    // 🔥 FIX: Сохраняем hostAddress для последующего использования
    // Для клиента это IP GO, для GO это его собственный IP (для GO не сохраняем в _lastKnownPeerIp — см. ниже)

    _log("🌐 [CONNECTED] Wi-Fi Group Established.");
    _log("   📋 Role: ${isHost ? 'Group Owner (GO)' : 'Client'}");
    _log("   📋 Host IP: $hostAddress");
    // WIFI_DIRECT_AUDIT: для GO hostAddress — свой IP; не сохраняем как peer для отправки (обновится из processIncomingPacket)
    _lastConnectedHost = hostAddress;
    if (!isHost) {
      _lastKnownPeerIp = hostAddress;
    }
    _log("   📋 Saved to _lastKnownPeerIp: $_lastKnownPeerIp");
    notifyListeners();

    // 🔥 КРИТИЧЕСКИЙ ФИКС #1: Запускаем TCP сервер ТОЛЬКО если мы Group Owner
    if (isHost) {
      _log("🛡️ [GO] We are Group Owner - starting TCP server...");
      _startPersistentTcpServerWhenGo();
    } else {
      _log(
          "📱 [CLIENT] We are client - will connect to GO's TCP server at $hostAddress:${MeshService.meshTcpPort}");
    }

    // 🔥 Wi-Fi Direct Fix: маршрут готов к отправке (sendAuto Channel 2 и cascade смогут использовать TCP)
    _isRouteReady = true;
    _log("   📋 isRouteReady=true (Wi-Fi Direct TCP available)");

    // 🔥 REPEATER: Регистрируем Wi-Fi Direct соединение ТОЛЬКО когда мы CLIENT (peer = GO)
    // GO не регистрирует свой IP — иначе relay пытается слать на себя (ECONNREFUSED)
    if (!isHost) {
      try {
        final repeater = locator<RepeaterService>();
        repeater.registerConnection(
          deviceId: hostAddress,
          channelType: ChannelType.wifiDirect,
          ipAddress: hostAddress,
          port: MeshService.meshTcpPort,
        );
        _log(
            "🔄 [REPEATER] Wi-Fi Direct connection registered: $hostAddress (client→GO)");
      } catch (e) {
        _log("⚠️ [REPEATER] Failed to register connection: $e");
      }
    }

    // [WIFI-PULL] No auto-push. Same as BLE: only pull on request. Client (initiator) sends OUTBOX_REQUEST once.
    if (isHost) {
      _log("   📋 [GO] Waiting for OUTBOX_REQUEST from client (no auto-push)");
      notifyListeners();
      return;
    }
    final targetIp = hostAddress;
    if (targetIp.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      final outboxRequest = jsonEncode(<String, String>{'type': 'OUTBOX_REQUEST'});
      await NativeMeshService.sendTcp(outboxRequest, host: targetIp);
      _log("[WIFI-PULL] OUTBOX_REQUEST sent");
    } catch (e) {
      _log("   ⚠️ [WIFI-PULL] OUTBOX_REQUEST send failed: $e");
    }
    notifyListeners();
  }

  // ============================================================================
  // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
  // ============================================================================

  // 🔥 WI-FI DIRECT: SSID и passphrase группы (для передачи GHOST через BLE)
  String? _wifiDirectNetworkName;
  String? _wifiDirectPassphrase;
  String? get wifiDirectNetworkName => _wifiDirectNetworkName;
  String? get wifiDirectPassphrase => _wifiDirectPassphrase;

  /// Вызывается когда Wi-Fi Direct группа создана или найдена
  void onWifiDirectGroupCreated({
    String? networkName,
    String? passphrase,
    bool isGroupOwner = false,
  }) {
    if (kMeshDiagnostics) {
      _log(meshDiagLog('p2p_role_decision', {
        'role': isGroupOwner ? 'GO' : 'client',
        'event': 'group_created_or_found',
      }));
      _log(meshDiagLog('group_creation_result', {
        'isGroupOwner': '$isGroupOwner',
        'hasNetworkName': '${networkName != null}',
      }));
    }
    _log("📡 [WiFi-Direct] Group ${isGroupOwner ? 'created' : 'found'}:");
    _log("   📋 SSID: $networkName");
    _log(
        "   📋 Passphrase: ${passphrase != null && passphrase.length > 4 ? '${passphrase.substring(0, 4)}***' : '***'}");
    _log("   📋 Owner: ${isGroupOwner ? 'Us' : 'Other device'}");

    // Сохраняем для передачи GHOST через BLE manufacturerData
    if (isGroupOwner && networkName != null && passphrase != null) {
      _wifiDirectNetworkName = networkName;
      _wifiDirectPassphrase = passphrase;
      _log(
          "   ✅ Passphrase saved for BLE advertising (GHOST will receive for Wi-Fi Direct connect)");
      // Обновляем BLE advertising с passphrase
      _btService.updateAdvertisingWithGroupInfo(networkName, passphrase);
    }

    // 🔥 FIX: Когда BRIDGE — GO без клиентов, onConnected не приходит (только при подключении клиента).
    // Считаем P2P "подключённым" и поднимаем постоянный TCP-сервер сразу при создании/найденной группе.
    if (isGroupOwner) {
      _isP2pConnected = true;
      _isHost = true;
      _isRouteReady = true;
      if (kMeshDiagnostics) {
        _log(meshDiagLog('p2p_state_transition', {
          '_isP2pConnected': 'true',
          'isRouteReady': 'true',
          'trigger': 'onWifiDirectGroupCreated_GO',
        }));
      }
      _log(
          "🌐 [WiFi-Direct] GO with no clients: _isP2pConnected=true, isRouteReady=true");
      _startPersistentTcpServerWhenGo();
      _log(
          "🔍 [WiFi-Direct] We are group owner - starting discovery to find clients...");
    }

    notifyListeners();
  }

  /// Запускает постоянный TCP-сервер в фоне, когда мы Group Owner (из onWifiDirectGroupCreated или onNetworkConnected).
  /// Разрешается для BRIDGE (phase bridgeActive) и для RELAY (призрак-релеятор в relay-режиме).
  Future<void> _startPersistentTcpServerWhenGo() async {
    try {
      if (!locator.isRegistered<NetworkPhaseContext>()) return;
      final phaseCtx = locator<NetworkPhaseContext>();
      final allowedByPhase = phaseCtx.allowsTcpServer;
      final allowedByRelay = _isRelayMode;
      if (!allowedByPhase && !allowedByRelay) {
        _log("[TCP][SKIP] server start skipped (phase=${phaseCtx.phase}, relay=$_isRelayMode)");
        return;
      }
      final canStartServer = await NativeMeshService.canStartTcpServer();
      if (!canStartServer) {
        _log("⚠️ [GO] TCP server disabled for this device - using BLE GATT");
        return;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      await NativeMeshService.startBackgroundMesh();
      _log("✅ [GO] Persistent TCP server started on port $meshTcpPort");
    } catch (e) {
      _log("❌ [GO] Failed to start persistent TCP server: $e");
    }
  }

  /// Автоматически создает Wi-Fi Direct группу если мы BRIDGE
  /// Вызывается из MeshOrchestrator при старте сети
  Future<bool> autoCreateWifiDirectGroupIfBridge() async {
    final currentRole = NetworkMonitor().currentRole;

    if (currentRole != MeshRole.BRIDGE) {
      _log("ℹ️ [WiFi-Direct] Not BRIDGE, skipping group creation");
      return false;
    }

    _log("🚀 [WiFi-Direct] BRIDGE обнаружен, создаем Wi-Fi Direct группу...");

    try {
      final groupInfo = await NativeMeshService.ensureWifiDirectGroupExists();

      if (groupInfo != null) {
        _log("✅ [WiFi-Direct] Group ready: ${groupInfo.networkName}");
        _log(
            "   📋 Passphrase: ${groupInfo.passphrase?.substring(0, (groupInfo.passphrase?.length ?? 0) > 4 ? 4 : (groupInfo.passphrase?.length ?? 0))}...");
        return true;
      } else {
        _log("⚠️ [WiFi-Direct] Failed to create group (fallback: BLE GATT)");
        return false;
      }
    } catch (e) {
      _log("❌ [WiFi-Direct] Ошибка создания группы: $e");
      return false;
    }
  }

  // --- GHOST-RELAY: призрак как релеятор при отсутствии BRIDGE ---

  /// Детерминированная задержка для выбора релеятора (tie-break: разные призраки ждут разное время).
  int _relayElectionDelaySeconds() {
    final ghostId = _apiService.currentUserId;
    if (ghostId.isEmpty) return _relayElectionDelayMinSec + 5;
    int h = 0;
    for (int i = 0; i < ghostId.length; i++) {
      h = (h * 31 + ghostId.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return _relayElectionDelayMinSec + (h % _relayElectionDelayRangeSec);
  }

  /// Проверяет, что в контексте давно нет BRIDGE (и нет уже RELAY).
  Future<bool> _hasNoBridgeForRelaySec() async {
    final discoveryContext = locator<DiscoveryContextService>();
    final bestBridge = discoveryContext.bestBridge;
    if (bestBridge != null && bestBridge.isValid) return false;
    final bestRelay = discoveryContext.bestRelay;
    if (bestRelay != null && bestRelay.isValid) return false;
    return true;
  }

  /// Пытается стать релеятором: после задержки и скана, если нет BRIDGE/RELAY — поднимает GATT.
  Future<void> tryBecomeRelay() async {
    if (NetworkMonitor().currentRole != MeshRole.GHOST) return;
    if (_isRelayMode) return;
    if (_relayElectionCooldownUntil != null &&
        DateTime.now().isBefore(_relayElectionCooldownUntil!)) {
      _log("[RELAY] Election cooldown active, skip");
      return;
    }
    if (_relayFailedStartUntil != null &&
        DateTime.now().isBefore(_relayFailedStartUntil!)) {
      _log("[RELAY] Failed-start cooldown active, skip");
      return;
    }
    // Адаптивность: слабые устройства не становятся релеятором (могут лагать или не поднять GATT)
    if (!await HardwareCheckService().canHostServer()) {
      _log("[RELAY] Weak device - skip becoming relay to avoid lag (can still use other relays)");
      return;
    }
    final pending = await db.getPendingFromOutbox();
    if (pending.isEmpty) {
      _log("[RELAY] No pending outbox, skip becoming relay");
      return;
    }
    if (!await _hasNoBridgeForRelaySec()) return;

    final delaySec = _relayElectionDelaySeconds();
    _log("🔄 [RELAY] Will try to become relay in ${delaySec}s (tie-break delay)");
    await Future.delayed(Duration(seconds: delaySec));

    if (NetworkMonitor().currentRole != MeshRole.GHOST || _isRelayMode) return;
    if (!await _hasNoBridgeForRelaySec()) {
      _log("[RELAY] BRIDGE/RELAY appeared during delay, skip");
      return;
    }

    _log("🔍 [RELAY] Scanning 5s for existing RELAY/BRIDGE...");
    try {
      await startDiscovery(SignalType.bluetooth);
      await Future.delayed(const Duration(seconds: 5));
    } catch (_) {}
    if (!await _hasNoBridgeForRelaySec()) {
      _log("[RELAY] Found BRIDGE/RELAY after scan, skip");
      return;
    }

    _log("🛡️ [RELAY] Starting GATT server as relay (no BRIDGE in range)...");
    try {
      final started = await _btService.startGattServerAsRelay();
      if (!started) {
        _log("⚠️ [RELAY] GATT server start failed (weak device or busy), cooldown ${_relayFailedCooldownSec}s");
        _relayFailedStartUntil =
            DateTime.now().add(const Duration(seconds: _relayFailedCooldownSec));
        return;
      }
      _isRelayMode = true;
      _relayStartTime = DateTime.now();
      _relayLastNoClientTime = DateTime.now();
      _log("✅ [RELAY] Relay mode ON — advertising as RELAY for other Ghosts");
      notifyListeners();
      // Option B: на сильных устройствах релеятор поднимает Wi‑Fi группу и TCP
      unawaited(_ensureWifiDirectGroupAsRelay());
    } catch (e) {
      _log("❌ [RELAY] GATT start error: $e — cooldown ${_relayFailedCooldownSec}s");
      _relayFailedStartUntil =
          DateTime.now().add(const Duration(seconds: _relayFailedCooldownSec));
    }
  }

  /// Option B: при режиме RELAY на устройстве, способном хостить TCP — создать Wi‑Fi группу и поднять TCP.
  Future<void> _ensureWifiDirectGroupAsRelay() async {
    if (!_isRelayMode) return;
    try {
      final canStart = await NativeMeshService.canStartTcpServer();
      if (!canStart) {
        _log("[RELAY][WiFi] TCP disabled for this device — relay GATT only");
        return;
      }
      if (!locator.isRegistered<NetworkPhaseContext>()) return;
      final phaseCtx = locator<NetworkPhaseContext>();
      if (!phaseCtx.allowsWifiDirectGroupCreate) {
        _log("[RELAY][WiFi] Phase does not allow group create — skip");
        return;
      }
      _log("[RELAY][WiFi] Creating Wi-Fi Direct group as relay...");
      final groupInfo = await NativeMeshService.ensureWifiDirectGroupExists();
      if (groupInfo != null && groupInfo.isGroupOwner) {
        onWifiDirectGroupCreated(
          networkName: groupInfo.networkName,
          passphrase: groupInfo.passphrase,
          isGroupOwner: true,
        );
        _log("[RELAY][WiFi] Group owner — TCP server started for relay");
      } else {
        _log("[RELAY][WiFi] Not group owner or group create failed — relay GATT only");
      }
    } catch (e) {
      _log("❌ [RELAY][WiFi] ensure group as relay failed: $e");
    }
  }

  /// Снимает режим релеятора и останавливает GATT-сервер (и TCP, если поднимали в Option B).
  Future<void> stopRelay() async {
    if (!_isRelayMode) return;
    _log("🛑 [RELAY] Stopping relay mode...");
    _isRelayMode = false;
    _relayStartTime = null;
    _relayLastNoClientTime = null;
    try {
      await _btService.stopGattServer();
    } catch (e) {
      _log("⚠️ [RELAY] stopGattServer error: $e");
    }
    try {
      await NativeMeshService.stopBackgroundMesh();
      _log("[RELAY] Background TCP stopped (was started as relay GO)");
    } catch (e) {
      _log("ℹ️ [RELAY] stopBackgroundMesh: $e");
    }
    _relayElectionCooldownUntil =
        DateTime.now().add(const Duration(seconds: 30));
    notifyListeners();
  }

  /// Если долго нет клиентов — снимаем режим релеятора (освобождаем для других).
  Future<void> stopRelayIfNoClients() async {
    if (!_isRelayMode) return;
    final count = _btService.connectedGattClientsCount;
    if (count > 0) {
      _relayLastNoClientTime = null;
      return;
    }
    if (_relayLastNoClientTime == null) {
      _relayLastNoClientTime = DateTime.now();
      return;
    }
    final elapsed =
        DateTime.now().difference(_relayLastNoClientTime!).inSeconds;
    if (elapsed >= _relayNoClientStopSec) {
      _log(
          "🛑 [RELAY] No clients for ${elapsed}s — stopping relay so others can try");
      await stopRelay();
    }
  }

  // --- ОБРАБОТКА ПАКЕТОВ ---

  String get lastKnownPeerIp => _lastKnownPeerIp;

  /// [WIFI-PULL] Same semantic as BLE: respond to OUTBOX_REQUEST with outbox contents (encryption/framing unchanged).
  Future<void> _handleWifiOutboxRequest(String requesterIp) async {
    try {
      final pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) {
        _log("[WIFI-PULL] No pending messages");
        return;
      }
      _log("[WIFI-PULL] Outbox size: ${pending.length}");
      _log("[WIFI-PULL] Sending ${pending.length} messages");
      for (final row in pending) {
        final id = row['id'] as String? ?? '';
        final content = row['content'] as String? ?? '';
        final chatRoomId = row['chatRoomId'] as String? ?? 'THE_BEACON_GLOBAL';
        final senderId = row['senderId'] as String? ?? 'GHOST_NODE';
        final createdAt = row['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        final isEncrypted = row['isEncrypted'] == 1;
        final msg = <String, dynamic>{
          'type': 'OFFLINE_MSG',
          'h': id,
          'content': content,
          'chatId': chatRoomId,
          'senderId': senderId,
          'timestamp': createdAt,
          'ts': createdAt,
          'ttl': 5,
        };
        if (isEncrypted) msg['isEncrypted'] = true;
        final messageJson = jsonEncode(msg);
        final fragments = _fragmentMessageForWifi(messageJson);
        for (final frag in fragments) {
          await NativeMeshService.sendTcp(jsonEncode(frag), host: requesterIp);
          await Future.delayed(const Duration(milliseconds: 50));
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _log("[WIFI-PULL] Transfer complete");
      reportMeshHealthWifiOutboxTransferSuccess();
      unawaited(_crdtOrCreate.startDigestExchange(requesterIp));
    } catch (e) {
      _log("   ❌ [WIFI-PULL] Error: $e");
    }
  }

  /// Same fragmentation as BLE (chunk 60, MSG_FRAG). Protocol unchanged.
  List<Map<String, dynamic>> _fragmentMessageForWifi(String message) {
    try {
      final Map<String, dynamic> base = jsonDecode(message);
      final String msgId = (base['h']?.toString().isNotEmpty == true)
          ? base['h'].toString()
          : DateTime.now().millisecondsSinceEpoch.toString();
      final String chatId = base['chatId']?.toString() ?? 'THE_BEACON_GLOBAL';
      final String senderId = base['senderId']?.toString() ?? 'UNKNOWN';
      final String content = base['content']?.toString() ?? message;
      const int chunkSize = 60;
      final int total = (content.length / chunkSize).ceil().clamp(1, 9999);
      if (total == 1) {
        final single = <String, dynamic>{
          'type': base['type'] ?? 'OFFLINE_MSG',
          'chatId': chatId,
          'senderId': senderId,
          'h': msgId,
          'content': content,
          'ttl': base['ttl'] ?? 5,
        };
        if (base['isEncrypted'] == true) single['isEncrypted'] = true;
        return [single];
      }
      final List<Map<String, dynamic>> frags = [];
      for (int i = 0; i < total; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize < content.length) ? start + chunkSize : content.length;
        frags.add({
          'type': 'MSG_FRAG',
          'mid': msgId,
          'idx': i,
          'tot': total,
          'data': content.substring(start, end),
          'chatId': chatId,
          'senderId': senderId,
          'ttl': base['ttl'] ?? 5,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
      return frags;
    } catch (_) {
      return [
        {'type': 'OFFLINE_MSG', 'content': message, 'h': DateTime.now().millisecondsSinceEpoch.toString(), 'ttl': 5}
      ];
    }
  }

  /// Логика: Распаковка -> Дедупликация -> Peer Lock -> Маршрутизация.
  Future<void> processIncomingPacket(dynamic rawData) async {
    final currentRole = NetworkMonitor().currentRole;
    final roleLabel = currentRole == MeshRole.BRIDGE ? 'BRIDGE' : 'GHOST';
    _log(
        "🧬 [$roleLabel] processIncomingPacket: New packet received. Analyzing...");

    final db = LocalDatabaseService();
    // Извлекаем менеджер Gossip через локатор для ретрансляции
    final gossip = locator<GossipManager>();

    try {
      String jsonString = "";
      String? senderIp;
      String? transportType = 'UNKNOWN';

      // --- 1. РАСПАКОВКА И ЗАХВАТ IP (Критично для Tecno/Huawei) ---
      // Native-слой присылает Map с контентом сообщения и IP адресом отправителя.
      // 🔥 FIX: Поддержка двух форматов:
      // 1. Обернутый формат: {'message': jsonString, 'senderIp': ...}
      // 2. Прямой формат: {type: 'OFFLINE_MSG', content: ..., senderIp: ...} (от BLE GATT)
      if (rawData is Map) {
        // Проверяем, есть ли поле 'message' (старый формат)
        if (rawData.containsKey('message') && rawData['message'] != null) {
          jsonString = rawData['message']?.toString() ?? "";
          senderIp = rawData['senderIp']?.toString();
        } else {
          // 🔥 FIX: rawData уже является самим сообщением (новый формат от BLE GATT)
          // Извлекаем senderIp и сериализуем обратно в JSON
          senderIp = rawData['senderIp']?.toString();
          // Создаем копию без senderIp для сериализации (senderIp - метаданные транспорта)
          final dataForSerialization = Map<String, dynamic>.from(rawData);
          dataForSerialization.remove('senderIp');
          jsonString = jsonEncode(dataForSerialization);
          _log(
              "   🔄 [FIX] rawData is already message object, serialized to JSON");
        }

        // Определяем тип транспорта по senderIp
        if (senderIp != null) {
          if (senderIp.contains(':')) {
            transportType = 'BLE_GATT'; // MAC адрес в формате XX:XX:XX:XX:XX:XX
          } else if (senderIp.contains('.')) {
            transportType = 'TCP'; // IP адрес
          } else {
            transportType = 'UNKNOWN';
          }
        }
      } else {
        jsonString = rawData.toString();
      }

      _log("   📋 Transport: $transportType");
      _log("   📋 Sender: $senderIp");
      _log("   📋 Raw data length: ${jsonString.length} bytes");

      if (jsonString.isEmpty) {
        _log("⚠️ [$roleLabel] Empty payload received. Aborting.");
        return;
      }

      // --- 2. ПАРСИНГ JSON ---
      final Map<String, dynamic> data = jsonDecode(jsonString);

      _log("   ✅ JSON parsed successfully");
      _log("   📋 Data keys: ${data.keys.toList()}");
      _log("   📋 Raw chatId from data: '${data['chatId']}'");

      final String packetType = data['type'] ?? 'UNKNOWN';

      // --- 2.5 [WIFI-PULL] OUTBOX_REQUEST: same semantic as BLE — respond with outbox, no auto-push ---
      if (packetType == 'OUTBOX_REQUEST') {
        if (senderIp != null && senderIp.isNotEmpty) {
          unawaited(_handleWifiOutboxRequest(senderIp));
        }
        return;
      }

      // --- 2.6 [CRDT] Causal sync (HEAD_EXCHANGE, REQUEST_RANGE, LOG_ENTRIES) ---
      if (senderIp != null && senderIp.isNotEmpty) {
        if (packetType == 'HEAD_EXCHANGE') {
          _log('[BEACON-SYNC] CRDT packet received: HEAD_EXCHANGE from peer — comparing chat heads');
          unawaited(_crdtOrCreate.onHeadExchangeReceived(data, senderIp));
          return;
        }
        if (packetType == 'REQUEST_RANGE') {
          _log('[BEACON-SYNC] CRDT packet received: REQUEST_RANGE from peer — sending missing messages');
          unawaited(_crdtOrCreate.onRequestRangeReceived(data, senderIp));
          return;
        }
        if (packetType == 'LOG_ENTRIES') {
          _log('[BEACON-SYNC] CRDT packet received: LOG_ENTRIES from peer — merging into THE BEACON chat');
          unawaited(_crdtOrCreate.onLogEntriesReceived(data, senderIp).then((_) {
            final chatId = data['chatId']?.toString();
            if (chatId != null && chatId.isNotEmpty) {
              _eventBus.bus.fire(ChatSyncCompletedEvent(chatId));
              _log('[BEACON-SYNC] ChatSyncCompletedEvent fired for $chatId — UI can refresh');
            }
          }));
          return;
        }
      }

      // --- 3. GOSSIP ДЕДУПЛИКАЦИЯ (Anti-Entropy Layer) ---
      // Генерируем или извлекаем уникальный хеш пакета.
      // 🔥 MSG_FRAG: каждый фрагмент должен иметь свой hash (mid+idx), иначе 2-й и 3-й отбрасываются как дубликат и сообщение не собирается.
      final String packetHash;
      if (data['mid'] != null && data['idx'] != null) {
        packetHash = "frag_${data['mid']}_${data['idx']}";
      } else {
        packetHash =
            data['h'] ?? "pulse_${data['timestamp']}_${data['senderId']}";
      }

      // Проверка через БД: если мы уже видели этот сигнал, мы его не обрабатываем и не пересылаем.
      if (await db.isPacketSeen(packetHash)) {
        _log(
            "♻️ [Gossip] Duplicate pulse ($packetHash). Dropping to save battery.");
        return;
      }

      // Извлекаем тактические метаданные (ДО использования в Peer Lock)
      final String senderId = data['senderId'] ?? 'Unknown';
      // Нормализуем ID чата для стабильной фильтрации на разных устройствах
      final String incomingChatId =
          (data['chatId'] ?? "").toString().trim().toUpperCase();

      // --- 4. МАРШРУТИЗАЦИЯ ОБРАТНОГО ПУТИ (Peer Lock) ---
      // Фиксируем IP отправителя. В Wi-Fi Direct IP могут меняться,
      // поэтому мы всегда запоминаем адрес последнего входящего пакета.
      // 🔒 Fix IP lock expiry: Only update if expired or new
      if (senderIp != null && senderIp.isNotEmpty && senderIp != "127.0.0.1") {
        final now = DateTime.now();
        final isExpired = _peerIpExpiry[senderIp]?.isBefore(now) ?? true;

        if (_lastKnownPeerIp != senderIp || isExpired) {
          _lastKnownPeerIp = senderIp;
          _peerIpExpiry[senderIp] =
              now.add(const Duration(minutes: 5)); // TTL: 5 minutes
          if (kMeshDiagnostics) {
            _log(meshDiagLog('resolved_peer_ip', {
              'peerIp': senderIp,
              'source': 'processIncomingPacket',
            }));
          }
          _log(
              "📍 [$roleLabel] Peer Locked -> $_lastKnownPeerIp (expires in 5min)");

          // 🔥 КРИТИЧНО: Если это MAGNET_WAVE, обновляем IP в DiscoveryContext
          if (packetType == 'MAGNET_WAVE' && currentRole == MeshRole.GHOST) {
            final serverToken = data['serverToken']?.toString();
            final waveIp = data['ip']?.toString();
            final wavePort = data['port'] is int
                ? data['port'] as int
                : (data['port'] != null
                    ? int.tryParse(data['port'].toString())
                    : null);

            _log("🌊 [MAGNET_WAVE] Received from $senderIp");
            _log(
                "   📋 Server token: ${serverToken != null ? (serverToken.length > 8 ? serverToken.substring(0, 8) : serverToken) + '...' : 'none'}");
            _log("   📋 IP from packet: $waveIp");
            _log("   📋 Port from packet: $wavePort");
            _log("   📋 Sender IP: $senderIp");

            if (serverToken != null) {
              final discoveryContext = locator<DiscoveryContextService>();
              // Ищем кандидата по токену и обновляем IP
              bool found = false;
              for (final candidate in discoveryContext.validCandidates) {
                if (candidate.isBridge) {
                  // 🔥 КРИТИЧНО: Сравниваем токены (может быть обрезанный токен в manufacturerData)
                  final candidateToken = candidate.bridgeToken;
                  if (candidateToken != null) {
                    // Проверяем, совпадает ли токен полностью или начинается с candidateToken
                    final tokenMatches = serverToken == candidateToken ||
                        (serverToken.length >= candidateToken.length &&
                            serverToken.substring(0, candidateToken.length) ==
                                candidateToken);

                    if (tokenMatches) {
                      // Используем IP из пакета, если есть, иначе используем senderIp
                      final finalIp = waveIp ?? senderIp;
                      final finalPort = wavePort ?? 55556;

                      discoveryContext.updateFromMeshDiscovery(
                        id: candidate.id,
                        mac: candidate.mac,
                        hops: 0,
                        ip: finalIp,
                        port: finalPort,
                        hasData: candidate.hasData,
                      );
                      _log(
                          "   ✅ Updated BRIDGE IP/port: $finalIp:$finalPort (token match)");
                      found = true;
                      break;
                    }
                  }
                }
              }

              if (!found) {
                _log(
                    "   ⚠️ BRIDGE with token $serverToken not found in DiscoveryContext");
                _log(
                    "   💡 This may happen if MAGNET_WAVE arrived before BLE scan");
              }
            } else {
              _log("   ⚠️ MAGNET_WAVE received but no serverToken in packet");
            }
          }

          notifyListeners(); // UI должен обновить статус "горячего" соединения
        }
      }

      _log("   📋 Packet type: $packetType");
      _log(
          "   📋 Sender ID: ${senderId.length > 8 ? senderId.substring(0, 8) : senderId}...");
      _log("   📋 Chat ID: $incomingChatId");

      // --- 4.5 REPEATER/REPAIR: Уведомляем RepeaterService о пакете ---
      // Это позволяет автоматически ретранслировать трафик доверенным устройствам
      try {
        final repeater = locator<RepeaterService>();
        if (repeater.isRunning && senderIp != null) {
          unawaited(repeater.onPacketReceived(data, senderIp));
        }
      } catch (e) {
        // RepeaterService может быть не инициализирован - это нормально
        _log("⚠️ [Repeater] Service not available: $e");
      }

      // --- 5. ТАКТИЧЕСКИЙ РОУТИНГ ПО ТИПАМ ПАКЕТОВ ---
      switch (packetType) {
        case 'DELIVERED_TO_CLOUD':
          // Сигнал от BRIDGE: сообщения доставлены в облако, снять с ретрансляции
          final batchId = data['batchId']?.toString() ?? '';
          final idsRaw = data['messageIds'];
          final List<String> messageIds = idsRaw is List
              ? idsRaw.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList()
              : [];
          if (messageIds.isNotEmpty && batchId.isNotEmpty) {
            final seenKey = 'delivered_cloud_$batchId';
            if (!await db.isPacketSeen(seenKey)) {
              for (final id in messageIds) {
                try {
                  await _db.removeFromOutbox(id);
                } catch (_) {}
              }
              _log("🛑 [DELIVERED_TO_CLOUD] Removed ${messageIds.length} from outbox (batch: $batchId)");
            }
          }
          break;

        // 🔥 FIX: Удален дублирующий case 'OFFLINE_MSG' - обработка происходит ниже в case 'OFFLINE_MSG': case 'MSG_FRAG':

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
            _log(
                "🧭 Route Optimized: Found path to Internet via $peerId ($peerDist hops)");

            // Срочно уведомляем Оркестратор о смене градиента
            locator<TacticalMeshOrchestrator>()
                .processRoutingPulse(RoutingPulse(
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
            final port = data['port'] is int
                ? data['port'] as int
                : (data['port'] != null
                    ? int.tryParse(data['port'].toString()) ?? 55556
                    : 55556);
            final bridgeIp = data['ip']
                ?.toString(); // 🔥 КРИТИЧНО: IP адрес BRIDGE из MAGNET_WAVE
            final expiresAt = data['expiresAt'] is int
                ? data['expiresAt'] as int
                : (data['expiresAt'] != null
                    ? int.tryParse(data['expiresAt'].toString()) ?? 0
                    : 0);
            final signature = data['signature']?.toString();
            final publicKey = data['publicKey']?.toString();

            _log("🧲 [GHOST] MAGNET_WAVE received!");
            _log("   📋 Token: ${serverToken?.substring(0, 8) ?? 'null'}...");
            _log("   📋 Port: $port");
            _log(
                "   📋 IP: ${bridgeIp ?? 'not provided (will use default 192.168.49.1)'}");
            _log("   📋 ExpiresAt: $expiresAt");

            // 🔥 КРИТИЧНО: Сохраняем IP и порт в DiscoveryContext для использования при подключении
            if (bridgeIp != null && bridgeIp.isNotEmpty) {
              final discoveryContext = locator<DiscoveryContextService>();
              final bridgeId = data['bridgeId']?.toString() ??
                  data['senderId']?.toString() ??
                  'unknown';

              // Пытаемся найти существующего кандидата по токену (из BLE scan)
              // Если не найден - создаем новый через updateFromMeshDiscovery
              UplinkCandidate? existingCandidate;
              for (final candidate in discoveryContext.validCandidates) {
                if (candidate.isBridge &&
                    candidate.bridgeToken == serverToken) {
                  existingCandidate = candidate;
                  break;
                }
              }

              if (existingCandidate != null) {
                // Обновляем существующего кандидата с IP адресом
                final updated = existingCandidate.copyWith(
                  ip: bridgeIp,
                  port: port,
                  bridgeToken: serverToken,
                  lastSeen: DateTime.now(),
                  discoverySource: "MAGNET_WAVE",
                );
                // Обновляем в контексте
                discoveryContext.updateFromMeshDiscovery(
                  id: existingCandidate.id,
                  mac: existingCandidate.mac,
                  hops: 0,
                  ip: bridgeIp,
                  port: port,
                  hasData: existingCandidate.hasData,
                );
                _log(
                    "   ✅ BRIDGE IP updated in existing candidate: $bridgeIp:$port (MAC: ${existingCandidate.mac.substring(existingCandidate.mac.length - 8)})");
              } else {
                // Создаем новый кандидат
                discoveryContext.updateFromMeshDiscovery(
                  id: bridgeId,
                  mac: 'unknown', // MAC будет обновлен из BLE scan
                  hops: 0,
                  ip: bridgeIp,
                  port: port,
                  hasData: false,
                );
                _log("   ✅ BRIDGE IP saved to new candidate: $bridgeIp:$port");
              }
            } else {
              _log(
                  "   ⚠️ MAGNET_WAVE does not contain IP address - will use default 192.168.49.1 or IP from Wi-Fi Direct");
            }

            // 🔒 SECURITY: Verify signature before processing
            if (signature != null && publicKey != null) {
              final signingService = MessageSigningService();
              await signingService.initialize();
              final isValid = await signingService.verifyMessage(
                  data, signature, publicKey);

              if (!isValid) {
                _log(
                    "❌ [Ghost] MAGNET_WAVE signature verification failed! Dropping message.");
                break; // Reject unsigned messages
              }

              _log("✅ [Ghost] MAGNET_WAVE signature verified");
            } else {
              _log(
                  "⚠️ [Ghost] MAGNET_WAVE missing signature or publicKey - rejecting (security)");
              break; // Reject unsigned messages
            }

            // Проверяем валидность токена
            if (serverToken != null && serverToken.isNotEmpty) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now < expiresAt) {
                _log(
                    "✅ [Ghost] Magnet wave is valid! Connecting to BRIDGE on port $port...");
                // 🔥 КРИТИЧНО: Запускаем загрузку немедленно (не в фоне)
                // Это важно для быстрой доставки сообщений
                await _handleMagnetWave(serverToken, port, expiresAt);
              } else {
                _log(
                    "⚠️ [Ghost] Magnet wave expired (now: $now, expires: $expiresAt)");
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
            _log(
                "❓ [Gossip] Packet query received: ${queryPacketId.substring(0, 8)}...");

            // Проверяем, есть ли у нас этот пакет в outbox или в сообщениях
            final pending = await db.getPendingFromOutbox();
            final hasInOutbox =
                pending.any((msg) => msg['id'] == queryPacketId);

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
              _log(
                  "📭 [Gossip] We don't have packet ${queryPacketId.substring(0, 8)}..., requesting...");
              // Отправляем запрос на получение пакета
              await locator<UltrasonicService>()
                  .transmitFrame("REQ:$queryPacketId");
            } else {
              // У нас есть пакет - отвечаем "ДА" и отправляем через сеть (если есть)
              _log(
                  "✅ [Gossip] We have packet ${queryPacketId.substring(0, 8)}..., will send via network");
              // Если есть Wi-Fi Direct или Router - отправляем через него
              if (senderIp != null) {
                Map<String, dynamic>? packetData;

                if (hasInOutbox) {
                  final msg =
                      pending.firstWhere((m) => m['id'] == queryPacketId);
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
                    foundMsg = messages.firstWhere((m) => m.id == queryPacketId,
                        orElse: () =>
                            foundMsg ??
                            ChatMessage(
                                id: '',
                                content: '',
                                senderId: '',
                                createdAt: DateTime.now()));
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
                    await NativeMeshService.sendTcp(jsonEncode(packetData),
                        host: senderIp);
                  } else {
                    // Если нет Wi-Fi Direct - отправляем через Router (если подключен)
                    final routerConnection = RouterConnectionService();
                    final connectedRouter = routerConnection.connectedRouter;
                    if (connectedRouter != null &&
                        connectedRouter.hasInternet) {
                      final routerProtocol = RouterBridgeProtocol();
                      // Используем sendViaRouter с IP роутера или шлем на шлюз
                      final routerIp =
                          connectedRouter.ipAddress ?? "192.168.1.1";
                      await routerProtocol.sendViaRouter(
                          jsonEncode(packetData), routerIp);
                    }
                  }
                }
              }
            }
          }
          break;

        case 'OFFLINE_MSG':
        case 'MSG_FRAG':
          final bool isFragment = packetType == 'MSG_FRAG';
          _log(
              "📥 [$roleLabel] ${isFragment ? 'MSG_FRAG' : 'OFFLINE_MSG'} detected for room: $incomingChatId");
          _log("   📋 Transport: $transportType");
          _log(
              "   📋 Sender: ${senderId.length > 8 ? senderId.substring(0, 8) : senderId}...");
          _log(
              "   📋 Message ID: ${packetHash.length > 8 ? packetHash.substring(0, 8) : packetHash}...");

          // 🔥 ЛОГИРОВАНИЕ: Детальная информация для BRIDGE и GHOST
          if (currentRole == MeshRole.BRIDGE) {
            _log(
                "   📥 [BRIDGE] ✅ ${isFragment ? 'Fragment' : 'Message'} received from GHOST via $transportType");
            _log(
                "      📋 Content length: ${data['content']?.toString().length ?? data['data']?.toString().length ?? 0} bytes");
            _log("      📋 Chat ID: $incomingChatId");
            _log("      📋 Sender IP: $senderIp");
            if (isFragment) {
              _log(
                  "      📦 Fragment ${data['idx']}/${data['tot']} for message ${data['mid']}");
            }
          } else {
            _log(
                "   📥 [GHOST] ✅ ${isFragment ? 'Fragment' : 'Message'} received from ${senderId.length > 8 ? senderId.substring(0, 8) : senderId}... via $transportType");
            _log(
                "   📥 [GHOST↔GHOST] Message from peer (relay or direct) — will process and show in chat");
            _log(
                "      📋 Content length: ${data['content']?.toString().length ?? data['data']?.toString().length ?? 0} bytes");
            _log("      📋 Chat ID: $incomingChatId");
            _log("      📋 Sender IP: $senderIp");
          }

          // 🔥 GHOST: безопасное получение myId (ApiService может быть не загружен)
          final String myId = await getCurrentUserIdSafe();

          // 🔥 ГИБКАЯ ФИЛЬТРАЦИЯ (Решение для Huawei/Xiaomi)
          bool isForMe = data['recipientId'] == myId;
          bool isGlobal = incomingChatId.contains("GLOBAL") ||
              incomingChatId.contains("BEACON");

          // 🔥 КРИТИЧНО: Фрагменты НЕ отправляются в UI!
          // Только полные сообщения (OFFLINE_MSG) идут в UI stream.
          // Фрагменты собираются в GossipManager и после сборки
          // полное сообщение отправляется в _messageController.
          if (!isFragment &&
              (isForMe || isGlobal || incomingChatId.isNotEmpty)) {
            _log("🚀 [Mesh] Complete message - relaying to UI stream.");
            _log(
                "   📋 isForMe: $isForMe, isGlobal: $isGlobal, incomingChatId: '$incomingChatId'");
            // Копия для UI: расшифровываем контент до показа в чате (BLE/relay присылают isEncrypted).
            // Оригинал data без изменений уходит в gossip для сохранения и ретрансляции.
            final Map<String, dynamic> dataForUi = Map<String, dynamic>.from(data);
            dataForUi['senderIp'] = senderIp;
            if (dataForUi['isEncrypted'] == true) {
              final String rawContent = dataForUi['content']?.toString() ?? '';
              if (rawContent.isNotEmpty && locator.isRegistered<EncryptionService>()) {
                try {
                  final encryption = locator<EncryptionService>();
                  final chatKey = await encryption.getChatKey(incomingChatId.isNotEmpty ? incomingChatId : 'THE_BEACON_GLOBAL');
                  final decrypted = await encryption.decrypt(rawContent, chatKey);
                  dataForUi['content'] = decrypted.isNotEmpty ? decrypted : '[Secure Message Captured]';
                  dataForUi['isEncrypted'] = false;
                } catch (_) {
                  dataForUi['content'] = '[Secure Message Captured]';
                  dataForUi['isEncrypted'] = false;
                }
              }
            }
            _log(
                "   📋 Content preview: ${(dataForUi['content']?.toString() ?? '').substring(0, (dataForUi['content']?.toString() ?? '').length > 50 ? 50 : (dataForUi['content']?.toString() ?? '').length)}");
            // 🔄 Event Bus: Fire message received event
            _eventBus.bus.fire(MessageReceivedEvent(dataForUi));
            // Legacy StreamController (for backward compatibility)
            _messageController
                .add(dataForUi); // Отправляем в стрим для ConversationScreen
            _log(
                "   ✅ [UI] Message added to messageStream (should appear in chat)");
          } else if (isFragment) {
            _log(
                "📦 [Mesh] Fragment - will be delivered to UI after assembly.");
          } else {
            _log("⚠️ [Mesh] Message NOT sent to UI stream:");
            _log("   📋 isFragment: $isFragment");
            _log("   📋 isForMe: $isForMe");
            _log("   📋 isGlobal: $isGlobal");
            _log(
                "   📋 incomingChatId: '$incomingChatId' (isEmpty: ${incomingChatId.isEmpty})");
          }

          // 🦠 GOSSIP PROPAGATION:
          // Передаем в GossipManager для:
          // - Сборки фрагментов (MSG_FRAG)
          // - Ретрансляции соседям
          // - Сохранения в SQL
          if (currentRole == MeshRole.BRIDGE) {
            _log(
                "   📤 [BRIDGE] Forwarding to GossipManager for processing...");
          }
          await gossip.processEnvelope(data);

          // 🔥 КРИТИЧНО: После обработки сообщения BRIDGE должен ретранслировать его GHOST устройствам
          // Это позволяет GHOST получать сообщения от других GHOST через BRIDGE
          // Исключаем сообщения от самого себя (чтобы не создавать циклы)
          final messageSenderId = data['senderId']?.toString() ?? '';
          final currentUserId = await getCurrentUserIdSafe();
          final isFromMe = messageSenderId == currentUserId;

          if (currentRole == MeshRole.BRIDGE && !isFragment && !isFromMe) {
            try {
              _log(
                  "   🔄 [BRIDGE] Initiating relay to GHOST devices after message processing...");
              _log(
                  "   📋 Message from: ${messageSenderId.length > 8 ? messageSenderId.substring(0, 8) : messageSenderId}... (not from me)");
              await gossip.attemptRelay(data);
              _log(
                  "   ✅ [BRIDGE] Relay initiated - message will be sent to nearby GHOST devices");
            } catch (e) {
              _log("   ⚠️ [BRIDGE] Failed to relay message: $e");
            }
          } else if (isFromMe) {
            _log("   ℹ️ [BRIDGE] Skipping relay - message is from this device");
          }

          if (currentRole == MeshRole.BRIDGE) {
            _log(
                "   ✅ [BRIDGE] ${isFragment ? 'Fragment' : 'Message'} processed successfully");
          }
          break;

        case 'GOSSIP_SYNC':
          _log("🔄 Gossip Sync: Merging tactical ad-pool metadata.");
          final List? adsRaw = data['payload']?['ads'];
          if (adsRaw != null) {
            for (var adJson in adsRaw) {
              try {
                await db.saveAd(AdPacket.fromJson(adJson));
              } catch (e) {
                continue;
              }
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
    _myDistanceToBridge =
        (currentRole == MeshRole.BRIDGE) ? 0 : orchestrator.myHops;

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

  /// BRIDGE: после успешного syncOutbox рассылает сигнал DELIVERED_TO_CLOUD,
  /// чтобы GHOST-ноды и ретрансляторы сняли эти сообщения с outbox и перестали ретранслировать.
  Future<void> broadcastDeliveredToCloud(List<String> messageIds, String batchId) async {
    if (messageIds.isEmpty) return;
    try {
      final packet = <String, dynamic>{
        'type': 'DELIVERED_TO_CLOUD',
        'messageIds': messageIds,
        'batchId': batchId,
        'ttl': 3,
        'h': 'delivered_${batchId}_${DateTime.now().millisecondsSinceEpoch}',
        'senderId': _apiService.currentUserId,
      };
      await locator<RepeaterService>().repeatPacket(packet);
      _log("🛑 [BRIDGE] broadcastDeliveredToCloud: ${messageIds.length} ids (batch: $batchId)");
    } catch (e) {
      _log("⚠️ [BRIDGE] broadcastDeliveredToCloud failed: $e");
    }
  }

  /// Метод "Заражения" (Viral Infection Protocol)
  /// Сохраняет пакет в Outbox для дальнейшей ретрансляции при обнаружении BRIDGE-ноды
  Future<void> _infectDevice(Map<String, dynamic> packet) async {
    final String packetId =
        "pulse_${packet['timestamp']}_${packet['senderId']}";

    // Если мы уже инкубировали этот пульс - выходим
    if (_lastSeenTimestamps.containsKey(packetId)) return;
    _lastSeenTimestamps[packetId] = DateTime.now().millisecondsSinceEpoch;
    try {
      final db = LocalDatabaseService();
      // Используем timestamp как часть ID, чтобы он был уникальным
      final String packetId =
          "pulse_${packet['timestamp'] ?? DateTime.now().millisecondsSinceEpoch}";

      final relayMsg = ChatMessage(
        id: packetId,
        content: packet['content'] ?? jsonEncode(packet),
        senderId: packet['senderId'] ?? "GHOST_NODE",
        createdAt: DateTime.now(),
        status: "MESH_RELAY",
      );
      await _incrementKarma(1);
      await db.addToOutbox(relayMsg, packet['chatId'] ?? "TRANSIT_ZONE",
          contentAlreadyEncrypted: true);
      _log("🦠 [Viral] Packet ${packetId} incubated.");
    } catch (e) {
      _log("⚠️ Infection failed: $e");
    }
  }

  /// МЕТОД "ЗАРАЖЕНИЯ" (Gossip Infection)
  /// Каждая нода, получив этот пакет, сохраняет его и пытается передать дальше
  Future<void> infectNeighbors(Map<String, dynamic> packet) async {
    final String packetId =
        packet['h'] ?? "pulse_${DateTime.now().millisecondsSinceEpoch}";

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
        status: 'MESH_RELAY');
    await db.saveMessage(msg, packet['chatId'] ?? 'THE_BEACON_GLOBAL',
        contentAlreadyEncrypted: true);

    // 3. Рассылаем всем Wi-Fi нодам в радиусе
    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh) {
        // Шлем по захваченному ранее IP или по IP группы
        String target =
            (node.id == _lastKnownPeerIp) ? _lastKnownPeerIp : "192.168.49.1";
        NativeMeshService.sendTcp(jsonEncode(packet), host: target);
      }
    }
  }

  /// Вирусная рассылка (Gossip Protocol)
  /// Шлет сообщение всем, кто в зоне доступа. Каждый получатель становится ретранслятором.
  Future<void> viralBroadcast(Map<String, dynamic> packet) async {
    final String packetId = packet['clientTempId'] ??
        "ghost_${DateTime.now().millisecondsSinceEpoch}";

    // 1. Проверяем, не пересылали ли мы это уже (защита от циклов)
    if (_lastSeenTimestamps.containsKey(packetId)) return;
    _lastSeenTimestamps[packetId] = DateTime.now().millisecondsSinceEpoch;

    _log(
        "🦠 [Viral] Infecting neighbors with packet: ${packetId.substring(0, 8)}");

    // 2. Рассылаем всем Wi-Fi нодам
    for (var node in _nearbyNodes.values) {
      if (node.type == SignalType.mesh) {
        // Мы используем IP, который захватили ранее (lastKnownPeerIp)
        NativeMeshService.sendTcp(jsonEncode(packet), host: _lastKnownPeerIp);
      }
    }

    // 3. Если мы нашли интернет (мы - Мост) и есть ApiService — сразу в облако
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE &&
        locator.isRegistered<ApiService>()) {
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
      // 1. Канонический ID = h (не генерировать из timestamp)
      final String meshId = data['h']?.toString() ??
          data['clientTempId']?.toString() ??
          data['id']?.toString() ??
          '';
      if (meshId.isEmpty) return;
      final int tsMs = data['ts'] ??
          data['timestamp'] ??
          DateTime.now().millisecondsSinceEpoch;

      // 2. Создаем объект сообщения (createdAt = ts)
      final msg = ChatMessage(
        id: meshId,
        content: data['content'] ?? "",
        senderId: data['senderId'] ?? "Unknown",
        senderUsername: data['senderUsername'] ?? "Nomad",
        createdAt: DateTime.fromMillisecondsSinceEpoch(tsMs),
        status: "MESH_LINK",
      );

      final String targetChatId = data['chatId'] ?? "THE_BEACON_GLOBAL";
      final bool alreadyEncrypted = data['isEncrypted'] == true;

      // 3. Сохраняем в SQLite (idempotent merge: no overwrite, no duplicate — CRDT)
      await db.saveMessage(msg, targetChatId,
          contentAlreadyEncrypted: alreadyEncrypted, idempotentMerge: true);

      _log("💾 [Storage] Offline packet cached for chat: $targetChatId");
    } catch (e) {
      _log("❌ [Storage-Error] Failed to auto-save mesh packet: $e");
    }
  }

  Future<void> dispatchMessage(ChatMessage msg) async {
    final orchestrator = locator<TacticalMeshOrchestrator>();

    // 1. Если я мост и есть ApiService — сразу в облако
    if (orchestrator.myHops == 0 && locator.isRegistered<ApiService>()) {
      _log("🌉 I am BRIDGE. Sending directly to Cloud.");
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
      await locator<LocalDatabaseService>()
          .saveMessage(msg, msg.id, contentAlreadyEncrypted: true);
      await locator<LocalDatabaseService>()
          .addToOutbox(msg, msg.id, contentAlreadyEncrypted: true);
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
    } else if (type == 'RES') {
      // Это ответ от сервера! Ищем, кому его вернуть в меш-сети.
      String? originalSenderId = orchestrator.reversePath.findNextHop(packetId);

      if (originalSenderId != null) {
        _log("🎯 Found reverse path for $packetId -> $originalSenderId");
        // Шлем ответ конкретному соседу
        await NativeMeshService.sendTcp(jsonEncode(data),
            host: originalSenderId);
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
    final ioc = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    final client = IOClient(ioc);

    final String ghostId = packet.payload['senderId'] ?? "Unknown";
    _log(
        "🌉 [Bridge] Proxying REQ for Node: ${ghostId.substring(0, 8)} -> $endpoint");

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
          : (_baseUrl +
              (endpoint.startsWith('/api')
                  ? endpoint.replaceFirst('/api', '')
                  : endpoint));

      http.Response response;
      final encodedBody = (rawBody != null && rawBody is! String)
          ? jsonEncode(rawBody)
          : rawBody;

      if (method == 'POST') {
        response = await client.post(Uri.parse(fullUrl),
            headers: proxyHeaders, body: encodedBody);
      } else {
        response = await client.get(Uri.parse(fullUrl), headers: proxyHeaders);
      }

      _log("☁️ [Server] Response: ${response.statusCode}");

      // 4. УПАКОВКА ОТВЕТА
      final resPacket = MeshPacket.createResponse(
          packet.id, response.statusCode, response.body);
      final String serializedRes = resPacket.serialize();

      // 5. 🔥 ТАКТИКА "ОБРАТНЫЙ ВСПЛЕСК" (Return Burst)
      // Шлем 3 раза, так как Huawei соседа мог "уснуть", пока мы ждали интернет
      if (_lastKnownPeerIp.isNotEmpty) {
        for (int i = 0; i < 3; i++) {
          await NativeMeshService.sendTcp(serializedRes,
              host: _lastKnownPeerIp);
          await Future.delayed(const Duration(milliseconds: 200));
        }
        _log("✅ [Bridge] Result delivered back to $_lastKnownPeerIp");
      }
    } catch (e) {
      _log("❌ [Bridge] Relay Failure: $e");
      // Шлем ошибку 503, чтобы "Призрак" не ждал вечно
      final errPacket = MeshPacket.createResponse(
          packet.id, 503, jsonEncode({'error': 'Mesh Bridge Timeout'}));
      if (_lastKnownPeerIp.isNotEmpty) {
        await NativeMeshService.sendTcp(errPacket.serialize(),
            host: _lastKnownPeerIp);
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

  /// GHOST: отправка пакета через роутер (TCP по подсети) когда нет Wi‑Fi Direct.
  /// Best-effort: не блокирует sendAuto, не меняет messageDeliveredToNetwork.
  Future<void> _tryGhostViaRouter(String offlinePacket) async {
    try {
      final routerProtocol = RouterBridgeProtocol();
      final devices = await routerProtocol.discoverDevicesInNetwork();
      if (devices.isEmpty) return;
      _log("🛰️ [GHOST-ROUTER] Trying ${devices.length} device(s) in subnet");
      for (final ip in devices) {
        final ok = await routerProtocol.sendViaRouter(offlinePacket, ip);
        if (ok) {
          _log("🛰️ [GHOST-ROUTER] Delivered to $ip");
          return;
        }
      }
    } catch (e) {
      _log("⚠️ [GHOST-ROUTER] Error: $e");
    }
  }

  /// Returns true only if the message was actually sent over TCP.
  /// Returns false when skipped (GO/no peer, would send to self) or when all attempts failed.
  Future<bool> sendTcpBurst(String message) async {
    final tcpAttemptStart = DateTime.now();
    _log("📤 [TCP-BURST] Starting TCP burst transmission");
    _log("   📋 Message length: ${message.length} bytes");

    // [WIFI-GUARD] Do not use Wi-Fi transport (TCP burst) when BLE is active; no pending/cooldown check
    final guard = await _evaluateWifiDirectGuard(requirePendingAndCooldown: false);
    if (!guard.allowed) {
      _log("[WIFI-GUARD] Blocked reason: ${guard.blockReason}");
      return false;
    }

    if (!_isP2pConnected) {
      if (kMeshDiagnostics) {
        _log(meshDiagLog('tcp_connect_skipped', {
          'reason': 'p2p_not_connected',
          'elapsedMs': '0',
        }));
      }
      _log("⚠️ [Burst] Wi-Fi Direct not connected - skipping TCP burst");
      _log("   💡 Message will be available via BLE advertising only");
      return false;
    }

    // 🔥 FIX: GO не шлёт на 192.168.49.1 — это его собственный IP (ECONNREFUSED)
    if (_isHost && _lastKnownPeerIp.isEmpty) {
      if (kMeshDiagnostics) {
        _log(meshDiagLog('tcp_connect_skipped', {
          'reason': 'GO_no_peer_ip',
          'elapsedMs': '${DateTime.now().difference(tcpAttemptStart).inMilliseconds}',
        }));
      }
      _log("   📋 [GO] No peer IP — clients connect to us, skipping TCP burst");
      return false;
    }

    final String targetIp =
        _lastKnownPeerIp.isNotEmpty ? _lastKnownPeerIp : "192.168.49.1";
    if (_isHost &&
        (targetIp == "192.168.49.1" || targetIp == _lastConnectedHost)) {
      if (kMeshDiagnostics) {
        _log(meshDiagLog('would_send_to_self', {
          'targetIp': targetIp,
          'elapsedMs': '${DateTime.now().difference(tcpAttemptStart).inMilliseconds}',
        }));
      }
      _log("   📋 [GO] Would send to self ($targetIp) — skipping TCP burst");
      return false;
    }
    final int port = MeshService.meshTcpPort;

    if (kMeshDiagnostics) {
      final ctx = await getDiagnosticContext();
      _log(meshDiagLog('tcp_connect_attempt_start', {
        'targetIp': targetIp,
        'port': '$port',
        'elapsedMs': '0',
        ...ctx,
      }));
    }
    _log(
        "🚀 [Burst] Initiating TCP transfer to $targetIp:$port (P2P: $_isP2pConnected, isRouteReady: $isRouteReady)");

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _log(
            "📤 [TCP-BURST] Attempt $attempt/3: Sending to $targetIp:$port...");
        await NativeMeshService.sendTcp(message, host: targetIp, port: port);
        if (kMeshDiagnostics) {
          final elapsed = DateTime.now().difference(tcpAttemptStart).inMilliseconds;
          _log(meshDiagLog('tcp_connect_result', {
            'result': 'success',
            'attempt': '$attempt',
            'elapsedMs': '$elapsed',
          }));
        }
        _log("✅ [Burst] Success on attempt $attempt");
        _log(
            "✅ [TCP-BURST] TCP burst completed successfully (host=$targetIp port=$port)");
        return true;
      } catch (e) {
        _log("⚠️ [Burst] Attempt $attempt failed: $e");
        if (e.toString().contains("failed to connect")) {
          _log(
              "   💡 Connection refused - target may not be in Wi-Fi Direct group");
        }
        await Future.delayed(Duration(seconds: attempt));
      }
    }
    if (kMeshDiagnostics) {
      final elapsed = DateTime.now().difference(tcpAttemptStart).inMilliseconds;
      _log(meshDiagLog('tcp_connect_result', {
        'result': 'timeout',
        'attempts': '3',
        'elapsedMs': '$elapsed',
      }));
    }
    _log("❌ [Burst] Fatal: Could not reach $targetIp:$port after 3 attempts.");
    _log("❌ [TCP-BURST] TCP burst failed after 3 attempts");
    _log("   💡 This is expected if devices are not in Wi-Fi Direct group");
    return false;
  }

  // --- ДОПОЛНИТЕЛЬНЫЕ МЕТОДЫ СВЯЗИ ---

  /// Отправляет HTTP-запрос через Mesh-цепочку (для режима GHOST)
  Future<dynamic> sendThroughMesh(String endpoint, String method,
      Map<String, String> headers, dynamic body) async {
    if (!_isP2pConnected) throw Exception("Mesh Link Offline.");

    // Создаем пакет запроса
    final packet = MeshPacket.createRequest(method, endpoint, headers, body);

    // Создаем "ожидатель" ответа
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[packet.id] = completer;

    _log(
        "👻 [Ghost] Injecting packet ${packet.id.substring(0, 8)} into Mesh...");

    // В Wi-Fi Direct "Призрак" всегда шлет пакет "Хосту" (Мосту) на стандартный IP
    String targetIp = "192.168.49.1";

    try {
      // Используем порт 55556 для временного BRIDGE сервера
      await NativeMeshService.sendTcp(packet.serialize(),
          host: targetIp, port: 55556);
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

    // 🔒 SECURITY FIX #4: Не ротируем токен, если есть активные GATT клиенты
    // Это предотвращает прерывание GHOST соединения при обновлении advertising
    if (_btService.hasActiveGattClients) {
      _log(
          "⏸️ [Bridge] GATT clients active (${_btService.connectedGattClientsCount} connected), skipping token rotation");
      _log(
          "   💡 Token rotation will resume after all clients disconnect + grace period");
      return;
    }

    // 🔥 Улучшение: Проверяем, прошло ли достаточно времени с последнего обновления токена
    // Это обеспечивает минимум 10 секунд стабильности advertising перед сменой токена
    if (_lastTokenUpdate != null) {
      final timeSinceLastUpdate = DateTime.now().difference(_lastTokenUpdate!);
      if (timeSinceLastUpdate < _minTokenStability) {
        final remaining = _minTokenStability - timeSinceLastUpdate;
        _log(
            "⏸️ [Bridge] Token stability window active (${remaining.inSeconds}s remaining), skipping update");
        return; // Не обновляем токен слишком часто
      }
    }

    _lastTokenUpdate = DateTime.now();

    // 🔥 КРИТИЧНО: ПРАВИЛЬНАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ ИНИЦИАЛИЗАЦИИ BRIDGE
    // ШАГ 1: GATT Server → ШАГ 2: Token → ШАГ 3: Advertising → ШАГ 4: TCP → ШАГ 5: MAGNET_WAVE

    // 🔥 ШАГ 1: Запускаем GATT Server ПЕРВЫМ и ждем готовности
    _log("🌉 [BRIDGE] Step 1: Starting GATT Server...");
    try {
      // Проверяем, не запущен ли GATT server уже
      final isGattRunning = await _btService.isGattServerRunning();
      if (!isGattRunning) {
        // Останавливаем предыдущий advertising перед запуском GATT server
        await _btService.stopAdvertising();
        await Future.delayed(const Duration(
            milliseconds: 500)); // Задержка для стабилизации BLE стека

        // Запускаем GATT server и ждем готовности
        // Используем внутренний метод _startGattServerAndWait() через рефлексию или прямой доступ
        // Но так как это приватный метод, используем публичный startGattServer() и проверяем состояние
        try {
          await _btService.startGattServer(); // Запускаем сервер (асинхронно)

          // Ждем готовности через проверку состояния (максимум 25 секунд, как в _startGattServerAndWait)
          bool gattReady = false;
          final maxWaitTime = const Duration(seconds: 25);
          final checkInterval = const Duration(milliseconds: 500);
          final maxAttempts =
              maxWaitTime.inMilliseconds ~/ checkInterval.inMilliseconds;

          for (int i = 0; i < maxAttempts; i++) {
            await Future.delayed(checkInterval);
            gattReady = await _btService.isGattServerRunning();
            if (gattReady) {
              _log(
                  "✅ [BRIDGE] GATT Server ready after ${(i + 1) * checkInterval.inMilliseconds}ms");
              break;
            }
            if (i % 4 == 0 && i > 0) {
              _log(
                  "⏳ [BRIDGE] Waiting for GATT server... (${(i + 1) * checkInterval.inMilliseconds}ms elapsed)");
            }
          }

          if (!gattReady) {
            _log(
                "⚠️ [BRIDGE] GATT server not ready after ${maxWaitTime.inSeconds}s - will continue in fallback mode");
          } else {
            _log("✅ [BRIDGE] Step 1 Complete: GATT Server ready");
            // Даем время BLE стеку стабилизироваться после запуска GATT server
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } catch (e) {
          _log("❌ [BRIDGE] GATT server start exception: $e");
        }
      } else {
        _log("ℹ️ [BRIDGE] GATT Server already running - skipping start");
        // Даем время BLE стеку стабилизироваться
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      _log(
          "❌ [BRIDGE] GATT server start error: $e - continuing in fallback mode");
    }

    // 🔥 ШАГ 2: Генерация токена ПОСЛЕ готовности GATT Server
    _log("🔑 [BRIDGE] Step 2: Generating token...");
    final serverToken = _generateTemporaryToken();
    // 🔥 MAC RANDOMIZATION FIX: Увеличено время жизни токена с 30s до 60s
    // Это синхронизировано с heartbeat интервалом (60s)
    // Даёт GHOST больше времени на connect после обнаружения BRIDGE
    final expiresAt = DateTime.now()
        .add(const Duration(seconds: 60))
        .millisecondsSinceEpoch; // Валиден 60 секунд

    // 🔥 ШАГ 2.1: Логирование генерации токена
    final tokenPreview =
        serverToken.length > 16 ? serverToken.substring(0, 16) : serverToken;
    _log(
        "🔑 [BRIDGE] Generated token: $tokenPreview... (valid 60s, timestamp: ${DateTime.now().millisecondsSinceEpoch})");

    // 2. Проверяем возможности железа перед поднятием сервера
    final hardwareCheck = HardwareCheckService();
    final canHost = await hardwareCheck.canHostServer();

    if (!canHost) {
      _log(
          "⚠️ [Bridge] Hardware check: Device may struggle with server hosting.");
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
      final encryptedToken = await tokenSigningService
          .encryptTokenForAdvertising(serverToken, expiresAt);

      // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN
      // M_0 — Mesh, hops=0 (BRIDGE)
      // 1 — есть pending сообщения (0 — нет)
      // BRIDGE — роль
      // ENCRYPTED_TOKEN — HMAC-токен
      final String tacticalName =
          "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";

      // 🔥 ШАГ 1.2: Обновление advertising не позже, чем через 500ms после генерации токена
      // 🔥 FIX: keepGattServer=true чтобы НЕ останавливать GATT сервер при обновлении advertising
      await _btService.stopAdvertising(keepGattServer: true);
      await Future.delayed(const Duration(
          milliseconds: 500)); // Задержка для стабилизации BLE стека
      await _btService.startAdvertising(tacticalName);

      // 🔥 ШАГ 1.4: Логирование обновления advertising
      final encryptedTokenPreview = encryptedToken.length > 16
          ? encryptedToken.substring(0, 16)
          : encryptedToken;
      _log("📡 [BRIDGE] Advertising updated with token");
      _log(
          "   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
      _log("   🔑 Encrypted token preview: $encryptedTokenPreview...");
      _log(
          "   ⏰ Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");

      // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android - проверка обновления advertising
      await Future.delayed(
          const Duration(milliseconds: 2000)); // 2-3 секунды для стабилизации
      final isAdvActive =
          await _btService.state == BleAdvertiseState.advertising;
      if (isAdvActive) {
        _log("✅ [BRIDGE] Advertising stabilized - token visible for GHOST");
      } else {
        _log(
            "⚠️ [BRIDGE] WARNING: Advertising may not be active - repeating update...");
        // Повторное обновление для надежности на медленных устройствах
        // 🔥 FIX: keepGattServer=true
        await _btService.stopAdvertising(keepGattServer: true);
        await Future.delayed(const Duration(milliseconds: 500));
        await _btService.startAdvertising(tacticalName);
        _log("🔄 [BRIDGE] Advertising updated again for stability");
      }

      // 🔥 КРИТИЧНО: GATT server уже запущен на ШАГЕ 1
      // Проверяем, что он готов
      final isGattReady = await _btService.isGattServerRunning();
      if (isGattReady) {
        _log("✅ [Bridge] GATT server ready (hardware-limited mode)");
      } else {
        _log(
            "⚠️ [Bridge] GATT server not ready - GHOST may not be able to connect via GATT");
      }
      return; // Не поднимаем TCP сервер для бюджетных устройств
    }

    // 3. Проверяем, можно ли поднимать TCP сервер
    final canStartServer = await NativeMeshService.canStartTcpServer();
    if (!canStartServer) {
      _log(
          "🚫 [Bridge] TCP server disabled for this device - using BLE GATT with token");
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
      final encryptedToken = await tokenSigningService
          .encryptTokenForAdvertising(serverToken, expiresAt);

      // Формат: M_0_1_BRIDGE_ENCRYPTED_TOKEN
      final String tacticalName =
          "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";

      // 🔥 ШАГ 1.2: Обновление advertising не позже, чем через 500ms после генерации токена
      // 🔥 FIX: keepGattServer=true чтобы НЕ останавливать GATT сервер при обновлении advertising
      await _btService.stopAdvertising(keepGattServer: true);
      await Future.delayed(const Duration(milliseconds: 500));
      await _btService.startAdvertising(tacticalName);

      // 🔥 ШАГ 1.4: Логирование
      final encryptedTokenPreview = encryptedToken.length > 16
          ? encryptedToken.substring(0, 16)
          : encryptedToken;
      _log("📡 [BRIDGE] Advertising updated with token (TCP server disabled)");
      _log(
          "   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
      _log("   🔑 Encrypted token preview: $encryptedTokenPreview...");

      // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android
      await Future.delayed(const Duration(milliseconds: 2000));
      final isAdvActive =
          await _btService.state == BleAdvertiseState.advertising;
      if (!isAdvActive) {
        _log(
            "⚠️ [BRIDGE] WARNING: Advertising may not be active - repeating update...");
        // 🔥 FIX: keepGattServer=true
        await _btService.stopAdvertising(keepGattServer: true);
        await Future.delayed(const Duration(milliseconds: 500));
        await _btService.startAdvertising(tacticalName);
        _log("🔄 [BRIDGE] Advertising updated again for stability");
      }

      // 🔥 КРИТИЧНО: GATT server уже запущен на ШАГЕ 1
      // Проверяем, что он готов
      final isGattReady = await _btService.isGattServerRunning();
      if (isGattReady) {
        _log("✅ [Bridge] GATT server ready (TCP server disabled)");
        // 🔥 DIAGNOSTIC: Log detailed GATT server status
        await _btService.logGattServerStatus();
      } else {
        _log(
            "⚠️ [Bridge] GATT server not ready - GHOST may not be able to connect via GATT");
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
    final encryptedToken = await tokenSigningService.encryptTokenForAdvertising(
        serverToken, expiresAt);

    // 🔥 ШАГ 3: Обновление advertising с токеном ПОСЛЕ готовности GATT Server
    _log("📡 [BRIDGE] Step 3: Updating advertising with token...");
    final String tacticalName =
        "M_0_${pendingCount > 0 ? '1' : '0'}_BRIDGE_$encryptedToken";

    // 🔥 КРИТИЧНО: Останавливаем предыдущее advertising и ждем стабилизации BLE стека
    // 🔥 FIX: keepGattServer=true чтобы НЕ останавливать GATT сервер при обновлении advertising
    await _btService.stopAdvertising(keepGattServer: true);
    await Future.delayed(const Duration(
        milliseconds: 500)); // Задержка для стабилизации BLE стека

    // Запускаем advertising с токеном
    await _btService.startAdvertising(tacticalName);

    // 🔥 ШАГ 1.4: Логирование обновления advertising
    final encryptedTokenPreview = encryptedToken.length > 16
        ? encryptedToken.substring(0, 16)
        : encryptedToken;
    _log("📡 [BRIDGE] Advertising updated with token");
    _log(
        "   📋 Tactical name: '$tacticalName' (length: ${tacticalName.length})");
    _log(
        "   🔑 Encrypted token preview: $encryptedTokenPreview... (full length: ${encryptedToken.length})");
    _log("   🔑 Original token preview: ${tokenPreview}...");
    _log(
        "   ⏰ Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");

    // 🔥 ШАГ 4.3: Стабилизация на Huawei/Android - проверка обновления advertising (2-3 секунды)
    await Future.delayed(const Duration(milliseconds: 2000));
    final isAdvActive = await _btService.state == BleAdvertiseState.advertising;
    if (isAdvActive) {
      _log("✅ [BRIDGE] Advertising stabilized - token visible for GHOST");
    } else {
      _log(
          "⚠️ [BRIDGE] WARNING: Advertising may not be active - attempting retry...");
      // 🔥 УЛУЧШЕНИЕ: Retry с обработкой ошибок
      try {
        // 🔥 ШАГ 1.3: Повторное обновление для медленных BLE устройств (Huawei/Android)
        // 🔥 FIX: keepGattServer=true
        await _btService.stopAdvertising(keepGattServer: true);
        await Future.delayed(
            const Duration(milliseconds: 1000)); // 500-1000ms для надежности
        await _btService.startAdvertising(tacticalName);

        // Проверяем результат после повторной попытки
        await Future.delayed(const Duration(milliseconds: 1000));
        final retryAdvState = _btService.state;
        if (retryAdvState == BleAdvertiseState.advertising) {
          _log(
              "✅ [BRIDGE] Advertising activated after retry - token visible for GHOST");
        } else {
          _log(
              "⚠️ [BRIDGE] Advertising still not active after retry (state: $retryAdvState)");
          _log("   💡 This device may have BLE advertising limitations");
          _log(
              "   💡 GHOST devices can still connect via TCP if they have IP/port from MAGNET_WAVE");
        }
      } catch (e) {
        _log("❌ [BRIDGE] Retry advertising failed: $e");
        _log(
            "   💡 Will continue without BLE advertising (TCP/GATT server still available)");
      }
    }

    // 🔥 ШАГ 3.5: Создаём Wi-Fi Direct группу, чтобы устройство стало Group Owner до запуска TCP
    // Без этого MeshBackgroundService.checkIfGroupOwner() всегда false → TCP сервер не поднимается
    _log(
        "🛡️ [BRIDGE] Step 3.5: Ensuring Wi-Fi Direct group (so we become Group Owner)...");
    try {
      final groupInfo = await NativeMeshService.ensureWifiDirectGroupExists()
          .timeout(const Duration(seconds: 15));
      if (groupInfo != null) {
        _log(
            "✅ [BRIDGE] Wi-Fi Direct group ready: ${groupInfo.networkName} (GO: ${groupInfo.isGroupOwner})");
        onWifiDirectGroupCreated(
          networkName: groupInfo.networkName,
          passphrase: groupInfo.passphrase,
          isGroupOwner: groupInfo.isGroupOwner,
        );
      } else {
        _log(
            "⚠️ [BRIDGE] Wi-Fi Direct group not created - TCP server may not start (fallback: BLE GATT)");
      }
    } catch (e) {
      _log("⚠️ [BRIDGE] Ensure Wi-Fi Direct group failed: $e");
    }

    // 🔥 ШАГ 4: Запускаем TCP сервер ТОЛЬКО после готовности GATT и стабилизации Advertising
    _log(
        "🛡️ [BRIDGE] Step 4: Starting TCP server (after GATT+Advertising)...");

    // 🔥 КРИТИЧНО: Проверяем готовность GATT server ПЕРЕД запуском TCP
    // Ждем готовности GATT server с таймаутом (максимум 25 секунд, как в _startGattServerAndWait)
    bool isGattReady = false;
    final maxGattWaitTime = const Duration(seconds: 25);
    final gattCheckInterval = const Duration(milliseconds: 500);
    final maxGattChecks =
        maxGattWaitTime.inMilliseconds ~/ gattCheckInterval.inMilliseconds;

    _log(
        "⏳ [BRIDGE] Waiting for GATT server ready (max ${maxGattWaitTime.inSeconds}s)...");
    for (int i = 0; i < maxGattChecks; i++) {
      await Future.delayed(gattCheckInterval);
      isGattReady = await _btService.isGattServerRunning();
      if (isGattReady) {
        _log(
            "✅ [BRIDGE] GATT server ready after ${(i + 1) * gattCheckInterval.inMilliseconds}ms");
        break;
      }
      if (i % 4 == 0 && i > 0) {
        _log(
            "⏳ [BRIDGE] Still waiting for GATT server... (${(i + 1) * gattCheckInterval.inMilliseconds}ms elapsed)");
      }
    }

    if (!isGattReady) {
      _log(
          "⚠️ [Bridge] GATT server not ready after ${maxGattWaitTime.inSeconds}s - starting TCP server anyway");
      _log(
          "   💡 TCP server can work independently, but BLE GATT may not be available");
    } else {
      _log("✅ [BRIDGE] GATT server confirmed ready - safe to start TCP server");
    }

    // Убеждаемся, что BLE операции завершены
    await Future.delayed(const Duration(
        milliseconds: 500)); // Даем время на стабилизацию BLE стека

    // 🔥 FIX: Проверяем состояние advertising, но НЕ БЛОКИРУЕМ TCP!
    // На Huawei и других устройствах BLE advertising может быть ограничен,
    // но TCP сервер ДОЛЖЕН запускаться для работы mesh через Wi-Fi Direct
    final advState = _btService.state;
    if (advState != BleAdvertiseState.advertising) {
      _log("⚠️ [Bridge] BLE Advertising not active (state: $advState)");
      _log("   💡 This is common on Huawei/Honor devices with BLE limitations");
      _log(
          "   💡 TCP server will start anyway - GHOST can connect via Wi-Fi Direct");
      // 🔥 FIX: НЕ ВОЗВРАЩАЕМСЯ! Продолжаем запуск TCP сервера
      // TCP - единственный способ связи если BLE advertising не работает
    } else {
      _log(
          "✅ [Bridge] BLE Advertising active - both BLE GATT and TCP available");
    }

    // Получаем адаптивную длительность сервера на основе батареи
    final serverDuration = await _getAdaptiveServerDuration();

    // Поднимаем кратковременный TCP сервер (после GATT и ADV)
    try {
      await NativeMeshService.startTemporaryTcpServer(
          durationSeconds: serverDuration);
      _log(
          "✅ [Bridge] Step 4 Complete: TCP server active for ${serverDuration}s (started after GATT+ADV)");
    } catch (e) {
      _log("⚠️ [Bridge] Failed to start TCP server: $e");
      // Если сервер не поднялся - продолжаем работать в BLE GATT режиме (advertising уже обновлен с токеном)
      _log(
          "📡 [Bridge] Continuing in BLE GATT mode (TCP server failed, but advertising has token)");
      return;
    }

    // 8. Формируем MAGNET_WAVE пакет с токеном и подписью
    final waveSigningService = MessageSigningService();
    await waveSigningService.initialize();

    // 🔥 КРИТИЧНО: Получаем IP адрес BRIDGE для включения в MAGNET_WAVE
    String? bridgeIp;
    if (_isP2pConnected && _isHost) {
      // Если мы хост Wi-Fi Direct группы, используем hostAddress
      bridgeIp =
          _lastConnectedHost; // Обычно 192.168.49.1 для Wi-Fi Direct хоста
    } else if (_isP2pConnected) {
      // Если мы клиент, используем стандартный IP хоста
      bridgeIp = "192.168.49.1";
    } else {
      // Пытаемся получить локальный IP адрес
      bridgeIp = await NativeMeshService.getLocalIpAddress();
      if (bridgeIp == null) {
        // Fallback на стандартный Wi-Fi Direct IP
        bridgeIp = "192.168.49.1";
      }
    }

    _log(
        "   📋 BRIDGE IP address: $bridgeIp (P2P connected: $_isP2pConnected, isHost: $_isHost)");

    final publicKey = await waveSigningService.getPublicKeyBase64();
    final wave = {
      'type': 'MAGNET_WAVE',
      'bridgeId': _hashUserId(_apiService.currentUserId), // Хеш для анонимности
      'serverToken': serverToken,
      'port': 55556, // Порт для временного BRIDGE сервера
      'ip': bridgeIp, // 🔥 КРИТИЧНО: IP адрес BRIDGE для TCP подключения
      'expiresAt': expiresAt,
      'hops': 0, // Я - источник
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderId': _hashUserId(_apiService.currentUserId),
      'publicKey': publicKey, // Public key for verification
    };

    // Sign the message
    final signature = await waveSigningService.signMessage(wave);
    wave['signature'] = signature;

    // 🔥 ШАГ 5: Отправляем MAGNET_WAVE ПОСЛЕ готовности всех компонентов
    _log("📡 [BRIDGE] Step 5: Emitting MAGNET_WAVE...");
    _log(
        "📡 [Magnet] Emitting wave with token: ${serverToken.substring(0, 8)}...");

    // 🔥 КРИТИЧНО: Даем время TCP server запуститься перед отправкой MAGNET_WAVE
    await Future.delayed(const Duration(milliseconds: 500));

    // Выстреливаем MAGNET_WAVE через Wi-Fi Direct (только если соединение установлено)
    if (_isP2pConnected) {
      String payload = jsonEncode(wave);
      _log(
          "   📤 Sending MAGNET_WAVE via Wi-Fi Direct (P2P connected: $_isP2pConnected)");
      sendTcpBurst(payload);
      _log("✅ [BRIDGE] Step 5 Complete: MAGNET_WAVE sent via Wi-Fi Direct");
    } else {
      _log(
          "   ⚠️ Wi-Fi Direct not connected - MAGNET_WAVE available only via BLE advertising");
      _log(
          "   💡 GHOST devices can extract token from BLE advertising name or manufacturerData");
      _log(
          "✅ [BRIDGE] Step 5 Complete: MAGNET_WAVE available via BLE advertising (token in name/manufacturerData)");
      // MAGNET_WAVE будет доступен через BLE advertising (токен уже в tactical name и manufacturerData)
    }

    _log("✅ [BRIDGE] Initialization sequence completed:");
    _log(
        "   1. GATT Server: ${await _btService.isGattServerRunning() ? '✅ Ready' : '❌ Not ready'}");
    _log("   2. Token: ✅ Generated");
    _log(
        "   3. Advertising: ${_btService.state == BleAdvertiseState.advertising ? '✅ Active' : '❌ Not active'}");
    _log("   4. TCP Server: ${canStartServer ? '✅ Started' : '❌ Disabled'}");
    _log("   5. MAGNET_WAVE: ✅ Emitted");
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
    final timestamp =
        DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final prefix = isError ? "❌ [SONAR-ERR]" : "🔊 [SONAR]";
    final fullLog = "$timestamp $prefix $msg";

    print(fullLog);
    // 🔄 Event Bus: Fire status event
    _eventBus.bus.fire(StatusEvent(fullLog));
    // Legacy StreamController (for backward compatibility)
    _statusController.add(fullLog); // Отправляем в терминал на экране
    notifyListeners();
  }

  // Универсальный логгер с выводом в терминал UI (панель с кнопкой Scan / Mesh Hybrid)
  void _log(String msg) {
    final timestamp =
        DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    final fullMsg = "[$timestamp] $msg";
    print(fullMsg);

    // Сохраняем в список всех логов
    _allLogs.add(fullMsg);
    if (_allLogs.length > _maxLogs) {
      _allLogs.removeAt(0); // Удаляем старые логи, если превышен лимит
    }

    // 🔄 Event Bus: Fire status event
    _eventBus.bus.fire(StatusEvent(fullMsg));
    // Legacy StreamController — все сообщения попадают в панель приложения (statusStream)
    _statusController.add(fullMsg);
    notifyListeners();
  }

  void _sendInitialHandshake() async {
    await Future.delayed(
        const Duration(seconds: 1)); // Даем сокету прогрузиться
    _log("👋 Sending Handshake to reveal my IP to Host...");

    final ping = jsonEncode({
      'type': 'PING',
      'senderId': _apiService.currentUserId.isNotEmpty
          ? _apiService.currentUserId
          : "GHOST_PREP",
      'senderUsername': _getSenderPseudonym(),
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
    if (kMeshDiagnostics) {
      _log(meshDiagLog('p2p_state_transition', {
        '_isP2pConnected': 'false',
        'isRouteReady': 'false',
        'trigger': 'onNetworkDisconnected',
      }));
    }
    _isP2pConnected = false;
    _isRouteReady = false;
    _isTransferring = false;
    _lastConnectedPeerAddress = null;
    if (_lastKnownPeerIp.isNotEmpty) resetCrdtSessionForPeer(_lastKnownPeerIp);

    // [WIFI] Retry connect to pending peer after state callback (no reset, no removeGroup)
    final pendingAddr = _pendingConnectAfterDisconnect;
    final pendingNN = _pendingConnectNetworkName;
    final pendingPP = _pendingConnectPassphrase;
    _pendingConnectAfterDisconnect = null;
    _pendingConnectNetworkName = null;
    _pendingConnectPassphrase = null;
    if (pendingAddr != null) {
      _log("[WIFI] State settled after disconnect, retrying connect to pending peer");
      Future.delayed(const Duration(seconds: 2), () {
        connectToNode(pendingAddr, networkName: pendingNN, passphrase: pendingPP);
      });
    }

    _log("🔌 Link severed.");

    // 🔥 REPEATER: Уведомляем о разрыве соединения
    try {
      final repeater = locator<RepeaterService>();
      // Отмечаем все Wi-Fi Direct соединения как failed
      for (final conn in repeater.connections) {
        if (conn.channelType == ChannelType.wifiDirect) {
          repeater.onDeviceDisconnected(conn.deviceId);
          _log(
              "🔄 [REPEATER] Wi-Fi Direct disconnection reported: ${conn.deviceId}");
        }
      }
    } catch (e) {
      _log("⚠️ [REPEATER] Failed to report disconnection: $e");
    }

    notifyListeners();
  }

  /// Обработка ошибок подключения Wi-Fi Direct
  void onNetworkConnectionFailed(String error, String message, int? code) {
    _isTransferring = false;
    _transferGuardTimer?.cancel();
    _connectTargetAddress = null;

    if (code == 0) {
      reportMeshHealthWifiConnectFailed();
      reportMeshHealthWifiCooldownTriggered();
      _wifiConnectFailedCooldownUntil =
          DateTime.now().add(Duration(seconds: _wifiConnectFailedCooldownSec));
      _log("[WIFI] Connect failed, entering cooldown");
    }

    _log("❌ [CONNECTION_FAILED] Wi-Fi Direct connection failed:");
    _log("   📋 Error: $error");
    _log("   📋 Message: $message");
    if (code != null) {
      _log("   📋 Code: $code");
    }

    // 🔥 REPEATER: Уведомляем об ошибке подключения
    try {
      final repeater = locator<RepeaterService>();
      // Отмечаем все Wi-Fi Direct соединения как failed
      for (final conn in repeater.connections) {
        if (conn.channelType == ChannelType.wifiDirect) {
          repeater.onDeviceDisconnected(conn.deviceId);
          _log(
              "🔄 [REPEATER] Wi-Fi Direct connection failure reported: ${conn.deviceId}");
        }
      }
    } catch (e) {
      _log("⚠️ [REPEATER] Failed to report connection failure: $e");
    }

    // Если Wi-Fi Direct выключен, предлагаем пользователю включить его
    if (error == "P2P_DISABLED") {
      _log(
          "💡 [CONNECTION_FAILED] Wi-Fi Direct is disabled. Please enable it in settings.");
    }

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

    // 1.5 🔥 REPEATER: Останавливаем Repeater/Repair Service
    try {
      final repeater = locator<RepeaterService>();
      if (repeater.isRunning) {
        repeater.stop();
        _log("🔄 [REPEATER] Service stopped");
      }
    } catch (e) {
      _log("⚠️ [REPEATER] Failed to stop: $e");
    }

    // 1.6 🔥 GHOST TRANSFER MANAGER: Останавливаем менеджер передачи
    try {
      final transferManager = locator<GhostTransferManager>();
      if (transferManager.isRunning) {
        transferManager.stop();
        _log("👻 [TRANSFER-MGR] Service stopped");
      }
    } catch (e) {
      _log("⚠️ [TRANSFER-MGR] Failed to stop: $e");
    }

    // 2. БЕЗОПАСНАЯ ОСТАНОВКА ВЕЩАНИЯ (SONAR / BEACON)
    try {
      // Проверяем статус перед тем как дергать натив
      // Используем существующий экземпляр из BluetoothMeshService, а не создаем новый
      final isAdvertising =
          await _btService.state == BleAdvertiseState.advertising;
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
          _log(
              "🧲 [Ghost] Has $pending messages, starting continuous BLE scan...");
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
  Future<void> _handleMagnetWaveFromBle(
      String tokenPrefix, int port, int expiresAt) async {
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

    final tokenPreview =
        tokenPrefix.length > 8 ? tokenPrefix.substring(0, 8) : tokenPrefix;
    _log(
        "🧲 [Ghost] Processing MAGNET_WAVE from BLE (token prefix: $tokenPreview...)");

    // Используем тот же метод, что и для TCP MAGNET_WAVE
    // Токен в BLE - это префикс, но BRIDGE должен принять его
    await _handleMagnetWave(tokenPrefix, port, expiresAt);
  }

  /// Публичный метод для Connection Stabilizer
  Future<void> handleMagnetWave(
      String serverToken, int port, int expiresAt) async {
    await _handleMagnetWave(serverToken, port, expiresAt);
  }

  /// Обрабатывает MAGNET_WAVE пакет от BRIDGE
  Future<void> _handleMagnetWave(
      String serverToken, int port, int expiresAt) async {
    // 🔥 КРИТИЧНО: Проверка просроченного токена перед использованием
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now > expiresAt) {
      _log("⏰ [GHOST] Token expired → Skipping GATT/TCP");
      _log(
          "   Token expires at: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()}");
      _log("   Current time: ${DateTime.now().toIso8601String()}");
      _log("   → Escalating to Sonar");
      // Переходим к Sonar для отправки сообщений
      final pending = await _db.getPendingFromOutbox();
      if (pending.isNotEmpty) {
        try {
          final msgId = pending.first['id'] as String;
          if (!_sentPayloads.containsKey(msgId)) {
            final firstP = pending.first;
            final int tsMagnet = (firstP['createdAt'] as int?) ??
                DateTime.now().millisecondsSinceEpoch;
            final messageData = jsonEncode({
              'type': 'OFFLINE_MSG',
              'content': firstP['content'],
              'senderId': _apiService.currentUserId,
              'h': msgId,
              'ts': tsMagnet,
              'ttl': 5,
            });
            final sonarPayload = messageData.length > 200
                ? messageData.substring(0, 200)
                : messageData;
            await locator<UltrasonicService>()
                .transmitFrame("DATA:$sonarPayload");
            // 🔒 Sonar только для рукопожатия/SOS — не помечаем как SENT, не удаляем из outbox
            _log(
                "📦 [ARCHITECTURE] Sonar hint emitted for $msgId (token expired). Message stays in outbox for retry.");
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
      _log("💤 [GHOST] No messages to upload to BRIDGE");
      return;
    }

    _log("   📋 Found ${pending.length} message(s) in outbox to upload");
    _log("   📤 Starting upload via TCP to BRIDGE...");

    // 🔥 УЛУЧШЕНИЕ: Получаем IP из DiscoveryContext (если есть из MAGNET_WAVE)
    // Это более надежно, чем полагаться только на Wi-Fi Direct
    final discoveryContext = locator<DiscoveryContextService>();

    // Ищем кандидата по токену (более точно, чем bestBridge)
    UplinkCandidate? candidateByToken;
    for (final candidate in discoveryContext.validBridges) {
      if (candidate.bridgeToken == serverToken) {
        candidateByToken = candidate;
        break;
      }
    }

    // Если не нашли по токену, используем bestBridge
    final candidate = candidateByToken ?? discoveryContext.bestBridge;
    String? bridgeIp;

    // Приоритет 1: IP из MAGNET_WAVE (если есть в DiscoveryContext)
    if (candidate != null && candidate.ip != null && candidate.port == port) {
      bridgeIp = candidate.ip;
      _log(
          "✅ [GHOST] Using BRIDGE IP from DiscoveryContext (MAGNET_WAVE): $bridgeIp:$port");
      _log(
          "   📋 Candidate MAC: ${candidate.mac.length > 8 ? candidate.mac.substring(candidate.mac.length - 8) : candidate.mac}");
      _log(
          "   📋 Candidate token: ${candidate.bridgeToken != null ? candidate.bridgeToken!.substring(0, 8) : 'none'}...");
    } else if (candidate != null && candidate.ip != null) {
      // IP есть, но порт не совпадает - используем IP, но с указанным портом
      bridgeIp = candidate.ip;
      _log(
          "⚠️ [GHOST] Using BRIDGE IP from DiscoveryContext, but port mismatch (candidate: ${candidate.port}, requested: $port)");
      _log("   📋 Using IP: $bridgeIp with requested port: $port");
    } else if (_isP2pConnected) {
      // Приоритет 2: Wi-Fi Direct соединение (стандартный адрес BRIDGE)
      bridgeIp = "192.168.49.1";
      _log("✅ [GHOST] P2P connected, using default BRIDGE IP: $bridgeIp");
      _log("   💡 Note: IP from MAGNET_WAVE not found in DiscoveryContext");
      if (candidate != null) {
        _log(
            "   📋 Candidate found but no IP: token=${candidate.bridgeToken != null ? candidate.bridgeToken!.substring(0, 8) : 'none'}..., ip=${candidate.ip}, port=${candidate.port}");
      } else {
        _log(
            "   📋 No candidate found in DiscoveryContext for token: ${serverToken.substring(0, 8)}...");
      }
    } else {
      _log(
          "🔌 [GHOST] No P2P connection and no IP from MAGNET_WAVE. Attempting to establish P2P...");
      _log("   📋 Current P2P status: _isP2pConnected=$_isP2pConnected");
      if (candidate != null) {
        _log(
            "   📋 Candidate found but no IP: token=${candidate.bridgeToken != null ? candidate.bridgeToken!.substring(0, 8) : 'none'}..., ip=${candidate.ip}, port=${candidate.port}");
      } else {
        _log(
            "   📋 No candidate found in DiscoveryContext for token: ${serverToken.substring(0, 8)}...");
        _log(
            "   💡 This may indicate that MAGNET_WAVE was not received or IP was not saved");
      }

      // Пытаемся запустить discovery для установки P2P соединения
      await NativeMeshService.startDiscovery();
      _log("   📋 Discovery started, waiting for P2P connection...");

      // Ждем до 5 секунд для установки соединения
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (_isP2pConnected) {
          bridgeIp = "192.168.49.1";
          _log("   ✅ P2P connection established!");
          break;
        }
        _log(
            "   ⏳ Waiting for P2P... (${i + 1}/5), _isP2pConnected=$_isP2pConnected");
      }

      if (bridgeIp == null) {
        _log("⚠️ [GHOST] P2P connection failed after 5s");
        _log(
            "   💡 Will try default IP 192.168.49.1 as fallback (devices may already be in same group)");
        _log(
            "   ⚠️ WARNING: This may fail if devices are not in Wi-Fi Direct group!");
        bridgeIp = "192.168.49.1";
      }
    }

    if (bridgeIp == null) {
      _log(
          "⚠️ [GHOST] No Wi-Fi Direct connection. Falling back to BLE GATT...");
      // Fallback на BLE GATT будет обработан в _executeCascadeRelay
      return;
    }

    // 🔥 ЛОГИРОВАНИЕ: Детальная информация о TCP подключении
    _log("   📋 Target BRIDGE IP: $bridgeIp:$port");
    _log("   📋 Token: ${serverToken.substring(0, 8)}...");
    _log("   📋 Connecting to BRIDGE via TCP...");

    final tokenPreview =
        serverToken.length > 8 ? serverToken.substring(0, 8) : serverToken;
    _log(
        "🚀 [Ghost] 🔗 Connecting to BRIDGE server at $bridgeIp:$port (token: $tokenPreview...)");

    // Проверяем, что порт правильный
    if (port != 55556) {
      _log("⚠️ [Ghost] WARNING: Unexpected port $port, expected 55556");
    }

    // 🔥 КРИТИЧНО: Проверяем TCP соединение перед попыткой загрузки
    _log("   🔍 Checking TCP connection availability...");
    final isTcpAvailable = await _checkTcpConnection(bridgeIp, port);
    if (!isTcpAvailable) {
      _log("⚠️ [GHOST] TCP connection check failed to $bridgeIp:$port");
      _log("   💡 Possible reasons:");
      _log("      - BRIDGE TCP server not started on port $port");
      _log("      - Wi-Fi Direct not connected (GHOST not in same group)");
      _log("      - Wrong IP address (BRIDGE may have different IP)");
      _log("      - Firewall blocking connection");
      _log("   🔄 Falling back to BLE GATT...");
      // Fallback на BLE GATT - не бросаем исключение, чтобы не прервать основной поток
      return;
    }

    _log("   ✅ TCP connection check passed - server is available");
    _log("   📤 Proceeding with upload...");

    try {
      await _uploadToBridgeServer(bridgeIp, port, serverToken);
      _log("✅ [GHOST] Successfully uploaded messages to BRIDGE!");
    } catch (e, stackTrace) {
      _log("❌ [GHOST] Bridge upload failed: $e");
      _log("   📋 Error type: ${e.runtimeType}");
      _log("   📋 Full error: ${e.toString()}");
      if (e.toString().contains("failed to connect") ||
          e.toString().contains("Connection refused")) {
        _log("   💡 TCP connection error detected:");
        _log("      - BRIDGE may not have TCP server running");
        _log("      - Wi-Fi Direct connection may be lost");
        _log("      - IP address may be incorrect");
      }
      _log("   🔄 Falling back to BLE GATT...");
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

      _log(
          "🔍 [DiscoveryContext] Making connection decision (pending: ${pending.length} messages)...");

      // Аплинк: BRIDGE приоритетен, при отсутствии — RELAY (призрак-релеятор)
      final bestBridge = discoveryContext.bestBridge;
      final bestRelay = discoveryContext.bestRelay;
      final UplinkCandidate? uplink = bestBridge ?? bestRelay;
      final bool isUplinkBridge = bestBridge != null;

      if (uplink == null) {
        _log("ℹ️ [DiscoveryContext] No valid BRIDGE or RELAY in context");
        return;
      }

      // Проверяем валидность кандидата
      // 🔥 Улучшение: Для BRIDGE с высокой уверенностью увеличиваем TTL
      if (!uplink.isValid) {
        // Если confidence очень высокий (>0.8) и много подтверждений, даём дополнительное время
        if (uplink.confidence > 0.8 && uplink.confirmationCount >= 5) {
          final extendedTtl =
              uplink.ttlSeconds + 30; // +30 секунд для надёжных кандидатов
          if (uplink.ageSeconds < extendedTtl) {
            _log(
                "🔄 [DiscoveryContext] Best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} expired but high confidence, using extended TTL (age: ${uplink.ageSeconds}s, extended: $extendedTtl)");
            // Продолжаем, но с предупреждением
          } else {
            _log(
                "⏸️ [DiscoveryContext] Best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} expired even with extended TTL (age: ${uplink.ageSeconds}s)");
            return;
          }
        } else {
          _log(
              "⏸️ [DiscoveryContext] Best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} expired (age: ${uplink.ageSeconds}s)");
          return;
        }
      }

      // Проверяем уверенность (минимальный порог)
      // 🔥 Улучшение: Для кандидата с множественными подтверждениями снижаем порог
      final minConfidence = uplink.confirmationCount >= 3 ? 0.2 : 0.3;
      if (uplink.confidence < minConfidence) {
        _log(
            "⏸️ [DiscoveryContext] ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} confidence too low (${uplink.confidence.toStringAsFixed(2)}, min=$minConfidence)");
        return;
      }

      // 🔥 Улучшение: Проверяем возраст кандидата - не блокируем если confidence высокий
      if (uplink.ageSeconds > 90) {
        if (uplink.confidence < 0.7) {
          _log(
              "⏸️ [DiscoveryContext] Best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} too old (${uplink.ageSeconds}s) and low confidence - skipping");
          return;
        } else {
          _log(
              "⚠️ [DiscoveryContext] Best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} old (${uplink.ageSeconds}s) but high confidence (${uplink.confidence.toStringAsFixed(2)}) - proceeding with caution");
          // Продолжаем, но будем использовать TCP fallback более агрессивно (только для BRIDGE)
        }
      }

      // 🔥 FIX #1: Cooldown по ТОКЕНУ, не по MAC (MAC rotation на Android)
      final cooldownDuration = 15; // Было: 30-60 секунд
      if (!_isCooldownExpiredByMac(uplink.mac,
          cooldownSeconds: cooldownDuration)) {
        final remaining = _getCooldownRemainingByMac(uplink.mac,
            cooldownSeconds: cooldownDuration);
        _log(
            "⏸️ [DiscoveryContext] ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} in cooldown (${remaining}s remaining)");
        return;
      } else {
        _log("✅ [DiscoveryContext] Cooldown EXPIRED - allowing connection");
      }

      // Проверяем, не идет ли уже передача
      // 🔥 BLE STABILIZATION: Transfer timeout должен быть > batch timeout (30s)
      // Используем _transferTtlSeconds (40s) чтобы не прерывать batch mid-flight
      if (_isTransferring && _transferStartTime != null) {
        final transferAge =
            DateTime.now().difference(_transferStartTime!).inSeconds;
        if (transferAge > _transferTtlSeconds) {
          _log(
              "⚠️ [WATCHDOG] Transfer stuck for ${transferAge}s (>${_transferTtlSeconds}s), forcing reset!");
          _isTransferring = false;
          _transferStartTime = null;
        } else {
          _log(
              "⏸️ [DiscoveryContext] Transfer already in progress (${transferAge}s)");
          return;
        }
      } else if (_isTransferring) {
        _log(
            "⏸️ [DiscoveryContext] Transfer already in progress (no start time)");
        _isTransferring = false; // 🔥 FIX: Сбрасываем если нет start time
        _transferStartTime = null;
      }

      // 🔥 Принимаем решение: подключаемся к лучшему аплинку (BRIDGE или RELAY)
      _log(
          "🧲 [DiscoveryContext] ✅ Connecting to best ${isUplinkBridge ? 'BRIDGE' : 'RELAY'}: ${uplink.id} "
          "(confidence=${uplink.confidence.toStringAsFixed(2)}, "
          "confirmations=${uplink.confirmationCount}, "
          "age=${uplink.ageSeconds}s, "
          "sources=${uplink.discoverySources.join(',')})");

      // 🔥 Улучшение: Пытаемся найти актуальный ScanResult для подключения
      // Это гарантирует, что мы используем свежий токен из advertising (BRIDGE) или RELAY
      try {
        final lastScanResults = await FlutterBluePlus.lastScanResults;
        ScanResult? matchingScanResult;

        // 🔥 КРИТИЧНО: Ищем по MAC адресу, но также проверяем manufacturerData для всех устройств
        // BRIDGE: 0x42,0x52 ("BR"); RELAY: 0x52,0x4C ("RL")
        for (final result in lastScanResults) {
          final resultMac = result.device.remoteId.str;
          final mfData = result.advertisementData.manufacturerData[0xFFFF];
          final isBridgeByMfData = mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x42 &&
              mfData[1] == 0x52; // "BR" = BRIDGE
          final isRelayByMfData = !isUplinkBridge &&
              mfData != null &&
              mfData.length >= 2 &&
              mfData[0] == 0x52 &&
              mfData[1] == 0x4C; // "RL" = RELAY
          final hasService = result.advertisementData.serviceUuids.any((uuid) =>
              uuid.toString().toLowerCase() ==
              _btService.SERVICE_UUID.toLowerCase());

          // 🔥 Улучшение: Проверяем через manufacturerData как fallback
          final advName = result.advertisementData.localName ?? "";
          final platformName = result.device.platformName;
          final effectiveName = advName.isEmpty ? platformName : advName;

          // Проверяем, что это наш аплинк: BRIDGE (MAC + BR/service/name) или RELAY (MAC + RL/name)
          final isMatchingMac = resultMac == uplink.mac;
          final isBridgeDevice = isBridgeByMfData ||
              hasService ||
              effectiveName.contains("BRIDGE") ||
              effectiveName.startsWith("M_0_");
          final isRelayDevice = isRelayByMfData ||
              effectiveName.contains("RELAY");
          final isUplinkDevice = isUplinkBridge ? isBridgeDevice : isRelayDevice;

          if (isMatchingMac && isUplinkDevice) {
            matchingScanResult = result;
            _log(
                "✅ [DiscoveryContext] Found matching ScanResult by MAC (${isUplinkBridge ? (isBridgeByMfData ? 'BR via mfData' : 'BR name/service') : (isRelayByMfData ? 'RL via mfData' : 'RELAY name')})");
            break;
          } else if ((isBridgeByMfData || isRelayByMfData) && matchingScanResult == null) {
            // 🔥 FALLBACK: Если MAC не совпадает, но есть manufacturerData - используем его
            matchingScanResult = result;
            _log(
                "✅ [DiscoveryContext] Found ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} via manufacturerData fallback (MAC mismatch: $resultMac vs ${uplink.mac})");
          }
        }

        // 🔥 Улучшение: Проверяем актуальность token перед подключением (только для BRIDGE)
        String? scanResultToken;
        if (matchingScanResult != null && isUplinkBridge) {
          final advName = matchingScanResult.advertisementData.localName ?? "";
          final platformName = matchingScanResult.device.platformName;
          final effectiveName = advName.isEmpty ? platformName : advName;

          if (effectiveName.startsWith("M_") &&
              effectiveName.contains("BRIDGE")) {
            final parts = effectiveName.split("_");
            if (parts.length >= 5 && parts[3] == "BRIDGE") {
              scanResultToken = parts[4];
            }
          }
        }

        // 🔥 Улучшение: Если token не совпадает или ScanResult не найден, используем TCP как основной канал (только BRIDGE)
        final tokenMismatch = isUplinkBridge &&
            uplink.bridgeToken != null &&
            scanResultToken != null &&
            uplink.bridgeToken != scanResultToken;

        if (tokenMismatch) {
          final contextTokenPreview = uplink.bridgeToken != null &&
                  uplink.bridgeToken!.length > 8
              ? uplink.bridgeToken!.substring(0, 8)
              : uplink.bridgeToken ?? 'none';
          final scanTokenPreview =
              scanResultToken != null && scanResultToken.length > 8
                  ? scanResultToken.substring(0, 8)
                  : scanResultToken ?? 'none';
          _log(
              "⚠️ [DiscoveryContext] Token mismatch: context=$contextTokenPreview..., scan=$scanTokenPreview...");
          _log(
              "🔄 [DiscoveryContext] Using TCP as primary channel due to token mismatch");
        }

        // 🔥 КРИТИЧНО: Если нет matching ScanResult, ищем по manufacturerData (BR или RL)
        if (matchingScanResult == null) {
          for (final result in lastScanResults) {
            final mfData = result.advertisementData.manufacturerData[0xFFFF];
            final isBr = mfData != null &&
                mfData.length >= 2 &&
                mfData[0] == 0x42 &&
                mfData[1] == 0x52;
            final isRl = mfData != null &&
                mfData.length >= 2 &&
                mfData[0] == 0x52 &&
                mfData[1] == 0x4C;
            final hasService = result.advertisementData.serviceUuids.any(
                (uuid) =>
                    uuid.toString().toLowerCase() ==
                    _btService.SERVICE_UUID.toLowerCase());

            if ((isUplinkBridge && (isBr || hasService)) ||
                (!isUplinkBridge && isRl)) {
              matchingScanResult = result;
              _log(
                  "✅ [DiscoveryContext] Found ${isUplinkBridge ? 'BRIDGE' : 'RELAY'} via manufacturerData fallback (no exact MAC match)");
              break;
            }
          }
        }

        // 🔥 TCP только для BRIDGE; при RELAY — только GATT
        // 🔥 Улучшение: TCP как основной канал при нестабильном BLE или token mismatch
        if (isUplinkBridge &&
            (tokenMismatch ||
                matchingScanResult == null ||
                uplink.ageSeconds > 60)) {
          if (uplink.ip != null && uplink.port != null) {
            _log(
                "🌐 [DiscoveryContext] Using TCP as primary channel (token mismatch or stale scan)");
            _setCooldownByMac(uplink.mac);
            _isTransferring = true;
            _transferStartTime = DateTime.now(); // 🔥 FIX: Track start time
            notifyListeners();
            try {
              // Если есть bridgeToken - используем его, иначе пробуем MAGNET_WAVE discovery
              if (uplink.bridgeToken != null) {
                // 🔥 MAC RANDOMIZATION FIX: Токен валиден 60 секунд
                await _handleMagnetWave(
                    uplink.bridgeToken!,
                    uplink.port!,
                    DateTime.now()
                        .add(const Duration(seconds: 60))
                        .millisecondsSinceEpoch);
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
                      _log(
                          "🚫 [ARCHITECTURE] Payload $msgId already sent via ${_sentPayloads[msgId]} — skipping duplicate");
                      _isTransferring = false;
                      notifyListeners();
                      return;
                    }

                    final firstP = pending.first;
                    final int tsSonarTcp = (firstP['createdAt'] as int?) ??
                        DateTime.now().millisecondsSinceEpoch;
                    final messageData = jsonEncode({
                      'type': 'OFFLINE_MSG',
                      'content': firstP['content'],
                      'senderId': _apiService.currentUserId,
                      'h': msgId,
                      'ts': tsSonarTcp,
                      'ttl': 5,
                    });
                    final sonarPayload = messageData.length > 200
                        ? messageData.substring(0, 200)
                        : messageData;
                    await locator<UltrasonicService>()
                        .transmitFrame("DATA:$sonarPayload");
                    // 🔒 Sonar только для рукопожатия/SOS — не помечаем как SENT, не удаляем из outbox
                    _log(
                        "📦 [ARCHITECTURE] Sonar hint emitted for $msgId (TCP without token). Message stays in outbox for retry.");
                    _log(
                        "✅ Sonar Packet Emitted (hint only). Cycle NOT closed.");
                  } catch (e) {
                    final msgId = pending.isNotEmpty
                        ? pending.first['id'] as String
                        : 'unknown';
                    _log(
                        "📦 [ARCHITECTURE] Payload $msgId Sonar hint failed: $e, keeping in outbox");
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
                final firstTcp = pendingForTcp.first;
                final int tsTcpFirst = (firstTcp['createdAt'] as int?) ??
                    DateTime.now().millisecondsSinceEpoch;
                final String payload = jsonEncode({
                  'type': 'OFFLINE_MSG',
                  'content': firstTcp['content'],
                  'senderId': _apiService.currentUserId,
                  'h': firstTcp['id'],
                  'ts': tsTcpFirst,
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
                _log(
                    "🔄 [DiscoveryContext] Falling back to BLE GATT after TCP failure");
                unawaited(
                    _executeCascadeRelay(matchingScanResult, uplink.hops));
              }
            }
          }
        } else if (matchingScanResult != null) {
          // 🔥 Connection Stabilizer только для BRIDGE (токен/режим); для RELAY — сразу каскад
          if (isUplinkBridge) {
            _log(
                "📡 [DiscoveryContext] Using Connection Stabilizer for BLE GATT (BRIDGE)");
            final stabilizer = locator<ConnectionStabilizer>();
            final updatedUplink = uplink.copyWith(
              bridgeToken: scanResultToken ?? uplink.bridgeToken,
              lastSeen: DateTime.now(),
            );
            stabilizer.startStabilization(updatedUplink);
          } else {
            _log(
                "📡 [DiscoveryContext] Connecting to RELAY via GATT (no stabilizer)");
            unawaited(
                _executeCascadeRelay(matchingScanResult, uplink.hops));
          }
        } else if (isUplinkBridge &&
            uplink.ip != null &&
            uplink.port != null &&
            uplink.bridgeToken != null) {
          // Fallback на TCP, если нет ScanResult (только BRIDGE)
          _log(
              "🌐 [DiscoveryContext] Using TCP connection (no ScanResult available): ${uplink.ip}:${uplink.port}");
          try {
            await _handleMagnetWave(
                uplink.bridgeToken!,
                uplink.port!,
                DateTime.now()
                    .add(const Duration(seconds: 60))
                    .millisecondsSinceEpoch);
          } catch (e) {
            _log("❌ [DiscoveryContext] TCP fallback failed: $e");
          }
        } else {
          _log(
              "⏸️ [DiscoveryContext] No matching ScanResult and no TCP info - will retry on next scan");
        }
      } catch (e) {
        _log("❌ [DiscoveryContext] Error during connection attempt: $e");
      }
    } catch (e) {
      _log(
          "❌ [DiscoveryContext] Error in _makeConnectionDecisionFromContext: $e");
    }
  }

  Future<void> _checkForBridgeAndForceSend() async {
    try {
      final pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;

      _log(
          "🔍 [Ghost] Checking for BRIDGE after scan (pending: ${pending.length} messages)...");

      // 🔥 Discovery Context: BRIDGE приоритетен, при отсутствии — RELAY
      final discoveryContext = locator<DiscoveryContextService>();
      final bestBridge = discoveryContext.bestBridge;
      final bestRelay = discoveryContext.bestRelay;
      final hasUplink = (bestBridge != null &&
              bestBridge.isValid &&
              bestBridge.confidence >= 0.3) ||
          (bestRelay != null &&
              bestRelay.isValid &&
              bestRelay.confidence >= 0.3);

      if (hasUplink) {
        _log(
            "🧲 [Ghost] ✅ Best uplink from context (BRIDGE=${bestBridge?.id ?? 'none'}, RELAY=${bestRelay?.id ?? 'none'})");
        await _makeConnectionDecisionFromContext();
        return;
      }

      // Получаем последние результаты сканирования
      final lastScanResults = await FlutterBluePlus.lastScanResults;

      // Look for BRIDGE in scan results: only hops=0 = BRIDGE (has internet). No internet = GHOST.
      for (var result in lastScanResults) {
        final advName = result.advertisementData.localName ?? '';
        if (advName.startsWith("M_")) {
          final parts = advName.split("_");
          if (parts.length >= 2) {
            final peerHops = int.tryParse(parts[1]) ?? 99;
            if (peerHops == 0) {
              // BRIDGE found (device with internet)
              final mac = result.device.remoteId.str;
              _log(
                  "🧲 [Ghost] ⚡ BRIDGE found after scan! Initiating forced send...");

              // 🔥 FIX #1: Cooldown по ТОКЕНУ, не по MAC
              final cooldownExpired = _isCooldownExpired(result);
              final cooldownRemaining = _getCooldownRemaining(result);

              // 🔥 BLE STABILIZATION: Transfer timeout должен быть > batch timeout (30s)
              // Используем _transferTtlSeconds (40s) чтобы не прерывать batch mid-flight
              final transferAge3 = _isTransferring && _transferStartTime != null
                  ? DateTime.now().difference(_transferStartTime!).inSeconds
                  : 0;
              final transferStuck = transferAge3 > _transferTtlSeconds;
              if (transferStuck) {
                _log(
                    "⚠️ [WATCHDOG] Transfer stuck for ${transferAge3}s (>${_transferTtlSeconds}s), forcing reset!");
                _isTransferring = false;
                _transferStartTime = null;
              }

              if (cooldownExpired && !_isTransferring) {
                // Cooldown is set only after failed attempt inside cascade
                unawaited(_executeCascadeRelay(result, peerHops));
                return; // Process only first BRIDGE found
              } else {
                _log(
                    "⏸️ [Ghost] BRIDGE found but ${!cooldownExpired ? 'cooldown active (${cooldownRemaining}s remaining)' : 'transfer in progress (${transferAge3}s)'}");
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
    final tcpCheckStart = DateTime.now();
    if (kMeshDiagnostics) {
      _log(meshDiagLog('tcp_connect_attempt_start', {
        'targetIp': ip,
        'port': '$port',
        'context': 'GHOST_check',
        'elapsedMs': '0',
      }));
    }
    try {
      _log(
          "   🔍 [GHOST] Checking TCP connection to $ip:$port (timeout: 3s)...");

      // Быстрая проверка соединения с коротким таймаутом (3 секунды)
      final socket =
          await Socket.connect(ip, port, timeout: const Duration(seconds: 3))
              .timeout(const Duration(seconds: 3), onTimeout: () {
        if (kMeshDiagnostics) {
          final elapsed = DateTime.now().difference(tcpCheckStart).inMilliseconds;
          _log(meshDiagLog('tcp_connect_result', {
            'result': 'timeout',
            'context': 'GHOST_check',
            'elapsedMs': '$elapsed',
          }));
        }
        _log("   ⏱️ [GHOST] TCP connection check timeout after 3s");
        throw TimeoutException("Connection check timeout");
      });

      // Если соединение установлено - сразу закрываем (это только проверка)
      await socket.close();
      if (kMeshDiagnostics) {
        final elapsed = DateTime.now().difference(tcpCheckStart).inMilliseconds;
        _log(meshDiagLog('tcp_connect_result', {
          'result': 'success',
          'context': 'GHOST_check',
          'elapsedMs': '$elapsed',
        }));
      }
      _log(
          "   ✅ [GHOST] TCP connection check passed - server is available at $ip:$port");
      return true;
    } catch (e) {
      if (kMeshDiagnostics) {
        final elapsed = DateTime.now().difference(tcpCheckStart).inMilliseconds;
        _log(meshDiagLog('tcp_connect_result', {
          'result': 'fail',
          'context': 'GHOST_check',
          'elapsedMs': '$elapsed',
          'error': e.toString(),
        }));
      }
      _log("   ❌ [GHOST] TCP connection check failed: $e");
      if (e.toString().contains("failed to connect")) {
        _log("   💡 Connection refused - BRIDGE TCP server may not be running");
      } else if (e.toString().contains("timeout")) {
        _log(
            "   💡 Connection timeout - BRIDGE may be unreachable or firewall blocking");
      } else {
        _log("   💡 Connection error: ${e.runtimeType}");
      }
      return false;
    }
  }

  /// Загружает batch сообщений на BRIDGE TCP сервер
  Future<void> _uploadToBridgeServer(String ip, int port, String token) async {
    _log("📤 [GHOST→BRIDGE] _uploadToBridgeServer: Starting upload process");
    _log("   📋 Target: $ip:$port");
    _log("   📋 Token: ${token.length > 8 ? token.substring(0, 8) : token}...");

    final pending = await _db.getPendingFromOutbox();
    if (pending.isEmpty) {
      _log("   ⚠️ No messages in outbox to upload");
      return;
    }

    // Ограничиваем batch до 100 сообщений
    final batch = pending.take(100).toList();
    final batchId = 'batch_${DateTime.now().millisecondsSinceEpoch}';

    _log(
        "📦 [GHOST→BRIDGE] Uploading ${batch.length} messages to BRIDGE (batch ID: $batchId)");
    _log("   📋 Total pending: ${pending.length}, batch size: ${batch.length}");

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
          socket = await Socket.connect(ip, port,
                  timeout: const Duration(seconds: 10))
              .timeout(const Duration(seconds: 10), onTimeout: () {
            throw TimeoutException("Connection timeout");
          });
          break; // Success, exit retry loop
        } catch (e) {
          retries++;
          if (retries >= maxRetries) {
            _log(
                "❌ [Ghost] TCP connection failed after $maxRetries attempts: $e");
            rethrow;
          }
          final delay =
              Duration(seconds: retries * 2); // Exponential backoff: 2s, 4s, 6s
          _log(
              "⚠️ [Ghost] TCP connection attempt $retries failed, retrying in ${delay.inSeconds}s...");
          await Future.delayed(delay);
        }
      }

      _log("✅ [GHOST→BRIDGE] Connected to BRIDGE server at $ip:$port");
      _log("   📋 Connection established successfully");

      // Формируем upload пакет
      _log("   📦 Preparing upload packet...");
      final uploadPacket = {
        'type': 'GHOST_UPLOAD',
        'token': token,
        'senderId': _hashUserId(_apiService.currentUserId),
        'batchId': batchId,
        'messages': batch
            .map((m) => {
                  'id': m['id']?.toString() ?? '',
                  'chatId': m['chatRoomId']?.toString() ?? 'THE_BEACON_GLOBAL',
                  'content': m['content']?.toString() ?? '',
                  'timestamp':
                      m['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
                })
            .toList(),
        'count': batch.length,
      };

      // Отправляем JSON (без пробелов для экономии)
      final jsonString = jsonEncode(uploadPacket);
      final payloadSize = utf8.encode('$jsonString\n').length;
      _log(
          "   📤 Sending upload packet (size: $payloadSize bytes, messages: ${batch.length})...");

      socket?.add(utf8.encode('$jsonString\n'));
      await socket?.flush();

      _log("   ✅ Upload packet sent successfully");

      _log("   ✅ Upload packet sent successfully");
      _log("   ⏳ Waiting for ACK from BRIDGE (timeout: 3s)...");

      // Ждем ACK (таймаут 3 секунды)
      final completer = Completer<String>();
      final subscription = socket?.listen(
        (data) {
          final ackData = utf8.decode(data);
          _log("   📥 [GHOST→BRIDGE] ACK received from BRIDGE: $ackData");
          if (!completer.isCompleted) {
            completer.complete(ackData);
          }
        },
        onError: (e) {
          _log("   ❌ [GHOST→BRIDGE] Error receiving ACK: $e");
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        },
        onDone: () {
          _log("   ⚠️ [GHOST→BRIDGE] Socket closed before ACK received");
          if (!completer.isCompleted) {
            completer
                .completeError(Exception("Socket closed before ACK received"));
          }
        },
        cancelOnError: true,
      );

      final response =
          await completer.future.timeout(const Duration(seconds: 3));
      await subscription?.cancel();

      _log("   📥 [GHOST→BRIDGE] ACK response received");
      final ack = jsonDecode(response) as Map<String, dynamic>;

      _log("   📋 ACK status: ${ack['status']}");
      _log("   📋 ACK batchId: ${ack['batchId']}");
      _log("   📋 ACK received count: ${ack['received']}");

      if (ack['status'] == 'OK' && ack['processed'] == true) {
        final received = ack['received'] ?? 0;
        _log(
            "✅ [GHOST→BRIDGE] Upload successful! BRIDGE received $received messages");
        _log("   📋 Batch ID: ${ack['batchId']}");

        // Удаляем из Outbox только успешно отправленные
        final ids = batch
            .map((m) => m['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        if (ids.isNotEmpty) {
          _log("   🗑️ Removing ${ids.length} messages from outbox...");
          for (final id in ids) {
            await _db.removeFromOutbox(id);
            _sentPayloads[id] = 'TCP';
          }
          _log("   ✅ Removed ${ids.length} messages from Outbox");
          _log(
              "🔄 [ARCHITECTURE] Cycle CLOSED via TCP (messages: $received, batch: ${ack['batchId']})");
        }
      } else {
        _log("⚠️ [GHOST→BRIDGE] BRIDGE rejected batch: ${ack['status']}");
        if (ack['error'] != null) {
          _log("   📋 Error: ${ack['error']}");
        }
      }
    } catch (e, stackTrace) {
      _log("❌ [GHOST→BRIDGE] Upload error: $e");
      _log("   📋 Error type: ${e.runtimeType}");
      _log("   📋 Stack trace: $stackTrace");
      rethrow; // Пробрасываем для fallback логики
    } finally {
      socket?.close();
      _log("   🔌 [GHOST→BRIDGE] Socket closed");
    }
  }

  // ============================================================
  // 👥 FRIENDS & MESSAGING PROTOCOLS (Масштабируемая система)
  // ============================================================

  /// Обрабатывает запрос на добавление в друзья
  Future<void> _handleFriendRequest(
      Map<String, dynamic> data, String? senderIp) async {
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

    // Локальное уведомление при заявке по mesh (в т.ч. когда приложение в фоне)
    unawaited(_showMeshFriendRequestNotification(senderUsername));
  }

  Future<void> _ensureMeshNotifications() async {
    if (_meshNotificationsInitialized) return;
    try {
      _meshNotifications ??= FlutterLocalNotificationsPlugin();
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _meshNotifications!.initialize(
          const InitializationSettings(android: android));
      _meshNotificationsInitialized = true;
    } catch (e) {
      _log("⚠️ [Mesh] Notifications init failed: $e");
    }
  }

  Future<void> _showMeshFriendRequestNotification(String username) async {
    try {
      await _ensureMeshNotifications();
      if (_meshNotifications == null) return;
      const androidDetails = AndroidNotificationDetails(
        'memento_mesh',
        'Mesh',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        showWhen: true,
      );
      await _meshNotifications!.show(
        DateTime.now().millisecondsSinceEpoch % 0x7FFFFFFF,
        'Friend request (Mesh)',
        '$username wants to add you as a friend.',
        const NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      _log("⚠️ [Mesh] Friend request notification failed: $e");
    }
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
      acceptedAt:
          status == 'accepted' ? DateTime.now().millisecondsSinceEpoch : null,
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
  Future<void> _handleDirectMessage(
      Map<String, dynamic> messageData, String? senderIp) async {
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
    final messageId = messageData['id']?.toString() ??
        'msg_${DateTime.now().millisecondsSinceEpoch}';

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
  Future<void> _handleGlobalChatMessage(
      Map<String, dynamic> messageData, String? senderIp) async {
    final senderId = messageData['senderId']?.toString() ?? '';
    final content = messageData['content']?.toString() ?? '';
    final gossipHash = messageData['gossip_hash']?.toString() ?? '';
    final messageId = messageData['id']?.toString() ??
        'msg_${DateTime.now().millisecondsSinceEpoch}';

    // Проверяем дедупликацию через gossip hash
    if (gossipHash.isNotEmpty && await _db.isGossipMessageSeen(gossipHash)) {
      _log(
          "♻️ [Global] Duplicate message (gossip hash: ${gossipHash.substring(0, 8)}...). Dropping.");
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
    await _db.addToOutbox(chatMessage, chatId, contentAlreadyEncrypted: true);

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
