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
  
  static final MethodChannel _gattChannel = MethodChannel('memento/gatt_server');
  StreamSubscription? _gattEventSubscription;

  BleAdvertiseState get state => _advState; // Legacy getter
  BleState get fsmState => _stateMachine.state; // New FSM getter
  
  BluetoothMeshService() {
    _setupGattServerListener();
  }
  
  void _setupGattServerListener() {
    // Подписываемся на события от GATT сервера
    _gattChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onGattDataReceived':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          final data = args['data'] as String?;
          if (deviceAddress != null && data != null) {
            _handleIncomingGattData(deviceAddress, data);
          }
          break;
        case 'onGattClientConnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("✅ [GATT-SERVER] Client connected: $deviceAddress");
          break;
        case 'onGattClientDisconnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final deviceAddress = args['deviceAddress'] as String?;
          _log("❌ [GATT-SERVER] Client disconnected: $deviceAddress");
          break;
        case 'onGattReady':
          _log("📥 [GATT-SERVER] Received onGattReady event from native");
          _onGattReady();
          break;
      }
    });
  }
  
  void _handleIncomingGattData(String deviceAddress, String data) {
    final preview = data.length > 100 ? data.substring(0, 100) : data;
    _log("📥 [GATT-SERVER] Received data from $deviceAddress: $preview...");
    
    try {
      // Парсим JSON данные
      final jsonData = jsonDecode(data) as Map<String, dynamic>;
      
      // Добавляем senderIp в данные для обработки
      jsonData['senderIp'] = deviceAddress;
      
      // Передаем данные в MeshService для обработки
      final meshService = locator<MeshService>();
      meshService.processIncomingPacket(jsonData);
    } catch (e) {
      _log("❌ [GATT-SERVER] Error processing incoming data: $e");
    }
  }

  // ======================================================
  // ⚡ AUTO-LINK LOGIC
  // ======================================================

  /// Отправляет сообщение через BLE GATT. Возвращает true при успешной доставке.
  Future<bool> sendMessage(BluetoothDevice device, String message) async {
    final id = device.remoteId.str;
    if (_pendingDevices.contains(id)) {
      _log("⏳ Device $id already in queue, skipping duplicate.");
      return false;
    }

    _pendingDevices.add(id);
    try {
      // Вызываем напрямую, без очереди, чтобы получить реальный результат
      await _sendWithDynamicRetries(device, message);
      return true; // Успех, если не было исключения
    } catch (e) {
      _log("❌ sendMessage failed: $e");
      return false;
    } finally {
      _pendingDevices.remove(id);
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
      // 🔒 Fix BLE state machine: Use event-driven approach instead of busy wait
      if (_advState != BleAdvertiseState.idle) {
        _log("⏸️ [ADV] Waiting for state to become idle...");
        if (_stateIdleCompleter == null || _stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter = Completer<void>();
        }
        try {
          await _stateIdleCompleter!.future.timeout(const Duration(seconds: 2));
        } catch (e) {
          _log("⚠️ [ADV] Timeout waiting for idle state, forcing idle");
          _advState = BleAdvertiseState.idle;
        }
      }
      
      // 🔥 FSM: Проверяем, что GATT сервер остановлен перед новым стартом
      try {
        await _stopGattServer();
        _log("✅ [ADV] GATT server stopped before new start");
      } catch (e) {
        _log("⚠️ [ADV] Error stopping GATT server: $e");
      }
      
      // Безопасный сброс старого состояния (только если действительно идет реклама)
      try {
        final isAdvertising = await _blePeripheral.isAdvertising;
        if (isAdvertising) {
          _log("🛑 [ADV] Stopping previous advertising session...");
          await _blePeripheral.stop();
          // Даем больше времени на остановку перед новым стартом (для Huawei и медленных устройств)
          await Future.delayed(const Duration(milliseconds: 500));
          _log("✅ [ADV] Previous advertising stopped");
        }
      } catch (e) {
        // Игнорируем ошибки при остановке, продолжаем запуск
        _log("ℹ️ [ADV] Cleanup warning: $e");
      }

      // 🔍 ВАЛИДАЦИЯ И ОБРЕЗКА ИМЕНИ (BLE ограничение: ~29 байт, но безопаснее ~20)
      String safeName = myName;
      if (safeName.length > 20) {
        _log("⚠️ [ADV] Name too long (${safeName.length}), truncating to 20 chars.");
        safeName = safeName.substring(0, 20);
      }
      if (safeName.isEmpty) {
        safeName = "M_255_0_GHST"; // Fallback
        _log("⚠️ [ADV] Empty name, using fallback: $safeName");
      }

      // 🔥 BRIDGE: Сначала поднимаем GATT Server, ждем onGattReady, только потом advertising
      final currentRole = NetworkMonitor().currentRole;
      final isBridge = currentRole == MeshRole.BRIDGE;
      
      if (isBridge) {
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
      }

      _log("📡 [ADV] Starting with name: '$safeName' (${safeName.length} chars)");

      // 🔥 FIX: Добавляем manufacturerData для определения роли (fallback если localName пустое)
      // manufacturerData должен быть Uint8List, а не Map
      // Используем manufacturerId = 0xFFFF (зарезервированный для тестирования)
      // 🔥 КРИТИЧНО: Для BRIDGE добавляем token в manufacturerData (для Huawei где localName пустое)
      Uint8List manufacturerData;
      if (isBridge && safeName.contains("BRIDGE_")) {
        // Извлекаем token из тактического имени (формат: M_0_1_BRIDGE_TOKEN)
        final parts = safeName.split("_");
        String? token;
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          token = parts[4];
        }
        
        if (token != null && token.isNotEmpty) {
          // Формат manufacturerData для BRIDGE с token:
          // [0x42, 0x52, ...token_bytes] (первые 2 байта = "BR", остальное = token)
          // Ограничение: manufacturerData обычно до 31 байт, но безопаснее ~20
          final tokenBytes = utf8.encode(token);
          final maxTokenBytes = 18; // 20 - 2 (BR) = 18 байт для token
          final truncatedToken = tokenBytes.length > maxTokenBytes 
              ? tokenBytes.sublist(0, maxTokenBytes) 
              : tokenBytes;
          
          manufacturerData = Uint8List.fromList([0x42, 0x52, ...truncatedToken]);
          _log("🔍 [ADV] BRIDGE with token in manufacturerData: ${token.length > 8 ? token.substring(0, 8) : token}... (${manufacturerData.length} bytes)");
        } else {
          manufacturerData = Uint8List.fromList([0x42, 0x52]); // "BR" = BRIDGE без token
          _log("🔍 [ADV] BRIDGE without token in manufacturerData");
        }
      } else {
        manufacturerData = isBridge 
          ? Uint8List.fromList([0x42, 0x52]) // "BR" = BRIDGE
          : Uint8List.fromList([0x47, 0x48]); // "GH" = GHOST
      }
      
      final data = AdvertiseData(
        serviceUuid: SERVICE_UUID,
        localName: safeName,
        includeDeviceName: false, // 🔥 ВАЖНО: Ставим false, чтобы сэкономить 20 байт
        manufacturerId: 0xFFFF, // 🔥 FIX: Manufacturer ID для тестирования
        manufacturerData: manufacturerData, // 🔥 FIX: Добавляем роль и token в manufacturerData
      );
      
      _log("🔍 [ADV] Advertising with manufacturerData: ${isBridge ? 'BRIDGE' : 'GHOST'} (0xFFFF: ${manufacturerData.length} bytes)");

      await _blePeripheral.start(advertiseData: data);
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
      _log("❌ [ADV] Failed to start: $e");
    }
  }

  Future<void> stopAdvertising() async {
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
    try {
      // Останавливаем GATT сервер перед остановкой advertising
      await _stopGattServer();
      
      // Проверяем, действительно ли идет реклама перед остановкой
      final isAdvertising = await _blePeripheral.isAdvertising;
      if (isAdvertising) {
        _log("🛑 [ADV] Stopping advertising...");
        await _blePeripheral.stop();
        // Даем время на полную остановку (для Huawei и медленных устройств)
        await Future.delayed(const Duration(milliseconds: 300));
        _log("✅ [ADV] Stopped successfully");
      } else {
        _log("ℹ️ [ADV] Not advertising, nothing to stop");
      }
    } catch (e) {
      _log("⚠️ [ADV] Error stopping: $e");
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
      // 🔒 Fix BLE state machine: Use event-driven approach
      if (_advState != BleAdvertiseState.idle) {
        _log("⚠️ [GATT-SERVER] FSM state is not idle ($_advState), waiting...");
        if (_stateIdleCompleter == null || _stateIdleCompleter!.isCompleted) {
          _stateIdleCompleter = Completer<void>();
        }
        try {
          await _stateIdleCompleter!.future.timeout(const Duration(seconds: 3));
        } catch (e) {
          _log("❌ [GATT-SERVER] FSM state still not idle after wait, aborting");
          return false;
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
  void _onGattReady() {
    _log("🔔 [GATT-SERVER] _onGattReady called");
    _log("🔔 [GATT-SERVER] Completer state: ${_serviceAddedCompleter != null ? 'exists' : 'null'}, completed: ${_serviceAddedCompleter?.isCompleted ?? 'N/A'}");
    
    // 🔥 ОБНОВЛЕННАЯ ЛОГИКА COMPLETER: Обработка поздних событий
    // Если completer null или завершён - создаём новый для следующего использования
    if (_serviceAddedCompleter == null || _serviceAddedCompleter!.isCompleted) {
      _log("⚠️ [GATT-SERVER] Completer is null or already completed - creating new one for late event");
      _serviceAddedCompleter = Completer<bool>();
      _serviceAddedCompleter!.complete(true);
      _log("✅ [GATT-SERVER] Late event handled - GATT server is ready");
    } else {
      _serviceAddedCompleter!.complete(true);
      _log("✅ [GATT-SERVER] Completer completed - GATT server is ready");
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
    // Мини-проверка прав перед коннектом (Huawei/Tecno могут крашить без CONNECT)
    if (Platform.isAndroid && !await Permission.bluetoothConnect.isGranted) {
      _log("⛔ BT CONNECT permission missing, abort send.");
      return;
    }

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
            return; // Прерываем попытки подключения
          }
          
          canProceed = true; // Устройство валидно
        } else {
          // Если deviceScanResult == null, но canProceed уже установлен (Huawei quirk)
          // Проверяем дополнительные условия
          if (!canProceed) {
            // 🔥 TECNO: Если local name пустое, но есть SERVICE_UUID - это нормально
            if (deviceLocalName?.isEmpty ?? true) {
              if (hasServiceUuid) {
                _log("ℹ️ [TECNO/INFINIX] Local name is empty, but SERVICE_UUID is present - this is normal for these devices");
                canProceed = true;
              } else {
                _log("⚠️ [WARNING] Local name is empty and no SERVICE_UUID - aborting connection");
                return;
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
        return; // Прерываем попытки подключения
      }
      _log("⚠️ [WARNING] Will attempt connection anyway, but may fail if service is not available");
      canProceed = true; // Продолжаем только если это не критическая ошибка
    }
    
    // Если проверка не прошла - не продолжаем
    if (!canProceed) {
      _log("🚫 [ABORT] Pre-connect verification failed. Aborting GATT connection attempts.");
      return;
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

      // 🔥 ПРОВЕРКА ИЗМЕНЕНИЙ: Убеждаемся, что устройство все еще рекламирует правильный сервис
      // Это защита от изменения advertising во время подключения
      try {
        final currentScanResults = await FlutterBluePlus.lastScanResults;
        ScanResult? currentScanResult;
        try {
          currentScanResult = currentScanResults.firstWhere(
            (r) => r.device.remoteId == device.remoteId,
          );
        } catch (e) {
          currentScanResult = null;
        }
        
        if (currentScanResult != null && originalAdvName != null) {
          final currentAdvName = currentScanResult.advertisementData.localName ?? '';
          final currentHasService = currentScanResult.advertisementData.serviceUuids
              .any((uuid) => uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase());
          
          // Проверяем, что advertising name не изменился
          if (currentAdvName != originalAdvName) {
            _log("⚠️ [WARNING] Device advertising name changed during connection attempt $attempt:");
            _log("   Original: '$originalAdvName' -> Current: '$currentAdvName'");
            _log("   Role or identity may have changed - aborting connection");
            break; // Прерываем попытки подключения
          }
          
          // Проверяем, что SERVICE_UUID все еще присутствует
          if (hasServiceUuid && !currentHasService) {
            _log("⚠️ [WARNING] Device stopped advertising SERVICE_UUID during connection attempt $attempt");
            _log("   Device may have changed role or stopped advertising - aborting connection");
            break; // Прерываем попытки подключения
          }
        } else if (currentScanResult == null) {
          _log("⚠️ [WARNING] Device no longer found in scan results during attempt $attempt");
          _log("   Device may have stopped advertising - aborting connection");
          break; // Прерываем попытки подключения
        }
      } catch (e) {
        _log("⚠️ [WARNING] Could not verify device state during attempt $attempt: $e");
        // Продолжаем, но логируем предупреждение
      }
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
        
        // 🔥 ДОПОЛНИТЕЛЬНАЯ ПРОВЕРКА: Убеждаемся, что устройство все еще видимо
        try {
          final lastScanResults = await FlutterBluePlus.lastScanResults;
          final isStillVisible = lastScanResults.any((r) => r.device.remoteId == device.remoteId);
          if (!isStillVisible) {
            _log("⚠️ Device ${device.remoteId} no longer visible in scan results. May have stopped advertising.");
            throw Exception("Device no longer visible");
          }
        } catch (e) {
          _log("⚠️ Could not verify device visibility: $e");
        }
        
        _log("📡 [CONNECT] Initiating connection...");
        final connectStart = DateTime.now();
        await device.connect(timeout: timeoutDuration, autoConnect: false);

        // Ждём подтверждение подключения
        bool connected = false;
        try {
          _log("⏳ [CONNECT] Waiting for connection confirmation...");
          connected = await connCompleter.future.timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              _log("⚠️ [CONNECT] Connection confirmation timeout, checking state...");
              return device.isConnected;
            },
          );
        } catch (e) {
          _log("⚠️ [CONNECT] Connection confirmation error: $e");
          await Future.delayed(const Duration(milliseconds: 500));
          connected = device.isConnected;
        }
        
        final connectElapsed = DateTime.now().difference(connectStart);
        if (!connected) {
          _log("❌ [CONNECT] Failed after ${connectElapsed.inSeconds}s - device not connected");
          throw Exception("No connect state after ${connectElapsed.inSeconds}s");
        }

        _log("✅ [SUCCESS] Link Established after ${connectElapsed.inSeconds}s! Discovering services...");
        // 🔄 Use FSM for state transition
        try {
          await _stateMachine.transition(BleState.CONNECTED);
        } catch (e) {
          _log("⚠️ [GATT] Invalid state transition to CONNECTED: $e");
        }
        _advState = BleAdvertiseState.connected;

        // MTU — сниженное для проблемных устройств
        if (Platform.isAndroid) {
          try {
            await device.requestMtu(158);
            await Future.delayed(const Duration(milliseconds: 200));
          } catch (e) {
            _log("⚠️ MTU request failed: $e");
          }
        }

        _log("🔍 [DISCOVERY] Starting service discovery...");
        final discoveryStart = DateTime.now();
        final services = await device.discoverServices();
        final discoveryElapsed = DateTime.now().difference(discoveryStart);
        _log("✅ [DISCOVERY] Service discovery completed in ${discoveryElapsed.inMilliseconds}ms");
        
        // Даём стэку Tecno/MTK «переварить» discovery перед первой записью
        await Future.delayed(const Duration(milliseconds: 400));
        
        // 🔍 ДЕТАЛЬНАЯ ПРОВЕРКА: Есть ли наш сервис на втором телефоне?
        _log("🔍 [DISCOVERY] Found ${services.length} services. Looking for $SERVICE_UUID...");
        _log("   All services: ${services.map((s) => s.uuid.toString()).join(', ')}");
        
        final matchingServices = services.where((s) => 
          s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()
        ).toList();
        
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

        // Фрагментация: делим сообщение на части, каждая не больше 60 байт полезной нагрузки
        _log("📤 [WRITE] Fragmenting message (${message.length} chars)...");
        final fragments = _fragmentMessage(message);
        _log("📤 [WRITE] Message split into ${fragments.length} fragment(s)");
        
        int totalBytes = 0;
        for (int fragIndex = 0; fragIndex < fragments.length; fragIndex++) {
          final frag = fragments[fragIndex];
          final bytes = utf8.encode(jsonEncode(frag));
          totalBytes += bytes.length;
          const int chunkSize = 60;
          int chunkCount = 0;
          
          for (int i = 0; i < bytes.length; i += chunkSize) {
            final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
            final chunk = bytes.sublist(i, end);
            
            _log("📤 [WRITE] Fragment ${fragIndex + 1}/${fragments.length}, chunk ${chunkCount + 1} (${chunk.length} bytes)...");
            final writeStart = DateTime.now();
            
            // 🔥 GHOST: Используем WRITE_NO_RESPONSE для оптимизации (быстрее, меньше нагрузки на 100k+ пользователей)
            await c.write(chunk, withoutResponse: true);
            
            final writeElapsed = DateTime.now().difference(writeStart);
            _log("✅ [WRITE] Chunk written in ${writeElapsed.inMilliseconds}ms");

            // 🔥 GHOST: Пауза 80-150ms между чанками (оптимально для масштабирования)
            if (end < bytes.length) {
              await Future.delayed(const Duration(milliseconds: 100)); // Оптимальная пауза
            }
            chunkCount++;
          }
          // Пауза между фрагментами
          if (fragIndex < fragments.length - 1) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        }
        _log("✅ [WRITE] All data sent successfully (${totalBytes} bytes total)");

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
        
        // 🔥 GHOST: Вернуться в scan после disconnect (для поиска других BRIDGE)
        _log("🔄 [GHOST] Returning to scan mode after successful GATT transfer");
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

    // Если мы сюда дошли — ни одна попытка не удалась
    if (!delivered) {
      throw Exception("GATT delivery failed after 3 attempts or session timeout");
    }
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
    print("🦷 [BT-Mesh] $msg");
    locator<MeshService>().addLog("🦷 [BT] $msg");
  }
}

class _BtTask {
  final BluetoothDevice device;
  final String message;
  _BtTask(this.device, this.message);
}