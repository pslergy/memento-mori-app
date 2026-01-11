import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'locator.dart';
import 'mesh_service.dart';

class NativeMeshService {
  static const MethodChannel _channel = MethodChannel('memento/wifi_direct');

  // Используем широковещательный поток для входящих пакетов
  static final StreamController<Map<String, dynamic>> _messageController =
  StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      // Логируем все входящие вызовы для отладки на Tecno
      print("📡 [Native -> Flutter] Method: ${call.method}");

      switch (call.method) {
        case 'onPeersFound':
          final List<dynamic> raw = call.arguments;
          locator<MeshService>().handleNativePeers(raw);
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
            // 🔥 ИСПРАВЛЕНИЕ: Получаем Map, а не String
            final Map<dynamic, dynamic> args = call.arguments;

            // Преобразуем в строго типизированный Map
            final incomingData = {
              'message': args['message']?.toString() ?? '',
              'senderIp': args['senderIp']?.toString() ?? '',
            };

            print("📩 [Mesh-Packet] From ${incomingData['senderIp']}: ${incomingData['message']}");

            // Отправляем в MeshService.
            // Передаем весь Map, чтобы MeshService знал IP отправителя (для Tecno это критично!)
            locator<MeshService>().processIncomingPacket(incomingData);

            // Также дублируем в локальный поток
            _messageController.add(incomingData);
          } catch (e) {
            print("❌ [NativeService] Error parsing incoming packet: $e");
          }
          break;

        default:
          print("⚠️ Unknown method from Native: ${call.method}");
      }
    });
  }

  // --- ТАКТИЧЕСКИЕ МЕТОДЫ ОТПРАВКИ ---

  static Future<void> startDiscovery() async {
    try {
      await _channel.invokeMethod('startDiscovery');
    } catch (e) {
      print("❌ WiFi-D Discovery Error: $e");
    }
  }

  static Future<void> stopDiscovery() async {
    try {
      await _channel.invokeMethod('stopDiscovery');
    } catch (e) {
      print("❌ WiFi-D Stop Error: $e");
    }
  }

  static Future<void> connect(String address) async {
    try {
      await _channel.invokeMethod('connect', {'deviceAddress': address});
    } catch (e) {
      print("❌ WiFi-D Connect Error: $e");
    }
  }

  /// Отправка пакета через TCP Bursts
  static Future<void> sendTcp(String message, {required String host}) async {
    try {
      // Добавляем терминатор строки для Kotlin Scanner/readLine
      final String payload = message.endsWith('\n') ? message : '$message\n';

      await _channel.invokeMethod('sendTcp', {
        'host': host,
        'port': 55555,
        'message': payload
      });
      print("🚀 [Native] TCP Payload sent to $host");
    } catch (e) {
      print("❌ [Native] TCP Send Failure: $e");
    }
  }
}