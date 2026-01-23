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

  // Широковещательный поток для входящих сообщений (Mesh)
  static final StreamController<Map<String, dynamic>> _messageController =
  StreamController<Map<String, dynamic>>.broadcast();

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

        case 'onP2pStateChanged':
          final args = Map<String, dynamic>.from(call.arguments);
          final bool enabled = args['enabled'] ?? false;
          print("📡 [Native] Wi-Fi Direct state changed: ${enabled ? 'ENABLED' : 'DISABLED'}");
          if (!enabled) {
            print("⚠️ [Native] Wi-Fi Direct is DISABLED. Please enable it in settings.");
          }
          break;

        case 'onMessageReceived':
          try {
            final Map<dynamic, dynamic> args = call.arguments;
            final incomingData = {
              'message': args['message']?.toString() ?? '',
              'senderIp': args['senderIp']?.toString() ?? '',
            };
            print("📩 [Mesh-Packet] From ${incomingData['senderIp']}: ${incomingData['message']}");
            locator<MeshService>().processIncomingPacket(incomingData);
            _messageController.add(incomingData);
          } catch (e) {
            print("❌ [NativeService] Mesh parse error: $e");
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

  static Future<void> connect(String address) async {
    if (address.isEmpty || address == "null") {
      print("❌ [Native] Connection aborted: Target address is empty.");
      return;
    }
    try {
      await _channel.invokeMethod('connect', {'deviceAddress': address});
    } catch (e) {
      print("❌ [Native] Connection Error: $e");
    }
  }

  /// Отправка данных через TCP (Burst Mode)
  static Future<void> sendTcp(String message, {required String host, int? port}) async {
    try {
      // Гарантируем терминатор строки для Kotlin BufferedReader
      final String payload = message.endsWith('\n') ? message : '$message\n';
      
      // Используем переданный порт или порт по умолчанию (55556 для временного BRIDGE сервера)
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
}