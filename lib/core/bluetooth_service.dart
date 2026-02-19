import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:synchronized/synchronized.dart'; // 🔒 SECURITY FIX: For atomic BLE operations

import 'MeshOrchestrator.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'network_phase_context.dart';
import 'network_monitor.dart';
import 'role/ghost_role.dart';
import 'ble_state_machine.dart';
import 'ble_session.dart';
import 'event_bus_service.dart';
import 'hardware_check_service.dart';
import 'mesh_diagnostics.dart';
import 'log_mac_mask.dart';
import 'ble_interaction_stats.dart';
import 'ble_hardware_strategy.dart';

// 🔄 Replaced with BleStateMachine - keeping enum for backward compatibility during migration
enum BleAdvertiseState {
  idle,
  starting,
  advertising,
  connecting,
  connected,
  stopping,
}

/// Result of a BLE relay attempt. skippedDueToRole = transport not eligible (e.g. PERIPHERAL); not a failure.
enum BleRelayResult {
  success,
  failure,
  skippedDueToRole,
}

class BluetoothMeshService {
  final String SERVICE_UUID = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
  final String CHAR_UUID = "c22d1e32-0310-4062-812e-89025078da9c";

  final Queue<_BtTask> _taskQueue = Queue();
  final Set<String> _pendingDevices = {};
  bool _isProcessingQueue = false;

  // Diagnostic agent: state for structured BLE tracing (guarded by kMeshDiagnostics).
  DateTime? _diagnosticAttemptStartTime;
  Map<String, String>? _diagnosticContext;
  bool _diagnosticFirstNotifyLogged = false;
  bool _diagnosticFirstWriteLogged = false;

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  BleAdvertiseState _advState =
      BleAdvertiseState.idle; // Legacy state (for migration)

  // 🔄 New FSM-based state management
  final BleStateMachine _stateMachine = BleStateMachine();
  BleStateMachine get stateMachine => _stateMachine;

  String? _cachedModel;

  // 🔥 ОПТИМИЗАЦИЯ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Минимальный интервал между операциями ADV
  // Не трогать ADV слишком часто, иначе BLE FSM "зависает" на Huawei/Xiaomi/Tecno/Infinix/Poco/Samsung
  DateTime? _lastAdvOperation;
  static const Duration _minAdvInterval =
      Duration(seconds: 2); // Минимум 2 секунды между операциями

  // 🔍 OUTBOX BOOST: при 0→1 в outbox — 8s окно ускоренного discovery (чаще scan/adv). Не трогает FSM/transport.
  DateTime? _outboxBoostUntil;
  DateTime? _lastOutboxBoostTime;
  Timer? _outboxBoostTimer;
  static const Duration _outboxBoostWindow = Duration(seconds: 8);
  static const Duration _outboxBoostMinInterval = Duration(seconds: 15);

  // 🔒 Fix BLE state machine: Use Completer instead of busy wait
  Completer<void>? _stateIdleCompleter;

  // 🔥 FIX: GATT Connection Mutex - предотвращает параллельные попытки connect
  bool _isGattConnecting = false;
  DateTime? _gattConnectStartTime;
  String? _currentGattTargetMac;
  static const Duration _gattConnectTimeout = Duration(seconds: 25);
  Completer<void>? _gattMutexCompleter;

  // 🔥 FIX: Explicit GATT connection state
  // IDLE -> CONNECTING -> CONNECTED -> DISCONNECTED
  String _gattConnectionState = 'IDLE';
  String get gattConnectionState => _gattConnectionState;

  /// [ACTIVE-SYNC] When Central in a CRDT-only session: used to write HEAD_EXCHANGE/REQUEST_RANGE/LOG_ENTRIES to peer.
  BluetoothCharacteristic? _crdtOnlyCentralCharacteristic;
  String? _crdtOnlyCentralTargetMac;

  // 🔒 BLE SESSION OWNERSHIP: single owner for all BLE ops. No parallel connects.
  BleSessionOwner _sessionOwner = BleSessionOwner.none;
  BleSessionOwner get sessionOwner => _sessionOwner;

  // 🔒 HARD GATT FSM: IDLE → CONNECTING → CONNECTED → DISCOVERED → TRANSFERRING → DONE → IDLE
  BleGattSessionState _gattSessionState = BleGattSessionState.IDLE;
  BleGattSessionState get gattSessionState => _gattSessionState;

  // 🔒 CENTRALIZED QUEUE: all modules MUST enqueue here — no direct sendMessage
  final Queue<BleSendQueueEntry> _bleSendQueue = Queue();
  bool _bleConsumerRunning = false;

  // 🔥 FIX: Public getter for GATT connecting state (used by MeshService to block scan)
  bool get isGattConnecting => _isGattConnecting;

  /// 🔥 FIX: Helper to release GATT mutex consistently
  /// Called on all exit paths from _sendWithDynamicRetries
  /// [state] can be 'IDLE' (default) or 'FAILED'
  void _releaseGattMutex(String reason, {String state = 'IDLE'}) {
    if (_isGattConnecting) {
      _log("🔓 [GATT-MUTEX] Released (reason: $reason, state: $state)");
    }
    if (_gattMutexCompleter != null && !_gattMutexCompleter!.isCompleted) {
      _gattMutexCompleter!.complete();
    }
    _gattMutexCompleter = null;
    _isGattConnecting = false;
    _gattConnectStartTime = null;
    _currentGattTargetMac = null;
    _gattConnectionState = state;
  }

  /// 🔥 Секунды с начала GATT connect (для unblock scan при зависании)
  int get gattConnectElapsedSeconds {
    if (_gattConnectStartTime == null) return 0;
    return DateTime.now().difference(_gattConnectStartTime!).inSeconds;
  }

  /// 🔒 [BLE][OWNER] Try acquire session owner. Returns true only if none or same owner.
  bool tryAcquireOwner(BleSessionOwner owner) {
    if (_sessionOwner == BleSessionOwner.none || _sessionOwner == owner) {
      _sessionOwner = owner;
      _log("[BLE][OWNER] acquired: $owner");
      return true;
    }
    _log(
        "[BLE][SKIP] Session owned by $_sessionOwner, requested: $owner, reason=owner");
    return false;
  }

  /// 🔒 [BLE][OWNER] Release session owner.
  void releaseOwner(BleSessionOwner owner) {
    if (_sessionOwner == owner) {
      _sessionOwner = BleSessionOwner.none;
      _log("[BLE][OWNER] released: $owner");
    }
  }

  // 🔒 BLE TRANSACTION FSM: single GATT lifecycle at a time. No scan/adv/connect outside IDLE.
  BleTransactionState _bleTransactionState = BleTransactionState.IDLE;
  BleTransactionState get bleTransactionState => _bleTransactionState;

  /// 🔒 HUAWEI BLE POLICY: When Central session ends we set this so advertising does not restart too soon.
  DateTime? _lastCentralSessionEndTime;
  DateTime? _globalBleCooldownUntil;
  /// Short quiet for GHOST→GHOST: peer MAC can rotate; connect ASAP after scan.
  bool _shortQuietForNextConnect = false;
  static const int _shortQuietPreConnectMs = 700;
  static const int _quietPreConnectMs = 1500; // 1.5s: проблемные стеки (Huawei/Tecno) нуждаются в большем «успокоении» после stopAdv
  static const int _quietPostDisconnectMs = 1750;

  /// Call before sendMessage/enqueue when connecting to GHOST with fresh ScanResult to reduce MAC staleness (random BLE MAC rotation).
  void setShortQuietForNextConnect(bool value) {
    _shortQuietForNextConnect = value;
  }
  static const int _globalCooldownSuccessSeconds = 2;
  static const int _globalCooldownFailureSeconds = 4;
  static const int _postConnectStabilizationMs = 1200;
  static const int _postDiscoverSettleMs = 400;
  static const int _discoverRetryDelayMs = 500;
  static const int _discoverRetryDelayServiceMissingMs =
      1200; // Доп. задержка при отсутствии сервиса (периферия может поднять GATT позже)
  /// Ограничение ожидания enable notify (FBP по умолчанию 15s — слишком долго в рамках batch 35s).
  /// При таймауте продолжаем без notify (BRIDGE→GHOST relay не будет, отправка всё равно идёт).
  static const int _notifyEnableTimeoutSeconds = 6;

  void _transitionTransaction(BleTransactionState to) {
    if (_bleTransactionState == to) return;
    final prev = _bleTransactionState;
    _bleTransactionState = to;
    _log("[BLE-FSM] $prev -> $to");
  }

  /// True when BLE FSM is in GATT lifecycle (no role switch, no GATT server start/stop).
  bool get isInGattLifecycle {
    switch (_bleTransactionState) {
      case BleTransactionState.CONNECTING:
      case BleTransactionState.STABILIZING_POST_CONNECT:
      case BleTransactionState.DISCOVERING:
      case BleTransactionState.TRANSFERRING:
      case BleTransactionState.LISTENING:
      case BleTransactionState.DISCONNECTING:
        return true;
      default:
        return false;
    }
  }

  bool get _globalCooldownExpired =>
      _globalBleCooldownUntil == null ||
      DateTime.now().isAfter(_globalBleCooldownUntil!);

  void setGlobalBleCooldown(bool success) {
    final sec =
        success ? _globalCooldownSuccessSeconds : _globalCooldownFailureSeconds;
    _globalBleCooldownUntil = DateTime.now().add(Duration(seconds: sec));
    _log("[BLE-TIMING] Global cooldown set: ${sec}s (success=$success)");
  }

  /// Only IDLE and cooldown expired allow a new BLE transaction.
  bool get canStartBleTransaction =>
      _bleTransactionState == BleTransactionState.IDLE &&
      _globalCooldownExpired;

  /// 🔒 [BLE] Scan MUST NOT run during transaction or GATT session.
  bool get canStartScan {
    if (_bleTransactionState != BleTransactionState.IDLE) return false;
    switch (_gattSessionState) {
      case BleGattSessionState.CONNECTING:
      case BleGattSessionState.CONNECTED:
      case BleGattSessionState.DISCOVERED:
      case BleGattSessionState.TRANSFERRING:
        return false;
      default:
        return true;
    }
  }

  /// 🔒 [GATT][STATE] Transition GATT session state. Re-entering same state = NOOP.
  void _gattTransition(BleGattSessionState to) {
    if (_gattSessionState == to) {
      _log("[GATT][SKIP] reason=already $to");
      return;
    }
    final from = _gattSessionState;
    _gattSessionState = to;
    _log("[GATT][STATE] $from -> $to");
  }

  // ---------------------------------------------------------------------------
  // 🔒 GattOperationGate: only ONE GATT operation (write / descriptor / MTU / read) at a time.
  // ---------------------------------------------------------------------------
  bool _gattBusy = false;
  final Queue<void Function()> _gattQueue = Queue<void Function()>();

  static bool _isGattBusyError(Object e) {
    final s = e.toString();
    return s.contains('201') || s.contains('WRITE_REQUEST_BUSY');
  }

  void _gattAbortAndClear() {
    _gattQueue.clear();
    _gattBusy = false;
    _log("⚠️ [GATT-GATE] BUSY abort: queue cleared, gattBusy=false");
  }

  void _onGattOperationComplete() {
    if (_gattQueue.isNotEmpty) {
      final next = _gattQueue.removeFirst();
      next();
    } else {
      _gattBusy = false;
    }
  }

  /// Enqueue a GATT operation. Only one runs at a time; completion triggers next or clears busy.
  Future<T> _enqueueGattOperation<T>(Future<T> Function() operation) async {
    final completer = Completer<T>();
    void runOne() {
      final f = operation();
      f.then(completer.complete, onError: completer.completeError);
      f.whenComplete(_onGattOperationComplete);
    }
    if (!_gattBusy) {
      _gattBusy = true;
      runOne();
    } else {
      _gattQueue.add(runOne);
    }
    return completer.future;
  }

  /// Single GATT write through the gate. On GATT_WRITE_REQUEST_BUSY (201): retry ONCE after 800ms; if still busy, abort and clear queue.
  Future<void> _gattWrite(
    BluetoothCharacteristic c,
    List<int> chunk, {
    required bool withoutResponse,
  }) async {
    await _enqueueGattOperation(() async {
      try {
        await c.write(chunk, withoutResponse: withoutResponse);
      } catch (e) {
        if (!_isGattBusyError(e)) rethrow;
        try {
          locator<MeshService>().reportMeshHealthBleBusy();
        } catch (_) {}
        _log("⚠️ [GATT-GATE] WRITE_REQUEST_BUSY (201) — retry once after 800ms");
        await Future.delayed(const Duration(milliseconds: 800));
        try {
          await c.write(chunk, withoutResponse: withoutResponse);
        } catch (e2) {
          if (_isGattBusyError(e2)) {
            _gattAbortAndClear();
          }
          rethrow;
        }
      }
    });
  }

  /// 🔒 [BLE][QUEUE] Centralized enqueue — single path for all BLE sends.
  /// Returns count of messages successfully sent. Callers MUST use this, never sendMessage directly.
  /// [messageIds], [sentFragmentIndices], [onFragmentSent] — для BLE resume по фрагментам (см. §6.19).
  Future<int> enqueue(
    String deviceId,
    List<String> messages, {
    List<String>? messageIds,
    List<int>? sentFragmentIndices,
    OnFragmentSent? onFragmentSent,
    bool isHuaweiBreakGlass = false,
    BleWriteStrategy? writeStrategy,
  }) async {
    if (messages.isEmpty) return 0;
    final entry = BleSendQueueEntry(
      deviceId,
      messages,
      messageIds: messageIds,
      sentFragmentIndices: sentFragmentIndices,
      onFragmentSent: onFragmentSent,
      isHuaweiBreakGlass: isHuaweiBreakGlass,
      writeStrategy: writeStrategy,
    );
    _bleSendQueue.add(entry);
    _log("[BLE][QUEUE] enqueue: device=$deviceId, msgs=${messages.length}");
    _kickConsumer();
    return _awaitResultForEntry(entry);
  }

  final Map<BleSendQueueEntry, Completer<int>> _entryCompleters = {};
  Future<int> _awaitResultForEntry(BleSendQueueEntry entry) async {
    final c = Completer<int>();
    _entryCompleters[entry] = c;
    return c.future;
  }

  void _completeEntry(BleSendQueueEntry entry, int sentCount) {
    final c = _entryCompleters.remove(entry);
    if (c != null && !c.isCompleted) c.complete(sentCount);
  }

  void _kickConsumer() {
    if (!_bleConsumerRunning && _bleSendQueue.isNotEmpty) {
      _bleConsumerRunning = true;
      _bleSendQueueConsumer();
    }
  }

  /// Single consumer — waits for DISCOVERED, sends batch, releases owner.
  Future<void> _bleSendQueueConsumer() async {
    while (_bleSendQueue.isNotEmpty) {
      final entry = _bleSendQueue.removeFirst();
      _log(
          "[BLE][QUEUE] dequeue: device=${entry.deviceId}, msgs=${entry.messages.length}");
      int sent = 0;
      try {
        final device = BluetoothDevice.fromId(entry.deviceId);
        if (!tryAcquireOwner(BleSessionOwner.batchSend)) {
          _log("[BLE][SKIP] Consumer could not acquire owner, re-queueing");
          _bleSendQueue.addFirst(entry);
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        sent = await _executeGattSession(device, entry);
      } catch (e) {
        _log("[BLE][QUEUE] Consumer error: $e");
      } finally {
        releaseOwner(BleSessionOwner.batchSend);
        _completeEntry(entry, sent);
      }
    }
    _bleConsumerRunning = false;
  }

  /// Single GATT session: connect → discover → write. No reset during TRANSFERRING.
  /// Called only by queue consumer; owner already acquired.
  Future<int> _executeGattSession(
      BluetoothDevice device, BleSendQueueEntry entry) async {
    return sendMultipleMessages(
      device,
      entry.messages,
      fromQueue: true,
      messageIds: entry.messageIds,
      sentFragmentIndices: entry.sentFragmentIndices,
      onFragmentSent: entry.onFragmentSent,
      isHuaweiBreakGlass: entry.isHuaweiBreakGlass,
      writeStrategy: entry.writeStrategy,
    );
  }

  /// Sync optimization: when CRDT diff=0, close connection to free the channel (central only).
  void requestGracefulDisconnectForSync(String peerAddress) {
    if (peerAddress.isEmpty || !peerAddress.contains(':')) return;
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) return;
    unawaited(_doGracefulDisconnectForSync(peerAddress));
  }

  Future<void> _doGracefulDisconnectForSync(String peerAddress) async {
    try {
      final device = BluetoothDevice.fromId(peerAddress);
      if (device.isConnected) {
        _log("🔌 [CRDT] Diff=0 — graceful disconnect from ${maskMacForLog(peerAddress)}");
        await device.disconnect();
      }
    } catch (e) {
      _log("⚠️ [CRDT] Graceful disconnect failed: $e");
    }
  }

  /// 🔥 FIX: Public method to force reset GATT state after external timeout
  void forceResetGattState(String reason) {
    if (_gattSessionState == BleGattSessionState.TRANSFERRING) {
      _log("[BLE][SKIP] reset blocked: reason=TRANSFERRING in progress");
      return;
    }
    _log("🚨 [GATT-FORCE-RESET] $reason");
    _gattSessionState = BleGattSessionState.IDLE;
    _sessionOwner = BleSessionOwner.none;
    _isGattConnecting = false;
    _gattConnectStartTime = null;
    _currentGattTargetMac = null;
    _gattConnectionState = 'IDLE';
    _log("   ✅ State reset to IDLE - scan unblocked");
  }

  static final MethodChannel _gattChannel =
      MethodChannel('memento/gatt_server');
  StreamSubscription? _gattEventSubscription;

  // 🔥 Native BLE Advertiser для Huawei/Honor (fallback если flutter_ble_peripheral не работает)
  static const MethodChannel _nativeAdvChannel =
      MethodChannel('memento/native_ble_advertiser');
  bool _useNativeAdvertiser = false;
  bool _nativeAdvertiserChecked = false;

  // 🔥 FIX: Track if advertising was actually started successfully
  // This prevents crash when stopping advertising that never started
  bool _advertisingStartedSuccessfully = false;
  bool _nativeAdvertisingStarted = false;

  // 🔥 WI-FI DIRECT: Последнее имя для advertising (нужно для updateAdvertisingWithGroupInfo)
  String? _lastAdvertisingName;
  Uint8List? _lastManufacturerDataBase; // без байта intent (has_outbox), для refresh
  String? _lastSafeName;

  // [GATT][STATE] Single-shot GATT ready flag — set on onGattReady, reset on stopGattServer
  bool _gattServerReady = false;
  bool get isGattServerReady => _gattServerReady;

  /// 🔒 Expected GATT server generation from native — used to DROP late onGattReady events.
  /// Set when startGattServer succeeds (from native return). Set to -1 on stopGattServer.
  int _expectedGattGen = -1;

  // 🔒 SECURITY FIX #4: Track connected GATT clients to prevent token rotation
  // This prevents BRIDGE from rotating token while GHOST is connected
  final Set<String> _connectedGattClients = {};

  // 🔥 BRIDGE→GHOST: буфер для сборки notify-чанков от BRIDGE (формат: 4-byte length + payload)
  final List<int> _ghostNotifyBuffer = [];
  int _ghostNotifyExpectedLength = -1;
  DateTime? _lastGattClientActivity;
  static const Duration _gattClientGracePeriod =
      Duration(seconds: 5); // Grace period after disconnect

  // 🔒 SECURITY FIX: Atomic locks for BLE operations
  final Lock _stopLock = Lock();
  final Lock _startLock = Lock();
  bool _isStopInProgress = false; // Keep for backward compatibility
  bool _isStartInProgress = false;

  BleAdvertiseState get state => _advState; // Legacy getter
  BleState get fsmState => _stateMachine.state; // New FSM getter

  /// Transport capability: true only when FSM allows initiating CENTRAL connection (enterCentralMode).
  /// Gossip BLE relay must check this before calling sendMessage; PERIPHERAL must not enter QUIET.
  bool canInitiateCentralConnection() {
    final s = _stateMachine.state;
    return s == BleState.IDLE || s == BleState.SCANNING;
  }

  /// 🔒 SECURITY FIX #4: Check if any GATT clients are active (connected or within grace period)
  /// This is used by BRIDGE to prevent token rotation while GHOST is connected
  bool get hasActiveGattClients {
    // If any clients are currently connected
    if (_connectedGattClients.isNotEmpty) {
      return true;
    }

    // Check grace period after last disconnect
    if (_lastGattClientActivity != null) {
      final timeSinceActivity =
          DateTime.now().difference(_lastGattClientActivity!);
      if (timeSinceActivity < _gattClientGracePeriod) {
        return true; // Still within grace period
      }
    }

    return false;
  }

  /// Get the number of currently connected GATT clients
  int get connectedGattClientsCount => _connectedGattClients.length;

  /// Get list of connected GATT client MAC addresses
  List<String> get connectedGattClients => _connectedGattClients.toList();

  /// Send message to connected GATT client
  /// Returns true if message was sent successfully
  Future<bool> sendMessageToGattClient(
      String deviceAddress, String messageJson) async {
    try {
      final result = await _gattChannel.invokeMethod('sendMessageToClient', {
        'deviceAddress': deviceAddress,
        'message': messageJson,
      });
      return result == true;
    } catch (e) {
      _log("❌ [GATT-SERVER] Failed to send message to ${maskMacForLog(deviceAddress)}: $e");
      return false;
    }
  }

  /// OUTBOX_REQUEST response: Peripheral (Huawei) sends pending outbox messages to Central via notify.
  /// Uses stored encrypted payload as-is; existing fragmentation; no re-encryption.
  Future<void> _handleOutboxRequest(String centralAddress) async {
    try {
      final db = locator<LocalDatabaseService>();
      final pending = await db.getPendingFromOutbox();
      if (pending.isEmpty) {
        _log("   ℹ️ [OUTBOX_REQUEST] No pending messages — nothing to send");
        return;
      }
      _log("   📋 [OUTBOX_REQUEST] Sending ${pending.length} pending message(s) via notify");
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
        final fragments = _fragmentMessage(messageJson);
        for (final frag in fragments) {
          final fragJson = jsonEncode(frag);
          final success = await sendMessageToGattClient(centralAddress, fragJson);
          if (!success) {
            _log("   ⚠️ [OUTBOX_REQUEST] Failed to send fragment for $id");
            break;
          }
          await Future.delayed(const Duration(milliseconds: 50));
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _log("   ✅ [OUTBOX_REQUEST] Outbox pull completed");
      if (locator.isRegistered<MeshService>()) {
        _log("[BEACON-SYNC] Outbox done — starting THE BEACON chat sync (CRDT) with peer");
        locator<MeshService>().startCrdtDigestExchange(centralAddress);
      } else {
        _log("[BEACON-SYNC] Chat sync skipped: MeshService not ready (CRDT not started)");
      }
    } catch (e) {
      _log("   ❌ [OUTBOX_REQUEST] Error: $e");
      _log("[BEACON-SYNC] Outbox error — CRDT not started, chat may stay out of sync");
    }
  }

  /// 🔥 Синхронизация сообщений BRIDGE → GHOST при подключении
  /// Проверяет, какие сообщения есть у BRIDGE, и отправляет их GHOST
  Future<void> _syncMessagesToGhost(String ghostAddress) async {
    try {
      final meshService = locator<MeshService>();
      final db = locator<LocalDatabaseService>();
      final currentRole = NetworkMonitor().currentRole;

      // Только BRIDGE синхронизирует сообщения
      if (currentRole != MeshRole.BRIDGE) return;

      _log("🔄 [BRIDGE-SYNC] Starting message sync to GHOST $ghostAddress...");

      // Получаем последние сообщения из чата "The Beacon" за последние 10 минут
      final recentMessages = await db.getRecentMessages(
        chatId: 'THE_BEACON_GLOBAL',
        since: DateTime.now().subtract(const Duration(minutes: 10)),
      );

      if (recentMessages.isEmpty) {
        _log("   ℹ️ No recent messages to sync");
        return;
      }

      _log("   📋 Found ${recentMessages.length} recent message(s) to sync");

      // Отправляем каждое сообщение GHOST устройству
      int sentCount = 0;
      for (var message in recentMessages) {
        try {
          final messageData = {
            'type': 'OFFLINE_MSG',
            'h': message.id,
            'content': message.content,
            'senderId': message.senderId,
            'senderUsername': message.senderUsername,
            'chatId': 'THE_BEACON_GLOBAL',
            'timestamp': message.createdAt.millisecondsSinceEpoch,
            'ttl': 5,
          };

          final messageJson = jsonEncode(messageData);
          final success =
              await sendMessageToGattClient(ghostAddress, messageJson);

          if (success) {
            sentCount++;
            _log(
                "   ✅ Synced message ${message.id.substring(0, message.id.length > 8 ? 8 : message.id.length)}...");
          } else {
            _log(
                "   ⚠️ Failed to sync message ${message.id.substring(0, message.id.length > 8 ? 8 : message.id.length)}...");
          }

          // Небольшая задержка между сообщениями
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          _log("   ❌ Error syncing message ${message.id}: $e");
        }
      }

      _log(
          "✅ [BRIDGE-SYNC] Message sync completed: $sentCount/${recentMessages.length} sent");
    } catch (e) {
      _log("❌ [BRIDGE-SYNC] Error during message sync: $e");
    }
  }

  /// True во время Boost Window (8s после перехода outbox 0→1). Используется для scan/adv без изменения FSM.
  bool get isOutboxBoostActive =>
      _outboxBoostUntil != null && DateTime.now().isBefore(_outboxBoostUntil!);

  BluetoothMeshService() {
    _setupGattServerListener();
    _checkNativeAdvertiserSupport();
    _setupOutboxBoostListener();
  }

  void _setupOutboxBoostListener() {
    try {
      locator<EventBusService>().on<OutboxFirstMessageEvent>((_) {
        _requestOutboxBoost();
        _refreshAdvertisingIntentFlag();
      });
      locator<EventBusService>().on<OutboxEmptyEvent>((_) {
        _refreshAdvertisingIntentFlag();
      });
    } catch (_) {}
  }

  /// Обновляет только байт intent (has_outbox) в BLE advertisement без смены FSM/подключений.
  void _refreshAdvertisingIntentFlag() {
    if (_lastManufacturerDataBase == null || _lastSafeName == null) return;
    if (!_stateMachine.isInState(BleState.ADVERTISING) &&
        _advState != BleAdvertiseState.advertising) return;
    if (_lastAdvOperation != null &&
        DateTime.now().difference(_lastAdvOperation!) < _minAdvInterval) return;
    _refreshAdvertisingIntentFlagAsync();
  }

  Future<void> _refreshAdvertisingIntentFlagAsync() async {
    if (_lastManufacturerDataBase == null || _lastSafeName == null) return;
    bool hasOutbox = false;
    try {
      hasOutbox = (await locator<LocalDatabaseService>().getPendingFromOutbox()).isNotEmpty;
    } catch (_) {}
    final newData = Uint8List.fromList([..._lastManufacturerDataBase!, hasOutbox ? 1 : 0]);
    _lastAdvOperation = DateTime.now();
    try {
      if (_nativeAdvertisingStarted && Platform.isAndroid) {
        await _nativeAdvChannel.invokeMethod('stopAdvertising');
        await Future.delayed(const Duration(milliseconds: 500));
        final success = await _nativeAdvChannel.invokeMethod<bool>('startAdvertising', {
          'localName': _lastSafeName,
          'manufacturerData': newData,
        });
        if (success == true) _log("🔍 [ADV] Intent flag updated (native): has_outbox=$hasOutbox");
      } else if (_advertisingStartedSuccessfully) {
        await _blePeripheral.stop();
        await Future.delayed(const Duration(milliseconds: 500));
        await _blePeripheral.start(advertiseData: AdvertiseData(
          serviceUuid: SERVICE_UUID,
          localName: _lastSafeName,
          includeDeviceName: false,
          manufacturerId: 0xFFFF,
          manufacturerData: newData,
        ));
        _log("🔍 [ADV] Intent flag updated (peripheral): has_outbox=$hasOutbox");
      }
    } catch (e) {
      _log("⚠️ [ADV] Intent flag refresh failed: $e");
    }
  }

  void _requestOutboxBoost() {
    final now = DateTime.now();
    if (_lastOutboxBoostTime != null &&
        now.difference(_lastOutboxBoostTime!) < _outboxBoostMinInterval) {
      return; // Idempotent: max 1 boost every 15s
    }
    _lastOutboxBoostTime = now;
    _outboxBoostTimer?.cancel();
    _outboxBoostUntil = now.add(_outboxBoostWindow);
    _log("🔍 [OUTBOX-BOOST] Boost window started (8s) — increased scan/adv discovery");
    _outboxBoostTimer = Timer(_outboxBoostWindow, () {
      _outboxBoostUntil = null;
      _log("🔍 [OUTBOX-BOOST] Boost window ended — normal scan/adv params");
    });
  }

  /// Проверяет, нужно ли использовать native advertiser
  Future<void> _checkNativeAdvertiserSupport() async {
    if (_nativeAdvertiserChecked) return;
    _nativeAdvertiserChecked = true;

    try {
      if (!Platform.isAndroid) {
        _useNativeAdvertiser = false;
        return;
      }

      final requires = await _nativeAdvChannel
          .invokeMethod<bool>('requiresNativeAdvertising');
      _useNativeAdvertiser = requires ?? false;

      if (_useNativeAdvertiser) {
        _log(
            "🔧 [ADV] Device requires native BLE advertiser (Huawei/Honor detected)");

        // Получаем информацию об устройстве
        final deviceInfo =
            await _nativeAdvChannel.invokeMethod<Map>('getDeviceInfo');
        if (deviceInfo != null) {
          _log("   📋 Brand: ${deviceInfo['brand']}");
          _log("   📋 Model: ${deviceInfo['model']}");
          _log("   📋 Firmware: ${deviceInfo['firmware']}");
        }
      }
    } catch (e) {
      _log("⚠️ [ADV] Error checking native advertiser support: $e");
      _useNativeAdvertiser = false;
    }
  }

  void _setupGattServerListener() {
    // Подписываемся на события от GATT сервера
    _gattChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onGattDataReceived':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          final data = args['data'] as String?;
          final isComplete = args['isComplete'] as bool? ?? false;
          if (deviceAddress != null && data != null) {
            _handleIncomingGattData(deviceAddress, data,
                isComplete: isComplete);
          }
          break;
        case 'onGattClientConnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("✅ [GATT-SERVER] Client connected: ${maskMacForLog(deviceAddress ?? '')}");
          // 🔒 SECURITY FIX #4: Track connected client to prevent token rotation
          if (deviceAddress != null) {
            _connectedGattClients.add(deviceAddress);
            _lastGattClientActivity = DateTime.now();
            _log(
                "📋 [GATT-SERVER] Active clients: ${_connectedGattClients.length}");

            // 🔥 FIX GATT UPLINK: Откладываем Bridge sync на 3s, чтобы GHOST успел сделать
            // discoverServices + write (uplink Ghost→Bridge) ДО того, как Bridge начнёт notify (downlink).
            // На Huawei одновременный notify (Bridge→Ghost) и write (Ghost→Bridge) вызывает сбои.
            _log(
                "🔄 [BRIDGE-SYNC] Delaying sync 3s to allow GHOST uplink write first...");
            unawaited(Future.delayed(const Duration(seconds: 3), () async {
              if (_connectedGattClients.contains(deviceAddress)) {
                await _syncMessagesToGhost(deviceAddress);
              } else {
                _log(
                    "⏸️ [BRIDGE-SYNC] GHOST ${maskMacForLog(deviceAddress)} disconnected during delay - skip sync");
              }
            }));
          }
          break;
        case 'onGattClientDisconnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("❌ [GATT-SERVER] Client disconnected: ${maskMacForLog(deviceAddress ?? '')}");
          // 🔒 SECURITY FIX #4: Remove client from tracking
          if (deviceAddress != null) {
            _connectedGattClients.remove(deviceAddress);
            _lastGattClientActivity = DateTime.now();
            _log(
                "📋 [GATT-SERVER] Active clients: ${_connectedGattClients.length}");
          }
          break;
        case 'onGattReady':
          // 🔥 FIX: Parse generation parameter to detect stale events
          int? generation;
          if (call.arguments != null && call.arguments is Map) {
            generation = (call.arguments as Map)['generation'] as int?;
          }
          _log(
              "📥 [GATT-SERVER] Received onGattReady event from native (gen: $generation)");
          _onGattReady(generation: generation);
          // 🔥 BLE AUDIT FIX: NativeMeshService.startGattServerAndWait() ждёт этот же сигнал
          try {
            NativeMeshService.completeGattReadyFromNative(true);
          } catch (_) {}
          break;
      }
    });
  }

  void _handleIncomingGattData(String deviceAddress, String data,
      {bool isComplete = false}) {
    final preview = data.length > 100 ? data.substring(0, 100) : data;
    _log(
        "📥 [BRIDGE] BLE GATT: Received ${isComplete ? 'COMPLETE' : 'partial'} data from GHOST ${maskMacForLog(deviceAddress)}");
    _log("   📋 Data preview: $preview...");
    _log("   📋 Full data length: ${data.length} bytes");

    // 🔥 FRAMING: Теперь данные приходят полностью собранные из Kotlin
    if (!isComplete) {
      _log(
          "⚠️ [BRIDGE] Data marked as incomplete - this should not happen with new framing protocol");
    }

    try {
      // Парсим JSON данные (теперь это полное сообщение!)
      final jsonData = jsonDecode(data) as Map<String, dynamic>;
      final messageType = jsonData['type'] ?? 'UNKNOWN';
      final messageId =
          jsonData['h'] ?? jsonData['mid'] ?? jsonData['id'] ?? 'unknown';

      _log("   ✅ [JSON] Parsed complete message successfully!");
      _log("   📋 Message type: $messageType");
      _log(
          "   📋 Message ID: ${messageId.toString().substring(0, messageId.toString().length > 8 ? 8 : messageId.toString().length)}...");

      // OUTBOX_REQUEST: Central (Tecno) asks Peripheral (Huawei) to send pending outbox messages via notify.
      // Huawei stays PERIPHERAL-only; we respond by sending each pending message (fragmented) via notify.
      if (messageType == 'OUTBOX_REQUEST') {
        _log("   📥 [OUTBOX_REQUEST] Central requested outbox pull — responding via notify");
        unawaited(_handleOutboxRequest(deviceAddress));
        return;
      }

      // Добавляем senderIp в данные для обработки
      jsonData['senderIp'] = deviceAddress;

      // 🔥 FIX BRIDGE→GHOST relay: processIncomingPacket() вызывается без await, поэтому
      // к моменту attemptRelay GHOST может уже отключиться и connectedGattClients пуст.
      // Сохраняем снимок подключённых GATT-клиентов сейчас — relay будет отправлять по нему.
      final recipientsSnapshot = _connectedGattClients.toList();
      if (recipientsSnapshot.isNotEmpty) {
        jsonData['_relayRecipientsSnapshot'] = recipientsSnapshot;
      }

      _log("   📤 Forwarding to MeshService.processIncomingPacket()...");

      // Передаем данные в MeshService для обработки (это вызовет SQL/hoop)
      final meshService = locator<MeshService>();
      meshService.processIncomingPacket(jsonData);

      // 🔥 ACK SEMANTICS: Определяем когда отправлять ACK
      // - OFFLINE_MSG / SOS: ACK сразу (полное сообщение)
      // - MSG_FRAG: ACK только после полной сборки всех фрагментов
      final bool isFragment = messageType == 'MSG_FRAG';

      if (isFragment) {
        // Для фрагментов - проверяем, собрано ли сообщение полностью
        final fragMessageId =
            jsonData['mid']?.toString() ?? messageId.toString();
        _log(
            "   📦 [FRAG] Fragment received, checking if message is complete...");

        // Асинхронно проверяем и отправляем ACK только при полной сборке
        _checkAndAckIfComplete(deviceAddress, fragMessageId);
      } else {
        // Для полных сообщений - ACK сразу
        _log("   ✅ [SQL] BLE GATT message processed and committed!");
        _sendAppAck(deviceAddress, messageId.toString());
      }
    } catch (e) {
      _log("❌ [BRIDGE] BLE GATT: Error processing incoming data: $e");
      _log("   📋 Raw data: $preview...");
      // НЕ отправляем ACK при ошибке - GHOST должен повторить попытку
    }
  }

  /// 🔥 Проверяет, собрано ли сообщение полностью, и отправляет ACK
  Future<void> _checkAndAckIfComplete(
      String deviceAddress, String messageId) async {
    try {
      final db = locator<LocalDatabaseService>();
      final isComplete = await db.isMessageComplete(messageId);

      if (isComplete) {
        _log("   🎉 [FRAG] Message $messageId fully assembled - sending ACK");
        _sendAppAck(deviceAddress, messageId);
      } else {
        _log("   ⏳ [FRAG] Message $messageId not yet complete - ACK deferred");
      }
    } catch (e) {
      _log("   ⚠️ [FRAG] Error checking message completion: $e");
    }
  }

  /// 🔥 Отправляет APP-level ACK на GHOST после успешной обработки сообщения
  void _sendAppAck(String deviceAddress, String messageId) {
    _log(
        "📤 [ACK] Sending app-level ACK to GHOST ${maskMacForLog(deviceAddress)} for message $messageId");
    try {
      // Используем MethodChannel для отправки ACK обратно на GHOST
      // Это событие будет перехвачено на Kotlin стороне и отправлено через GATT notify
      _gattChannel.invokeMethod('sendAppAck', {
        'deviceAddress': deviceAddress,
        'messageId': messageId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _log("   ✅ [ACK] App-level ACK sent for $messageId");
    } catch (e) {
      _log("   ⚠️ [ACK] Failed to send app-level ACK: $e");
      // Не критично - GHOST по timeout повторит
    }
  }

  // ======================================================
  // ⚡ AUTO-LINK LOGIC
  // ======================================================

  /// Отправляет сообщение через BLE GATT. Возвращает true при успешной доставке.
  /// 🔒 Delegates to enqueue — single path for all BLE sends.
  Future<bool> sendMessage(BluetoothDevice device, String message) async {
    // 🔍🔍🔍 CRITICAL DIAGNOSTIC: Абсолютно первая строка - БЕЗ обращения к device!
    _log(
        "🦷🔍🔍🔍 [BT-CRITICAL] sendMessage ENTERED AT ${DateTime.now().toIso8601String()}");

    // 🔍 Теперь безопасно обращаемся к device
    String id = "UNKNOWN";
    String shortMac = "UNKNOWN";
    try {
      _log("🦷🔍 [BT-DIAGNOSTIC] Accessing device.remoteId...");
      id = device.remoteId.str;
      shortMac = id.length > 8 ? id.substring(id.length - 8) : id;
      _log(
          "🦷🔍 [BT-DIAGNOSTIC] sendMessage - shortMac: $shortMac, msg length: ${message.length}");
    } catch (e) {
      _log("🦷❌ [BT-DIAGNOSTIC] FAILED to access device.remoteId: $e");
      return false;
    }

    _log("🔗 [SEND-MSG] Delegating to enqueue for $shortMac");
    try {
      final sent = await enqueue(id, [message]);
      return sent > 0;
    } catch (e) {
      _log("❌ [SEND-MSG] Failed for $shortMac: $e");
      return false;
    }
  }

  /// BLE relay entry point: guard by transport capability. Use for Gossip/Epidemic relay only.
  /// Returns skippedDueToRole when FSM is not eligible for central (e.g. ADVERTISING); not an error.
  Future<BleRelayResult> sendMessageForRelay(BluetoothDevice device, String message) async {
    if (!canInitiateCentralConnection()) {
      _log(
          "[BLE-RELAY] Skipped: transport not eligible for central connect. state=${_stateMachine.state}");
      return BleRelayResult.skippedDueToRole;
    }
    try {
      final ok = await sendMessage(device, message);
      return ok ? BleRelayResult.success : BleRelayResult.failure;
    } catch (e) {
      _log("❌ [BLE-RELAY] sendMessage error: $e");
      return BleRelayResult.failure;
    }
  }

  /// Прямое подключение для обмена RoutingPulse (4 байта)
  Future<void> quickLinkAndPing(BluetoothDevice device, Uint8List pulse) async {
    // Проверяем права перед коннектом (Huawei/Tecno могут крашить без CONNECT)
    if (!await Permission.bluetoothConnect.isGranted) {
      _log("⛔ BT CONNECT permission missing, abort quickLink");
      return;
    }
    // 🔄 Use FSM for state validation
    if (!_stateMachine.canConnect()) {
      _log(
          "⏸️ [QuickLink] Cannot connect in state: ${_stateMachine.state}, skipping.");
      return;
    }

    try {
      await _stateMachine.transition(BleState.CONNECTING);
    } catch (e) {
      _log("❌ [QuickLink] Invalid state transition: $e");
      return;
    }

    // Legacy state update
    // 🔄 Use FSM for state validation
    if (!_stateMachine.canConnect()) {
      _log(
          "⏸️ [QuickLink] Cannot connect in state: ${_stateMachine.state}, skipping.");
      return;
    }

    try {
      await _stateMachine.transition(BleState.CONNECTING);
    } catch (e) {
      _log("❌ [QuickLink] Invalid state transition: $e");
      return;
    }

    _advState = BleAdvertiseState.connecting;
    _log("⚡ Auto-Link triggered for ${maskMacForLog(device.remoteId.str)}");

    try {
      await enterCentralMode();
      await device.connect(
          timeout: const Duration(seconds: 15), autoConnect: false);
      if (Platform.isAndroid) {
        await _enqueueGattOperation(() => device.requestMtu(247));
      }

      final services = await device.discoverServices();
      final targetService =
          services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      final targetChar = targetService.characteristics
          .firstWhere((c) => c.uuid.toString() == CHAR_UUID);

      await _gattWrite(targetChar, pulse, withoutResponse: true);
      _log("🛰️ Tactical pulse delivered to ${maskMacForLog(device.remoteId.str)}");
    } catch (e) {
      _log("⚠️ QuickLink failed: $e");
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
      // Reset FSM to IDLE
      await _stateMachine.forceTransition(BleState.IDLE);
      _advState = BleAdvertiseState.idle;
    }
  }

  // ======================================================
  // 📡 PERIPHERAL MODE (Advertising)
  // ======================================================

  /// Stable device UUID hash (first 8 bytes of SHA256(userId)) for BLE advertising.
  /// Used so peers can find us by UUID when MAC rotates; connect by "device with this UUID" not by saved MAC.
  List<int> _deviceUuidHashBytes() {
    String userId = '';
    try {
      if (locator.isRegistered<ApiService>()) {
        userId = locator<ApiService>().currentUserId;
      }
    } catch (_) {}
    if (userId.isEmpty) userId = 'unknown';
    final bytes = utf8.encode(userId);
    final hash = sha256.convert(bytes);
    return hash.bytes.sublist(0, 8);
  }

  Future<void> startAdvertising(String myName) async {
    // 🔒 Scan/Advertising safety: only when IDLE (no overlapping with GATT transaction).
    if (_bleTransactionState != BleTransactionState.IDLE) {
      _log("⚠️ [ADV] startAdvertising skipped — BleTransactionState != IDLE ($_bleTransactionState)");
      return;
    }
    // 🔥 ОПТИМИЗАЦИЯ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Проверяем минимальный интервал
    if (_lastAdvOperation != null) {
      final timeSinceLastOp = DateTime.now().difference(_lastAdvOperation!);
      if (timeSinceLastOp < _minAdvInterval) {
        final waitTime = _minAdvInterval - timeSinceLastOp;
        _log(
            "⏸️ [ADV] Too soon since last operation (${timeSinceLastOp.inMilliseconds}ms), waiting ${waitTime.inMilliseconds}ms...");
        await Future.delayed(waitTime);
      }
    }
    // 🔒 HUAWEI BLE POLICY: Do not restart advertising within 2s of Central session end.
    final isHuawei = await HardwareCheckService().isHuaweiOrHonor();
    if (isHuawei && _lastCentralSessionEndTime != null) {
      final sinceCentral = DateTime.now().difference(_lastCentralSessionEndTime!);
      if (sinceCentral.inSeconds < 2) {
        final waitMs = 2000 - sinceCentral.inMilliseconds;
        if (waitMs > 0) {
          _log("⏸️ [ADV] Huawei policy: waiting ${waitMs}ms after Central session before advertising");
          await Future.delayed(Duration(milliseconds: waitMs));
        }
      }
    }
    _lastAdvOperation = DateTime.now();

    // 🔥 FSM: Проверяем состояние перед стартом
    // 🔄 Use FSM for state validation
    if (!_stateMachine.canAdvertise()) {
      _log(
          "⏸️ [ADV] Cannot advertise in state: ${_stateMachine.state}, skipping.");
      return;
    }

    try {
      await _stateMachine.transition(BleState.ADVERTISING);
    } catch (e) {
      _log("❌ [ADV] Invalid state transition: $e");
      return;
    }

    // Legacy state update (for backward compatibility)
    _advState = BleAdvertiseState.starting;

    try {
      // 🔥 FIX: Убрана deadlock проверка!
      // Старый код устанавливал _advState = starting, а потом ждал пока он станет idle
      // Это создавало deadlock - completer никогда не завершался
      _log("📡 [ADV] State: starting, proceeding with advertising...");

      // 🔥 FIX: НЕ ОСТАНАВЛИВАЕМ GATT сервер при обновлении advertising!
      // Раньше здесь был _stopGattServer() который убивал GATT сервер при каждом обновлении токена
      // Это приводило к тому что isGattServerRunning() возвращал false и ждал 21 секунду
      // GATT сервер должен работать независимо от advertising
      final isGattRunning = await _isGattServerRunning();
      if (isGattRunning) {
        _log("✅ [ADV] GATT server already running - keeping it active");
      } else {
        _log(
            "ℹ️ [ADV] GATT server not running (will be started later if needed)");
      }

      // 🔥 КРИТИЧНО: Агрессивная очистка всех advertising sets перед запуском нового
      // Это решает проблему "ADVERTISE_FAILED_TOO_MANY_ADVERTISERS" на Huawei и других устройствах
      try {
        // Сначала проверяем состояние
        bool isCurrentlyAdvertising = false;
        try {
          isCurrentlyAdvertising = await _blePeripheral.isAdvertising;
        } catch (e) {
          _log("⚠️ [ADV] Error checking isAdvertising: $e");
        }

        if (isCurrentlyAdvertising) {
          _log("🛑 [ADV] Stopping previous advertising session...");
        } else {
          _log(
              "🛑 [ADV] Force stopping all advertising sets (prevent TOO_MANY_ADVERTISERS)...");
        }

        // 🔥 FIX: Only call stop if we believe advertising might be active
        // This helps prevent "Reply already submitted" crash on flutter_ble_peripheral
        if (isCurrentlyAdvertising || _advertisingStartedSuccessfully) {
          try {
            await _blePeripheral.stop();
            // Даем больше времени на остановку перед новым стартом (для Huawei и медленных устройств)
            await Future.delayed(const Duration(milliseconds: 800));
            _log("✅ [ADV] Previous advertising stopped");
          } catch (stopError) {
            final stopErrorStr = stopError.toString();
            // 🔥 FIX: Handle both "Failed to find advertising callback" and "Reply already submitted"
            if (stopErrorStr.contains('Failed to find advertising callback')) {
              _log(
                  "ℹ️ [ADV] Advertising callback already removed by system (this is normal)");
            } else if (stopErrorStr.contains('Reply already submitted')) {
              _log(
                  "ℹ️ [ADV] Reply already submitted - stop was already processed");
            } else {
              _log("⚠️ [ADV] Error stopping advertising: $stopError");
            }
            // Даем время на стабилизацию даже при ошибке
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } else {
          _log(
              "ℹ️ [ADV] Skipping pre-start cleanup (no previous advertising detected)");
          await Future.delayed(const Duration(milliseconds: 300));
        }

        // 🔥 КРИТИЧНО: Дополнительная проверка и повторная остановка через небольшую задержку
        // Это помогает на устройствах, где advertising sets "зависают"
        await Future.delayed(const Duration(milliseconds: 200));
        try {
          final stillAdvertising = await _blePeripheral.isAdvertising;
          if (stillAdvertising) {
            _log("🛑 [ADV] Advertising still active, force stopping again...");
            try {
              await _blePeripheral.stop();
              await Future.delayed(const Duration(milliseconds: 500));
              _log("✅ [ADV] Force stop completed");
            } catch (e) {
              // Handle "Reply already submitted" gracefully
              if (e.toString().contains('Reply already submitted')) {
                _log(
                    "ℹ️ [ADV] Reply already submitted on force stop - continuing");
              } else {
                _log("⚠️ [ADV] Error on force stop: $e");
              }
            }
          }
        } catch (e) {
          _log("ℹ️ [ADV] Secondary stop check warning: $e");
        }
      } catch (e) {
        // Игнорируем ошибки при проверке состояния, продолжаем запуск
        _log("ℹ️ [ADV] Cleanup warning: $e");
        // Даем время на стабилизацию даже при ошибке
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // 🔥 КРИТИЧНО: Извлекаем token из ОРИГИНАЛЬНОГО имени ДО обрезки
      // Это гарантирует, что токен всегда попадет в manufacturerData, даже если localName обрезан
      final currentRole = NetworkMonitor().currentRole;
      final isBridge = currentRole == MeshRole.BRIDGE;
      String? extractedToken;

      if (isBridge) {
        // Извлекаем token из оригинального имени (формат: M_0_1_BRIDGE_TOKEN)
        // Проверяем как полное имя, так и обрезанное (на случай если имя уже было обрезано ранее)
        final parts = myName.split("_");
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          extractedToken = parts[4];
          _log(
              "🔑 [ADV] Token extracted from original name: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (length: ${extractedToken.length})");
        } else if (myName.contains("BRIDGE_")) {
          // Fallback: если формат немного отличается, пытаемся извлечь после "BRIDGE_"
          final bridgeIndex = myName.indexOf("BRIDGE_");
          if (bridgeIndex != -1) {
            final tokenStart = bridgeIndex + 7; // "BRIDGE_".length = 7
            if (tokenStart < myName.length) {
              extractedToken = myName.substring(tokenStart);
              _log(
                  "🔑 [ADV] Token extracted from original name (fallback): ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (length: ${extractedToken.length})");
            }
          }
        } else {
          // 🔥 FIX: Если имя короткое (M_0_0_df78) без BRIDGE_TOKEN
          // Это означает, что вызов пришел НЕ из emitInternetMagnetWave()
          // В этом случае мы НЕ должны рекламировать - это ошибка вызывающего кода
          _log("⚠️ [ADV] BRIDGE name without token detected: '$myName'");
          _log("   📋 Parts: ${parts.join(', ')} (length: ${parts.length})");
          _log(
              "   ❌ Token extraction FAILED - name does not contain 'BRIDGE_TOKEN' format");
          _log(
              "   💡 This call should come from emitInternetMagnetWave() with proper token");
          _log(
              "   💡 Advertising will have manufacturerData=[66,82] (BR only, NO TOKEN)");
          _log(
              "   ⚠️ GHOST devices will see this BRIDGE but GATT will be FORBIDDEN!");
        }
      }

      // 🔍 ВАЛИДАЦИЯ И ОБРЕЗКА ИМЕНИ (BLE ограничение: ~29 байт, но безопаснее ~20)
      String safeName = myName;
      if (safeName.length > 20) {
        _log(
            "⚠️ [ADV] Name too long (${safeName.length}), truncating to 20 chars.");
        safeName = safeName.substring(0, 20);
        _log("   📋 Original: '$myName'");
        _log("   📋 Truncated: '$safeName'");
      }
      if (safeName.isEmpty) {
        safeName = "M_255_0_GHST"; // Fallback
        _log("⚠️ [ADV] Empty name, using fallback: $safeName");
      }

      // 🔥 BRIDGE: Сначала поднимаем GATT Server, ждем onGattReady, только потом advertising
      if (isBridge) {
        // 🔥 КРИТИЧНО: Проверяем, не запущен ли GATT server уже
        final isGattRunning = await _isGattServerRunning();
        if (!isGattRunning) {
          _log(
              "🌉 [BRIDGE] Step 1: Starting GATT Server before advertising...");
          final serverStarted = await _startGattServerAndWait();
          if (!serverStarted) {
            _log(
                "⚠️ [BRIDGE] Failed to start GATT server - continuing in fallback mode (advertising without GATT server)");
            // 🔥 FALLBACK: Продолжаем рекламировать даже без GATT server
            // GHOST устройства могут найти нас по тактическому имени
            // GATT server может запуститься позже
          } else {
            _log(
                "✅ [BRIDGE] Step 1 Complete: GATT Server ready (onGattReady received)");
          }
        } else {
          _log("ℹ️ [BRIDGE] GATT Server already running - skipping start");
        }
      }

      _log(
          "📡 [ADV] Starting with name: '$safeName' (${safeName.length} chars)");

      _lastAdvertisingName = myName;

      // 🔥 КРИТИЧНО: Добавляем manufacturerData с токеном ДО обрезки имени
      // manufacturerData должен быть Uint8List, а не Map
      // Используем manufacturerId = 0xFFFF (зарезервированный для тестирования)
      // 🔥 КРИТИЧНО: Для BRIDGE ВСЕГДА добавляем token в manufacturerData (даже если localName пустое)
      // 🔍 INTENT: последний байт = has_outbox (bit 0): 1 если outbox > 0, иначе 0 (<= 31 bytes legacy)
      bool hasOutbox = false;
      try {
        final pending = await locator<LocalDatabaseService>().getPendingFromOutbox();
        hasOutbox = pending.isNotEmpty;
      } catch (_) {}
      final int flagsByte = hasOutbox ? 1 : 0;

      Uint8List baseMf;
      if (isBridge) {
        if (extractedToken != null && extractedToken.isNotEmpty) {
          final tokenBytes = utf8.encode(extractedToken);
          final maxTokenBytes = 23;
          final truncatedToken = tokenBytes.length > maxTokenBytes
              ? tokenBytes.sublist(0, maxTokenBytes)
              : tokenBytes;

          baseMf = Uint8List.fromList([0x42, 0x52, ...truncatedToken]);
          _log(
              "🔍 [ADV] BRIDGE with token in manufacturerData: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (${baseMf.length + 1} bytes + intent)");
          _log(
              "   📋 Token bytes: ${truncatedToken.length} bytes (original: ${tokenBytes.length} bytes)");
        } else {
          baseMf = Uint8List.fromList([0x42, 0x52]);
          _log(
              "⚠️ [ADV] BRIDGE without token in manufacturerData (token extraction failed)");
          _log("   📋 Original name: '$myName'");
          _log("   📋 Safe name: '$safeName'");
        }
      } else if (myName.contains("RELAY")) {
        final deviceUuidBytes = _deviceUuidHashBytes();
        baseMf = Uint8List.fromList([0x52, 0x4C, ...deviceUuidBytes]);
      } else {
        final deviceUuidBytes = _deviceUuidHashBytes();
        baseMf = Uint8List.fromList([0x47, 0x48, ...deviceUuidBytes]);
      }
      _lastManufacturerDataBase = baseMf;
      _lastSafeName = safeName;
      final manufacturerData = Uint8List.fromList([...baseMf, flagsByte]);

      final data = AdvertiseData(
        serviceUuid: SERVICE_UUID,
        localName: safeName,
        includeDeviceName:
            false, // 🔥 ВАЖНО: Ставим false, чтобы сэкономить 20 байт
        manufacturerId: 0xFFFF, // 🔥 FIX: Manufacturer ID для тестирования
        manufacturerData:
            manufacturerData, // 🔥 FIX: Добавляем роль и token в manufacturerData
      );

      _log(
          "🔍 [ADV] Advertising with manufacturerData: ${isBridge ? 'BRIDGE' : 'GHOST'} (0xFFFF: ${manufacturerData.length} bytes)");

      // 🔥 FIX: Используем native advertiser для Huawei/Honor если flutter_ble_peripheral не работает
      bool advertisingStarted = false;

      // Reset tracking flags before starting
      _advertisingStartedSuccessfully = false;
      _nativeAdvertisingStarted = false;

      if (_useNativeAdvertiser && Platform.isAndroid) {
        _log("🔧 [ADV] Using native BLE advertiser (Huawei/Honor mode)");
        try {
          final success =
              await _nativeAdvChannel.invokeMethod<bool>('startAdvertising', {
            'localName': safeName,
            'manufacturerData': manufacturerData,
          });
          advertisingStarted = success ?? false;

          if (advertisingStarted) {
            _log("✅ [ADV] Native advertiser started successfully");
            _nativeAdvertisingStarted = true;
          } else {
            _log(
                "⚠️ [ADV] Native advertiser failed, falling back to flutter_ble_peripheral");
          }
        } catch (e) {
          _log(
              "⚠️ [ADV] Native advertiser error: $e, falling back to flutter_ble_peripheral");
        }
      }

      // Fallback или стандартный путь
      if (!advertisingStarted) {
        try {
          // 🔍 OUTBOX-BOOST: при активном boost — более частый advertise (interval LOW ≈100ms)
          if (isOutboxBoostActive && Platform.isAndroid) {
            await _blePeripheral.start(
                advertiseData: data,
                advertiseSetParameters: AdvertiseSetParameters(
                    interval: 160)); // 160 = INTERVAL_LOW (high frequency)
            _log("✅ [ADV] flutter_ble_peripheral started (boost: high freq)");
          } else {
            await _blePeripheral.start(advertiseData: data);
            _log("✅ [ADV] flutter_ble_peripheral started successfully");
          }
          advertisingStarted = true;
        } catch (e) {
          _log("❌ [ADV] flutter_ble_peripheral failed to start: $e");
          advertisingStarted = false;
          // Re-throw to be handled by outer catch block
          rethrow;
        }
      }

      // 🔥 FIX: Only mark as successfully started if we actually started
      _advertisingStartedSuccessfully = advertisingStarted;

      // FSM state already set to ADVERTISING in transition above
      _advState = BleAdvertiseState.advertising;
      _log("✅ [ADV] ADVERTISING ACTIVE: '$safeName'");

      // 🔥 GHOST: Запускаем GATT сервер после advertising (для обратной совместимости)
      if (!isBridge) {
        await _startGattServer();
      }
    } catch (e) {
      // Reset FSM on error
      await _stateMachine.forceTransition(BleState.IDLE);
      _advState = BleAdvertiseState.idle;

      // 🔥 FIX: Reset tracking flags on error
      _advertisingStartedSuccessfully = false;
      _nativeAdvertisingStarted = false;

      // 🔥 УЛУЧШЕНИЕ: Детальная обработка ошибок advertising
      final errorStr = e.toString();
      if (errorStr.contains('status=1')) {
        _log(
            "❌ [ADV] Failed to start: ADVERTISE_FAILED_TOO_MANY_ADVERTISERS (status=1)");
        _log("   ⚠️ Too many active advertising sets on this device");
        _log("   🔄 Attempting aggressive cleanup and retry...");

        // 🔥 КРИТИЧНО: Агрессивная очистка при ошибке TOO_MANY_ADVERTISERS
        try {
          // Принудительно останавливаем все advertising sets
          await _blePeripheral.stop();
          await Future.delayed(const Duration(milliseconds: 1000));

          // Проверяем, остановилось ли
          final stillAdvertising = await _blePeripheral.isAdvertising;
          if (stillAdvertising) {
            _log("   ⚠️ Advertising still active after stop, forcing again...");
            await _blePeripheral.stop();
            await Future.delayed(const Duration(milliseconds: 1000));
          }

          _log("   ✅ Cleanup completed");

          // 🔥 FIX: Пробуем native advertiser как fallback
          if (Platform.isAndroid && !_useNativeAdvertiser) {
            _log("   🔧 Trying native BLE advertiser as fallback...");
            try {
              // В catch manufacturerData из try недоступна — собираем заново (GH/BR/RL + deviceUuid + intent)
              final role = NetworkMonitor().currentRole;
              final isBridgeRole = role == MeshRole.BRIDGE;
              final uuidBytes = _deviceUuidHashBytes();
              Uint8List baseFallback = isBridgeRole
                  ? Uint8List.fromList([0x42, 0x52])
                  : (myName.contains("RELAY")
                      ? Uint8List.fromList([0x52, 0x4C, ...uuidBytes])
                      : Uint8List.fromList([0x47, 0x48, ...uuidBytes]));
              bool fbHasOutbox = false;
              try {
                fbHasOutbox = (await locator<LocalDatabaseService>().getPendingFromOutbox()).isNotEmpty;
              } catch (_) {}
              final fallbackMfData = Uint8List.fromList([...baseFallback, fbHasOutbox ? 1 : 0]);

              final success = await _nativeAdvChannel
                  .invokeMethod<bool>('startAdvertising', {
                'localName':
                    myName.length > 8 ? myName.substring(0, 8) : myName,
                'manufacturerData': fallbackMfData,
              });
              if (success == true) {
                _log("   ✅ Native advertiser fallback succeeded!");
                _advState = BleAdvertiseState.advertising;
                _useNativeAdvertiser = true; // Переключаемся на native
              } else {
                _log("   ⚠️ Native advertiser fallback also failed");
              }
            } catch (nativeError) {
              _log("   ⚠️ Native advertiser error: $nativeError");
            }
          }

          _log(
              "   💡 This device may have limitations on concurrent BLE advertising");
          _log(
              "   💡 GHOST devices can still connect via TCP if they have IP/port from MAGNET_WAVE");
        } catch (cleanupError) {
          _log("   ⚠️ Cleanup failed: $cleanupError");
        }

        _log(
            "   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else if (errorStr.contains('status=2')) {
        _log(
            "❌ [ADV] Failed to start: ADVERTISE_FAILED_ALREADY_STARTED (status=2)");
        _log(
            "   ⚠️ Advertising already active, attempting to stop and restart...");
        try {
          await _blePeripheral.stop();
          await Future.delayed(const Duration(milliseconds: 500));
          // Не пытаемся перезапустить автоматически - пусть вызывающий код решает
        } catch (_) {}
      } else if (errorStr.contains('status=3')) {
        _log(
            "❌ [ADV] Failed to start: ADVERTISE_FAILED_FEATURE_UNSUPPORTED (status=3)");
        _log("   ⚠️ BLE advertising not supported on this device");
        _log(
            "   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else if (errorStr.contains('status=4')) {
        _log(
            "❌ [ADV] Failed to start: ADVERTISE_FAILED_INTERNAL_ERROR (status=4)");
        _log("   ⚠️ Internal BLE stack error");
        _log(
            "   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else {
        _log("❌ [ADV] Failed to start: $e");
        _log(
            "   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      }
    }
  }

  /// 🔥 WI-FI DIRECT: Обновляет BLE advertising с passphrase для GHOST
  /// GHOST извлекает passphrase из manufacturerData и использует при Wi-Fi Direct connect
  Future<void> updateAdvertisingWithGroupInfo(
      String networkName, String passphrase) async {
    if (_bleTransactionState != BleTransactionState.IDLE) {
      _log("⚠️ [ADV] updateAdvertisingWithGroupInfo skipped — BleTransactionState != IDLE");
      return;
    }
    if (NetworkMonitor().currentRole != MeshRole.BRIDGE) return;
    if (_lastAdvertisingName == null) {
      _log(
          "⚠️ [ADV] Cannot update: no previous advertising name (startAdvertising not called yet)");
      return;
    }
    final myName = _lastAdvertisingName!;
    String? extractedToken;
    final parts = myName.split("_");
    if (parts.length >= 5 && parts[3] == "BRIDGE") {
      extractedToken = parts[4];
    } else if (myName.contains("BRIDGE_")) {
      final bridgeIndex = myName.indexOf("BRIDGE_");
      if (bridgeIndex != -1) extractedToken = myName.substring(bridgeIndex + 7);
    }
    if (extractedToken == null || extractedToken.isEmpty) {
      _log("⚠️ [ADV] Cannot add passphrase: token not found in last name");
      return;
    }
    // Формат: [0x42, 0x52, token(12), 0x7C, passphrase(8)] — 2+12+1+8=23 bytes
    final fullTokenBytes = utf8.encode(extractedToken);
    final tokenBytes = fullTokenBytes.length > 12
        ? fullTokenBytes.sublist(0, 12)
        : fullTokenBytes;
    final pass8 = (passphrase.length >= 8)
        ? passphrase.substring(0, 8)
        : passphrase.padRight(8, ' ');
    final passphraseBytes = utf8.encode(pass8);
    bool hasOutbox = false;
    try {
      hasOutbox = (await locator<LocalDatabaseService>().getPendingFromOutbox()).isNotEmpty;
    } catch (_) {}
    final manufacturerData = Uint8List.fromList(
        [0x42, 0x52, ...tokenBytes, 0x7C, ...passphraseBytes, hasOutbox ? 1 : 0]);
    final safeName = myName.length > 20 ? myName.substring(0, 20) : myName;
    _log(
        "📡 [ADV] Updating with passphrase for Wi-Fi Direct (GHOST will receive)");
    try {
      if (_nativeAdvertisingStarted && Platform.isAndroid) {
        try {
          await _nativeAdvChannel.invokeMethod('stopAdvertising');
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
        final success =
            await _nativeAdvChannel.invokeMethod<bool>('startAdvertising', {
          'localName': safeName,
          'manufacturerData': manufacturerData,
        });
        if (success == true) {
          _log("✅ [ADV] Updated with passphrase (native)");
          return;
        }
        _log("⚠️ [ADV] Native update failed, trying flutter_ble_peripheral");
      }
      if (!_nativeAdvertisingStarted) {
        await _blePeripheral.stop();
        await Future.delayed(const Duration(milliseconds: 500));
        await _blePeripheral.start(
            advertiseData: AdvertiseData(
          serviceUuid: SERVICE_UUID,
          localName: safeName,
          includeDeviceName: false,
          manufacturerId: 0xFFFF,
          manufacturerData: manufacturerData,
        ));
        _log("✅ [ADV] Updated with passphrase (flutter_ble_peripheral)");
      }
    } catch (e) {
      _log("⚠️ [ADV] Failed to update with passphrase: $e");
    }
  }

  /// Останавливает BLE advertising
  ///
  /// [keepGattServer] - если true, GATT сервер НЕ будет остановлен.
  /// Используйте keepGattServer=true при обновлении advertising (token rotation),
  /// чтобы избежать 25-секундного таймаута при перезапуске GATT сервера.
  Future<void> stopAdvertising({bool keepGattServer = false}) async {
    // 🔥 FIX: Mutex to prevent concurrent stop operations causing "Reply already submitted"
    // Используем synchronized lock для атомарной проверки и установки флага
    return _stopLock.synchronized(() async {
      if (_isStopInProgress) {
        _log("⏸️ [ADV] Stop already in progress, skipping duplicate call");
        return;
      }

      _isStopInProgress = true;

      try {
        // 🔥 ОПТИМИЗАЦИЯ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Проверяем минимальный интервал
        if (_lastAdvOperation != null) {
          final timeSinceLastOp = DateTime.now().difference(_lastAdvOperation!);
          if (timeSinceLastOp < _minAdvInterval) {
            final waitTime = _minAdvInterval - timeSinceLastOp;
            _log(
                "⏸️ [ADV] Too soon since last operation (${timeSinceLastOp.inMilliseconds}ms), waiting ${waitTime.inMilliseconds}ms...");
            await Future.delayed(waitTime);
          }
        }
        _lastAdvOperation = DateTime.now();

        // 🔥 FSM: Защита от повторных вызовов
        // 🔄 Use FSM for state validation
        if (_stateMachine.isInState(BleState.IDLE)) {
          _log("⏸️ [ADV] Already idle, skipping duplicate stop.");
          return;
        }

        try {
          await _stateMachine.transition(BleState.IDLE);
        } catch (e) {
          _log("⚠️ [ADV] Error transitioning to IDLE: $e, forcing...");
          await _stateMachine.forceTransition(BleState.IDLE);
        }

        _advState = BleAdvertiseState.stopping;

        // 🔥 FIX: Только останавливаем GATT сервер если явно запрошено
        // При обновлении advertising (token rotation) GATT сервер должен продолжать работать
        // чтобы избежать race condition и 25-секундного таймаута
        if (!keepGattServer) {
          await _stopGattServer();
        } else {
          _log("ℹ️ [ADV] Keeping GATT server active (advertising-only stop)");
        }

        // 🔥 FIX: Only stop native advertiser if it was actually started
        if (_nativeAdvertisingStarted &&
            _useNativeAdvertiser &&
            Platform.isAndroid) {
          try {
            await _nativeAdvChannel.invokeMethod('stopAdvertising');
            _log("🛑 [ADV] Native advertiser stopped");
            _nativeAdvertisingStarted = false;
          } catch (e) {
            _log("⚠️ [ADV] Error stopping native advertiser: $e");
          }
        }

        // 🔥 FIX: Only call flutter_ble_peripheral.stop() if advertising was actually started
        // This prevents the "Reply already submitted" crash when stopping non-started advertising
        if (_advertisingStartedSuccessfully) {
          try {
            // Проверяем, действительно ли идет реклама перед остановкой
            final isAdvertising = await _blePeripheral.isAdvertising;
            if (isAdvertising) {
              _log("🛑 [ADV] Stopping advertising...");
              await _blePeripheral.stop();
              // Даем время на полную остановку (для Huawei и медленных устройств)
              await Future.delayed(const Duration(milliseconds: 300));
              _log("✅ [ADV] Stopped successfully");
            } else {
              _log("ℹ️ [ADV] isAdvertising=false, skipping stop call");
            }
          } catch (e) {
            // 🔥 FIX: Handle "Reply already submitted" gracefully
            final errorStr = e.toString();
            if (errorStr.contains('Reply already submitted')) {
              _log(
                  "ℹ️ [ADV] Reply already submitted - stop was already processed");
            } else {
              _log("⚠️ [ADV] Error stopping: $e");
            }
          }
        } else {
          _log(
              "ℹ️ [ADV] Advertising was never started successfully, skipping stop call");
        }

        // Reset tracking flags
        _advertisingStartedSuccessfully = false;
      } catch (e) {
        _log("⚠️ [ADV] Error in stopAdvertising: $e");
        if (e.toString().contains("Reply already submitted")) {
          _log(
              "   ℹ️ [ADV] Ignoring 'Reply already submitted' error (known flutter_ble_peripheral issue)");
        }
      } finally {
        _advState = BleAdvertiseState.idle;
        _log("💤 FSM → IDLE");
        if (_stateIdleCompleter != null && !_stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter!.complete();
          _stateIdleCompleter = null;
        }
        _isStopInProgress = false;
      }
    });
  }

  // ======================================================
  // 🔥 GATT SERVER MANAGEMENT
  // ======================================================

  Completer<bool>? _serviceAddedCompleter;

  /// 🔒 BLE QUIET WINDOW + ROLE GATE: Enter CENTRAL — stop scan and our advertising.
  /// MUST only be called by the peer that has decided to become CENTRAL (tie-breaker).
  /// PERIPHERAL must NOT call this; PERIPHERAL keeps advertising + GATT server until link is established.
  /// HUAWEI POLICY: On Huawei/Honor we stop GATT server too (keepGattServer: false) to avoid dual-role concurrency.
  /// Sonar/Gossip/Epidemic/AUTO-TRIGGER must check bleTransactionState and pause during non-IDLE.
  Future<void> enterCentralMode() async {
    if (_stateMachine.isPeripheralRole && _gattServerReady) {
      _log(
          "[BLE-INVARIANT] PERIPHERAL must not enter QUIET; aborting enterCentralMode (stay advertising)");
      throw StateError(
          'PERIPHERAL must not enter QUIET_PRE_CONNECT; only CENTRAL may. FSM state=${_stateMachine.state}');
    }
    // 🔒 Scan/Advertising safety: only run stopScan/stopAdvertising when IDLE.
    if (_bleTransactionState != BleTransactionState.IDLE) {
      _log("⚠️ [BLE-QUIET] enterCentralMode skipped — BleTransactionState != IDLE ($_bleTransactionState)");
      return;
    }
    _transitionTransaction(BleTransactionState.QUIET_PRE_CONNECT);
    final isHuawei = await HardwareCheckService().isHuaweiOrHonor();
    if (isHuawei) {
      _log("[BLE-QUIET] enter (Huawei policy) — stopping scan, advertising, and GATT server");
    } else {
      _log(
          "[BLE-QUIET] enter — stopping scan and our advertising only (GATT server stays ON)");
    }
    try {
      await FlutterBluePlus.stopScan();
      int n = 0;
      while (FlutterBluePlus.isScanningNow && n < 20) {
        await Future.delayed(const Duration(milliseconds: 100));
        n++;
      }
      if (FlutterBluePlus.isScanningNow)
        _log("[BLE-BLOCK] Scan still active after 2s");
    } catch (e) {
      _log("⚠️ [BLE-ROLE] stopScan: $e");
    }
    await stopAdvertising(keepGattServer: !isHuawei);
    await _stateMachine.forceTransition(BleState.IDLE);
    _advState = BleAdvertiseState.idle;
    final quietMs = _shortQuietForNextConnect ? _shortQuietPreConnectMs : _quietPreConnectMs;
    if (_shortQuietForNextConnect) {
      _shortQuietForNextConnect = false;
      _log("[BLE-TIMING] Using SHORT quiet (${quietMs}ms) for GHOST connect (reduce MAC staleness)");
    } else {
      _log("[BLE-TIMING] Quiet pre-connect: waiting ${quietMs}ms");
    }
    await Future.delayed(Duration(milliseconds: quietMs));
    _log("[BLE-QUIET] exit — stack ready for connectGatt, CENTRAL allowed");
  }

  /// True when in BLE connect window: no AudioTrack/Sonar emission (QUIET_PRE_CONNECT, CONNECTING, SERVICE_DISCOVERY).
  bool get isInBleConnectWindow {
    switch (_bleTransactionState) {
      case BleTransactionState.QUIET_PRE_CONNECT:
      case BleTransactionState.CONNECTING:
      case BleTransactionState.STABILIZING_POST_CONNECT:
      case BleTransactionState.DISCOVERING:
        return true;
      default:
        return false;
    }
  }

  /// Запускает GATT сервер и ждет подтверждения готовности (для BRIDGE)
  /// Таймаут отсчитывается от момента addService(), а не от начала запуска
  /// Проверяет, запущен ли GATT server
  Future<bool> _isGattServerRunning() async {
    try {
      final result =
          await _gattChannel.invokeMethod<bool>('isGattServerRunning');
      return result ?? false;
    } catch (e) {
      _log("⚠️ [GATT-SERVER] Error checking server state: $e");
      return false;
    }
  }

  /// Публичный метод для проверки состояния GATT server
  Future<bool> isGattServerRunning() async {
    return await _isGattServerRunning();
  }

  /// 🔥 DIAGNOSTIC: Log detailed GATT server status
  Future<void> logGattServerStatus() async {
    try {
      final result =
          await _gattChannel.invokeMethod<Map>('getGattServerStatus');
      if (result != null) {
        _log("📊 [GATT-SERVER] Detailed status:");
        result.forEach((key, value) {
          _log("   📋 $key: $value");
        });
      }
    } catch (e) {
      _log("⚠️ [GATT-SERVER] Error getting status: $e");
    }
  }

  Future<bool> _startGattServerAndWait() async {
    try {
      if (isInGattLifecycle) {
        _log(
            "[BLE-BLOCK] GATT server start skipped — GATT lifecycle active (role freeze)");
        return false;
      }
      if (_gattServerReady) {
        _log("[GATT][SKIP] startGattServer skipped (already ready)");
        return true;
      }
      final isRunning = await _isGattServerRunning();
      if (isRunning) {
        _gattServerReady = true;
        _stateMachine.forceTransition(BleState.GATT_READY);
        _log("[GATT][SKIP] GATT server already running, marking ready");
        return true;
      }
      _stateMachine.forceTransition(BleState.GATT_STARTING);
      _log("[GATT][STATE] idle -> gattStarting");
      _log(
          "🚀 [GATT-SERVER] Starting GATT server and waiting for onGattReady...");

      // 🔥 ДУБЛИРУЮЩАЯ ПРОВЕРКА: Убеждаемся, что сервер действительно остановлен
      final isAdvertising = await _blePeripheral.isAdvertising;
      if (isAdvertising) {
        _log(
            "⚠️ [GATT-SERVER] Advertising still active, stopping before GATT server start...");
        try {
          await _blePeripheral.stop();
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (e) {
          _log("⚠️ [GATT-SERVER] Error stopping advertising: $e");
        }
      }

      // Проверяем состояние FSM
      // 🔥 FIX #2: FSM Recovery - если не IDLE, принудительно сбрасываем
      if (_advState != BleAdvertiseState.idle) {
        _log(
            "⚠️ [GATT-SERVER] FSM state is not idle ($_advState), attempting recovery...");

        // Ждём 2 секунды для естественного перехода в IDLE
        if (_stateIdleCompleter == null || _stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter = Completer<void>();
        }
        try {
          await _stateIdleCompleter!.future.timeout(const Duration(seconds: 2));
          _log("✅ [GATT-SERVER] FSM naturally transitioned to IDLE");
        } catch (e) {
          // INVARIANT: Do NOT transition to IDLE while GATT server is starting (we are in GATT_STARTING).
          // Aggressive cleanup causes deadlocks; proceed with GATT start and let onGattReady apply.
          _log(
              "⚠️ [GATT-SERVER] FSM not idle after 2s (state=${_stateMachine.state}); proceeding with GATT start, no reset");
        }
      }

      // 🔥 ОБНОВЛЕННАЯ ЛОГИКА COMPLETER: Обработка поздних событий
      // Если completer уже существует и не завершён - используем его
      // Если завершён или null - создаём новый
      if (_serviceAddedCompleter == null ||
          _serviceAddedCompleter!.isCompleted) {
        _serviceAddedCompleter = Completer<bool>();
        _log(
            "📝 [GATT-SERVER] New completer created, waiting for onGattReady event...");
      } else {
        _log(
            "📝 [GATT-SERVER] Reusing existing completer, waiting for onGattReady event...");
      }

      // Запускаем сервер (addService() будет вызван внутри). Native returns Map { success, generation }.
      final raw = await _gattChannel.invokeMethod<dynamic>('startGattServer');
      final result = raw is Map ? (raw['success'] == true) : (raw == true);
      final gen = raw is Map ? (raw['generation'] as int?) : null;
      if (gen != null) _expectedGattGen = gen;
      _log(
          "📡 [GATT-SERVER] startGattServer returned: success=$result, gen=$gen");

      if (result != true) {
        _log("⚠️ [GATT-SERVER] Failed to start GATT server");
        _serviceAddedCompleter = null;
        _expectedGattGen = -1;
        return false;
      }

      // 🔥 ТАЙМАУТ ОТСЧИТЫВАЕТСЯ ОТ addService()
      // addService() вызывается синхронно внутри startGattServer(),
      // поэтому таймаут начинается сразу после возврата из startGattServer()
      // Увеличен до 25 секунд для Huawei (иногда onGattReady приходит через 20 секунд)
      _log(
          "⏳ [GATT-SERVER] Waiting for onGattReady event (timeout: 25s from addService())...");

      try {
        final gattReady = await _serviceAddedCompleter!.future.timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            // 🔥 ИСПРАВЛЕНИЕ: Проверяем, не завершен ли completer перед возвратом false
            if (_serviceAddedCompleter != null &&
                _serviceAddedCompleter!.isCompleted) {
              _log(
                  "ℹ️ [GATT-SERVER] Timeout occurred, but completer already completed (late event handled)");
              // Completer уже завершен - событие пришло, но поздно
              return true;
            }
            _log(
                "⏱️ [GATT-SERVER] Timeout waiting for onGattReady (25s from addService())");
            _log(
                "⚠️ [GATT-SERVER] Completer state: ${_serviceAddedCompleter != null ? 'exists' : 'null'}, completed: ${_serviceAddedCompleter?.isCompleted ?? 'N/A'}");
            return false;
          },
        );

        _log("✅ [GATT-SERVER] onGattReady received: $gattReady");
        _serviceAddedCompleter = null;
        return gattReady;
      } catch (e) {
        // 🔥 ИСПРАВЛЕНИЕ: Проверяем completer даже при ошибке
        if (_serviceAddedCompleter != null &&
            _serviceAddedCompleter!.isCompleted) {
          _log(
              "✅ [GATT-SERVER] Error occurred, but completer already completed (late event handled)");
          _serviceAddedCompleter = null;
          return true;
        }
        _log("❌ [GATT-SERVER] Error waiting for onGattReady: $e");
        _serviceAddedCompleter = null;
        return false;
      }
    } catch (e) {
      _log("❌ [GATT-SERVER] Error starting server: $e");
      _serviceAddedCompleter = null;
      return false;
    }
  }

  /// Публичный метод для запуска GATT сервера (без ожидания)
  Future<void> startGattServer() async {
    await _startGattServer();
  }

  /// Запуск GATT-сервера в режиме призрак-релеятор (без проверки роли BRIDGE).
  /// Возвращает true при успешном старте или если сервер уже готов.
  Future<bool> startGattServerAsRelay() async {
    try {
      if (isInGattLifecycle) {
        _log("[RELAY-GATT] Already in GATT lifecycle, skip");
        return true;
      }
      return await _startGattServerAndWait();
    } catch (e) {
      _log("❌ [RELAY-GATT] Start failed: $e");
      return false;
    }
  }

  Future<void> _startGattServer() async {
    try {
      if (isInGattLifecycle) {
        _log(
            "[BLE-BLOCK] GATT server start skipped — GATT lifecycle active (role freeze)");
        return;
      }
      final raw = await _gattChannel.invokeMethod<dynamic>('startGattServer');
      final success = raw is Map ? (raw['success'] == true) : (raw == true);
      final gen = raw is Map ? (raw['generation'] as int?) : null;
      if (gen != null) _expectedGattGen = gen;
      if (success) {
        _log("✅ [GATT-SERVER] GATT server started successfully");
      } else {
        _log("⚠️ [GATT-SERVER] Failed to start GATT server");
      }
    } catch (e) {
      _log("❌ [GATT-SERVER] Error starting server: $e");
    }
  }

  /// 🔥 АВТОМАТИЧЕСКИЙ ЗАПУСК GATT SERVER ПРИ СТАРТЕ ПРИЛОЖЕНИЯ
  /// Оптимизирован для слабых устройств (Huawei, Xiaomi, Tecno, Infinix, Poco, Samsung)
  /// Запускается только для BRIDGE устройств
  Future<bool> autoStartGattServerIfBridge() async {
    try {
      // Проверяем роль устройства
      final currentRole = NetworkMonitor().currentRole;
      final isBridge = currentRole == MeshRole.BRIDGE;

      if (!isBridge) {
        _log(
            "ℹ️ [AUTO-GATT] Not a BRIDGE device, skipping GATT server auto-start");
        return false;
      }

      _log(
          "🚀 [AUTO-GATT] BRIDGE detected, starting GATT server automatically...");

      // 🔥 ОПТИМИЗАЦИЯ ДЛЯ СЛАБЫХ УСТРОЙСТВ: Проверяем состояние перед запуском
      // Убеждаемся, что предыдущие операции завершены
      // 🔒 Fix BLE state machine: Use event-driven approach
      if (_advState != BleAdvertiseState.idle) {
        _log("⏸️ [AUTO-GATT] BLE state is not idle ($_advState), waiting...");
        if (_stateIdleCompleter == null || _stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter = Completer<void>();
        }
        try {
          await _stateIdleCompleter!.future.timeout(const Duration(seconds: 3));
        } catch (e) {
          _log("⚠️ [AUTO-GATT] BLE state still not idle after wait, aborting");
          return false;
        }
      }

      // Проверяем, что advertising не активен
      try {
        final isAdvertising = await _blePeripheral.isAdvertising;
        if (isAdvertising) {
          _log(
              "⚠️ [AUTO-GATT] Advertising still active, stopping before GATT server start...");
          try {
            await _blePeripheral.stop();
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            _log("⚠️ [AUTO-GATT] Error stopping advertising: $e");
          }
        }
      } catch (e) {
        _log("⚠️ [AUTO-GATT] Error checking advertising state: $e");
      }

      // 🔥 ОПТИМИЗАЦИЯ: Задержка для стабилизации BLE стека на слабых устройствах
      await Future.delayed(const Duration(milliseconds: 800));

      // Запускаем GATT server и ждем готовности
      final serverStarted = await _startGattServerAndWait();

      if (serverStarted) {
        _log("✅ [AUTO-GATT] GATT server started successfully on app launch");
        return true;
      } else {
        _log(
            "⚠️ [AUTO-GATT] GATT server failed to start on app launch (will retry later)");
        return false;
      }
    } catch (e) {
      _log("❌ [AUTO-GATT] Error in auto-start: $e");
      return false;
    }
  }

  /// Вызывается из нативного кода при готовности GATT сервера (после onServiceAdded).
  /// INVARIANT: onGattReady MUST NOT be dropped (except stale generation). Late callbacks are accepted
  /// and applied so that GATT server ready state is never lost; completer is completed if a waiter exists.
  void _onGattReady({int? generation}) {
    _log("[GATT][STATE] onGattReady received (gen: $generation)");
    if (_expectedGattGen < 0) {
      _log("🚫 [GATT-SERVER] DROP onGattReady — server already stopped");
      _log("[GATT-GUARD] Rejecting onGattReady after stop");
      return;
    }
    if (generation != null && generation != _expectedGattGen) {
      _log(
          "🚫 [GATT-SERVER] DROP stale onGattReady — gen $generation != expected $_expectedGattGen (server restarted)");
      return;
    }
    _gattServerReady = true;
    final state = _stateMachine.state;
    if (state == BleState.IDLE || state == BleState.GATT_STARTING) {
      _stateMachine.forceTransition(BleState.GATT_READY);
      _log(
          "🔔 [GATT-SERVER] _onGattReady applied, FSM -> GATT_READY (native gen: $generation)");
    } else {
      _log(
          "🔔 [GATT-SERVER] _onGattReady accepted (late, state=$state); GATT server ready flag set");
    }
    if (_serviceAddedCompleter == null) {
      _log(
          "ℹ️ [GATT-SERVER] No active completer - onGattReady accepted (late/duplicate), no waiter");
    } else if (_serviceAddedCompleter!.isCompleted) {
      _log(
          "ℹ️ [GATT-SERVER] Completer already completed - onGattReady accepted (duplicate)");
    } else {
      _serviceAddedCompleter!.complete(true);
      _log(
          "✅ [GATT-SERVER] Completer completed - GATT server is ready (native gen: $generation)");
    }
  }

  /// Публичный метод для остановки GATT-сервера (в т.ч. при снятии режима RELAY).
  Future<void> stopGattServer() async {
    await _stopGattServer();
  }

  Future<void> _stopGattServer() async {
    try {
      await _gattChannel.invokeMethod('stopGattServer');
      _gattServerReady = false;
      _expectedGattGen = -1;
      _stateMachine.forceTransition(BleState.IDLE);
      _log("[GATT][STATE] gattReady -> idle (server stopped)");
      _log("🛑 [GATT-SERVER] GATT server stopped");
    } catch (e) {
      _log("⚠️ [GATT-SERVER] Error stopping server: $e");
    }
  }

  // ======================================================
  // 🧠 QUEUE & RESILIENCE
  // ======================================================

  Future<void> _processQueue() async {
    if (_isProcessingQueue || _taskQueue.isEmpty) return;
    _isProcessingQueue = true;

    while (_taskQueue.isNotEmpty) {
      final task = _taskQueue.removeFirst();
      _pendingDevices.remove(task.device.remoteId.str);
      await _sendWithDynamicRetries(task.device, task.message);
      await Future.delayed(const Duration(milliseconds: 800));
    }
    _isProcessingQueue = false;
  }

  // Внутри BluetoothMeshService.dart -> _sendWithDynamicRetries

  // Внутри BluetoothMeshService.dart

  // Внутри BluetoothMeshService

  Future<void> _sendWithDynamicRetries(
      BluetoothDevice device, String message) async {
    // 🔍🔍🔍 CRITICAL DIAGNOSTIC
    _log("🟡🟡🟡 [BT-CRITICAL] _sendWithDynamicRetries ENTERED!");

    final shortMac = device.remoteId.str.length > 8
        ? device.remoteId.str.substring(device.remoteId.str.length - 8)
        : device.remoteId.str;

    _log("🟡🟡🟡 [BT-CRITICAL] _sendWithDynamicRetries - shortMac: $shortMac");
    _log("🚀 [GATT-ENTRY] _sendWithDynamicRetries started for $shortMac");

    // Мини-проверка прав перед коннектом (Huawei/Tecno могут крашить без CONNECT)
    if (Platform.isAndroid && !await Permission.bluetoothConnect.isGranted) {
      _log("⛔ BT CONNECT permission missing, abort send.");
      throw Exception(
          "BT CONNECT permission missing"); // 🔥 FIX: throw, не return!
    }

    if (!canStartBleTransaction) {
      _log(
          "[BLE-BLOCK] New BLE attempt skipped: transaction=$_bleTransactionState, cooldown=${_globalCooldownExpired ? "expired" : "active"}");
      throw Exception(
          "BLE transaction not allowed: state=$_bleTransactionState");
    }
    final targetMac = device.remoteId.str;
    if (_isGattConnecting) {
      final elapsed = _gattConnectStartTime != null
          ? DateTime.now().difference(_gattConnectStartTime!).inSeconds
          : 0;

      if (elapsed > _gattConnectTimeout.inSeconds) {
        _releaseGattMutex(
            "force release stuck mutex (${elapsed}s > ${_gattConnectTimeout.inSeconds}s)");
      } else {
        final mutexCompleter = _gattMutexCompleter;
        if (mutexCompleter != null && !mutexCompleter.isCompleted) {
          _log(
              "🟡 [GATT-MUTEX] Waiting for existing session ($_currentGattTargetMac) to finish...");
          try {
            await mutexCompleter.future.timeout(const Duration(seconds: 2));
            await Future.delayed(const Duration(milliseconds: 120));
          } catch (_) {
            _log(
                "🚫 [GATT-MUTEX] Still busy after wait (${elapsed}s) — aborting to preserve timings");
            throw Exception("GATT connection already in progress");
          }
        } else {
          _log(
              "🟡 [GATT-MUTEX] Busy without completer handle, short backoff before retry");
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }

    if (_isGattConnecting) {
      _log(
          "🚫 [GATT-MUTEX] Connection still marked in progress after wait - aborting to avoid deadlock");
      throw Exception("GATT connection already in progress");
    }

    // 🔥 FIX: Захватываем GATT mutex
    _isGattConnecting = true;
    _gattConnectStartTime = DateTime.now();
    _currentGattTargetMac = targetMac;
    _gattConnectionState = 'CONNECTING';
    if (_gattMutexCompleter == null || _gattMutexCompleter!.isCompleted) {
      _gattMutexCompleter = Completer<void>();
    }
    _log("🔒 [GATT-MUTEX] Acquired - target: $targetMac");

    // 🔒 INVARIANT: Ensure peer is currently advertising connectable BEFORE we stop scan (enterCentralMode).
    // If lastScanResults empty, do a short rescan so we don't use stale or missing data.
    const Duration kScanResultStaleRescanDuration = Duration(seconds: 2);
    List<ScanResult> lastScanResults = await FlutterBluePlus.lastScanResults;
    if (lastScanResults.isEmpty && _bleTransactionState == BleTransactionState.IDLE) {
      _log(
          "🔍 [PRE-CONNECT] No scan results — brief rescan to ensure peer is advertising connectable");
      try {
        await FlutterBluePlus.startScan(
            timeout: kScanResultStaleRescanDuration,
            androidScanMode: isOutboxBoostActive
                ? AndroidScanMode.lowLatency
                : AndroidScanMode.balanced);
        await Future.delayed(const Duration(milliseconds: 2500));
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 200));
        lastScanResults = await FlutterBluePlus.lastScanResults;
      } catch (e) {
        _log("⚠️ [PRE-CONNECT] Rescan failed: $e");
      }
    }

    await enterCentralMode();
    _transitionTransaction(BleTransactionState.CONNECTING);
    _log("🚀 [GATT-DATA-ATTACK] Target: ${device.remoteId}");

    // 🔥 КРИТИЧЕСКАЯ ПРОВЕРКА: Убеждаемся, что устройство рекламирует наш сервис
    // Это важно, так как без SERVICE_UUID подключение не имеет смысла
    bool hasServiceUuid = false;
    String? deviceLocalName;
    bool canProceed = false;
    String?
        originalAdvName; // Сохраняем оригинальное имя для проверки изменений
    bool hasTacticalName = false; // Объявляем вне блока для доступа везде
    bool isBridgeByMfData = false; // Объявляем вне блока для доступа везде
    bool isGhostByMfData =
        false; // GHOST = 0x47 0x48 ("GH") — валидный mesh узел для GATT

    try {
      _log(
          "🔍 [PRE-CONNECT] Checking scan results (total: ${lastScanResults.length})...");
      if (kMeshDiagnostics && lastScanResults.isNotEmpty) {
        final ctx = await getDiagnosticContext();
        for (final r in lastScanResults) {
          final mf = r.advertisementData.manufacturerData;
          final mfStr = mf.isEmpty
              ? 'none'
              : mf.entries.map((e) => '${e.key}:${e.value.length}').join(';');
          _log(meshDiagLog('ble_scan_result_received', {
            'device': r.device.remoteId.str,
            'rssi': '${r.rssi}',
            'manufacturerData': mfStr,
            'elapsedMs': '0',
            ...ctx,
          }));
        }
      }
      if (lastScanResults.isEmpty) {
        _log(
            "⚠️ [WARNING] No scan results after rescan. Device may have stopped advertising.");
        _log(
            "   🔥 HUAWEI FIX: Proceeding with connection anyway (scan may be stopped)");
        canProceed = true;
      } else {
        // 🔥 HUAWEI FIX: Ищем устройство по MAC и manufacturerData (для рандомизированных MAC)
        ScanResult? deviceScanResult;
        final targetMac = device.remoteId.str;

        try {
          // Сначала пытаемся найти по точному device.remoteId
          deviceScanResult = lastScanResults.firstWhere(
            (r) => r.device.remoteId == device.remoteId,
          );
        } catch (e) {
          // Fallback 1: Ищем по MAC адресу
          try {
            deviceScanResult = lastScanResults.firstWhere(
              (r) => r.device.remoteId.str == targetMac,
            );
            _log("✅ [PRE-CONNECT] Found device by MAC fallback: $targetMac");
          } catch (e2) {
            // Fallback 2: Ищем по manufacturerData (BR или GH) или service UUID (для рандомизированных MAC на Huawei)
            for (final result in lastScanResults) {
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
              final isBridgeByMf = mfData != null &&
                  mfData.length >= 2 &&
                  (mfData[0] == 0x42 || mfData[0] == 66) &&
                  (mfData[1] == 0x52 || mfData[1] == 82); // "BR"
              final isGhostByMf = mfData != null &&
                  mfData.length >= 2 &&
                  (mfData[0] == 0x47 || mfData[0] == 71) &&
                  (mfData[1] == 0x48 || mfData[1] == 72); // "GH"
              final hasService = result.advertisementData.serviceUuids.any(
                  (uuid) =>
                      uuid.toString().toLowerCase() ==
                      SERVICE_UUID.toLowerCase());
              if ((isBridgeByMf || isGhostByMf || hasService) &&
                  result.device.remoteId.str == targetMac) {
                deviceScanResult = result;
                _log(
                    "✅ [PRE-CONNECT] Found device by manufacturerData/service fallback: $targetMac");
                break;
              }
            }

            if (deviceScanResult == null) {
              _log(
                  "⚠️ [WARNING] Device not found in scan results, but proceeding anyway (Huawei quirk)");
              canProceed = true; // Продолжаем без scan result на Huawei
            }
          }
        }

        if (deviceScanResult != null) {
          deviceLocalName = deviceScanResult.advertisementData.localName;
          originalAdvName = deviceLocalName; // Сохраняем для проверки изменений
          hasServiceUuid = deviceScanResult.advertisementData.serviceUuids.any(
              (uuid) =>
                  uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase());

          // 🔥 HUAWEI/TECNO FIX: manufacturerData — извлечение по значениям (ключ на Tecno/других может быть не 0xFFFF)
          final mfMap = deviceScanResult.advertisementData.manufacturerData;
          List<int>? mfData = mfMap[0xFFFF] ?? mfMap[65535];
          if (mfData == null && mfMap.isNotEmpty) {
            for (final entry in mfMap.entries) {
              final v = entry.value;
              if (v is! List || v.length < 2) continue;
              final a =
                  v[0] is int ? v[0] as int : int.tryParse(v[0].toString());
              final b =
                  v[1] is int ? v[1] as int : int.tryParse(v[1].toString());
              if (a == null || b == null) continue;
              if ((a == 0x47 && b == 0x48) ||
                  (a == 71 && b == 72) ||
                  (a == 0x42 && b == 0x52) ||
                  (a == 66 && b == 82)) {
                mfData = v is List<int> ? v : List<int>.from(v);
                break;
              }
            }
          }
          // Доп. fallback: по значениям (не по ключу) — на Tecno/других ключ может быть другой тип
          if (mfData == null && mfMap.isNotEmpty) {
            for (final v in mfMap.values) {
              if (v is! List || v.length < 2) continue;
              final a =
                  v[0] is int ? v[0] as int : int.tryParse(v[0].toString());
              final b =
                  v[1] is int ? v[1] as int : int.tryParse(v[1].toString());
              if (a == null || b == null) continue;
              if ((a == 0x47 && b == 0x48) ||
                  (a == 71 && b == 72) ||
                  (a == 0x42 && b == 0x52) ||
                  (a == 66 && b == 82)) {
                mfData = v is List<int> ? v : List<int>.from(v);
                break;
              }
            }
          }
          isBridgeByMfData = mfData != null &&
              mfData.length >= 2 &&
              (mfData[0] == 0x42 || mfData[0] == 66) &&
              (mfData[1] == 0x52 || mfData[1] == 82); // "BR" = BRIDGE
          isGhostByMfData = mfData != null &&
              mfData.length >= 2 &&
              (mfData[0] == 0x47 || mfData[0] == 71) &&
              (mfData[1] == 0x48 || mfData[1] == 72); // "GH" = GHOST
          final isMeshByMfData = isBridgeByMfData || isGhostByMfData;

          // Определяем hasTacticalName
          hasTacticalName = deviceLocalName?.startsWith("M_") ?? false;

          _log("🔍 [PRE-CONNECT] Device scan data:");
          _log("   Local name: '${deviceLocalName ?? 'NONE'}'");
          _log("   Has SERVICE_UUID: $hasServiceUuid");
          _log("   Is BRIDGE by manufacturerData: $isBridgeByMfData");
          _log("   Is GHOST by manufacturerData: $isGhostByMfData");
          _log("   Has tactical name: $hasTacticalName");
          _log(
              "   Available UUIDs: ${deviceScanResult.advertisementData.serviceUuids.map((u) => u.toString()).join(', ')}");
          _log(
              "   Manufacturer data: ${deviceScanResult.advertisementData.manufacturerData}");

          // 🔥 HUAWEI/TECNO/INFINIX QUIRK: Устройства часто не рекламируют local name, но рекламируют SERVICE_UUID или manufacturerData (BR или GH)
          // Валидный mesh узел: SERVICE_UUID, tactical name (M_*), или manufacturerData BR/GH
          if (!hasServiceUuid && !hasTacticalName && !isMeshByMfData) {
            _log(
                "❌ [CRITICAL] Target device ${device.remoteId} does NOT advertise SERVICE_UUID, tactical name, or manufacturerData (BR/GH)");
            _log("   Cannot connect - device is not a valid mesh node");
            // 🔥 FIX: Release GATT mutex and throw exception for proper error handling
            _releaseGattMutex(
                "pre-connect validation failed - not a valid mesh node",
                state: 'FAILED');
            throw Exception(
                "Device is not a valid mesh node (no SERVICE_UUID, tactical name, or manufacturerData)");
          }

          canProceed = true; // Устройство валидно
        } else {
          // Если deviceScanResult == null, но canProceed уже установлен (Huawei quirk)
          // Проверяем дополнительные условия
          if (!canProceed) {
            // 🔥 TECNO: Если local name пустое, но есть SERVICE_UUID или manufacturerData - это нормально
            if (deviceLocalName?.isEmpty ?? true) {
              if (hasServiceUuid) {
                _log(
                    "ℹ️ [TECNO/INFINIX] Local name is empty, but SERVICE_UUID is present - this is normal for these devices");
                canProceed = true;
              } else if (isBridgeByMfData || isGhostByMfData) {
                // 🔥 FIX: Allow connection if BRIDGE or GHOST detected via manufacturerData (Huawei/Tecno quirk)
                _log(
                    "ℹ️ [HUAWEI/TECNO] Local name is empty and no SERVICE_UUID, but mesh node (BR/GH) detected via manufacturerData - proceeding");
                canProceed = true;
              } else {
                _log(
                    "⚠️ [WARNING] Local name is empty, no SERVICE_UUID, no manufacturerData - aborting connection");
                _releaseGattMutex("no valid mesh indicators", state: 'FAILED');
                throw Exception(
                    "Device has no SERVICE_UUID, tactical name, or manufacturerData");
              }
            }

            if (!hasServiceUuid && hasTacticalName) {
              _log(
                  "⚠️ [WARNING] Device has tactical name but no SERVICE_UUID (Huawei/Tecno quirk?)");
              _log(
                  "   Will attempt connection anyway, but service discovery may fail");
              canProceed = true;
            }

            if (hasServiceUuid) {
              _log(
                  "✅ [VERIFY] Target device advertises SERVICE_UUID ($SERVICE_UUID)");
              canProceed = true;
            }

            // 🔥 FIX: Allow connection if BRIDGE or GHOST detected via manufacturerData
            if (!canProceed && (isBridgeByMfData || isGhostByMfData)) {
              _log(
                  "✅ [VERIFY] Mesh node (BR/GH) detected via manufacturerData - proceeding");
              canProceed = true;
            }
          }
        }
      }
    } catch (e) {
      _log("❌ [ERROR] Could not verify SERVICE_UUID before connection: $e");
      // Если это критическая ошибка (устройство не найдено или не рекламирует) - не продолжаем
      if (e.toString().contains("does not advertise required service") ||
          e.toString().contains("not a valid mesh node") ||
          e.toString().contains("not found in last scan results")) {
        _log(
            "🚫 [ABORT] Cannot proceed with connection - device is not valid or not found");
        // 🔥 FIX: Release GATT mutex and rethrow
        _releaseGattMutex("pre-connect exception", state: 'FAILED');
        rethrow; // Propagate the exception
      }
      _log(
          "⚠️ [WARNING] Will attempt connection anyway, but may fail if service is not available");
      canProceed = true; // Продолжаем только если это не критическая ошибка
    }

    // Если проверка не прошла - не продолжаем
    if (!canProceed) {
      _log(
          "🚫 [ABORT] Pre-connect verification failed. Aborting GATT connection attempts.");
      // 🔥 FIX: Release GATT mutex and throw exception
      _releaseGattMutex("pre-connect verification failed", state: 'FAILED');
      throw Exception("Pre-connect verification failed - canProceed is false");
    }

    // Подписка на состояние подключения (важно для Tecno/MTK)
    StreamSubscription<BluetoothConnectionState>? stateSub;

    // Глобальный таймер на всю сессию GATT (чтобы не висеть вечно на проблемном чипе)
    final DateTime sessionStart = DateTime.now();
    const Duration maxSessionDuration =
        Duration(seconds: 60); // Увеличено для проблемных устройств

    bool delivered = false;

    for (int attempt = 1; attempt <= 3; attempt++) {
      // Если мы уже слишком долго мучаем одно устройство — выходим и даем каскаду перейти на другие каналы
      final elapsed = DateTime.now().difference(sessionStart);
      if (elapsed > maxSessionDuration) {
        _log(
            "⏱️ GATT session timed out globally after ${elapsed.inSeconds}s (max: ${maxSessionDuration.inSeconds}s). Aborting.");
        break;
      }

      // Логируем прогресс каждые 10 секунд
      if (elapsed.inSeconds > 0 && elapsed.inSeconds % 10 == 0) {
        _log(
            "⏳ [PROGRESS] GATT session in progress: ${elapsed.inSeconds}s elapsed, attempt $attempt/3");
      }

      // 🔥 FIX: УБРАНА ПРОВЕРКА lastScanResults ПОСЛЕ ОСТАНОВКИ SCAN
      // После stopScan() lastScanResults пустой, что вызывало мгновенный break
      // Мы уже проверили устройство ДО остановки scan - повторная проверка невозможна
      // GHOST уже сохранил ScanResult - используем его напрямую
      _log(
          "📋 [ATTEMPT $attempt] Skipping scan results check (scan already stopped)");
      _log("   📋 Using pre-verified device: ${device.remoteId}");
      _log("   📋 Pre-verified SERVICE_UUID: $hasServiceUuid");
      _log("   📋 Pre-verified BRIDGE by mfData: $isBridgeByMfData");
      try {
        // 🔥 ШАГ 1: Проверка состояния BLE адаптера
        final adapterState = await FlutterBluePlus.adapterState.first.timeout(
          const Duration(seconds: 2),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
        if (adapterState != BluetoothAdapterState.on) {
          _log("⚠️ BLE adapter is OFF. Attempting to turn on...");
          if (Platform.isAndroid) {
            try {
              await FlutterBluePlus.turnOn();
              await Future.delayed(const Duration(seconds: 2));
            } catch (e) {
              _log("❌ Failed to turn on BLE: $e");
              throw Exception("BLE adapter unavailable");
            }
          } else {
            throw Exception("BLE adapter unavailable");
          }
        }

        // 🔥 ШАГ 2: Останавливаем ВСЁ перед connect (GHOST протокол)
        // 🔄 Use FSM for state transition
        try {
          await _stateMachine.transition(BleState.CONNECTING);
        } catch (e) {
          _log("⚠️ [GATT] Invalid state transition to CONNECTING: $e");
        }
        _advState = BleAdvertiseState.connecting;

        _log("🛑 [GHOST] Stopping ALL BLE operations before connect...");

        // Останавливаем сканирование
        try {
          await FlutterBluePlus.stopScan();
          _log("✅ [GHOST] Scan stopped");
        } catch (e) {
          _log("⚠️ [GHOST] Error stopping scan: $e");
        }

        // Останавливаем advertising (если было)
        try {
          final isAdvertising = await _blePeripheral.isAdvertising;
          if (isAdvertising) {
            await _blePeripheral.stop();
            _log("✅ [GHOST] Advertising stopped");
          }
        } catch (e) {
          _log("⚠️ [GHOST] Error stopping advertising: $e");
        }

        // 🔒 Stack already clean from enterCentralMode(); short pause only if we just stopped adv in-loop.
        final pauseDuration = const Duration(milliseconds: 200);
        _log(
            "⏸️ [GHOST] Waiting ${pauseDuration.inMilliseconds}ms for BLE stack...");
        await Future.delayed(pauseDuration);

        // 🔥 ШАГ 3: АГРЕССИВНАЯ ОЧИСТКА ЗАВИСШЕГО СОЕДИНЕНИЯ
        // Проверяем текущее состояние и принудительно отключаемся
        try {
          final currentState = await device.connectionState.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => BluetoothConnectionState.disconnected,
          );
          _log("🔍 Current connection state: $currentState");

          if (currentState == BluetoothConnectionState.connected ||
              currentState == BluetoothConnectionState.connecting) {
            _log("🔌 Force disconnecting from previous session...");
            await device.disconnect();
            // Ждем подтверждения отключения
            await device.connectionState
                .where((s) => s == BluetoothConnectionState.disconnected)
                .first
                .timeout(const Duration(seconds: 3), onTimeout: () {
              _log("⚠️ Disconnect timeout, continuing anyway...");
              return BluetoothConnectionState.disconnected;
            });
          }
        } catch (e) {
          _log("⚠️ Disconnect cleanup warning: $e");
        }

        await Future.delayed(const Duration(milliseconds: 300));

        // Ожидаем состояние connected через stream
        final connCompleter = Completer<bool>();
        stateSub = device.connectionState.listen((s) {
          if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
            final elapsed =
                DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
            final stateStr = s == BluetoothConnectionState.connected
                ? 'connected'
                : s == BluetoothConnectionState.disconnected
                    ? 'disconnected'
                    : s == BluetoothConnectionState.connecting
                        ? 'connecting'
                        : 'unknown';
            _log(meshDiagLog('onConnectionStateChange_client', {
              'state': stateStr,
              'target': device.remoteId.str,
              'elapsedMs': '$elapsed',
              ...?_diagnosticContext,
            }));
          }
          if (s == BluetoothConnectionState.connected &&
              !connCompleter.isCompleted) {
            connCompleter.complete(true);
          } else if (s == BluetoothConnectionState.disconnected &&
              !connCompleter.isCompleted) {
            connCompleter.complete(false);
          }
        });

        final elapsed = DateTime.now().difference(sessionStart);
        _log("🔗 GATT Attempt $attempt/3: Connecting to ${device.remoteId}...");
        _log(
            "   Device name: ${device.platformName.isNotEmpty ? device.platformName : 'Unknown'}");
        _log("   Device ID: ${device.remoteId}");
        _log(
            "   Session elapsed: ${elapsed.inSeconds}s / ${maxSessionDuration.inSeconds}s");

        // 🔥 УВЕЛИЧЕННЫЙ ТАЙМАУТ ДЛЯ TECNO/INFINIX: 15s для первой попытки, 20s для второй, 25s для третьей
        // Эти устройства требуют больше времени для установления GATT соединения
        final timeoutDuration = Duration(seconds: 15 + (attempt * 5));
        _log(
            "   Connection timeout: ${timeoutDuration.inSeconds}s (extended for problematic devices)");

        // 🔥 FIX: Убрана проверка visibility - она fail'илась из-за MAC рандомизации
        // GHOST уже получил ScanResult с BRIDGE - этого достаточно для GATT connect
        // MAC может измениться между scan и connect на Android (особенно Huawei)
        _log(
            "📡 [GATT] Skipping visibility check (MAC randomization workaround)");
        _log("   📋 Proceeding with saved device reference directly");

        if (kMeshDiagnostics) {
          _diagnosticAttemptStartTime = DateTime.now();
          _diagnosticContext = await getDiagnosticContext();
          _diagnosticFirstNotifyLogged = false;
          _diagnosticFirstWriteLogged = false;
          final targetMac = device.remoteId.str;
          _log(meshDiagLog('connect_attempt_start', {
            'role': 'CENTRAL',
            'target': targetMac,
            'timeoutSec': '${timeoutDuration.inSeconds}',
            'elapsedMs': '0',
            'attempt': '$attempt',
            ...?_diagnosticContext,
          }));
        }
        _log("📡 [CONNECT] Initiating connection...");
        _log("   📋 Target device: ${device.remoteId}");
        _log("   📋 Timeout: ${timeoutDuration.inSeconds}s");
        _log("   📋 Auto-connect: false");

        // 🔥 FIX: Проверяем Bluetooth adapter state перед connect
        final adapterStateNow = FlutterBluePlus.adapterStateNow;
        _log("   📋 Bluetooth adapter: $adapterStateNow");
        if (adapterStateNow != BluetoothAdapterState.on) {
          _log("❌ [CONNECT] Bluetooth adapter not ready: $adapterStateNow");
          throw Exception("Bluetooth adapter not ready: $adapterStateNow");
        }

        // 🔥 FIX: Принудительный disconnect перед connect (очистка stale connection)
        try {
          if (device.isConnected) {
            _log("⚠️ [CONNECT] Device already connected - disconnecting first");
            await device.disconnect();
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } catch (e) {
          _log("⚠️ [CONNECT] Pre-disconnect warning: $e");
        }

        final connectStart = DateTime.now();

        final staggerMs = (DateTime.now().millisecondsSinceEpoch % 300);
        if (staggerMs > 50) {
          _log("⏱️ [GATT] Stagger ${staggerMs}ms before connect");
          await Future.delayed(Duration(milliseconds: staggerMs));
        }

        // 🔥 FIX: Добавляем progress timer для диагностики
        Timer? progressTimer;
        progressTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
          final elapsed = DateTime.now().difference(connectStart).inSeconds;
          _log(
              "⏳ [CONNECT] Still waiting for connection... (${elapsed}s elapsed)");
          _log("   📋 device.isConnected: ${device.isConnected}");
        });

        try {
          _log("🦷🔍 [BT-DIAG] CALLING device.connect() NOW...");
          _log("🚀 [CONNECT] Calling device.connect()...");
          await device.connect(timeout: timeoutDuration, autoConnect: false);
          _log("🦷🔍 [BT-DIAG] device.connect() RETURNED!");
          _log("✅ [CONNECT] device.connect() returned successfully");
        } catch (connectError) {
          _log("🦷🔍 [BT-DIAG] device.connect() EXCEPTION: $connectError");
          _log("❌ [CONNECT] device.connect() failed: $connectError");
          if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
            final durationMs =
                DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
            _log(meshDiagLog('disconnect', {
              'target': device.remoteId.str,
              'reason': 'connect_failed',
              'durationMs': '$durationMs',
              'elapsedMs': '$durationMs',
              'error': connectError.toString().replaceAll(' ', '_'),
              ...?_diagnosticContext,
            }));
          }
          // 🔥 FIX: Принудительный disconnect при ошибке connect
          try {
            await device.disconnect();
            _log("🔌 [CONNECT] Forced disconnect after connect failure");
            try {
              locator<MeshService>().reportMeshHealthBleDisconnect();
              locator<MeshService>().resetCrdtSessionForPeer(device.remoteId.str);
            } catch (_) {}
          } catch (e) {
            _log("⚠️ [CONNECT] Cleanup disconnect failed: $e");
          }
          throw connectError;
        } finally {
          progressTimer?.cancel();
        }

        // 🔥🔥🔥 CRITICAL FIX: Проверяем device.isConnected СРАЗУ после connect()
        // НЕ ждём stream events - они могут быть ненадёжными на Android/Huawei
        bool connected = false;
        try {
          _log("🦷🔍 [BT-DIAG] Checking connection state immediately...");
          _log(
              "⏳ [CONNECT] Checking connection state IMMEDIATELY (not waiting for stream)...");

          // Сначала проверяем device.isConnected напрямую
          final directCheck = device.isConnected;
          _log("   📋 Direct device.isConnected: $directCheck");
          _log("🦷🔍 [BT-DIAG] Direct isConnected: $directCheck");

          if (directCheck) {
            // Если device.connect() вернулся успешно И isConnected=true,
            // НЕ ЖДЁМ stream - сразу идём дальше!
            _log(
                "✅ [CONNECT] Connection confirmed via direct check - skipping stream wait!");
            connected = true;
          } else {
            // Если direct check = false, даём stream шанс (может быть задержка)
            _log(
                "⚠️ [CONNECT] Direct check=false, waiting for stream (max 2s)...");

            connected = await connCompleter.future.timeout(
              const Duration(seconds: 2), // 🔥 Уменьшили с 4s до 2s
              onTimeout: () {
                _log("⚠️ [CONNECT] Stream timeout, final check...");
                final finalState = device.isConnected;
                _log("   📋 Final device.isConnected: $finalState");
                return finalState;
              },
            );
          }

          _log("✅ [CONNECT] Connection result: $connected");
          _log("🦷🔍 [BT-DIAG] Connection result: $connected");
        } catch (e) {
          _log("⚠️ [CONNECT] Connection confirmation error: $e");
          _log("🦷🔍 [BT-DIAG] Connection check error: $e");
          await Future.delayed(const Duration(milliseconds: 300));
          connected = device.isConnected;
          _log("   📋 Fallback check - device.isConnected: $connected");
        }

        final connectElapsed = DateTime.now().difference(connectStart);
        _log("📊 [CONNECT] Connection attempt summary:");
        _log("   📋 Elapsed time: ${connectElapsed.inSeconds}s");
        _log("   📋 Connected: $connected");
        _log("   📋 device.isConnected: ${device.isConnected}");

        if (!connected) {
          _log(
              "❌ [CONNECT] Failed after ${connectElapsed.inSeconds}s - device not connected");

          // 🔥 FIX: Update GATT connection state on failure
          _gattConnectionState = 'FAILED';
          _log("🔗 [GATT-STATE] State: FAILED");

          _log("   📋 Device: ${device.remoteId}");
          _log("   📋 Connection state: ${device.isConnected}");
          _log("   📋 Connection elapsed: ${connectElapsed.inSeconds}s");
          _log("   💡 Possible reasons:");
          _log("      1. BRIDGE GATT server not running or not ready");
          _log(
              "      2. BRIDGE advertising not active (SERVICE_UUID not advertised)");
          _log("      3. Device out of range or stopped advertising");
          _log(
              "      4. BLE stack issue on BRIDGE device (Huawei/Android BLE limitations)");
          _log("      5. BRIDGE GATT server crashed or not started");
          _log("      6. Permission issues on BRIDGE device");
          _log("   🔍 Check BRIDGE logs for:");
          _log("      - GATT server start status");
          _log("      - Advertising status");
          _log("      - onGattClientConnected events");
          throw Exception(
              "No connect state after ${connectElapsed.inSeconds}s");
        }

        _log(
            "✅ [SUCCESS] Link Established after ${connectElapsed.inSeconds}s!");
        _gattConnectionState = 'CONNECTED';
        try {
          locator<MeshService>().reportMeshHealthBleConnectionSuccess();
        } catch (_) {}
        try {
          await _stateMachine.transition(BleState.CONNECTED);
        } catch (e) {
          _log("⚠️ [GATT] Invalid state transition to CONNECTED: $e");
        }
        _advState = BleAdvertiseState.connected;

        _transitionTransaction(BleTransactionState.STABILIZING_POST_CONNECT);
        _log(
            "[BLE-TIMING] Post-connect stabilization: ${_postConnectStabilizationMs}ms");
        await Future.delayed(
            Duration(milliseconds: _postConnectStabilizationMs));
        _transitionTransaction(BleTransactionState.DISCOVERING);
        _log("🔍 [DISCOVERY] Starting service discovery...");

        // 🔥🔥🔥 CRITICAL FIX: MTU request может вызывать disconnect на Huawei/Honor!
        // Пропускаем MTU request для стабильности - используем default MTU (23 bytes - 3 header = 20 bytes payload)
        // Если нужен большой MTU, лучше использовать фрагментацию
        if (Platform.isAndroid) {
          // Проверяем соединение ПЕРЕД MTU request
          if (!device.isConnected) {
            _log("❌ [MTU] Connection lost BEFORE MTU request!");
            print("🦷🔍 [BT-DIAG] Connection lost before MTU!");
            throw Exception("Connection lost before MTU request");
          }

          try {
            _log(
                "📐 [MTU] Requesting MTU 158 (safe value for most devices)...");
            _log("🦷🔍 [BT-DIAG] Requesting MTU...");
            await _enqueueGattOperation(() => device.requestMtu(158));
            await Future.delayed(
                const Duration(milliseconds: 300)); // 🔥 Увеличили паузу

            // 🔥 CRITICAL: Проверяем что соединение не разорвалось после MTU request!
            if (!device.isConnected) {
              _log(
                  "❌ [MTU] Connection lost AFTER MTU request - Huawei quirk detected!");
              _log(
                  "🦷🔍 [BT-DIAG] Connection lost after MTU - reconnecting...");
              // Пробуем переподключиться без MTU request
              throw Exception(
                  "MTU request caused disconnect - will retry without MTU");
            }
            _log("✅ [MTU] MTU request successful, connection still active");
          } catch (e) {
            _log("⚠️ MTU request failed: $e");
            _log("🦷🔍 [BT-DIAG] MTU failed: $e");
            // Проверяем соединение после ошибки
            if (!device.isConnected) {
              _log("❌ [MTU] Connection lost after MTU error!");
              throw Exception("MTU request caused connection loss");
            }
          }
        }

        // 🔥 CRITICAL: Финальная проверка соединения перед service discovery
        if (!device.isConnected) {
          _log("❌ [PRE-DISCOVERY] Connection lost before service discovery!");
          _log("🦷🔍 [BT-DIAG] Connection lost before discovery!");
          throw Exception("Connection lost before service discovery");
        }

        _log("🦷🔍 [BT-DIAG] Starting service discovery...");
        _log("🔍 [DISCOVERY] Starting service discovery...");

        // 🔥🔥🔥 CRITICAL FIX: clearGattCache может вызывать disconnect на Huawei!
        // Пропускаем его для стабильности - лучше иметь stale cache чем потерять соединение
        // Если service discovery не найдёт сервис, сделаем cache clear и retry
        bool skipCacheClear =
            true; // 🔥 По умолчанию пропускаем для стабильности

        if (!skipCacheClear) {
          try {
            _log("🦷🔍 [BT-DIAG] Clearing GATT cache...");
            _log("🧹 [DISCOVERY] Clearing GATT cache (Android fix)...");
            await device.clearGattCache();
            await Future.delayed(const Duration(milliseconds: 300));

            // 🔥 CRITICAL: Проверяем соединение после cache clear!
            if (!device.isConnected) {
              _log(
                  "❌ [DISCOVERY] Connection lost after cache clear - Huawei quirk!");
              _log("🦷🔍 [BT-DIAG] Connection lost after cache clear!");
              throw Exception("Cache clear caused disconnect");
            }
            _log("✅ [DISCOVERY] GATT cache cleared, connection still active");
          } catch (e) {
            _log("🦷🔍 [BT-DIAG] GATT cache clear failed: $e");
            _log("⚠️ [DISCOVERY] GATT cache clear failed: $e");
            if (!device.isConnected) {
              throw Exception("Cache clear caused connection loss");
            }
          }
        } else {
          _log(
              "ℹ️ [DISCOVERY] Skipping GATT cache clear (stability mode for Huawei/Honor)");
        }
        if (!device.isConnected) {
          _log("❌ [DISCOVERY] Connection lost before discoverServices!");
          throw Exception("Connection lost before discoverServices");
        }
        if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
          final elapsed =
              DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
          _log(meshDiagLog('service_discovery_start', {
            'target': device.remoteId.str,
            'elapsedMs': '$elapsed',
            ...?_diagnosticContext,
          }));
        }
        final discoveryStart = DateTime.now();
        List<BluetoothService> services = await device.discoverServices();
        final discoveryElapsed = DateTime.now().difference(discoveryStart);
        if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
          final elapsed =
              DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
          _log(meshDiagLog(services.isEmpty ? 'service_discovery_fail' : 'service_discovery_success', {
            'target': device.remoteId.str,
            'servicesCount': '${services.length}',
            'discoverMs': '${discoveryElapsed.inMilliseconds}',
            'elapsedMs': '$elapsed',
            ...?_diagnosticContext,
          }));
        }
        _log(
            "[BLE-TIMING] discoverServices() took ${discoveryElapsed.inMilliseconds}ms, got ${services.length} services");
        if (services.isEmpty) {
          _log(
              "[BLE-TIMING] No services, retry after ${_discoverRetryDelayMs}ms");
          await Future.delayed(Duration(milliseconds: _discoverRetryDelayMs));
          services = await device.discoverServices();
          _log("🔄 [DISCOVERY] Retry found ${services.length} services");
        }
        _log("[BLE-TIMING] Post-discover settle: ${_postDiscoverSettleMs}ms");
        await Future.delayed(Duration(milliseconds: _postDiscoverSettleMs));

        // 🔍 ДЕТАЛЬНАЯ ПРОВЕРКА: Есть ли наш сервис на втором телефоне?
        _log(
            "🔍 [DISCOVERY] Found ${services.length} services. Looking for $SERVICE_UUID...");
        _log(
            "   All services: ${services.map((s) => s.uuid.toString()).join(', ')}");

        var matchingServices = services
            .where((s) =>
                s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase())
            .toList();

        if (matchingServices.isEmpty) {
          _log(
              "⚠️ [DISCOVERY] Service $SERVICE_UUID not found, retry once after ${_discoverRetryDelayMs}ms");
          await Future.delayed(Duration(milliseconds: _discoverRetryDelayMs));
          services = await device.discoverServices();
          matchingServices = services
              .where((s) =>
                  s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase())
              .toList();
          if (matchingServices.isNotEmpty)
            _log("✅ [DISCOVERY] Service found on retry");
        }
        if (matchingServices.isEmpty) {
          _log(
              "❌ [CRITICAL] Target device does NOT have our service ($SERVICE_UUID)");
          _log(
              "   This means the device is not advertising the service correctly");
          _log("   Available services:");
          for (var svc in services) {
            _log(
                "     - ${svc.uuid} (${svc.characteristics.length} characteristics)");
          }

          // 🔥 ДЛЯ HUAWEI/TECNO: Если устройство имеет тактическое имя, но нет сервиса
          // это может быть проблема с рекламой. Пробуем найти похожий сервис
          if (deviceLocalName?.startsWith("M_") ?? false) {
            _log(
                "⚠️ Device has tactical name but service not found - this is a critical issue");
            _log(
                "   The device should be advertising SERVICE_UUID but it's missing");
            _log("   Possible causes:");
            _log("   1. Device stopped advertising");
            _log("   2. BLE stack issue on target device");
            _log("   3. Permission issue on target device");
          }

          throw Exception(
              "Service $SERVICE_UUID not found on target device. Device may not be advertising correctly.");
        }

        final s = matchingServices.first;
        _log("✅ Service found! Looking for characteristic $CHAR_UUID...");

        final matchingChars = s.characteristics
            .where((c) => c.uuid.toString() == CHAR_UUID)
            .toList();
        if (matchingChars.isEmpty) {
          _log(
              "❌ [CRITICAL] Characteristic $CHAR_UUID not found. Available characteristics:");
          for (var ch in s.characteristics) {
            _log(
                "   - ${ch.uuid} (write: ${ch.properties.write}, notify: ${ch.properties.notify})");
          }
          throw Exception("Characteristic $CHAR_UUID not found");
        }

        final c = matchingChars.first;
        _log(
            "✅ Characteristic found! Properties: write=${c.properties.write}, notify=${c.properties.notify}");

        // 🔥 BRIDGE→GHOST: подписываемся на notify, чтобы получать сообщения от BRIDGE после отправки
        // 🔥 BLE FIX: Ограничиваем ожидание 6s (FBP по умолчанию 15s) — не сжигаем batch 35s при медленной периферии
        StreamSubscription<List<int>>? notifySub;
        if (c.properties.notify) {
          if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
            final elapsed =
                DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
            _log(meshDiagLog('notify_enable_start', {
              'target': device.remoteId.str,
              'timeoutSec': '$_notifyEnableTimeoutSeconds',
              'elapsedMs': '$elapsed',
              ...?_diagnosticContext,
            }));
          }
          try {
            await _enqueueGattOperation(() => c.setNotifyValue(true).timeout(
              Duration(seconds: _notifyEnableTimeoutSeconds),
              onTimeout: () => throw TimeoutException('Notify enable'),
            ));
            if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
              final elapsed =
                  DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
              _log(meshDiagLog('notify_enable_success', {
                'target': device.remoteId.str,
                'elapsedMs': '$elapsed',
                ...?_diagnosticContext,
              }));
            }
            _ghostNotifyBuffer.clear();
            _ghostNotifyExpectedLength = -1;
            final bridgeAddress = device.remoteId.str;
            notifySub = c.lastValueStream.listen(
              (value) => _onNotifyChunkFromBridge(bridgeAddress, value),
              onError: (e) => _log("⚠️ [GHOST] Notify stream error: $e"),
            );
            _log(
                "📥 [GHOST] Subscribed to BRIDGE notify - can receive relayed messages");
          } catch (e) {
            if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
              final elapsed =
                  DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
              _log(meshDiagLog('notify_enable_timeout', {
                'target': device.remoteId.str,
                'elapsedMs': '$elapsed',
                'error': e.toString().replaceAll(' ', '_'),
                ...?_diagnosticContext,
              }));
            }
            _log("⚠️ [GHOST] Could not enable notify: $e");
          }
        } else {
          _log(
              "ℹ️ [GHOST] Characteristic does not support notify - BRIDGE→GHOST relay may not work");
        }

        recordBleInteraction(BleInteractionStats(
          peerId: device.remoteId.str,
          attemptedAction: BleAttemptedAction.connect,
          result: BleInteractionResult.success,
          timestamp: DateTime.now(),
        ));
        _transitionTransaction(BleTransactionState.TRANSFERRING);
        // 🔥 LENGTH-PREFIXED FRAMING: Формат [4 bytes: length (Big-Endian)][N bytes: JSON]
        _log("📤 [WRITE] Fragmenting message (${message.length} chars)...");
        final fragments = _fragmentMessage(message);
        _log("📤 [WRITE] Message split into ${fragments.length} fragment(s)");

        int totalBytes = 0;
        for (int fragIndex = 0; fragIndex < fragments.length; fragIndex++) {
          final frag = fragments[fragIndex];
          final jsonPayload = utf8.encode(jsonEncode(frag));

          // 🔥 Создаём framed message: [4 bytes length header][JSON payload]
          final framedMessage = _createFramedMessage(jsonPayload);
          totalBytes += framedMessage.length;

          _log(
              "📤 [WRITE] Fragment ${fragIndex + 1}/${fragments.length}: payload=${jsonPayload.length} bytes, framed=${framedMessage.length} bytes");

          const int chunkSize = 60;
          int chunkCount = 0;

          for (int i = 0; i < framedMessage.length; i += chunkSize) {
            final end = (i + chunkSize < framedMessage.length)
                ? i + chunkSize
                : framedMessage.length;
            final chunk = framedMessage.sublist(i, end);

            _log(
                "📤 [WRITE] Fragment ${fragIndex + 1}/${fragments.length}, chunk ${chunkCount + 1} (${chunk.length} bytes, offset $i)...");
            final writeStart = DateTime.now();

            // 🔒 GattOperationGate: single write (BUSY retry once 800ms inside _gattWrite)
            try {
              await _gattWrite(c, chunk, withoutResponse: true);
              if (kMeshDiagnostics && !_diagnosticFirstWriteLogged) {
                _diagnosticFirstWriteLogged = true;
                final elapsed = _diagnosticAttemptStartTime != null
                    ? DateTime.now()
                        .difference(_diagnosticAttemptStartTime!)
                        .inMilliseconds
                    : 0;
                _log(meshDiagLog('first_characteristic_write', {
                  'target': device.remoteId.str,
                  'elapsedMs': '$elapsed',
                  'chunkLen': '${chunk.length}',
                  ...?_diagnosticContext,
                }));
                _log(meshDiagLog('write_result', {
                  'result': 'success',
                  'target': device.remoteId.str,
                  'elapsedMs': '$elapsed',
                  ...?_diagnosticContext,
                }));
              }
            } catch (writeErr) {
              if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
                final elapsed =
                    DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
                _log(meshDiagLog('write_result', {
                  'result': 'error',
                  'target': device.remoteId.str,
                  'elapsedMs': '$elapsed',
                  'error': writeErr.toString().replaceAll(' ', '_'),
                  ...?_diagnosticContext,
                }));
              }
              recordBleInteraction(BleInteractionStats(
                peerId: device.remoteId.str,
                attemptedAction: BleAttemptedAction.write,
                result: BleInteractionResult.failed,
                timestamp: DateTime.now(),
              ));
              rethrow;
            }

            final writeElapsed = DateTime.now().difference(writeStart);
            _log("✅ [WRITE] Chunk written in ${writeElapsed.inMilliseconds}ms");

            // 🔥 GHOST: Пауза 80-150ms между чанками (оптимально для масштабирования)
            if (end < framedMessage.length) {
              await Future.delayed(
                  const Duration(milliseconds: 100)); // Оптимальная пауза
            }
            chunkCount++;
          }
          // Пауза между фрагментами
          if (fragIndex < fragments.length - 1) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        }
        _log(
            "✅ [WRITE] All data sent successfully (${totalBytes} bytes total, with length headers)");
        try {
          locator<MeshService>().reportMeshHealthBleWriteSuccess();
        } catch (_) {}
        recordBleInteraction(BleInteractionStats(
          peerId: device.remoteId.str,
          attemptedAction: BleAttemptedAction.write,
          result: BleInteractionResult.success,
          timestamp: DateTime.now(),
        ));
        _log("💎 [FINAL-DELIVERY] Packet delivered via BLE!");
        _transitionTransaction(BleTransactionState.LISTENING);
        _log("📥 [GHOST] Listen window 5s for BRIDGE→GHOST messages...");
        await Future.delayed(const Duration(seconds: 5));
        await notifySub?.cancel();
        _ghostNotifyBuffer.clear();
        _ghostNotifyExpectedLength = -1;

        _transitionTransaction(BleTransactionState.DISCONNECTING);
        if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
          final durationMs =
              DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
          _log(meshDiagLog('disconnect', {
            'target': device.remoteId.str,
            'reason': 'successful_delivery',
            'durationMs': '$durationMs',
            'elapsedMs': '$durationMs',
            ...?_diagnosticContext,
          }));
          _diagnosticAttemptStartTime = null;
          _diagnosticContext = null;
        }
        _log("🔌 [GHOST] Disconnecting after write and listen window");
        await stateSub?.cancel();
        try {
          await device.disconnect();
          _log("✅ [GHOST] Disconnected successfully");
          try {
            locator<MeshService>().reportMeshHealthBleDisconnect();
            locator<MeshService>().resetCrdtSessionForPeer(device.remoteId.str);
          } catch (_) {}
        } catch (e) {
          _log("⚠️ [GHOST] Error disconnecting: $e");
        }
        _releaseGattMutex("successful delivery");
        await _stateMachine.forceTransition(BleState.IDLE);
        _advState = BleAdvertiseState.idle;
        delivered = true;

        _transitionTransaction(BleTransactionState.QUIET_POST_DISCONNECT);
        _log(
            "[BLE-QUIET] enter post-disconnect — waiting ${_quietPostDisconnectMs}ms");
        _log("[BLE-TIMING] Quiet post-disconnect: ${_quietPostDisconnectMs}ms");
        await Future.delayed(Duration(milliseconds: _quietPostDisconnectMs));
        _transitionTransaction(BleTransactionState.IDLE);
        _log("[BLE-QUIET] exit post-disconnect");
        _lastCentralSessionEndTime = DateTime.now();
        setGlobalBleCooldown(true);
        return;
      } catch (e) {
        final errorStr = e.toString();
        final isError133 = errorStr.contains('133') ||
            errorStr.contains('ANDROID_SPECIFIC_ERROR');
        final isTimeout =
            errorStr.contains('Timed out') || errorStr.contains('timeout');

        _log("⚠️ GATT Attempt $attempt failed: $e");
        recordBleInteraction(BleInteractionStats(
          peerId: device.remoteId.str,
          attemptedAction: BleAttemptedAction.connect,
          result: isTimeout ? BleInteractionResult.timeout : BleInteractionResult.failed,
          timestamp: DateTime.now(),
        ));
        try {
          await HardwareCheckService().recordBleCentralFailure();
        } catch (_) {}
        // Копируемая строка для логов (без эмодзи): GATT error 133 / ANDROID_SPECIFIC_ERROR
        if (isError133)
          _log(
              "GATT_ERROR_133_ANDROID_SPECIFIC_ERROR connect failed attempt=$attempt exception=$e");

        // 🔥 ОБРАБОТКА TIMEOUT: Быстрее переходим к следующей попытке или Sonar
        if (isTimeout) {
          _log("⏱️ Connection timeout. Waiting longer before retry...");
          // Для timeout - короче задержка перед retry (2s, 4s, 6s)
          if (attempt < 3) {
            await Future.delayed(Duration(seconds: attempt * 2));
          } else {
            // Последняя попытка провалилась - выходим быстрее
            _log("❌ All GATT attempts failed due to timeout. Aborting.");
            break;
          }
          continue;
        }

        // 🔥 СПЕЦИАЛЬНАЯ ОБРАБОТКА ОШИБКИ 133 (Android BLE стек в нестабильном состоянии)
        if (isError133) {
          _log(
              "GATT_ERROR_133_ANDROID_SPECIFIC_ERROR performing BLE stack reset");
          _log(
              "🚨 [CRITICAL] Error 133 detected! Performing aggressive BLE stack reset...");

          // 1. Принудительно отключаемся
          try {
            await device.disconnect();
            try {
              locator<MeshService>().reportMeshHealthBleDisconnect();
              locator<MeshService>().resetCrdtSessionForPeer(device.remoteId.str);
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (_) {}

          // 2. Останавливаем сканирование полностью
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}

          // 3. Даем стеку больше времени на восстановление
          await Future.delayed(Duration(seconds: 8 + (attempt * 3)));

          // 4. Если это последняя попытка, пробуем перезапустить BLE адаптер
          if (attempt == 3) {
            _log("🔄 Last attempt: Trying to reset BLE adapter...");
            try {
              if (Platform.isAndroid) {
                await FlutterBluePlus.turnOff();
                await Future.delayed(const Duration(seconds: 2));
                await FlutterBluePlus.turnOn();
                await Future.delayed(const Duration(seconds: 2));
              }
            } catch (resetErr) {
              _log("⚠️ BLE adapter reset failed: $resetErr");
            }
          }
        } else if (isTimeout) {
          _log("⏱️ Connection timeout. Waiting longer before retry...");
          // Для таймаутов увеличиваем паузу еще больше
          await Future.delayed(Duration(seconds: 10 + (attempt * 3)));
        } else {
          // Для других ошибок стандартная пауза
          await Future.delayed(Duration(seconds: 6 + (attempt * 2)));
        }

        try {
          await stateSub?.cancel();
        } catch (_) {}
        try {
          await device.disconnect();
        } catch (_) {}
        // Reset FSM to IDLE on error
        await _stateMachine.forceTransition(BleState.IDLE);
        _advState = BleAdvertiseState.idle;
      }
    }

    // 🔥 FIX: ОБЯЗАТЕЛЬНОЕ освобождение GATT mutex
    _transitionTransaction(BleTransactionState.QUIET_POST_DISCONNECT);
    _log(
        "[BLE-QUIET] enter post-disconnect (failure path) — waiting ${_quietPostDisconnectMs}ms");
    _log(
        "[BLE-TIMING] Quiet post-disconnect (failure): ${_quietPostDisconnectMs}ms");
    await Future.delayed(Duration(milliseconds: _quietPostDisconnectMs));
    _transitionTransaction(BleTransactionState.IDLE);
    _log("[BLE-QUIET] exit post-disconnect");
    _lastCentralSessionEndTime = DateTime.now();
    setGlobalBleCooldown(delivered);
    _releaseGattMutex("end of _sendWithDynamicRetries - delivered: $delivered",
        state: delivered ? 'IDLE' : 'FAILED');

    if (!delivered) {
      throw Exception(
          "GATT delivery failed after 3 attempts or session timeout");
    }
  }

  /// 🔥 BLE STABILIZATION: Single session clock (task spec)
  /// CONNECTING 15s | DISCOVERING 8s | TRANSFERRING 10s | TOTAL 35s
  static const int _batchHardLimitSeconds = 35;
  static const int _connectTimeoutSeconds =
      20; // Huawei/Tecno: 15s часто недостаточно для GATT connect
  static const int _breakGlassConnectTimeoutSeconds = 12; // ADAPTIVE: Huawei break-glass single attempt
  static const int _discoverTimeoutSeconds = 8;
  static const int _transferTimeoutSeconds = 10;

  /// Макс. размер payload по BLE (рекомендация §6.17). Сообщения больше — пропускаем в batch, остаются для TCP/cloud.
  static const int kMaxBlePayloadBytes = 20 * 1024;

  /// 🔥 НОВЫЙ МЕТОД: Отправка множественных сообщений в рамках одного подключения
  /// Используется для отправки всех сообщений из outbox без переподключения
  /// 🔥 CRITICAL FIX: Подключается один раз, отправляет все сообщения, отключается только в конце
  /// 🔥 BLE STABILIZATION: Весь batch ограничен hard limit (35s total)
  /// [fromQueue]=true when called by queue consumer (owner already acquired).
  /// [messageIds], [sentFragmentIndices], [onFragmentSent] — для BLE resume по фрагментам.
  Future<int> sendMultipleMessages(
      BluetoothDevice device, List<String> messages,
      {bool fromQueue = false,
      List<String>? messageIds,
      List<int>? sentFragmentIndices,
      OnFragmentSent? onFragmentSent,
      bool isHuaweiBreakGlass = false,
      BleWriteStrategy? writeStrategy}) async {
    final batchId = DateTime.now().millisecondsSinceEpoch % 100000;
    _log(
        "📤 [BATCH-$batchId] START: ${messages.length} msg(s) to ${device.remoteId.str.substring(device.remoteId.str.length > 8 ? device.remoteId.str.length - 8 : 0)}");
    _log("   ⏱️ Hard limit: 35s (connect 15s + discover 8s + transfer 10s)");

    if (messages.isEmpty) {
      _log("⚠️ [BATCH] No messages to send");
      return 0;
    }
    if (!canStartBleTransaction) {
      _log(
          "[BLE-BLOCK] Batch skipped: transaction=$_bleTransactionState, cooldown=${_globalCooldownExpired ? "expired" : "active"}");
      return 0;
    }
    final targetMac = device.remoteId.str;
    if (!fromQueue) {
      if (!tryAcquireOwner(BleSessionOwner.batchSend)) {
        _log("[BLE][SKIP] Session owned by $_sessionOwner, reason=owner");
        throw Exception("GATT session owned by $_sessionOwner");
      }
      if (_isGattConnecting) {
        _log("[BLE][SKIP] GATT connection already in progress, reason=state");
        throw Exception("GATT connection already in progress");
      }
    }

    // 🔥 BLE STABILIZATION: Hard limit timer для всего batch
    final batchStartTime = DateTime.now();
    bool batchAborted = false;
    final hardLimitTimer =
        Timer(const Duration(seconds: _batchHardLimitSeconds), () {
      batchAborted = true;
      _log(
          "🚨 [BATCH-HARD-LIMIT] Batch exceeded ${_batchHardLimitSeconds}s - aborting!");
    });

    // Захватываем GATT mutex
    _isGattConnecting = true;
    _gattConnectStartTime = DateTime.now();
    _currentGattTargetMac = targetMac;
    _gattConnectionState = 'CONNECTING';
    _gattTransition(BleGattSessionState.CONNECTING);
    _log("🔒 [BATCH] GATT mutex acquired for batch send");

    int sentCount = 0;
    StreamSubscription<BluetoothConnectionState>? stateSub;
    StreamSubscription<List<int>>? batchNotifySub;
    BluetoothCharacteristic? characteristic;

    try {
      if (kMeshDiagnostics) {
        _diagnosticAttemptStartTime = batchStartTime;
        _diagnosticContext = await getDiagnosticContext();
        _diagnosticFirstNotifyLogged = false;
        _diagnosticFirstWriteLogged = false;
        final elapsed =
            DateTime.now().difference(batchStartTime).inMilliseconds;
        _log(meshDiagLog('ble_batch_start', {
          'target': targetMac,
          'elapsedMs': '$elapsed',
          ...?_diagnosticContext,
        }));
      }
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().onBleTransferStarted();
      }
      if (_stateMachine.state == BleState.ADVERTISING) {
        _log("[FSM] Controlled demotion ADVERTISING → IDLE for relay");
        await stopAdvertising(keepGattServer: true);
      }
      await enterCentralMode();
      _transitionTransaction(BleTransactionState.CONNECTING);
      _stateMachine.forceTransition(BleState.CONNECTING);
      _log("[BLE][STATE] -> connecting (batch send start)");
      _log("🔗 [BATCH] Connecting to device for batch send...");
      final staggerMs = (DateTime.now().millisecondsSinceEpoch % 300);
      if (staggerMs > 50) {
        _log("[BLE-TIMING] Stagger ${staggerMs}ms before connect");
        await Future.delayed(Duration(milliseconds: staggerMs));
      }
      final connectStart = DateTime.now();
      if (kMeshDiagnostics) {
        final elapsed =
            DateTime.now().difference(batchStartTime).inMilliseconds;
        _log(meshDiagLog('connect_attempt_start', {
          'role': 'CENTRAL',
          'target': targetMac,
          'timeoutSec': '${isHuaweiBreakGlass ? _breakGlassConnectTimeoutSeconds : _connectTimeoutSeconds}',
          'elapsedMs': '$elapsed',
          ...?_diagnosticContext,
        }));
      }
      final connectTimeoutSec = isHuaweiBreakGlass
          ? _breakGlassConnectTimeoutSeconds
          : _connectTimeoutSeconds;
      _log(
          "🚀 [BATCH] Stage: CONNECT (timeout: ${connectTimeoutSec}s)${isHuaweiBreakGlass ? ' [ADAPTIVE break-glass]' : ''}...");

      try {
        if (isHuaweiBreakGlass) {
          BleLinkStrategyResolver.recordHuaweiBreakGlassAttempt();
        }
        await device.connect(
            timeout: Duration(seconds: connectTimeoutSec),
            autoConnect: false);
        final connectDuration = DateTime.now().difference(connectStart);
        _log(
            "✅ [BATCH] device.connect() returned in ${connectDuration.inMilliseconds}ms");
        print(
            "🔴 [BT-DEBUG] device.connect() SUCCESS after ${connectDuration.inMilliseconds}ms");

        // 🔥 BLE STABILIZATION: Проверяем hard limit после connect
        if (batchAborted) {
          _log("⚠️ [BATCH] Hard limit reached during connect - aborting");
          throw Exception("Batch hard limit exceeded during connect");
        }
      } catch (connectError) {
        if (isHuaweiBreakGlass) {
          BleLinkStrategyResolver.recordHuaweiBreakGlassFailure();
        }
        _log("❌ [BATCH] device.connect() failed: $connectError");
        _log("   📋 Error type: ${connectError.runtimeType}");
        print(
            "🔴 [BT-DEBUG] device.connect() FAILED: $connectError (${connectError.runtimeType})");
        throw Exception("Connect failed: $connectError");
      }

      // Проверяем подключение
      if (!device.isConnected) {
        _log("❌ [BATCH] device.isConnected = false after connect()");
        throw Exception("Device not connected after connect()");
      }
      _stateMachine.forceTransition(BleState.CONNECTED);
      _gattTransition(BleGattSessionState.CONNECTED);
      _log("[GATT][STATE] CONNECTED");
      _log(
          "✅ [BATCH] Connected in ${DateTime.now().difference(connectStart).inMilliseconds}ms");
      _transitionTransaction(BleTransactionState.STABILIZING_POST_CONNECT);
      _log(
          "[BLE-TIMING] Post-connect stabilization: ${_postConnectStabilizationMs}ms");
      await Future.delayed(Duration(milliseconds: _postConnectStabilizationMs));
      _transitionTransaction(BleTransactionState.DISCOVERING);

      // Запрашиваем MTU
      if (Platform.isAndroid) {
        try {
          await _enqueueGattOperation(() => device.requestMtu(158));
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          _log("⚠️ [BATCH] MTU request failed: $e");
        }
      }

      // Обнаруживаем сервисы
      if (batchAborted) {
        _log(
            "⚠️ [BATCH] Hard limit reached before discoverServices - aborting");
        throw Exception("Batch hard limit exceeded before discoverServices");
      }
      if (kMeshDiagnostics) {
        final elapsed =
            DateTime.now().difference(batchStartTime).inMilliseconds;
        _log(meshDiagLog('service_discovery_start', {
          'target': targetMac,
          'elapsedMs': '$elapsed',
          ...?_diagnosticContext,
        }));
      }
      _log("🔍 [BATCH] Stage: DISCOVER...");
      final discoverStart = DateTime.now();
      List<BluetoothService> services = await device.discoverServices();
      final discoverMs =
          DateTime.now().difference(discoverStart).inMilliseconds;
      if (kMeshDiagnostics) {
        final elapsed =
            DateTime.now().difference(batchStartTime).inMilliseconds;
        _log(meshDiagLog(services.isEmpty ? 'service_discovery_fail' : 'service_discovery_success', {
          'target': targetMac,
          'servicesCount': '${services.length}',
          'discoverMs': '$discoverMs',
          'elapsedMs': '$elapsed',
          ...?_diagnosticContext,
        }));
      }
      _log(
          "[BLE-TIMING] discoverServices took ${discoverMs}ms, got ${services.length} services");
      if (services.isEmpty) {
        _log(
            "[BLE-TIMING] No services, retry after ${_discoverRetryDelayMs}ms");
        await Future.delayed(Duration(milliseconds: _discoverRetryDelayMs));
        services = await device.discoverServices();
      }
      _log("[BLE-TIMING] Post-discover settle: ${_postDiscoverSettleMs}ms");
      await Future.delayed(Duration(milliseconds: _postDiscoverSettleMs));
      var matchingServices = services
          .where((s) =>
              s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase())
          .toList();
      if (matchingServices.isEmpty && services.isNotEmpty) {
        _log(
            "⚠️ [BATCH] Service $SERVICE_UUID not found, retry after ${_discoverRetryDelayServiceMissingMs}ms (peripheral may expose GATT later)");
        await Future.delayed(
            Duration(milliseconds: _discoverRetryDelayServiceMissingMs));
        services = await device.discoverServices();
        matchingServices = services
            .where((s) =>
                s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase())
            .toList();
      }
      if (matchingServices.isEmpty) {
        if (kMeshDiagnostics) {
          final elapsed =
              DateTime.now().difference(batchStartTime).inMilliseconds;
          _log(meshDiagLog('service_discovery_fail', {
            'target': targetMac,
            'reason': 'service_not_found',
            'serviceUuid': SERVICE_UUID,
            'elapsedMs': '$elapsed',
            ...?_diagnosticContext,
          }));
        }
        _log(
            "❌ [BATCH] Service $SERVICE_UUID not found after retry. Device may be in central mode (GATT server stopped).");
        throw Exception(
            "Service $SERVICE_UUID not found on target device. Device may not be advertising correctly.");
      }
      final service = matchingServices.first;
      characteristic = service.characteristics.firstWhere(
        (c) => c.uuid.toString() == CHAR_UUID,
        orElse: () => throw Exception("Characteristic $CHAR_UUID not found"),
      );

      _log(
          "✅ [BATCH] Service and characteristic found - ready to send ${messages.length} message(s)");
      _stateMachine.forceTransition(BleState.SERVICES_READY);
      _gattTransition(BleGattSessionState.DISCOVERED);
      _transitionTransaction(BleTransactionState.TRANSFERRING);
      _log("[GATT][STATE] DISCOVERED — WRITE allowed");

      // Проверяем, что characteristic не null
      if (characteristic == null) {
        throw Exception("Characteristic is null after discovery");
      }

      // 🔥 GHOST↔GHOST FIX: Сначала WRITE, потом notify. На Huawei таймаут notify до записи
      // оставляет стек в состоянии WRITE_REQUEST_BUSY — запись не проходит. Порядок: write → notify → listen.

      // 🔥 Pre-write settle: даём стеку периферии (Huawei/другие) время после discover
      _log("[BLE-TIMING] Pre-write settle: 500ms (GHOST↔GHOST stability)");
      await Future.delayed(const Duration(milliseconds: 500));

      // 🔥 Notify at connection stage (not before OUTBOX_REQUEST): so Central can receive outbox pull response from Peripheral.
      final shouldEnableNotify = characteristic!.properties.notify &&
          (writeStrategy == null || writeStrategy!.useNotify);
      if (shouldEnableNotify && batchNotifySub == null) {
        if (writeStrategy?.delayNotify == true) {
          _log("[BLE][ADAPTIVE] delayNotify: 300ms before enable notify");
          await Future.delayed(const Duration(milliseconds: 300));
        }
          try {
            await _enqueueGattOperation(() => characteristic!.setNotifyValue(true).timeout(
              Duration(seconds: _notifyEnableTimeoutSeconds),
              onTimeout: () => throw TimeoutException('Notify enable'),
            ));
          _ghostNotifyBuffer.clear();
          _ghostNotifyExpectedLength = -1;
          final bridgeAddress = device.remoteId.str;
          batchNotifySub = characteristic!.lastValueStream.listen(
            (value) => _onNotifyChunkFromBridge(bridgeAddress, value),
            onError: (e) => _log("⚠️ [BATCH] Notify stream error: $e"),
          );
          _log("📥 [BATCH] Notify enabled at connection stage — subscribed to BRIDGE notify");
        } catch (e) {
          _log("⚠️ [BATCH] Notify enable at connection stage failed (non-blocking): $e");
        }
      }

      _stateMachine.forceTransition(BleState.TRANSFERRING);
      _gattTransition(BleGattSessionState.TRANSFERRING);
      _log("[GATT][STATE] TRANSFERRING — WRITE OK");
      for (int i = 0; i < messages.length; i++) {
        // [BLE][SKIP] Guard: не пишем до servicesReady
        if (!_stateMachine.canWrite) {
          _log(
              "[BLE][SKIP] write skipped (state=${_stateMachine.state}, canWrite=false)");
          break;
        }
        // 🔥 BLE STABILIZATION: Проверяем hard limit перед каждым сообщением
        if (batchAborted) {
          _log(
              "⏸️ [BATCH] Hard limit reached - stopping at message ${i}/${messages.length}");
          _log("[BEACON-SYNC] Connection time limit reached — CRDT/listen window may be short; chat may stay out of sync");
          break;
        }

        // Проверяем, что соединение еще активно
        if (!device.isConnected) {
          _log(
              "❌ [BATCH] Connection lost before message ${i + 1}/${messages.length}");
          break;
        }

        try {
          final message = messages[i];
          // 🔥 §6.17: Ограничение размера по BLE — большие сообщения пропускаем, остаются для TCP/cloud
          if (message.length > kMaxBlePayloadBytes) {
            _log(
                "⚠️ [BATCH] Message ${i + 1} exceeds BLE limit (${message.length} > $kMaxBlePayloadBytes bytes), skipping");
            continue;
          }

          final String? messageId =
              (messageIds != null && i < messageIds.length) ? messageIds[i] : null;
          final int sentFragmentIndex =
              (sentFragmentIndices != null && i < sentFragmentIndices.length)
                  ? sentFragmentIndices[i]
                  : -1;

          final writeStart = DateTime.now();
          _log(
              "📤 [BATCH] Stage: WRITE message ${i + 1}/${messages.length}...");

          final fragments = _fragmentMessage(message);
          // Resume: отправляем только фрагменты с индекса sentFragmentIndex+1
          final bool useResume = messageId != null &&
              onFragmentSent != null &&
              fragments.length > 1 &&
              sentFragmentIndex >= 0;
          final int startIdx = useResume ? sentFragmentIndex + 1 : 0;
          final toSend = useResume
              ? fragments.sublist(startIdx)
              : fragments;

          if (toSend.isEmpty) {
            _log("   ⏭️ [BATCH] Message ${i + 1} already fully sent (resume), counting as sent");
            sentCount++;
            if (i < messages.length - 1) {
              await Future.delayed(const Duration(milliseconds: 200));
            }
            continue;
          }

          int totalBytes = 0;
          for (int k = 0; k < toSend.length; k++) {
            final frag = toSend[k];
            final int actualIndex = startIdx + k;
            final jsonPayload = utf8.encode(jsonEncode(frag));
            final framedMessage = _createFramedMessage(jsonPayload);
            totalBytes += framedMessage.length;

            const int chunkSize = 60;
            for (int j = 0; j < framedMessage.length; j += chunkSize) {
              if (!device.isConnected) {
                throw Exception("Connection lost during message send");
              }

              final end = (j + chunkSize < framedMessage.length)
                  ? j + chunkSize
                  : framedMessage.length;
              final chunk = framedMessage.sublist(j, end);
              // 🔒 GattOperationGate: single write (BUSY retry once 800ms inside _gattWrite)
              if (writeStrategy != null) {
                final useWithout = !writeStrategy!.useWriteWithResponse;
                try {
                  await _gattWrite(characteristic, chunk, withoutResponse: useWithout);
                  if (kMeshDiagnostics && !_diagnosticFirstWriteLogged) {
                    _diagnosticFirstWriteLogged = true;
                    final elapsed = _diagnosticAttemptStartTime != null
                        ? DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds
                        : 0;
                    _log(meshDiagLog('first_characteristic_write', {
                      'target': targetMac,
                      'elapsedMs': '$elapsed',
                      'chunkLen': '${chunk.length}',
                      ...?_diagnosticContext,
                    }));
                  }
                } catch (firstErr) {
                  _log("⚠️ [BATCH][ADAPTIVE] First write failed, switching strategy once: $firstErr");
                  try {
                    await _gattWrite(characteristic, chunk, withoutResponse: !useWithout);
                  } catch (_) {
                    rethrow;
                  }
                }
              } else {
                try {
                  await _gattWrite(characteristic, chunk, withoutResponse: true);
                  if (kMeshDiagnostics && !_diagnosticFirstWriteLogged) {
                    _diagnosticFirstWriteLogged = true;
                    final elapsed = _diagnosticAttemptStartTime != null
                        ? DateTime.now()
                            .difference(_diagnosticAttemptStartTime!)
                            .inMilliseconds
                        : 0;
                    _log(meshDiagLog('first_characteristic_write', {
                      'target': targetMac,
                      'elapsedMs': '$elapsed',
                      'chunkLen': '${chunk.length}',
                      ...?_diagnosticContext,
                    }));
                  }
                } catch (writeErr) {
                  try {
                    await _gattWrite(characteristic, chunk, withoutResponse: false);
                  } catch (_) {
                    rethrow;
                  }
                }
              }

              if (end < framedMessage.length) {
                await Future.delayed(const Duration(milliseconds: 100));
              }
            }

            if (messageId != null) {
              onFragmentSent?.call(messageId, actualIndex, fragments.length);
            }

            if (toSend.length > 1 && k < toSend.length - 1) {
              await Future.delayed(const Duration(milliseconds: 150));
            }
          }

          sentCount++;
          final writeMs = DateTime.now().difference(writeStart).inMilliseconds;
          _log("   ✅ [BATCH] WRITE OK: ${writeMs}ms (${totalBytes} bytes)");

          if (i < messages.length - 1) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        } catch (e) {
          _log("   ⚠️ [BATCH] Failed to send message ${i + 1}: $e");
          if (_isGattBusyError(e)) {
            batchAborted = true;
          }
        }
      }

      // Pull outbox from Peripheral (Huawei): send OUTBOX_REQUEST so it responds with pending messages via notify.
      if (device.isConnected && characteristic != null) {
        try {
          final outboxRequestJson = jsonEncode(<String, String>{'type': 'OUTBOX_REQUEST'});
          final outboxPayload = utf8.encode(outboxRequestJson);
          final outboxFramed = _createFramedMessage(outboxPayload);
          const int chunkSize = 60;
          for (int j = 0; j < outboxFramed.length; j += chunkSize) {
            final end = (j + chunkSize < outboxFramed.length) ? j + chunkSize : outboxFramed.length;
            final chunk = outboxFramed.sublist(j, end);
            if (writeStrategy != null) {
              await _gattWrite(characteristic!, chunk, withoutResponse: !writeStrategy!.useWriteWithResponse);
            } else {
              await _gattWrite(characteristic!, chunk, withoutResponse: true);
            }
            if (end < outboxFramed.length) {
              await Future.delayed(const Duration(milliseconds: 100));
            }
          }
          _log("📤 [BATCH] OUTBOX_REQUEST sent — waiting for BRIDGE outbox via notify");
        } catch (e) {
          _log("⚠️ [BATCH] OUTBOX_REQUEST write failed (non-blocking): $e");
        }
      }

      final totalMs = DateTime.now().difference(batchStartTime).inMilliseconds;
      _log(
          "📊 [BATCH-$batchId] END: $sentCount/${messages.length} sent in ${totalMs}ms");

      // 🔥 ШАГ 2: После записи включаем notify для окна listen (BRIDGE→GHOST relay). Если уже включили до OUTBOX_REQUEST — пропускаем.
      if (shouldEnableNotify && batchNotifySub == null) {
        if (writeStrategy?.delayNotify == true) {
          _log("[BLE][ADAPTIVE] delayNotify: 300ms before enable notify");
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (kMeshDiagnostics) {
          final elapsed =
              DateTime.now().difference(batchStartTime).inMilliseconds;
          _log(meshDiagLog('notify_enable_start', {
            'target': targetMac,
            'timeoutSec': '$_notifyEnableTimeoutSeconds',
            'elapsedMs': '$elapsed',
            ...?_diagnosticContext,
          }));
        }
        try {
          await _enqueueGattOperation(() => characteristic!.setNotifyValue(true).timeout(
            Duration(seconds: _notifyEnableTimeoutSeconds),
            onTimeout: () => throw TimeoutException('Notify enable'),
          ));
          if (kMeshDiagnostics) {
            final elapsed =
                DateTime.now().difference(batchStartTime).inMilliseconds;
            _log(meshDiagLog('notify_enable_success', {
              'target': targetMac,
              'elapsedMs': '$elapsed',
              ...?_diagnosticContext,
            }));
          }
          _ghostNotifyBuffer.clear();
          _ghostNotifyExpectedLength = -1;
          final bridgeAddress = device.remoteId.str;
          batchNotifySub = characteristic!.lastValueStream.listen(
            (value) => _onNotifyChunkFromBridge(bridgeAddress, value),
            onError: (e) => _log("⚠️ [BATCH] Notify stream error: $e"),
          );
          _log("📥 [BATCH] Subscribed to BRIDGE notify (after write)");
        } catch (e) {
          if (kMeshDiagnostics) {
            final elapsed =
                DateTime.now().difference(batchStartTime).inMilliseconds;
            _log(meshDiagLog('notify_enable_timeout', {
              'target': targetMac,
              'elapsedMs': '$elapsed',
              'error': e.toString().replaceAll(' ', '_'),
              ...?_diagnosticContext,
            }));
          }
          _log("⚠️ [BATCH] Could not enable notify (after write): $e");
        }
      }

    } catch (e) {
      if (kMeshDiagnostics) {
        _diagnosticAttemptStartTime = null;
        _diagnosticContext = null;
      }
      _log("❌ [BATCH] Batch send error: $e");
    } finally {
      // 🔥 BLE STABILIZATION: Отменяем hard limit timer
      hardLimitTimer.cancel();
      final batchDuration = DateTime.now().difference(batchStartTime);
      _log(
          "📊 [BATCH] Batch duration: ${batchDuration.inMilliseconds}ms (limit: ${_batchHardLimitSeconds}s)");
      _log("[BEACON-SYNC] Entering listen window (${batchAborted ? 3 : 6}s) for CRDT/outbox from peer — chat sync runs in this window");

      _transitionTransaction(BleTransactionState.LISTENING);
      final listenWindowSeconds = batchAborted ? 3 : 6;
      _log(
          "📥 [BATCH] Stage: LISTEN (${listenWindowSeconds}s for BRIDGE→GHOST relay)...");
      await Future.delayed(Duration(seconds: listenWindowSeconds));
      await batchNotifySub?.cancel();
      _ghostNotifyBuffer.clear();
      _ghostNotifyExpectedLength = -1;
      _transitionTransaction(BleTransactionState.DISCONNECTING);
      if (kMeshDiagnostics && _diagnosticAttemptStartTime != null) {
        final durationMs =
            DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds;
        _log(meshDiagLog('disconnect', {
          'target': targetMac,
          'reason': batchAborted ? 'hard_limit_abort' : 'batch_complete',
          'durationMs': '$durationMs',
          'elapsedMs': '$durationMs',
          ...?_diagnosticContext,
        }));
        _diagnosticAttemptStartTime = null;
        _diagnosticContext = null;
      }
      try {
        await stateSub?.cancel();
        if (device.isConnected) {
          _log("🔌 [BATCH] Stage: DISCONNECT...");
          await device.disconnect();
        }
      } catch (e) {
        _log("⚠️ [BATCH] Error disconnecting: $e");
      }
      _gattTransition(BleGattSessionState.DONE);
      _releaseGattMutex(
          "batch send completed - sent: $sentCount/${messages.length}, aborted: $batchAborted");
      if (!fromQueue) releaseOwner(BleSessionOwner.batchSend);
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().onBleTransferEnded();
      }
      _gattTransition(BleGattSessionState.IDLE);
      await _stateMachine.forceTransition(BleState.IDLE);
      _advState = BleAdvertiseState.idle;
      _transitionTransaction(BleTransactionState.QUIET_POST_DISCONNECT);
      _log(
          "[BLE-QUIET] enter post-disconnect (batch) — waiting ${_quietPostDisconnectMs}ms");
      _log(
          "[BLE-TIMING] Quiet post-disconnect (batch): ${_quietPostDisconnectMs}ms");
      await Future.delayed(Duration(milliseconds: _quietPostDisconnectMs));
      _transitionTransaction(BleTransactionState.IDLE);
      _log("[BLE-QUIET] exit post-disconnect");
      _lastCentralSessionEndTime = DateTime.now();
      setGlobalBleCooldown(sentCount > 0);
    }

    return sentCount;
  }

  /// [ACTIVE-SYNC] CRDT-only session: connect → discover → enable notify → send HEAD_EXCHANGE → listen 6s → disconnect.
  /// No outbox cascade. Uses same FSM/connect path; does not change transport state machine.
  /// Call only when no other BLE session is active. Max 1 connection per epoch.
  Future<bool> runCrdtOnlySession(BluetoothDevice device) async {
    final targetMac = device.remoteId.str;
    if (!tryAcquireOwner(BleSessionOwner.activeSyncCrdt)) {
      _log("[ACTIVE-SYNC] Skip: session owned by $_sessionOwner");
      return false;
    }
    if (_isGattConnecting || _bleTransactionState != BleTransactionState.IDLE) {
      releaseOwner(BleSessionOwner.activeSyncCrdt);
      _log("[ACTIVE-SYNC] Skip: GATT busy or transaction not IDLE");
      return false;
    }
    _isGattConnecting = true;
    _currentGattTargetMac = targetMac;
    StreamSubscription<BluetoothConnectionState>? stateSub;
    StreamSubscription<List<int>>? notifySub;
    BluetoothCharacteristic? characteristic;
    try {
      await enterCentralMode();
      _gattTransition(BleGattSessionState.CONNECTING);
      _transitionTransaction(BleTransactionState.CONNECTING);
      _stateMachine.forceTransition(BleState.CONNECTING);
      _log("[ACTIVE-SYNC] Connecting to ${maskMacForLog(targetMac)} for CRDT-only sync...");
      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      if (!device.isConnected) {
        _log("[ACTIVE-SYNC] Connect failed: not connected");
        return false;
      }
      _gattTransition(BleGattSessionState.CONNECTED);
      _transitionTransaction(BleTransactionState.STABILIZING_POST_CONNECT);
      await Future.delayed(Duration(milliseconds: _postConnectStabilizationMs));
      _transitionTransaction(BleTransactionState.DISCOVERING);
      if (Platform.isAndroid) {
        try {
          await _enqueueGattOperation(() => device.requestMtu(158));
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (_) {}
      }
      List<BluetoothService> services = await device.discoverServices();
      await Future.delayed(Duration(milliseconds: _postDiscoverSettleMs));
      var matchingServices = services
          .where((s) => s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase())
          .toList();
      if (matchingServices.isEmpty) {
        _log("[ACTIVE-SYNC] Service not found");
        return false;
      }
      final service = matchingServices.first;
      characteristic = service.characteristics.firstWhere(
        (c) => c.uuid.toString() == CHAR_UUID,
        orElse: () => throw Exception("Char not found"),
      );
      _gattTransition(BleGattSessionState.DISCOVERED);
      await Future.delayed(const Duration(milliseconds: 500));
      await _enqueueGattOperation(() => characteristic!.setNotifyValue(true).timeout(
        Duration(seconds: _notifyEnableTimeoutSeconds),
        onTimeout: () => throw TimeoutException('Notify enable'),
      ));
      _ghostNotifyBuffer.clear();
      _ghostNotifyExpectedLength = -1;
      _crdtOnlyCentralCharacteristic = characteristic;
      _crdtOnlyCentralTargetMac = targetMac;
      notifySub = characteristic!.lastValueStream.listen(
        (value) => _onNotifyChunkFromBridge(targetMac, value),
        onError: (e) => _log("⚠️ [ACTIVE-SYNC] Notify error: $e"),
      );
      _log("[ACTIVE-SYNC] Notify enabled — sending HEAD_EXCHANGE");
      if (locator.isRegistered<MeshService>()) {
        locator<MeshService>().startCrdtDigestExchange(targetMac);
      }
      _transitionTransaction(BleTransactionState.LISTENING);
      _log("[ACTIVE-SYNC] Listen window 6s for CRDT response");
      await Future.delayed(const Duration(seconds: 6));
      await notifySub.cancel();
      _ghostNotifyBuffer.clear();
      _ghostNotifyExpectedLength = -1;
      _log("[ACTIVE-SYNC] Session complete");
      return true;
    } catch (e) {
      _log("[ACTIVE-SYNC] Error: $e");
      return false;
    } finally {
      _crdtOnlyCentralCharacteristic = null;
      _crdtOnlyCentralTargetMac = null;
      try {
        await stateSub?.cancel();
        if (device.isConnected) await device.disconnect();
      } catch (_) {}
      _gattTransition(BleGattSessionState.DONE);
      _releaseGattMutex("active-sync crdt-only completed");
      releaseOwner(BleSessionOwner.activeSyncCrdt);
      if (locator.isRegistered<MeshService>()) {
        locator<MeshService>().resetCrdtSessionForPeer(targetMac);
      }
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().onBleTransferEnded();
      }
      _gattTransition(BleGattSessionState.IDLE);
      _stateMachine.forceTransition(BleState.IDLE);
      _transitionTransaction(BleTransactionState.QUIET_POST_DISCONNECT);
      await Future.delayed(Duration(milliseconds: _quietPostDisconnectMs));
      _transitionTransaction(BleTransactionState.IDLE);
    }
  }

  /// 🔥 BRIDGE→GHOST: обрабатывает чанки notify от BRIDGE, собирает в полное сообщение и передаёт в mesh
  /// Формат как у GattServerHelper: [4 bytes length Big-Endian][N bytes JSON]
  void _onNotifyChunkFromBridge(String bridgeAddress, List<int> chunk) {
    if (chunk.isEmpty) return;
    if (kMeshDiagnostics && !_diagnosticFirstNotifyLogged) {
      _diagnosticFirstNotifyLogged = true;
      final elapsed = _diagnosticAttemptStartTime != null
          ? DateTime.now().difference(_diagnosticAttemptStartTime!).inMilliseconds
          : 0;
      _log(meshDiagLog('first_notify_received', {
        'bridgeAddress': bridgeAddress,
        'elapsedMs': '$elapsed',
        'chunkLen': '${chunk.length}',
        ...?_diagnosticContext,
      }));
    }
    _ghostNotifyBuffer.addAll(chunk);
    if (_ghostNotifyExpectedLength < 0 && _ghostNotifyBuffer.length >= 4) {
      _ghostNotifyExpectedLength = (_ghostNotifyBuffer[0] << 24) |
          (_ghostNotifyBuffer[1] << 16) |
          (_ghostNotifyBuffer[2] << 8) |
          _ghostNotifyBuffer[3];
    }
    while (_ghostNotifyExpectedLength >= 0 &&
        _ghostNotifyBuffer.length >= 4 + _ghostNotifyExpectedLength) {
      final payload =
          _ghostNotifyBuffer.sublist(4, 4 + _ghostNotifyExpectedLength);
      _ghostNotifyBuffer.removeRange(0, 4 + _ghostNotifyExpectedLength);
      _ghostNotifyExpectedLength = -1;
      if (_ghostNotifyBuffer.length >= 4) {
        _ghostNotifyExpectedLength = (_ghostNotifyBuffer[0] << 24) |
            (_ghostNotifyBuffer[1] << 16) |
            (_ghostNotifyBuffer[2] << 8) |
            _ghostNotifyBuffer[3];
      }
      try {
        final jsonStr = utf8.decode(payload);
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        map['senderIp'] = bridgeAddress;
        _log(
            "📥 [GHOST] Received message from BRIDGE via notify (${payload.length} bytes)");
        locator<MeshService>().processIncomingPacket(map);
      } catch (e) {
        _log("⚠️ [GHOST] Notify reassembly error: $e");
      }
    }
  }

  /// [ACTIVE-SYNC] Write payload to connected peer when we are Central (CRDT-only session). Same framing as batch.
  /// Returns true if write was performed; false if not in CRDT-only session or peer mismatch.
  Future<bool> writeFromCentralToPeer(String peerAddress, String payloadJson) async {
    if (_crdtOnlyCentralTargetMac != peerAddress || _crdtOnlyCentralCharacteristic == null) {
      return false;
    }
    try {
      final payload = utf8.encode(payloadJson);
      final framed = _createFramedMessage(payload);
      const int chunkSize = 60;
      for (int j = 0; j < framed.length; j += chunkSize) {
        final end = (j + chunkSize < framed.length) ? j + chunkSize : framed.length;
        final chunk = framed.sublist(j, end);
        await _gattWrite(_crdtOnlyCentralCharacteristic!, chunk, withoutResponse: true);
        if (end < framed.length) await Future.delayed(const Duration(milliseconds: 100));
      }
      return true;
    } catch (e) {
      _log("⚠️ [ACTIVE-SYNC] writeFromCentralToPeer failed: $e");
      return false;
    }
  }

  /// 🔥 LENGTH-PREFIXED FRAMING: Создаёт framed message с 4-байтным заголовком длины
  /// Формат: [4 bytes: payload length (Big-Endian)][N bytes: JSON payload]
  Uint8List _createFramedMessage(List<int> jsonPayload) {
    final payloadLength = jsonPayload.length;

    // Создаём 4-байтный header с длиной (Big-Endian)
    final header = Uint8List(4);
    header[0] = (payloadLength >> 24) & 0xFF;
    header[1] = (payloadLength >> 16) & 0xFF;
    header[2] = (payloadLength >> 8) & 0xFF;
    header[3] = payloadLength & 0xFF;

    // Объединяем header + payload
    final framedMessage = Uint8List(4 + payloadLength);
    framedMessage.setRange(0, 4, header);
    framedMessage.setRange(4, 4 + payloadLength, jsonPayload);

    _log(
        "📦 [FRAMING] Created framed message: header=[${header[0]},${header[1]},${header[2]},${header[3]}], payload=$payloadLength bytes, total=${framedMessage.length} bytes");

    return framedMessage;
  }

  /// Делит сообщение на логические фрагменты, используя существующую схему MSG_FRAG
  List<Map<String, dynamic>> _fragmentMessage(String message) {
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

      // Если короткое — отправляем как есть, без фрагмента
      if (total == 1) {
        return [
          {
            'type': base['type'] ?? 'OFFLINE_MSG',
            'chatId': chatId,
            'senderId': senderId,
            'h': msgId,
            'content': content,
            'ttl': base['ttl'] ?? 5,
          }
        ];
      }

      final List<Map<String, dynamic>> frags = [];
      for (int i = 0; i < total; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize < content.length)
            ? start + chunkSize
            : content.length;
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
      // fallback: отправляем как один маленький пакет (без фрагментации)
      return [
        {
          'type': 'OFFLINE_MSG',
          'content': message,
          'h': DateTime.now().millisecondsSinceEpoch.toString(),
          'ttl': 5,
        }
      ];
    }
  }

  Future<String> _getDeviceModel() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return "${a.manufacturer} ${a.model}";
    }
    return "iOS";
  }

  /// Logs go to in-app panel (Mesh Hybrid / Scan screen via MeshService.statusStream).
  void _log(String msg) {
    print("🦷 [BT-Mesh] $msg");
    if (!locator.isRegistered<MeshService>()) return;
    try {
      locator<MeshService>().addLog("🦷 [BT] $msg");
    } catch (e) {
      print("⚠️ [BT-LOG] Failed to addLog: $e");
    }
  }
}

class _BtTask {
  final BluetoothDevice device;
  final String message;
  _BtTask(this.device, this.message);
}
