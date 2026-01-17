import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'locator.dart';
import 'mesh_service.dart';

class NativeMeshService {
  // Канал для Wi-Fi Direct и системных функций
  static const MethodChannel _channel = MethodChannel('memento/wifi_direct');

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
          // Мы НЕ подключаемся сразу, а просим MeshService показать диалог пользователю
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

        case 'onMessageReceived':
          try {
            // Принимаем Map с сообщением и IP отправителя
            final Map<dynamic, dynamic> args = call.arguments;
            final incomingData = {
              'message': args['message']?.toString() ?? '',
              'senderIp': args['senderIp']?.toString() ?? '',
            };

            print("📩 [Mesh-Packet] From ${incomingData['senderIp']}: ${incomingData['message']}");

            // Отправляем в MeshService для вирусной ретрансляции и логики
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
            // Пробрасываем пойманный звук в UltrasonicService
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
  static Future<void> startDiscovery() async {
    try {
      await _channel.invokeMethod('startDiscovery');
    } catch (e) {
      print("❌ [Native] Discovery Error: $e");
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
      print("☢️ [Native] P2P Stack Reset performed.");
    } catch (e) {
      print("❌ [Native] Force Reset Error: $e");
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
  static Future<void> sendTcp(String message, {required String host}) async {
    try {
      // Гарантируем терминатор строки для Kotlin BufferedReader
      final String payload = message.endsWith('\n') ? message : '$message\n';

      await _channel.invokeMethod('sendTcp', {
        'host': host,
        'port': 55555,
        'message': payload
      });
      print("🚀 [Native] TCP Burst delivered to $host");
    } catch (e) {
      print("❌ [Native] TCP Transmission Failure: $e");
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
}