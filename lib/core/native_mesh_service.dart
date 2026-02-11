import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'locator.dart';
import 'mesh_service.dart';

class NativeMeshService {
  // Канал для Wi-Fi Direct и системных функций
  static const MethodChannel _channel = MethodChannel('memento/wifi_direct');

  static const MethodChannel _p2pChannel = MethodChannel('memento/p2p');

  // Канал для Акустического Сонара (Звук)
  static const MethodChannel _sonarChannel = MethodChannel('memento/sonar');

  // 🔥 КРИТИЧНО: Канал для GATT Server
  static const MethodChannel _gattChannel = MethodChannel('memento/gatt_server');

  // Широковещательный поток для входящих сообщений (Mesh)
  static final StreamController<Map<String, dynamic>> _messageController =
  StreamController<Map<String, dynamic>>.broadcast();
  
  // 🔥 КРИТИЧНО: Completer для ожидания onGattReady события
  static Completer<bool>? _gattReadyCompleter;

  static Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  /// ЕДИНАЯ ИНИЦИАЛИЗАЦИЯ ВСЕХ КАНАЛОВ СВЯЗИ
  static void init() {
    // --- 📡 Настройка основного канала (Wi-Fi Direct) ---
    _channel.setMethodCallHandler((call) async {
      print("📡 [Native -> Mesh] Incoming Method: ${call.method}");

      switch (call.method) {
        case 'onPeersFound':
          final List<dynamic> raw = call.arguments;
          locator<MeshService>().handleNativePeers(raw);
          break;

        case 'onAutoLinkRequest':
          final String senderId = call.arguments.toString();
          print("🔊 [Native] Auto-Link signal caught for: $senderId");
          // Передаем сигнал в MeshService, который через стрим покажет диалог в MainScreen
          locator<MeshService>().handleIncomingLinkRequest(senderId);
          break;

        case 'onConnected':
          final args = Map<String, dynamic>.from(call.arguments);
          final bool isHost = args['isHost'] ?? false;
          final String hostAddress = args['hostAddress'] ?? '';
          locator<MeshService>().onNetworkConnected(isHost, hostAddress);
          break;

        case 'onDisconnected':
          locator<MeshService>().onNetworkDisconnected();
          break;

        case 'onConnectionFailed':
          final args = Map<String, dynamic>.from(call.arguments);
          final String error = args['error'] ?? 'UNKNOWN';
          final String message = args['message'] ?? 'Connection failed';
          final int? code = args['code'] as int?;
          print("❌ [Native] Wi-Fi Direct connection failed:");
          print("   📋 Error: $error");
          print("   📋 Message: $message");
          if (code != null) print("   📋 Code: $code");
          // Уведомляем MeshService об ошибке подключения
          try {
            locator<MeshService>().onNetworkConnectionFailed(error, message, code);
          } catch (e) {
            print("⚠️ [Native] MeshService.onNetworkConnectionFailed error: $e");
          }
          break;

        case 'onP2pStateChanged':
          final args = Map<String, dynamic>.from(call.arguments);
          final bool enabled = args['enabled'] ?? false;
          print("📡 [Native] Wi-Fi Direct state changed: ${enabled ? 'ENABLED' : 'DISABLED'}");
          if (!enabled) {
            print("⚠️ [Native] Wi-Fi Direct is DISABLED. Please enable it in settings.");
          }
          break;
          
        // 🔥 ЛОГИ ИЗ НАТИВНОГО КОДА В UI ТЕРМИНАЛ
        case 'onNativeLog':
          final args = Map<String, dynamic>.from(call.arguments);
          final String tag = args['tag'] ?? 'NATIVE';
          final String message = args['message'] ?? '';
          // Передаем лог в MeshService для отображения в UI терминале
          try {
            locator<MeshService>().addLog("[$tag] $message");
          } catch (e) {
            print("⚠️ [Native] Failed to add native log: $e");
          }
          break;
          
        // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
        case 'onGroupCreated':
          final args = Map<String, dynamic>.from(call.arguments);
          final networkName = args['networkName'] as String?;
          final passphrase = args['passphrase'] as String?;
          final isGroupOwner = args['isGroupOwner'] as bool? ?? false;
          final clientCount = args['clientCount'] as int? ?? 0;
          final reused = args['reused'] as bool? ?? false;
          
          print("✅ [Native] Wi-Fi Direct group ${reused ? 'found' : 'created'}:");
          print("   📋 SSID: $networkName");
          print("   📋 Passphrase: ${passphrase?.substring(0, passphrase.length > 4 ? 4 : passphrase.length)}...");
          print("   📋 Owner: ${isGroupOwner ? 'Us' : 'Other device'}");
          print("   📋 Clients: $clientCount");

          // 🔥 Лог в UI терминал (MeshHybridScreen / LOG TERMINAL)
          try {
            locator<MeshService>().addLog("[WiFi-Direct] Group ${reused ? 'found' : 'created'}: SSID=$networkName, Pass=***");
          } catch (_) {}

          // Уведомляем MeshService о созданной группе
          try {
            locator<MeshService>().onWifiDirectGroupCreated(
              networkName: networkName,
              passphrase: passphrase,
              isGroupOwner: isGroupOwner,
            );
          } catch (e) {
            print("⚠️ [Native] MeshService.onWifiDirectGroupCreated error: $e");
          }
          break;
          
        case 'onGroupCreationFailed':
          final args = Map<String, dynamic>.from(call.arguments);
          final error = args['error'] as String?;
          final message = args['message'] as String?;
          final code = args['code'] as int?;
          
          print("❌ [Native] Wi-Fi Direct group creation failed:");
          print("   📋 Error: $error");
          print("   📋 Message: $message");
          if (code != null) print("   📋 Code: $code");
          break;
          
        case 'onGroupRemoved':
          final args = Map<String, dynamic>.from(call.arguments);
          final success = args['success'] as bool? ?? false;
          print("${success ? '✅' : '❌'} [Native] Wi-Fi Direct группа удалена: $success");
          break;

        case 'onMessageReceived':
          try {
            final Map<dynamic, dynamic> args = call.arguments;
            final incomingData = {
              'message': args['message']?.toString() ?? '',
              'senderIp': args['senderIp']?.toString() ?? '',
            };
            
            // 🔥 ЛОГИРОВАНИЕ: Детальная информация о приеме через TCP
            print("📥 [BRIDGE] TCP: Received message from GHOST ${incomingData['senderIp']}");
            final messagePreview = incomingData['message']!.length > 100 
                ? incomingData['message']!.substring(0, 100) 
                : incomingData['message']!;
            print("   📋 Message preview: $messagePreview...");
            print("   📋 Full message length: ${incomingData['message']!.length} bytes");
            
            // Пытаемся извлечь тип сообщения для логирования
            try {
              final messageJson = jsonDecode(incomingData['message']!);
              final messageType = messageJson['type'] ?? 'UNKNOWN';
              final messageId = messageJson['h'] ?? messageJson['id'] ?? 'unknown';
              print("   📋 Message type: $messageType");
              print("   📋 Message ID: ${messageId.toString().substring(0, messageId.toString().length > 8 ? 8 : messageId.toString().length)}...");
            } catch (_) {
              print("   ⚠️ Could not parse message JSON for logging");
            }
            
            print("   📤 Forwarding to MeshService.processIncomingPacket()...");
            locator<MeshService>().processIncomingPacket(incomingData);
            _messageController.add(incomingData);
            print("   ✅ TCP message processed successfully");
          } catch (e) {
            print("❌ [BRIDGE] TCP: Error processing incoming message: $e");
          }
          break;

        default:
          print("⚠️ Unknown Mesh method: ${call.method}");
      }
    });

    // --- 🔊 Настройка канала Сонара (Акустика) ---
    _sonarChannel.setMethodCallHandler((call) async {
      print("🔊 [Native -> Sonar] Incoming Method: ${call.method}");
      switch (call.method) {
        case 'onSignalDetected':
          try {
            final String signal = call.arguments.toString();
            locator<UltrasonicService>().handleInboundSignal(signal);
          } catch (e) {
            print("❌ [NativeService] Sonar signal error: $e");
          }
          break;
        default:
          print("⚠️ Unknown Sonar method: ${call.method}");
      }
    });

    // --- 🦷 GATT Server: handler НЕ ставим здесь ---
    // 🔥 BLE AUDIT FIX: Канал memento/gatt_server обрабатывается ТОЛЬКО в BluetoothMeshService.
    // Раньше setMethodCallHandler здесь перезаписывал handler и onGattDataReceived не доходил до
    // processIncomingPacket. onGattReady для startGattServerAndWait завершается через
    // completeGattReadyFromNative() из BluetoothMeshService.
  }
  
  /// Вызывается из BluetoothMeshService при получении onGattReady с натива.
  /// Нужно для startGattServerAndWait() — чтобы completer завершился при одном handler на канале.
  static void completeGattReadyFromNative(bool value) {
    if (_gattReadyCompleter != null && !_gattReadyCompleter!.isCompleted) {
      _gattReadyCompleter!.complete(value);
      _gattReadyCompleter = null;
      print("✅ [Native] GATT ready completer completed from BluetoothMeshService");
    }
  }


  static Future<Map<double, double>> runFrequencySweep() async {
    try {
      final Map<dynamic, dynamic> raw =
      await _sonarChannel.invokeMethod('runFrequencySweep');

      return raw.map(
            (key, value) => MapEntry(
          (key as num).toDouble(),
          (value as num).toDouble(),
        ),
      );
    } catch (e) {
      print("❌ [Native] FFT sweep failed: $e");
      rethrow;
    }
  }


  static Future<Map<String, dynamic>> getHardwareCapabilities() async {
    try {
      // Спрашиваем через p2p канал (где мы прописали это в Kotlin)
      final Map<dynamic, dynamic>? result = await _p2pChannel.invokeMethod('getHardwareCapabilities');
      return result != null ? Map<String, dynamic>.from(result) : {};
    } catch (e) {
      print("❌ Caps Error: $e");
      return {"hasAware": false, "hasDirect": true};
    }
  }

  static Future<void> startAwareSession(String peerId) async {
    try {
      // Пока вызываем заглушку, но канал уже пробит
      await _p2pChannel.invokeMethod('startAwareSession', {'peerId': peerId});
    } catch (e) {
      print("❌ Aware Session Error: $e");
    }
  }


  // --- МЕТОДЫ УПРАВЛЕНИЯ (Flutter -> Native) ---

  /// Запуск фонового "бессмертного" сервиса Kotlin
  static Future<void> startBackgroundMesh() async {
    try {
      await _channel.invokeMethod('startMeshService');
      print("🛡️ [Native] Mesh Guardian Service started.");
    } catch (e) {
      print("❌ [Native] BG Service Start Error: $e");
    }
  }

  static Future<void> stopBackgroundMesh() async {
    try {
      await _channel.invokeMethod('stopMeshService');
    } catch (e) {
      print("❌ [Native] BG Service Stop Error: $e");
    }
  }

  /// Поиск устройств Wi-Fi Direct
  /// Возвращает true если discovery запущен, false если Wi-Fi Direct отключен
  static Future<bool> startDiscovery() async {
    try {
      await _channel.invokeMethod('startDiscovery');
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'P2P_DISABLED') {
        print("⚠️ [Native] Wi-Fi Direct is DISABLED. Requesting activation...");
        // Запрашиваем активацию
        await requestP2pActivation();
        return false;
      }
      print("❌ [Native] Discovery Error: ${e.message}");
      return false;
    } catch (e) {
      print("❌ [Native] Discovery Error: $e");
      return false;
    }
  }

  /// Проверяет состояние Wi-Fi Direct
  static Future<bool> checkP2pState() async {
    try {
      final result = await _channel.invokeMethod('checkP2pState');
      // Безопасное приведение типа: результат может быть Map<Object?, Object?>
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final enabled = resultMap['enabled'] ?? false;
      return enabled is bool ? enabled : false;
    } catch (e) {
      print("❌ [Native] Check P2P state error: $e");
      return false;
    }
  }

  /// Проверяет, активен ли discovery
  static Future<bool> checkDiscoveryState() async {
    try {
      final result = await _channel.invokeMethod('checkDiscoveryState');
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final active = resultMap['active'] ?? false;
      return active is bool ? active : false;
    } catch (e) {
      print("❌ [Native] Check discovery state error: $e");
      return false;
    }
  }

  /// Запрашивает активацию Wi-Fi Direct (открывает настройки)
  static Future<void> requestP2pActivation() async {
    try {
      await _channel.invokeMethod('requestP2pActivation');
      print("📱 [Native] Opening Wi-Fi settings for user to enable Wi-Fi Direct");
    } catch (e) {
      print("❌ [Native] Request P2P activation error: $e");
    }
  }

  static Future<void> stopDiscovery() async {
    try {
      await _channel.invokeMethod('stopDiscovery');
    } on MissingPluginException {
      print("⚠️ [Native] Method stopDiscovery not implemented on Android yet.");
    } catch (e) {
      print("❌ [Native] Stop Error: $e");
    }
  }

  /// Принудительный сброс P2P стека (Ядерный сброс для Tecno/Huawei)
  static Future<void> forceReset() async {
    try {
      await _channel.invokeMethod('forceReset');
    } catch (e) {
      print("❌ Force Reset Error: $e");
    }
  }
  
  // ============================================================================
  // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
  // ============================================================================
  
  /// Создает Wi-Fi Direct группу автоматически
  /// [forceCreate] - если true, удалит существующую группу и создаст новую
  /// Возвращает информацию о группе или null при ошибке
  static Future<WifiDirectGroupInfo?> createWifiDirectGroup({bool forceCreate = false}) async {
    try {
      print("🚀 [Native] Создание Wi-Fi Direct группы (forceCreate: $forceCreate)...");
      
      final result = await _channel.invokeMethod('createGroup', {
        'forceCreate': forceCreate,
      });
      
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final success = resultMap['success'] as bool? ?? false;
      
      if (success) {
        final info = WifiDirectGroupInfo(
          networkName: resultMap['networkName'] as String?,
          passphrase: resultMap['passphrase'] as String?,
          isGroupOwner: resultMap['isGroupOwner'] as bool? ?? false,
          clientCount: resultMap['clientCount'] as int? ?? 0,
        );
        
        print("✅ [Native] Group created: ${info.networkName}");
        return info;
      } else {
        print("❌ [Native] Не удалось создать группу");
        return null;
      }
    } catch (e) {
      print("❌ [Native] Create group error: $e");
      return null;
    }
  }
  
  /// Удаляет Wi-Fi Direct группу
  static Future<bool> removeWifiDirectGroup() async {
    try {
      print("🗑️ [Native] Удаление Wi-Fi Direct группы...");
      
      final result = await _channel.invokeMethod('removeGroup');
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final success = resultMap['success'] as bool? ?? false;
      
      print("${success ? '✅' : '❌'} [Native] Группа удалена: $success");
      return success;
    } catch (e) {
      print("❌ [Native] Remove group error: $e");
      return false;
    }
  }
  
  /// Получает информацию о текущей Wi-Fi Direct группе
  static Future<WifiDirectGroupInfo?> getWifiDirectGroupInfo() async {
    try {
      final result = await _channel.invokeMethod('getGroupInfo');
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final exists = resultMap['exists'] as bool? ?? false;
      
      if (exists) {
        return WifiDirectGroupInfo(
          networkName: resultMap['networkName'] as String?,
          passphrase: resultMap['passphrase'] as String?,
          isGroupOwner: resultMap['isGroupOwner'] as bool? ?? false,
          ownerAddress: resultMap['ownerAddress'] as String?,
          clientCount: resultMap['clientCount'] as int? ?? 0,
        );
      }
      
      return null;
    } catch (e) {
      print("❌ [Native] Get group info error: $e");
      return null;
    }
  }
  
  /// Автоматически создает группу если её нет
  /// Идеально для автоматического mesh-режима
  static Future<WifiDirectGroupInfo?> ensureWifiDirectGroupExists() async {
    try {
      print("🔍 [Native] Checking/creating Wi-Fi Direct group...");
      
      final result = await _channel.invokeMethod('ensureGroupExists');
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      final success = resultMap['success'] as bool? ?? false;
      
      if (success) {
        return WifiDirectGroupInfo(
          networkName: resultMap['networkName'] as String?,
          passphrase: resultMap['passphrase'] as String?,
          isGroupOwner: resultMap['isGroupOwner'] as bool? ?? false,
          clientCount: resultMap['clientCount'] as int? ?? 0,
        );
      }
      
      return null;
    } catch (e) {
      print("❌ [Native] Ensure group exists error: $e");
      return null;
    }
  }
  
  /// Проверяет, является ли устройство владельцем группы
  static Future<bool> isWifiDirectGroupOwner() async {
    try {
      final result = await _channel.invokeMethod('isGroupOwner');
      final Map<dynamic, dynamic> resultMap = Map<dynamic, dynamic>.from(result ?? {});
      return resultMap['isGroupOwner'] as bool? ?? false;
    } catch (e) {
      print("❌ [Native] Is group owner check error: $e");
      return false;
    }
  }

  static Future<void> connect(String address, {String? networkName, String? passphrase}) async {
    if (address.isEmpty || address == "null") {
      print("❌ [Native] Connection aborted: Target address is empty.");
      return;
    }
    try {
      await _channel.invokeMethod('connect', {
        'deviceAddress': address,
        if (networkName != null && networkName.isNotEmpty) 'networkName': networkName,
        if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
      });
    } catch (e) {
      print("❌ [Native] Connection Error: $e");
    }
  }

  /// Отправка данных через TCP (Burst Mode)
  static Future<void> sendTcp(String message, {required String host, int? port}) async {
    try {
      // Гарантируем терминатор строки для Kotlin BufferedReader
      final String payload = message.endsWith('\n') ? message : '$message\n';
      
      // 🔥 Wi-Fi Direct Fix: единый порт 55556 — BRIDGE слушает, GHOST шлёт
      final int targetPort = port ?? 55556;

      await _channel.invokeMethod('sendTcp', {
        'host': host,
        'port': targetPort,
        'message': payload
      });
      print("🚀 [Native] TCP Burst delivered to $host:$targetPort");
    } catch (e) {
      print("❌ [Native] TCP Transmission Failure: $e");
    }
  }

  /// Запускает кратковременный TCP сервер на указанное время
  /// Проверяет, можно ли поднимать TCP сервер на этом устройстве
  static Future<bool> canStartTcpServer() async {
    try {
      final result = await _channel.invokeMethod('canStartTcpServer');
      return result as bool? ?? true; // По умолчанию разрешаем
    } catch (e) {
      print("⚠️ [Native] CanStartTcpServer check error: $e");
      return true; // По умолчанию разрешаем, если проверка не удалась
    }
  }

  static Future<void> startTemporaryTcpServer({required int durationSeconds}) async {
    try {
      // Проверяем, можно ли поднимать сервер
      final canStart = await canStartTcpServer();
      if (!canStart) {
        print("🚫 [Native] TCP server disabled for this device - using BLE GATT");
        throw Exception("TCP server disabled for weak device or after crash");
      }
      
      await _channel.invokeMethod('startTemporaryTcpServer', {
        'durationSeconds': durationSeconds,
      });
      print("🛡️ [Native] Temporary TCP server started for ${durationSeconds}s");
    } catch (e) {
      print("❌ [Native] Temporary server start error: $e");
      rethrow; // Пробрасываем ошибку для обработки в mesh_service
    }
  }

  /// Останавливает временный TCP сервер
  static Future<void> stopTemporaryTcpServer() async {
    try {
      await _channel.invokeMethod('stopTemporaryTcpServer');
      print("🛑 [Native] Temporary TCP server stopped");
    } catch (e) {
      print("❌ [Native] Temporary server stop error: $e");
    }
  }

  /// Получает очередь сообщений из bridge_queue
  static Future<List<Map<String, dynamic>>> getQueuedMessages() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod('getQueuedMessages');
      if (result == null) return [];
      return result.map((item) => Map<String, dynamic>.from(item)).toList();
    } catch (e) {
      print("❌ [Native] Get queued messages error: $e");
      return [];
    }
  }

  // --- МЕТОДЫ УПРАВЛЕНИЯ СОНАРОМ ---

  static Future<void> startSonarListening() async {
    try {
      await _sonarChannel.invokeMethod('startListening');
      print("👂 [Native] Sonar listening activated.");
    } catch (e) {
      print("❌ [Native] Sonar Start Error: $e");
    }
  }

  static Future<void> stopSonarListening() async {
    try {
      await _sonarChannel.invokeMethod('stopListening');
    } catch (e) {
      print("❌ [Native] Sonar Stop Error: $e");
    }
  }

  // ==========================================
  // 🛰️ ROUTER CAPTURE PROTOCOL METHODS
  // ==========================================

  static const MethodChannel _routerChannel = MethodChannel('memento/router');

  /// Сканирует доступные Wi-Fi сети
  static Future<List<Map<String, dynamic>>> scanWifiNetworks() async {
    try {
      final List<dynamic>? result = await _routerChannel.invokeMethod('scanWifiNetworks');
      if (result == null) return [];
      return result.map((item) => Map<String, dynamic>.from(item)).toList();
    } catch (e) {
      print("❌ [Native] Scan WiFi networks error: $e");
      return [];
    }
  }

  /// Подключается к роутеру по SSID и паролю
  static Future<bool> connectToRouter(String ssid, String? password) async {
    try {
      final result = await _routerChannel.invokeMethod('connectToRouter', {
        'ssid': ssid,
        'password': password,
      });
      return result as bool? ?? false;
    } catch (e) {
      print("❌ [Native] Connect to router error: $e");
      return false;
    }
  }

  /// Отключается от текущего роутера
  static Future<bool> disconnectFromRouter() async {
    try {
      final result = await _routerChannel.invokeMethod('disconnectFromRouter');
      return result as bool? ?? false;
    } catch (e) {
      print("❌ [Native] Disconnect from router error: $e");
      return false;
    }
  }

  /// Получает локальный IP адрес устройства в сети роутера
  static Future<String?> getLocalIpAddress() async {
    try {
      final result = await _routerChannel.invokeMethod('getLocalIpAddress');
      return result as String?;
    } catch (e) {
      print("❌ [Native] Get local IP error: $e");
      return null;
    }
  }

  /// Проверяет доступность интернета через роутер
  static Future<bool> checkInternetViaRouter() async {
    try {
      final result = await _routerChannel.invokeMethod('checkInternetViaRouter');
      return result as bool? ?? false;
    } catch (e) {
      print("❌ [Native] Check internet via router error: $e");
      return false;
    }
  }

  /// Получает информацию о текущем подключенном роутере
  static Future<Map<String, dynamic>?> getConnectedRouterInfo() async {
    try {
      final result = await _routerChannel.invokeMethod('getConnectedRouterInfo');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      print("❌ [Native] Get connected router info error: $e");
      return null;
    }
  }

  // ==========================================
  // 🦷 GATT SERVER METHODS
  // ==========================================

  /// Запускает GATT server и ждет готовности (с Completer)
  /// Возвращает true если сервер готов, false при ошибке или таймауте
  static Future<bool> startGattServerAndWait({Duration timeout = const Duration(seconds: 25)}) async {
    try {
      print("🚀 [Native] Starting GATT server and waiting for ready...");
      
      // Проверяем, не запущен ли уже сервер
      final isRunning = await isGattServerRunning();
      if (isRunning) {
        print("ℹ️ [Native] GATT server already running");
        return true;
      }
      
      // Создаем новый completer
      if (_gattReadyCompleter != null && !_gattReadyCompleter!.isCompleted) {
        print("⚠️ [Native] Previous GATT completer still active, completing it");
        _gattReadyCompleter!.complete(false);
      }
      _gattReadyCompleter = Completer<bool>();
      
      // Запускаем сервер
      final result = await _gattChannel.invokeMethod<bool>('startGattServer');
      print("📡 [Native] startGattServer returned: $result");
      
      if (result != true) {
        print("⚠️ [Native] Failed to start GATT server");
        _gattReadyCompleter = null;
        return false;
      }
      
      // Ждем onGattReady события
      print("⏳ [Native] Waiting for onGattReady event (timeout: ${timeout.inSeconds}s)...");
      try {
        final gattReady = await _gattReadyCompleter!.future.timeout(
          timeout,
          onTimeout: () {
            print("⏱️ [Native] Timeout waiting for onGattReady (${timeout.inSeconds}s)");
            if (_gattReadyCompleter != null && _gattReadyCompleter!.isCompleted) {
              print("ℹ️ [Native] Completer already completed (late event)");
              return true;
            }
            return false;
          },
        );
        
        print("✅ [Native] GATT server ready: $gattReady");
        _gattReadyCompleter = null;
        return gattReady;
      } catch (e) {
        if (_gattReadyCompleter != null && _gattReadyCompleter!.isCompleted) {
          print("✅ [Native] Error occurred but completer completed (late event)");
          _gattReadyCompleter = null;
          return true;
        }
        print("❌ [Native] Error waiting for onGattReady: $e");
        _gattReadyCompleter = null;
        return false;
      }
    } catch (e) {
      print("❌ [Native] Error starting GATT server: $e");
      _gattReadyCompleter = null;
      return false;
    }
  }

  /// Останавливает GATT server
  static Future<void> stopGattServer() async {
    try {
      await _gattChannel.invokeMethod('stopGattServer');
      print("🛑 [Native] GATT server stopped");
      // Отменяем completer если он активен
      if (_gattReadyCompleter != null && !_gattReadyCompleter!.isCompleted) {
        _gattReadyCompleter!.complete(false);
        _gattReadyCompleter = null;
      }
    } catch (e) {
      print("❌ [Native] Error stopping GATT server: $e");
    }
  }

  /// Проверяет, запущен ли GATT server
  static Future<bool> isGattServerRunning() async {
    try {
      final result = await _gattChannel.invokeMethod<bool>('isGattServerRunning');
      return result ?? false;
    } catch (e) {
      print("❌ [Native] Error checking GATT server state: $e");
      return false;
    }
  }
}

/// Информация о Wi-Fi Direct группе
class WifiDirectGroupInfo {
  final String? networkName;
  final String? passphrase;
  final bool isGroupOwner;
  final String? ownerAddress;
  final int clientCount;
  
  WifiDirectGroupInfo({
    this.networkName,
    this.passphrase,
    this.isGroupOwner = false,
    this.ownerAddress,
    this.clientCount = 0,
  });
  
  @override
  String toString() {
    return 'WifiDirectGroupInfo(networkName: $networkName, isOwner: $isGroupOwner, clients: $clientCount)';
  }
}