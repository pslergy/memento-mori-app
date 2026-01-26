import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:synchronized/synchronized.dart'; // 🔒 SECURITY FIX: For atomic BLE operations

import 'MeshOrchestrator.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'network_monitor.dart';
import 'ble_state_machine.dart';
import 'event_bus_service.dart';

// 🔄 Replaced with BleStateMachine - keeping enum for backward compatibility during migration
enum BleAdvertiseState {
  idle,
  starting,
  advertising,
  connecting,
  connected,
  stopping,
}

class BluetoothMeshService {
  final String SERVICE_UUID = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
  final String CHAR_UUID    = "c22d1e32-0310-4062-812e-89025078da9c";

  final Queue<_BtTask> _taskQueue = Queue();
  final Set<String> _pendingDevices = {};
  bool _isProcessingQueue = false;

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  BleAdvertiseState _advState = BleAdvertiseState.idle; // Legacy state (for migration)
  
  // 🔄 New FSM-based state management
  final BleStateMachine _stateMachine = BleStateMachine();
  BleStateMachine get stateMachine => _stateMachine;
  
  String? _cachedModel;
  
  // 🔥 ОПТИМИЗАЦИЯ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Минимальный интервал между операциями ADV
  // Не трогать ADV слишком часто, иначе BLE FSM "зависает" на Huawei/Xiaomi/Tecno/Infinix/Poco/Samsung
  DateTime? _lastAdvOperation;
  static const Duration _minAdvInterval = Duration(seconds: 2); // Минимум 2 секунды между операциями
  
  // 🔒 Fix BLE state machine: Use Completer instead of busy wait
  Completer<void>? _stateIdleCompleter;
  
  // 🔥 FIX: GATT Connection Mutex - предотвращает параллельные попытки connect
  bool _isGattConnecting = false;
  DateTime? _gattConnectStartTime;
  String? _currentGattTargetMac;
  static const Duration _gattConnectTimeout = Duration(seconds: 20);
  
  // 🔥 FIX: Explicit GATT connection state
  // IDLE -> CONNECTING -> CONNECTED -> DISCONNECTED
  String _gattConnectionState = 'IDLE';
  String get gattConnectionState => _gattConnectionState;
  
  // 🔥 FIX: Public getter for GATT connecting state (used by MeshService to block scan)
  bool get isGattConnecting => _isGattConnecting;
  
  /// 🔥 FIX: Helper to release GATT mutex consistently
  /// Called on all exit paths from _sendWithDynamicRetries
  /// [state] can be 'IDLE' (default) or 'FAILED'
  void _releaseGattMutex(String reason, {String state = 'IDLE'}) {
    if (_isGattConnecting) {
      _log("🔓 [GATT-MUTEX] Released (reason: $reason, state: $state)");
    }
    _isGattConnecting = false;
    _gattConnectStartTime = null;
    _currentGattTargetMac = null;
    _gattConnectionState = state;
  }
  
  /// 🔥 FIX: Public method to force reset GATT state after external timeout
  /// Called by MeshService when GATT timeout occurs but _sendWithDynamicRetries is still running
  void forceResetGattState(String reason) {
    _log("🚨 [GATT-FORCE-RESET] $reason");
    _log("   📋 Previous state: $_gattConnectionState");
    _log("   📋 Was connecting: $_isGattConnecting");
    _log("   📋 Target: $_currentGattTargetMac");
    
    _isGattConnecting = false;
    _gattConnectStartTime = null;
    _currentGattTargetMac = null;
    _gattConnectionState = 'IDLE';
    
    _log("   ✅ State reset to IDLE - scan unblocked");
  }
  
  static final MethodChannel _gattChannel = MethodChannel('memento/gatt_server');
  StreamSubscription? _gattEventSubscription;
  
  // 🔥 Native BLE Advertiser для Huawei/Honor (fallback если flutter_ble_peripheral не работает)
  static const MethodChannel _nativeAdvChannel = MethodChannel('memento/native_ble_advertiser');
  bool _useNativeAdvertiser = false;
  bool _nativeAdvertiserChecked = false;
  
  // 🔥 FIX: Track if advertising was actually started successfully
  // This prevents crash when stopping advertising that never started
  bool _advertisingStartedSuccessfully = false;
  bool _nativeAdvertisingStarted = false;
  
  // 🔒 SECURITY FIX #4: Track connected GATT clients to prevent token rotation
  // This prevents BRIDGE from rotating token while GHOST is connected
  final Set<String> _connectedGattClients = {};
  DateTime? _lastGattClientActivity;
  static const Duration _gattClientGracePeriod = Duration(seconds: 5); // Grace period after disconnect
  
  // 🔒 SECURITY FIX: Atomic locks for BLE operations
  final Lock _stopLock = Lock();
  final Lock _startLock = Lock();
  bool _isStopInProgress = false; // Keep for backward compatibility
  bool _isStartInProgress = false;

  BleAdvertiseState get state => _advState; // Legacy getter
  BleState get fsmState => _stateMachine.state; // New FSM getter
  
  /// 🔒 SECURITY FIX #4: Check if any GATT clients are active (connected or within grace period)
  /// This is used by BRIDGE to prevent token rotation while GHOST is connected
  bool get hasActiveGattClients {
    // If any clients are currently connected
    if (_connectedGattClients.isNotEmpty) {
      return true;
    }
    
    // Check grace period after last disconnect
    if (_lastGattClientActivity != null) {
      final timeSinceActivity = DateTime.now().difference(_lastGattClientActivity!);
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
  Future<bool> sendMessageToGattClient(String deviceAddress, String messageJson) async {
    try {
      final result = await _gattChannel.invokeMethod('sendMessageToClient', {
        'deviceAddress': deviceAddress,
        'message': messageJson,
      });
      return result == true;
    } catch (e) {
      _log("❌ [GATT-SERVER] Failed to send message to $deviceAddress: $e");
      return false;
    }
  }
  
  BluetoothMeshService() {
    _setupGattServerListener();
    _checkNativeAdvertiserSupport();
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
      
      final requires = await _nativeAdvChannel.invokeMethod<bool>('requiresNativeAdvertising');
      _useNativeAdvertiser = requires ?? false;
      
      if (_useNativeAdvertiser) {
        _log("🔧 [ADV] Device requires native BLE advertiser (Huawei/Honor detected)");
        
        // Получаем информацию об устройстве
        final deviceInfo = await _nativeAdvChannel.invokeMethod<Map>('getDeviceInfo');
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
            _handleIncomingGattData(deviceAddress, data, isComplete: isComplete);
          }
          break;
        case 'onGattClientConnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("✅ [GATT-SERVER] Client connected: $deviceAddress");
          // 🔒 SECURITY FIX #4: Track connected client to prevent token rotation
          if (deviceAddress != null) {
            _connectedGattClients.add(deviceAddress);
            _lastGattClientActivity = DateTime.now();
            _log("📋 [GATT-SERVER] Active clients: ${_connectedGattClients.length}");
          }
          break;
        case 'onGattClientDisconnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("❌ [GATT-SERVER] Client disconnected: $deviceAddress");
          // 🔒 SECURITY FIX #4: Remove client from tracking
          if (deviceAddress != null) {
            _connectedGattClients.remove(deviceAddress);
            _lastGattClientActivity = DateTime.now();
            _log("📋 [GATT-SERVER] Active clients: ${_connectedGattClients.length}");
          }
          break;
        case 'onGattReady':
          // 🔥 FIX: Parse generation parameter to detect stale events
          int? generation;
          if (call.arguments != null && call.arguments is Map) {
            generation = (call.arguments as Map)['generation'] as int?;
          }
          _log("📥 [GATT-SERVER] Received onGattReady event from native (gen: $generation)");
          _onGattReady(generation: generation);
          break;
      }
    });
  }
  
  void _handleIncomingGattData(String deviceAddress, String data, {bool isComplete = false}) {
    final preview = data.length > 100 ? data.substring(0, 100) : data;
    _log("📥 [BRIDGE] BLE GATT: Received ${isComplete ? 'COMPLETE' : 'partial'} data from GHOST $deviceAddress");
    _log("   📋 Data preview: $preview...");
    _log("   📋 Full data length: ${data.length} bytes");
    
    // 🔥 FRAMING: Теперь данные приходят полностью собранные из Kotlin
    if (!isComplete) {
      _log("⚠️ [BRIDGE] Data marked as incomplete - this should not happen with new framing protocol");
    }
    
    try {
      // Парсим JSON данные (теперь это полное сообщение!)
      final jsonData = jsonDecode(data) as Map<String, dynamic>;
      final messageType = jsonData['type'] ?? 'UNKNOWN';
      final messageId = jsonData['h'] ?? jsonData['mid'] ?? jsonData['id'] ?? 'unknown';
      
      _log("   ✅ [JSON] Parsed complete message successfully!");
      _log("   📋 Message type: $messageType");
      _log("   📋 Message ID: ${messageId.toString().substring(0, messageId.toString().length > 8 ? 8 : messageId.toString().length)}...");
      
      // Добавляем senderIp в данные для обработки
      jsonData['senderIp'] = deviceAddress;
      
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
        final fragMessageId = jsonData['mid']?.toString() ?? messageId.toString();
        _log("   📦 [FRAG] Fragment received, checking if message is complete...");
        
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
  Future<void> _checkAndAckIfComplete(String deviceAddress, String messageId) async {
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
    _log("📤 [ACK] Sending app-level ACK to GHOST $deviceAddress for message $messageId");
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
  Future<bool> sendMessage(BluetoothDevice device, String message) async {
    // 🔍🔍🔍 CRITICAL DIAGNOSTIC: Абсолютно первая строка - БЕЗ обращения к device!
    _log("🦷🔍🔍🔍 [BT-CRITICAL] sendMessage ENTERED AT ${DateTime.now().toIso8601String()}");
    
    // 🔍 Теперь безопасно обращаемся к device
    String id = "UNKNOWN";
    String shortMac = "UNKNOWN";
    try {
      _log("🦷🔍 [BT-DIAGNOSTIC] Accessing device.remoteId...");
      id = device.remoteId.str;
      shortMac = id.length > 8 ? id.substring(id.length - 8) : id;
      _log("🦷🔍 [BT-DIAGNOSTIC] sendMessage - shortMac: $shortMac, msg length: ${message.length}");
    } catch (e) {
      _log("🦷❌ [BT-DIAGNOSTIC] FAILED to access device.remoteId: $e");
      return false;
    }
    
    _log("🔗 [SEND-MSG] Starting sendMessage to $shortMac");
    _log("   📋 Message length: ${message.length} chars");
    _log("   📋 Pending devices: $_pendingDevices");
    _log("   📋 GATT state: $_gattConnectionState, connecting: $_isGattConnecting");
    
    if (_pendingDevices.contains(id)) {
      _log("⏳ [SEND-MSG] Device $shortMac already in queue, skipping duplicate.");
      return false;
    }

    _pendingDevices.add(id);
    _log("✅ [SEND-MSG] Device $shortMac added to queue, calling _sendWithDynamicRetries...");
    
    try {
      // Вызываем напрямую, без очереди, чтобы получить реальный результат
      await _sendWithDynamicRetries(device, message);
      _log("✅ [SEND-MSG] _sendWithDynamicRetries completed successfully for $shortMac");
      return true; // Успех, если не было исключения
    } catch (e) {
      _log("❌ [SEND-MSG] Failed for $shortMac: $e");
      return false;
    } finally {
      _pendingDevices.remove(id);
      _log("🔓 [SEND-MSG] Device $shortMac removed from queue");
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
      _log("⏸️ [QuickLink] Cannot connect in state: ${_stateMachine.state}, skipping.");
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
      _log("⏸️ [QuickLink] Cannot connect in state: ${_stateMachine.state}, skipping.");
      return;
    }
    
    try {
      await _stateMachine.transition(BleState.CONNECTING);
    } catch (e) {
      _log("❌ [QuickLink] Invalid state transition: $e");
      return;
    }
    
    _advState = BleAdvertiseState.connecting;
    _log("⚡ Auto-Link triggered for ${device.remoteId}");

    try {
      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      if (Platform.isAndroid) await device.requestMtu(247);

      final services = await device.discoverServices();
      final targetService = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      final targetChar = targetService.characteristics.firstWhere((c) => c.uuid.toString() == CHAR_UUID);

      await targetChar.write(pulse, withoutResponse: true);
      _log("🛰️ Tactical pulse delivered to ${device.remoteId}");
    } catch (e) {
      _log("⚠️ QuickLink failed: $e");
    } finally {
      try { await device.disconnect(); } catch (_) {}
      // Reset FSM to IDLE
      await _stateMachine.forceTransition(BleState.IDLE);
      _advState = BleAdvertiseState.idle;
    }
  }


  // ======================================================
  // 📡 PERIPHERAL MODE (Advertising)
  // ======================================================

  Future<void> startAdvertising(String myName) async {
    // 🔥 ОПТИМИЗАЦИЯ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Проверяем минимальный интервал
    if (_lastAdvOperation != null) {
      final timeSinceLastOp = DateTime.now().difference(_lastAdvOperation!);
      if (timeSinceLastOp < _minAdvInterval) {
        final waitTime = _minAdvInterval - timeSinceLastOp;
        _log("⏸️ [ADV] Too soon since last operation (${timeSinceLastOp.inMilliseconds}ms), waiting ${waitTime.inMilliseconds}ms...");
        await Future.delayed(waitTime);
      }
    }
    _lastAdvOperation = DateTime.now();
    
    // 🔥 FSM: Проверяем состояние перед стартом
    // 🔄 Use FSM for state validation
    if (!_stateMachine.canAdvertise()) {
      _log("⏸️ [ADV] Cannot advertise in state: ${_stateMachine.state}, skipping.");
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
        _log("ℹ️ [ADV] GATT server not running (will be started later if needed)");
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
          _log("🛑 [ADV] Force stopping all advertising sets (prevent TOO_MANY_ADVERTISERS)...");
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
              _log("ℹ️ [ADV] Advertising callback already removed by system (this is normal)");
            } else if (stopErrorStr.contains('Reply already submitted')) {
              _log("ℹ️ [ADV] Reply already submitted - stop was already processed");
            } else {
              _log("⚠️ [ADV] Error stopping advertising: $stopError");
            }
            // Даем время на стабилизацию даже при ошибке
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } else {
          _log("ℹ️ [ADV] Skipping pre-start cleanup (no previous advertising detected)");
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
                _log("ℹ️ [ADV] Reply already submitted on force stop - continuing");
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
          _log("🔑 [ADV] Token extracted from original name: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (length: ${extractedToken.length})");
        } else if (myName.contains("BRIDGE_")) {
          // Fallback: если формат немного отличается, пытаемся извлечь после "BRIDGE_"
          final bridgeIndex = myName.indexOf("BRIDGE_");
          if (bridgeIndex != -1) {
            final tokenStart = bridgeIndex + 7; // "BRIDGE_".length = 7
            if (tokenStart < myName.length) {
              extractedToken = myName.substring(tokenStart);
              _log("🔑 [ADV] Token extracted from original name (fallback): ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (length: ${extractedToken.length})");
            }
          }
        } else {
          // 🔥 FIX: Если имя короткое (M_0_0_df78) без BRIDGE_TOKEN
          // Это означает, что вызов пришел НЕ из emitInternetMagnetWave()
          // В этом случае мы НЕ должны рекламировать - это ошибка вызывающего кода
          _log("⚠️ [ADV] BRIDGE name without token detected: '$myName'");
          _log("   📋 Parts: ${parts.join(', ')} (length: ${parts.length})");
          _log("   ❌ Token extraction FAILED - name does not contain 'BRIDGE_TOKEN' format");
          _log("   💡 This call should come from emitInternetMagnetWave() with proper token");
          _log("   💡 Advertising will have manufacturerData=[66,82] (BR only, NO TOKEN)");
          _log("   ⚠️ GHOST devices will see this BRIDGE but GATT will be FORBIDDEN!");
        }
      }

      // 🔍 ВАЛИДАЦИЯ И ОБРЕЗКА ИМЕНИ (BLE ограничение: ~29 байт, но безопаснее ~20)
      String safeName = myName;
      if (safeName.length > 20) {
        _log("⚠️ [ADV] Name too long (${safeName.length}), truncating to 20 chars.");
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
          _log("🌉 [BRIDGE] Step 1: Starting GATT Server before advertising...");
          final serverStarted = await _startGattServerAndWait();
          if (!serverStarted) {
            _log("⚠️ [BRIDGE] Failed to start GATT server - continuing in fallback mode (advertising without GATT server)");
            // 🔥 FALLBACK: Продолжаем рекламировать даже без GATT server
            // GHOST устройства могут найти нас по тактическому имени
            // GATT server может запуститься позже
          } else {
            _log("✅ [BRIDGE] Step 1 Complete: GATT Server ready (onGattReady received)");
          }
        } else {
          _log("ℹ️ [BRIDGE] GATT Server already running - skipping start");
        }
      }

      _log("📡 [ADV] Starting with name: '$safeName' (${safeName.length} chars)");

      // 🔥 КРИТИЧНО: Добавляем manufacturerData с токеном ДО обрезки имени
      // manufacturerData должен быть Uint8List, а не Map
      // Используем manufacturerId = 0xFFFF (зарезервированный для тестирования)
      // 🔥 КРИТИЧНО: Для BRIDGE ВСЕГДА добавляем token в manufacturerData (даже если localName пустое)
      Uint8List manufacturerData;
      if (isBridge) {
        if (extractedToken != null && extractedToken.isNotEmpty) {
          // Формат manufacturerData для BRIDGE с token:
          // [0x42, 0x52, ...token_bytes] (первые 2 байта = "BR", остальное = token)
          // Ограничение: manufacturerData обычно до 31 байт, но безопаснее ~25 для надежности
          final tokenBytes = utf8.encode(extractedToken);
          final maxTokenBytes = 23; // 25 - 2 (BR) = 23 байт для token (увеличено для надежности)
          final truncatedToken = tokenBytes.length > maxTokenBytes 
              ? tokenBytes.sublist(0, maxTokenBytes) 
              : tokenBytes;
          
          manufacturerData = Uint8List.fromList([0x42, 0x52, ...truncatedToken]);
          _log("🔍 [ADV] BRIDGE with token in manufacturerData: ${extractedToken.length > 8 ? extractedToken.substring(0, 8) : extractedToken}... (${manufacturerData.length} bytes)");
          _log("   📋 Token bytes: ${truncatedToken.length} bytes (original: ${tokenBytes.length} bytes)");
        } else {
          // 🔥 FALLBACK: Если токен не найден, все равно рекламируем "BR" для определения роли
          manufacturerData = Uint8List.fromList([0x42, 0x52]); // "BR" = BRIDGE без token
          _log("⚠️ [ADV] BRIDGE without token in manufacturerData (token extraction failed)");
          _log("   📋 Original name: '$myName'");
          _log("   📋 Safe name: '$safeName'");
        }
      } else {
        manufacturerData = Uint8List.fromList([0x47, 0x48]); // "GH" = GHOST
      }
      
      final data = AdvertiseData(
        serviceUuid: SERVICE_UUID,
        localName: safeName,
        includeDeviceName: false, // 🔥 ВАЖНО: Ставим false, чтобы сэкономить 20 байт
        manufacturerId: 0xFFFF, // 🔥 FIX: Manufacturer ID для тестирования
        manufacturerData: manufacturerData, // 🔥 FIX: Добавляем роль и token в manufacturerData
      );
      
      _log("🔍 [ADV] Advertising with manufacturerData: ${isBridge ? 'BRIDGE' : 'GHOST'} (0xFFFF: ${manufacturerData.length} bytes)");

      // 🔥 FIX: Используем native advertiser для Huawei/Honor если flutter_ble_peripheral не работает
      bool advertisingStarted = false;
      
      // Reset tracking flags before starting
      _advertisingStartedSuccessfully = false;
      _nativeAdvertisingStarted = false;
      
      if (_useNativeAdvertiser && Platform.isAndroid) {
        _log("🔧 [ADV] Using native BLE advertiser (Huawei/Honor mode)");
        try {
          final success = await _nativeAdvChannel.invokeMethod<bool>('startAdvertising', {
            'localName': safeName,
            'manufacturerData': manufacturerData,
          });
          advertisingStarted = success ?? false;
          
          if (advertisingStarted) {
            _log("✅ [ADV] Native advertiser started successfully");
            _nativeAdvertisingStarted = true;
          } else {
            _log("⚠️ [ADV] Native advertiser failed, falling back to flutter_ble_peripheral");
          }
        } catch (e) {
          _log("⚠️ [ADV] Native advertiser error: $e, falling back to flutter_ble_peripheral");
        }
      }
      
      // Fallback или стандартный путь
      if (!advertisingStarted) {
        try {
          await _blePeripheral.start(advertiseData: data);
          advertisingStarted = true;
          _log("✅ [ADV] flutter_ble_peripheral started successfully");
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
        _log("❌ [ADV] Failed to start: ADVERTISE_FAILED_TOO_MANY_ADVERTISERS (status=1)");
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
              // Определяем роль для manufacturerData
              final currentRole = NetworkMonitor().currentRole;
              final isBridgeRole = currentRole == MeshRole.BRIDGE;
              
              final success = await _nativeAdvChannel.invokeMethod<bool>('startAdvertising', {
                'localName': myName.length > 8 ? myName.substring(0, 8) : myName,
                'manufacturerData': isBridgeRole 
                    ? Uint8List.fromList([0x42, 0x52]) // "BR"
                    : Uint8List.fromList([0x47, 0x48]), // "GH"
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
          
          _log("   💡 This device may have limitations on concurrent BLE advertising");
          _log("   💡 GHOST devices can still connect via TCP if they have IP/port from MAGNET_WAVE");
        } catch (cleanupError) {
          _log("   ⚠️ Cleanup failed: $cleanupError");
        }
        
        _log("   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else if (errorStr.contains('status=2')) {
        _log("❌ [ADV] Failed to start: ADVERTISE_FAILED_ALREADY_STARTED (status=2)");
        _log("   ⚠️ Advertising already active, attempting to stop and restart...");
        try {
          await _blePeripheral.stop();
          await Future.delayed(const Duration(milliseconds: 500));
          // Не пытаемся перезапустить автоматически - пусть вызывающий код решает
        } catch (_) {}
      } else if (errorStr.contains('status=3')) {
        _log("❌ [ADV] Failed to start: ADVERTISE_FAILED_FEATURE_UNSUPPORTED (status=3)");
        _log("   ⚠️ BLE advertising not supported on this device");
        _log("   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else if (errorStr.contains('status=4')) {
        _log("❌ [ADV] Failed to start: ADVERTISE_FAILED_INTERNAL_ERROR (status=4)");
        _log("   ⚠️ Internal BLE stack error");
        _log("   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      } else {
        _log("❌ [ADV] Failed to start: $e");
        _log("   🔄 Will continue without BLE advertising (TCP/GATT server still available)");
      }
    }
  }

  /// Останавливает BLE advertising
  /// 
  /// [keepGattServer] - если true, GATT сервер НЕ будет остановлен.
  /// Используйте keepGattServer=true при обновлении advertising (token rotation),
  /// чтобы избежать 25-секундного таймаута при перезапуске GATT сервера.
  Future<void> stopAdvertising({bool keepGattServer = false}) async {
    // 🔥 FIX: Mutex to prevent concurrent stop operations causing "Reply already submitted"
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
          _log("⏸️ [ADV] Too soon since last operation (${timeSinceLastOp.inMilliseconds}ms), waiting ${waitTime.inMilliseconds}ms...");
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
      if (_nativeAdvertisingStarted && _useNativeAdvertiser && Platform.isAndroid) {
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
            _log("ℹ️ [ADV] Reply already submitted - stop was already processed");
          } else {
            _log("⚠️ [ADV] Error stopping: $e");
          }
        }
      } else {
        _log("ℹ️ [ADV] Advertising was never started successfully, skipping stop call");
      }
      
      // Reset tracking flags
      _advertisingStartedSuccessfully = false;
      
    } catch (e) {
      _log("⚠️ [ADV] Error in stopAdvertising: $e");
      // Игнорируем ошибки при остановке, чтобы не блокировать состояние
    } finally {
      // 🔥 FSM: Фиксируем состояние idle только после полной остановки
      // FSM state already set to IDLE in transition above
      _advState = BleAdvertiseState.idle;
      _log("💤 FSM → IDLE");
      
      // 🔒 Fix BLE state machine: Complete completer when state becomes idle
      if (_stateIdleCompleter != null && !_stateIdleCompleter!.isCompleted) {
        _stateIdleCompleter!.complete();
        _stateIdleCompleter = null;
      }
      
      // 🔥 FIX: Release mutex
      _isStopInProgress = false;
    }
  }
  
  // ======================================================
  // 🔥 GATT SERVER MANAGEMENT
  // ======================================================
  
  Completer<bool>? _serviceAddedCompleter;
  
  /// Запускает GATT сервер и ждет подтверждения готовности (для BRIDGE)
  /// Таймаут отсчитывается от момента addService(), а не от начала запуска
  /// Проверяет, запущен ли GATT server
  Future<bool> _isGattServerRunning() async {
    try {
      final result = await _gattChannel.invokeMethod<bool>('isGattServerRunning');
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
      final result = await _gattChannel.invokeMethod<Map>('getGattServerStatus');
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
      _log("🚀 [GATT-SERVER] Starting GATT server and waiting for onGattReady...");
      
      // 🔥 ПРОВЕРКА: Если GATT server уже запущен, не запускаем повторно
      final isRunning = await _isGattServerRunning();
      if (isRunning) {
        _log("ℹ️ [GATT-SERVER] GATT server already running, skipping start");
        return true;
      }
      
      // 🔥 ДУБЛИРУЮЩАЯ ПРОВЕРКА: Убеждаемся, что сервер действительно остановлен
      final isAdvertising = await _blePeripheral.isAdvertising;
      if (isAdvertising) {
        _log("⚠️ [GATT-SERVER] Advertising still active, stopping before GATT server start...");
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
        _log("⚠️ [GATT-SERVER] FSM state is not idle ($_advState), attempting recovery...");
        
        // Ждём 2 секунды для естественного перехода в IDLE
        if (_stateIdleCompleter == null || _stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter = Completer<void>();
        }
        try {
          await _stateIdleCompleter!.future.timeout(const Duration(seconds: 2));
          _log("✅ [GATT-SERVER] FSM naturally transitioned to IDLE");
        } catch (e) {
          // 🔥 FIX: Принудительный сброс FSM вместо abort
          _log("⚠️ [GATT-SERVER] FSM still not idle, forcing reset to IDLE...");
          _advState = BleAdvertiseState.idle;
          
          // Сбрасываем BLE state machine если она есть
          try {
            if (_stateMachine.state != BleState.IDLE) {
              await _stateMachine.forceTransition(BleState.IDLE);
            }
          } catch (_) {
            // Ignore
          }
          
          // Даём время BLE стеку стабилизироваться после сброса
          await Future.delayed(const Duration(milliseconds: 500));
          _log("✅ [GATT-SERVER] FSM forcefully reset to IDLE");
        }
      }
      
      // 🔥 ОБНОВЛЕННАЯ ЛОГИКА COMPLETER: Обработка поздних событий
      // Если completer уже существует и не завершён - используем его
      // Если завершён или null - создаём новый
      if (_serviceAddedCompleter == null || _serviceAddedCompleter!.isCompleted) {
        _serviceAddedCompleter = Completer<bool>();
        _log("📝 [GATT-SERVER] New completer created, waiting for onGattReady event...");
      } else {
        _log("📝 [GATT-SERVER] Reusing existing completer, waiting for onGattReady event...");
      }
      
      // Запускаем сервер (addService() будет вызван внутри)
      final result = await _gattChannel.invokeMethod<bool>('startGattServer');
      _log("📡 [GATT-SERVER] startGattServer returned: $result");
      
      if (result != true) {
        _log("⚠️ [GATT-SERVER] Failed to start GATT server");
        _serviceAddedCompleter = null;
        return false;
      }
      
      // 🔥 ТАЙМАУТ ОТСЧИТЫВАЕТСЯ ОТ addService()
      // addService() вызывается синхронно внутри startGattServer(),
      // поэтому таймаут начинается сразу после возврата из startGattServer()
      // Увеличен до 25 секунд для Huawei (иногда onGattReady приходит через 20 секунд)
      _log("⏳ [GATT-SERVER] Waiting for onGattReady event (timeout: 25s from addService())...");
      
      try {
        final gattReady = await _serviceAddedCompleter!.future.timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            // 🔥 ИСПРАВЛЕНИЕ: Проверяем, не завершен ли completer перед возвратом false
            if (_serviceAddedCompleter != null && _serviceAddedCompleter!.isCompleted) {
              _log("ℹ️ [GATT-SERVER] Timeout occurred, but completer already completed (late event handled)");
              // Completer уже завершен - событие пришло, но поздно
              return true;
            }
            _log("⏱️ [GATT-SERVER] Timeout waiting for onGattReady (25s from addService())");
            _log("⚠️ [GATT-SERVER] Completer state: ${_serviceAddedCompleter != null ? 'exists' : 'null'}, completed: ${_serviceAddedCompleter?.isCompleted ?? 'N/A'}");
            return false;
          },
        );
        
        _log("✅ [GATT-SERVER] onGattReady received: $gattReady");
        _serviceAddedCompleter = null;
        return gattReady;
      } catch (e) {
        // 🔥 ИСПРАВЛЕНИЕ: Проверяем completer даже при ошибке
        if (_serviceAddedCompleter != null && _serviceAddedCompleter!.isCompleted) {
          _log("✅ [GATT-SERVER] Error occurred, but completer already completed (late event handled)");
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
  
  Future<void> _startGattServer() async {
    try {
      final result = await _gattChannel.invokeMethod<bool>('startGattServer');
      if (result == true) {
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
        _log("ℹ️ [AUTO-GATT] Not a BRIDGE device, skipping GATT server auto-start");
        return false;
      }
      
      _log("🚀 [AUTO-GATT] BRIDGE detected, starting GATT server automatically...");
      
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
          _log("⚠️ [AUTO-GATT] Advertising still active, stopping before GATT server start...");
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
        _log("⚠️ [AUTO-GATT] GATT server failed to start on app launch (will retry later)");
        return false;
      }
    } catch (e) {
      _log("❌ [AUTO-GATT] Error in auto-start: $e");
      return false;
    }
  }
  
  /// Вызывается из нативного кода при готовности GATT сервера (после onServiceAdded)
  /// [generation] - версия GATT сервера от native (для логирования и диагностики)
  /// 
  /// 🔥 NOTE: Основная защита от race condition реализована на native стороне:
  /// - Native отменяет pending callbacks при stopGattServer()
  /// - Native использует generation для игнорирования stale callbacks
  /// Flutter просто принимает любой валидный onGattReady для активного completer
  void _onGattReady({int? generation}) {
    _log("🔔 [GATT-SERVER] _onGattReady called (native gen: $generation)");
    _log("🔔 [GATT-SERVER] Completer state: ${_serviceAddedCompleter != null ? 'exists' : 'null'}, completed: ${_serviceAddedCompleter?.isCompleted ?? 'N/A'}");
    
    // 🔥 ОБНОВЛЕННАЯ ЛОГИКА COMPLETER: 
    // Если completer существует и не завершён - завершаем его
    // Если completer null или уже завершён - просто логируем (не создаём новый)
    if (_serviceAddedCompleter == null) {
      _log("ℹ️ [GATT-SERVER] No active completer - onGattReady event ignored (possibly late event after timeout)");
    } else if (_serviceAddedCompleter!.isCompleted) {
      _log("ℹ️ [GATT-SERVER] Completer already completed - onGattReady event ignored (duplicate event)");
    } else {
      _serviceAddedCompleter!.complete(true);
      _log("✅ [GATT-SERVER] Completer completed - GATT server is ready (native gen: $generation)");
    }
  }
  
  Future<void> _stopGattServer() async {
    try {
      await _gattChannel.invokeMethod('stopGattServer');
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

  Future<void> _sendWithDynamicRetries(BluetoothDevice device, String message) async {
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
      throw Exception("BT CONNECT permission missing"); // 🔥 FIX: throw, не return!
    }

    // 🔥 FIX: GATT MUTEX - запрет параллельных попыток connect
    final targetMac = device.remoteId.str;
    if (_isGattConnecting) {
      final elapsed = _gattConnectStartTime != null 
          ? DateTime.now().difference(_gattConnectStartTime!).inSeconds 
          : 0;
      
      // Принудительный сброс если mutex завис больше 20 секунд
      if (elapsed > _gattConnectTimeout.inSeconds) {
        _releaseGattMutex("force release stuck mutex (${elapsed}s > ${_gattConnectTimeout.inSeconds}s)");
      } else {
        _log("🚫 [GATT-MUTEX] Connection already in progress to $_currentGattTargetMac (${elapsed}s elapsed)");
        _log("   📋 New target $targetMac BLOCKED - wait for current connection to complete");
        throw Exception("GATT connection already in progress");
      }
    }
    
    // 🔥 FIX: Захватываем GATT mutex
    _isGattConnecting = true;
    _gattConnectStartTime = DateTime.now();
    _currentGattTargetMac = targetMac;
    _gattConnectionState = 'CONNECTING';
    _log("🔒 [GATT-MUTEX] Acquired - target: $targetMac");
    
    // 🔥 FIX: ПРИНУДИТЕЛЬНАЯ ОСТАНОВКА SCAN ПЕРЕД CONNECT
    // Это критично для Android - scan и connect конфликтуют на BLE стеке
    _log("🛑 [GATT] FORCE stopping BLE scan before connect...");
    try {
      await FlutterBluePlus.stopScan();
      // Ждём реальной остановки scan
      int scanCheckAttempts = 0;
      while (FlutterBluePlus.isScanningNow && scanCheckAttempts < 10) {
        await Future.delayed(const Duration(milliseconds: 100));
        scanCheckAttempts++;
      }
      if (FlutterBluePlus.isScanningNow) {
        _log("⚠️ [GATT] Scan still active after 1s - proceeding anyway (risky!)");
      } else {
        _log("✅ [GATT] Scan confirmed STOPPED after ${scanCheckAttempts * 100}ms");
      }
    } catch (e) {
      _log("⚠️ [GATT] Error stopping scan: $e - proceeding anyway");
    }
    
    // 🔥 FIX: Пауза 500ms для стабилизации BLE стека после остановки scan
    _log("⏸️ [GATT] Waiting 500ms for BLE stack stabilization after scan stop...");
    await Future.delayed(const Duration(milliseconds: 500));

    _log("🚀 [GATT-DATA-ATTACK] Target: ${device.remoteId}");
    
    // 🔥 КРИТИЧЕСКАЯ ПРОВЕРКА: Убеждаемся, что устройство рекламирует наш сервис
    // Это важно, так как без SERVICE_UUID подключение не имеет смысла
    bool hasServiceUuid = false;
    String? deviceLocalName;
    bool canProceed = false;
    String? originalAdvName; // Сохраняем оригинальное имя для проверки изменений
    bool hasTacticalName = false; // Объявляем вне блока для доступа везде
    bool isBridgeByMfData = false; // Объявляем вне блока для доступа везде
    
    try {
      // Проверяем последние scan results для этого устройства
      final lastScanResults = await FlutterBluePlus.lastScanResults;
      _log("🔍 [PRE-CONNECT] Checking scan results (total: ${lastScanResults.length})...");
      
      if (lastScanResults.isEmpty) {
        _log("⚠️ [WARNING] No scan results available. Device may have stopped advertising.");
        _log("   🔥 HUAWEI FIX: Proceeding with connection anyway (scan may be stopped)");
        // На Huawei scan может быть остановлен, но устройство все еще доступно
        canProceed = true; // Продолжаем без проверки scan results
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
            // Fallback 2: Ищем по manufacturerData (для рандомизированных MAC на Huawei)
            for (final result in lastScanResults) {
              final mfData = result.advertisementData.manufacturerData[0xFFFF];
              final isBridgeByMfData = mfData != null && 
                  mfData.length >= 2 && 
                  mfData[0] == 0x42 && 
                  mfData[1] == 0x52; // "BR" = BRIDGE
              final hasService = result.advertisementData.serviceUuids
                  .any((uuid) => uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase());
              
              // Если это BRIDGE через manufacturerData или service UUID - используем его
              if ((isBridgeByMfData || hasService) && result.device.remoteId.str == targetMac) {
                deviceScanResult = result;
                _log("✅ [PRE-CONNECT] Found device by manufacturerData fallback: $targetMac");
                break;
              }
            }
            
            if (deviceScanResult == null) {
              _log("⚠️ [WARNING] Device not found in scan results, but proceeding anyway (Huawei quirk)");
              canProceed = true; // Продолжаем без scan result на Huawei
            }
          }
        }
        
        if (deviceScanResult != null) {
        
          deviceLocalName = deviceScanResult.advertisementData.localName;
          originalAdvName = deviceLocalName; // Сохраняем для проверки изменений
          hasServiceUuid = deviceScanResult.advertisementData.serviceUuids
              .any((uuid) => uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase());
          
          // 🔥 HUAWEI FIX: Проверяем manufacturerData как fallback
          final mfData = deviceScanResult.advertisementData.manufacturerData[0xFFFF];
          isBridgeByMfData = mfData != null && 
              mfData.length >= 2 && 
              mfData[0] == 0x42 && 
              mfData[1] == 0x52; // "BR" = BRIDGE
          
          // Определяем hasTacticalName
          hasTacticalName = deviceLocalName?.startsWith("M_") ?? false;
          
          _log("🔍 [PRE-CONNECT] Device scan data:");
          _log("   Local name: '${deviceLocalName ?? 'NONE'}'");
          _log("   Has SERVICE_UUID: $hasServiceUuid");
          _log("   Is BRIDGE by manufacturerData: $isBridgeByMfData");
          _log("   Has tactical name: $hasTacticalName");
          _log("   Available UUIDs: ${deviceScanResult.advertisementData.serviceUuids.map((u) => u.toString()).join(', ')}");
          _log("   Manufacturer data: ${deviceScanResult.advertisementData.manufacturerData}");
          
          // 🔥 HUAWEI/TECNO/INFINIX QUIRK: Эти устройства часто не рекламируют local name, но рекламируют SERVICE_UUID или manufacturerData
          // Если есть SERVICE_UUID или manufacturerData BRIDGE - это валидное mesh устройство
          
          if (!hasServiceUuid && !hasTacticalName && !isBridgeByMfData) {
            _log("❌ [CRITICAL] Target device ${device.remoteId} does NOT advertise SERVICE_UUID, tactical name, or manufacturerData");
            _log("   Cannot connect - device is not a valid mesh node");
            // 🔥 FIX: Release GATT mutex and throw exception for proper error handling
            _releaseGattMutex("pre-connect validation failed - not a valid mesh node", state: 'FAILED');
            throw Exception("Device is not a valid mesh node (no SERVICE_UUID, tactical name, or manufacturerData)");
          }
          
          canProceed = true; // Устройство валидно
        } else {
          // Если deviceScanResult == null, но canProceed уже установлен (Huawei quirk)
          // Проверяем дополнительные условия
          if (!canProceed) {
            // 🔥 TECNO: Если local name пустое, но есть SERVICE_UUID или manufacturerData - это нормально
            if (deviceLocalName?.isEmpty ?? true) {
              if (hasServiceUuid) {
                _log("ℹ️ [TECNO/INFINIX] Local name is empty, but SERVICE_UUID is present - this is normal for these devices");
                canProceed = true;
              } else if (isBridgeByMfData) {
                // 🔥 FIX: Allow connection if BRIDGE detected via manufacturerData (Huawei quirk)
                _log("ℹ️ [HUAWEI] Local name is empty and no SERVICE_UUID, but BRIDGE detected via manufacturerData - proceeding");
                canProceed = true;
              } else {
                _log("⚠️ [WARNING] Local name is empty, no SERVICE_UUID, no manufacturerData - aborting connection");
                _releaseGattMutex("no valid mesh indicators", state: 'FAILED');
                throw Exception("Device has no SERVICE_UUID, tactical name, or manufacturerData");
              }
            }
            
            if (!hasServiceUuid && hasTacticalName) {
              _log("⚠️ [WARNING] Device has tactical name but no SERVICE_UUID (Huawei/Tecno quirk?)");
              _log("   Will attempt connection anyway, but service discovery may fail");
              canProceed = true;
            }
            
            if (hasServiceUuid) {
              _log("✅ [VERIFY] Target device advertises SERVICE_UUID ($SERVICE_UUID)");
              canProceed = true;
            }
            
            // 🔥 FIX: Allow connection if BRIDGE detected via manufacturerData
            if (!canProceed && isBridgeByMfData) {
              _log("✅ [VERIFY] BRIDGE detected via manufacturerData - proceeding");
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
        _log("🚫 [ABORT] Cannot proceed with connection - device is not valid or not found");
        // 🔥 FIX: Release GATT mutex and rethrow
        _releaseGattMutex("pre-connect exception", state: 'FAILED');
        rethrow; // Propagate the exception
      }
      _log("⚠️ [WARNING] Will attempt connection anyway, but may fail if service is not available");
      canProceed = true; // Продолжаем только если это не критическая ошибка
    }
    
    // Если проверка не прошла - не продолжаем
    if (!canProceed) {
      _log("🚫 [ABORT] Pre-connect verification failed. Aborting GATT connection attempts.");
      // 🔥 FIX: Release GATT mutex and throw exception
      _releaseGattMutex("pre-connect verification failed", state: 'FAILED');
      throw Exception("Pre-connect verification failed - canProceed is false");
    }

    // Подписка на состояние подключения (важно для Tecno/MTK)
    StreamSubscription<BluetoothConnectionState>? stateSub;

    // Глобальный таймер на всю сессию GATT (чтобы не висеть вечно на проблемном чипе)
    final DateTime sessionStart = DateTime.now();
    const Duration maxSessionDuration = Duration(seconds: 60); // Увеличено для проблемных устройств

    bool delivered = false;

    for (int attempt = 1; attempt <= 3; attempt++) {
      // Если мы уже слишком долго мучаем одно устройство — выходим и даем каскаду перейти на другие каналы
      final elapsed = DateTime.now().difference(sessionStart);
      if (elapsed > maxSessionDuration) {
        _log("⏱️ GATT session timed out globally after ${elapsed.inSeconds}s (max: ${maxSessionDuration.inSeconds}s). Aborting.");
        break;
      }
      
      // Логируем прогресс каждые 10 секунд
      if (elapsed.inSeconds > 0 && elapsed.inSeconds % 10 == 0) {
        _log("⏳ [PROGRESS] GATT session in progress: ${elapsed.inSeconds}s elapsed, attempt $attempt/3");
      }

      // 🔥 FIX: УБРАНА ПРОВЕРКА lastScanResults ПОСЛЕ ОСТАНОВКИ SCAN
      // После stopScan() lastScanResults пустой, что вызывало мгновенный break
      // Мы уже проверили устройство ДО остановки scan - повторная проверка невозможна
      // GHOST уже сохранил ScanResult - используем его напрямую
      _log("📋 [ATTEMPT $attempt] Skipping scan results check (scan already stopped)");
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
        
        // 🔥 КРИТИЧНО: Пауза 300-800ms для стабилизации Android BLE стека
        final pauseDuration = const Duration(milliseconds: 500); // Оптимально для 100k+ пользователей
        _log("⏸️ [GHOST] Waiting ${pauseDuration.inMilliseconds}ms for BLE stack stabilization...");
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
        
        // Дополнительная пауза после disconnect для стабилизации стека
        await Future.delayed(const Duration(milliseconds: 1000));

        // Ожидаем состояние connected через stream
        final connCompleter = Completer<bool>();
        stateSub = device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.connected && !connCompleter.isCompleted) {
            connCompleter.complete(true);
          } else if (s == BluetoothConnectionState.disconnected && !connCompleter.isCompleted) {
            connCompleter.complete(false);
          }
        });

        final elapsed = DateTime.now().difference(sessionStart);
        _log("🔗 GATT Attempt $attempt/3: Connecting to ${device.remoteId}...");
        _log("   Device name: ${device.platformName.isNotEmpty ? device.platformName : 'Unknown'}");
        _log("   Device ID: ${device.remoteId}");
        _log("   Session elapsed: ${elapsed.inSeconds}s / ${maxSessionDuration.inSeconds}s");
        
        // 🔥 УВЕЛИЧЕННЫЙ ТАЙМАУТ ДЛЯ TECNO/INFINIX: 15s для первой попытки, 20s для второй, 25s для третьей
        // Эти устройства требуют больше времени для установления GATT соединения
        final timeoutDuration = Duration(seconds: 15 + (attempt * 5));
        _log("   Connection timeout: ${timeoutDuration.inSeconds}s (extended for problematic devices)");
        
        // 🔥 FIX: Убрана проверка visibility - она fail'илась из-за MAC рандомизации
        // GHOST уже получил ScanResult с BRIDGE - этого достаточно для GATT connect
        // MAC может измениться между scan и connect на Android (особенно Huawei)
        _log("📡 [GATT] Skipping visibility check (MAC randomization workaround)");
        _log("   📋 Proceeding with saved device reference directly");
        
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
        
        // 🔥 FIX: Добавляем progress timer для диагностики
        Timer? progressTimer;
        progressTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
          final elapsed = DateTime.now().difference(connectStart).inSeconds;
          _log("⏳ [CONNECT] Still waiting for connection... (${elapsed}s elapsed)");
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
          // 🔥 FIX: Принудительный disconnect при ошибке connect
          try {
            await device.disconnect();
            _log("🔌 [CONNECT] Forced disconnect after connect failure");
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
          _log("⏳ [CONNECT] Checking connection state IMMEDIATELY (not waiting for stream)...");
          
          // Сначала проверяем device.isConnected напрямую
          final directCheck = device.isConnected;
          _log("   📋 Direct device.isConnected: $directCheck");
          _log("🦷🔍 [BT-DIAG] Direct isConnected: $directCheck");
          
          if (directCheck) {
            // Если device.connect() вернулся успешно И isConnected=true, 
            // НЕ ЖДЁМ stream - сразу идём дальше!
            _log("✅ [CONNECT] Connection confirmed via direct check - skipping stream wait!");
            connected = true;
          } else {
            // Если direct check = false, даём stream шанс (может быть задержка)
            _log("⚠️ [CONNECT] Direct check=false, waiting for stream (max 2s)...");
            
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
          _log("❌ [CONNECT] Failed after ${connectElapsed.inSeconds}s - device not connected");
          
          // 🔥 FIX: Update GATT connection state on failure
          _gattConnectionState = 'FAILED';
          _log("🔗 [GATT-STATE] State: FAILED");
          
          _log("   📋 Device: ${device.remoteId}");
          _log("   📋 Connection state: ${device.isConnected}");
          _log("   📋 Connection elapsed: ${connectElapsed.inSeconds}s");
          _log("   💡 Possible reasons:");
          _log("      1. BRIDGE GATT server not running or not ready");
          _log("      2. BRIDGE advertising not active (SERVICE_UUID not advertised)");
          _log("      3. Device out of range or stopped advertising");
          _log("      4. BLE stack issue on BRIDGE device (Huawei/Android BLE limitations)");
          _log("      5. BRIDGE GATT server crashed or not started");
          _log("      6. Permission issues on BRIDGE device");
          _log("   🔍 Check BRIDGE logs for:");
          _log("      - GATT server start status");
          _log("      - Advertising status");
          _log("      - onGattClientConnected events");
          throw Exception("No connect state after ${connectElapsed.inSeconds}s");
        }

        _log("✅ [SUCCESS] Link Established after ${connectElapsed.inSeconds}s! Discovering services...");
        
        // 🔥 FIX: Update GATT connection state
        _gattConnectionState = 'CONNECTED';
        _log("🔗 [GATT-STATE] State: CONNECTED");
        
        // 🔄 Use FSM for state transition
        try {
          await _stateMachine.transition(BleState.CONNECTED);
        } catch (e) {
          _log("⚠️ [GATT] Invalid state transition to CONNECTED: $e");
        }
        _advState = BleAdvertiseState.connected;

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
            _log("📐 [MTU] Requesting MTU 158 (safe value for most devices)...");
            _log("🦷🔍 [BT-DIAG] Requesting MTU...");
            await device.requestMtu(158);
            await Future.delayed(const Duration(milliseconds: 300)); // 🔥 Увеличили паузу
            
            // 🔥 CRITICAL: Проверяем что соединение не разорвалось после MTU request!
            if (!device.isConnected) {
              _log("❌ [MTU] Connection lost AFTER MTU request - Huawei quirk detected!");
              _log("🦷🔍 [BT-DIAG] Connection lost after MTU - reconnecting...");
              // Пробуем переподключиться без MTU request
              throw Exception("MTU request caused disconnect - will retry without MTU");
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
        bool skipCacheClear = true; // 🔥 По умолчанию пропускаем для стабильности
        
        if (!skipCacheClear) {
          try {
            _log("🦷🔍 [BT-DIAG] Clearing GATT cache...");
            _log("🧹 [DISCOVERY] Clearing GATT cache (Android fix)...");
            await device.clearGattCache();
            await Future.delayed(const Duration(milliseconds: 300));
            
            // 🔥 CRITICAL: Проверяем соединение после cache clear!
            if (!device.isConnected) {
              _log("❌ [DISCOVERY] Connection lost after cache clear - Huawei quirk!");
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
          _log("ℹ️ [DISCOVERY] Skipping GATT cache clear (stability mode for Huawei/Honor)");
          _log("🦷🔍 [BT-DIAG] Skipping cache clear for stability");
        }
        
        // 🔥 CRITICAL: Финальная проверка перед discoverServices
        if (!device.isConnected) {
          _log("❌ [DISCOVERY] Connection lost before discoverServices!");
          throw Exception("Connection lost before discoverServices");
        }
        
        _log("🦷🔍 [BT-DIAG] Calling discoverServices()...");
        final discoveryStart = DateTime.now();
        List<BluetoothService> services = await device.discoverServices();
        _log("🦷🔍 [BT-DIAG] discoverServices() returned ${services.length} services!");
        final discoveryElapsed = DateTime.now().difference(discoveryStart);
        _log("✅ [DISCOVERY] Service discovery completed in ${discoveryElapsed.inMilliseconds}ms");
        
        // 🔥 RETRY: If no services found, retry once after delay
        if (services.isEmpty) {
          _log("⚠️ [DISCOVERY] No services found, retrying after 500ms...");
          await Future.delayed(const Duration(milliseconds: 500));
          services = await device.discoverServices();
          _log("🔄 [DISCOVERY] Retry found ${services.length} services");
        }
        
        // Даём стэку Tecno/MTK «переварить» discovery перед первой записью
        await Future.delayed(const Duration(milliseconds: 400));
        
        // 🔍 ДЕТАЛЬНАЯ ПРОВЕРКА: Есть ли наш сервис на втором телефоне?
        _log("🔍 [DISCOVERY] Found ${services.length} services. Looking for $SERVICE_UUID...");
        _log("   All services: ${services.map((s) => s.uuid.toString()).join(', ')}");
        
        final matchingServices = services.where((s) => 
          s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()
        ).toList();
        
        if (matchingServices.isEmpty) {
          _log("⚠️ [DISCOVERY] Service $SERVICE_UUID not found in first discovery");
          _log("   📋 Found ${services.length} services: ${services.map((s) => s.uuid.toString()).join(', ')}");
          
          // 🔥 HUAWEI/ANDROID FIX: Retry service discovery after cache clear
          _log("🔄 [DISCOVERY] Retrying with cache refresh...");
          try {
            await device.clearGattCache();
            await Future.delayed(const Duration(milliseconds: 500));
            services = await device.discoverServices();
            _log("🔄 [DISCOVERY] Retry found ${services.length} services");
            
            // Check again for our service
            final retryMatchingServices = services.where((s) => 
              s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()
            ).toList();
            
            if (retryMatchingServices.isNotEmpty) {
              _log("✅ [DISCOVERY] Service found on retry!");
              matchingServices.addAll(retryMatchingServices);
            }
          } catch (e) {
            _log("⚠️ [DISCOVERY] Retry failed: $e");
          }
        }
        
        if (matchingServices.isEmpty) {
          _log("❌ [CRITICAL] Target device does NOT have our service ($SERVICE_UUID)");
          _log("   This means the device is not advertising the service correctly");
          _log("   Available services:");
          for (var svc in services) {
            _log("     - ${svc.uuid} (${svc.characteristics.length} characteristics)");
          }
          
          // 🔥 ДЛЯ HUAWEI/TECNO: Если устройство имеет тактическое имя, но нет сервиса
          // это может быть проблема с рекламой. Пробуем найти похожий сервис
          if (deviceLocalName?.startsWith("M_") ?? false) {
            _log("⚠️ Device has tactical name but service not found - this is a critical issue");
            _log("   The device should be advertising SERVICE_UUID but it's missing");
            _log("   Possible causes:");
            _log("   1. Device stopped advertising");
            _log("   2. BLE stack issue on target device");
            _log("   3. Permission issue on target device");
          }
          
          throw Exception("Service $SERVICE_UUID not found on target device. Device may not be advertising correctly.");
        }
        
        final s = matchingServices.first;
        _log("✅ Service found! Looking for characteristic $CHAR_UUID...");
        
        final matchingChars = s.characteristics.where((c) => c.uuid.toString() == CHAR_UUID).toList();
        if (matchingChars.isEmpty) {
          _log("❌ [CRITICAL] Characteristic $CHAR_UUID not found. Available characteristics:");
          for (var ch in s.characteristics) {
            _log("   - ${ch.uuid} (write: ${ch.properties.write}, notify: ${ch.properties.notify})");
          }
          throw Exception("Characteristic $CHAR_UUID not found");
        }
        
        final c = matchingChars.first;
        _log("✅ Characteristic found! Properties: write=${c.properties.write}, notify=${c.properties.notify}");

        // 🔥 LENGTH-PREFIXED FRAMING: Формат [4 bytes: length (Big-Endian)][N bytes: JSON]
        // Фрагментация: делим сообщение на части, каждая не больше 60 байт полезной нагрузки
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
          
          _log("📤 [WRITE] Fragment ${fragIndex + 1}/${fragments.length}: payload=${jsonPayload.length} bytes, framed=${framedMessage.length} bytes");
          
          const int chunkSize = 60;
          int chunkCount = 0;
          
          for (int i = 0; i < framedMessage.length; i += chunkSize) {
            final end = (i + chunkSize < framedMessage.length) ? i + chunkSize : framedMessage.length;
            final chunk = framedMessage.sublist(i, end);
            
            _log("📤 [WRITE] Fragment ${fragIndex + 1}/${fragments.length}, chunk ${chunkCount + 1} (${chunk.length} bytes, offset $i)...");
            final writeStart = DateTime.now();
            
            // 🔥 GHOST: Используем WRITE_NO_RESPONSE для оптимизации (быстрее, меньше нагрузки на 100k+ пользователей)
            await c.write(chunk, withoutResponse: true);
            
            final writeElapsed = DateTime.now().difference(writeStart);
            _log("✅ [WRITE] Chunk written in ${writeElapsed.inMilliseconds}ms");

            // 🔥 GHOST: Пауза 80-150ms между чанками (оптимально для масштабирования)
            if (end < framedMessage.length) {
              await Future.delayed(const Duration(milliseconds: 100)); // Оптимальная пауза
            }
            chunkCount++;
          }
          // Пауза между фрагментами
          if (fragIndex < fragments.length - 1) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        }
        _log("✅ [WRITE] All data sent successfully (${totalBytes} bytes total, with length headers)");

        _log("💎 [FINAL-DELIVERY] Packet delivered via BLE!");

        // 🔥 GHOST: СРАЗУ disconnect после write (не держим соединение)
        _log("🔌 [GHOST] Disconnecting immediately after write (protocol requirement)");
        await stateSub?.cancel();
        try {
          await device.disconnect();
          _log("✅ [GHOST] Disconnected successfully");
        } catch (e) {
          _log("⚠️ [GHOST] Error disconnecting: $e");
        }
        
        // Reset FSM to IDLE on success
        await _stateMachine.forceTransition(BleState.IDLE);
        _advState = BleAdvertiseState.idle;
        delivered = true; // ВСЁ, ПОБЕДА!
        
        // 🔥 CRITICAL FIX: Освобождаем GATT mutex ПЕРЕД return!
        // Без этого _gattConnectionState остаётся CONNECTED навсегда и блокирует scan
        _releaseGattMutex("successful delivery");
        
        // 🔥 GHOST: Вернуться в scan после disconnect (для поиска других BRIDGE)
        _log("🔄 [GHOST] Returning to scan mode after successful GATT transfer");
        _log("🔗 [GATT-STATE] State reset to IDLE - BLE scan unblocked");
        // Scan будет запущен автоматически через MeshOrchestrator или MeshService
        
        return;

      } catch (e) {
        final errorStr = e.toString();
        final isError133 = errorStr.contains('133') || errorStr.contains('ANDROID_SPECIFIC_ERROR');
        final isTimeout = errorStr.contains('Timed out') || errorStr.contains('timeout');
        
        _log("⚠️ GATT Attempt $attempt failed: $e");
        
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
          _log("🚨 [CRITICAL] Error 133 detected! Performing aggressive BLE stack reset...");
          
          // 1. Принудительно отключаемся
          try {
            await device.disconnect();
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
        
        try { await stateSub?.cancel(); } catch (_) {}
        try { await device.disconnect(); } catch (_) {}
        // Reset FSM to IDLE on error
        await _stateMachine.forceTransition(BleState.IDLE);
        _advState = BleAdvertiseState.idle;
      }
    }

    // 🔥 FIX: ОБЯЗАТЕЛЬНОЕ освобождение GATT mutex
    _releaseGattMutex("end of _sendWithDynamicRetries - delivered: $delivered", state: delivered ? 'IDLE' : 'FAILED');

    // Если мы сюда дошли — ни одна попытка не удалась
    if (!delivered) {
      throw Exception("GATT delivery failed after 3 attempts or session timeout");
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
    
    _log("📦 [FRAMING] Created framed message: header=[${header[0]},${header[1]},${header[2]},${header[3]}], payload=$payloadLength bytes, total=${framedMessage.length} bytes");
    
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

  void _log(String msg) {
    // 🔥🔥🔥 CRITICAL: Двойное логирование для гарантии попадания в консоль
    print("🦷 [BT-Mesh] $msg");
    try {
      locator<MeshService>().addLog("🦷 [BT] $msg");
    } catch (e) {
      // Если addLog не работает, хотя бы print должен сработать
      print("⚠️ [BT-LOG] Failed to addLog: $e");
    }
  }
}

class _BtTask {
  final BluetoothDevice device;
  final String message;
  _BtTask(this.device, this.message);
}