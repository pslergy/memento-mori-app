import 'dart:io';
import 'dart:convert';
import '../native_mesh_service.dart';

/// Протокол передачи данных через Wi-Fi роутер
class RouterBridgeProtocol {
  static final RouterBridgeProtocol _instance = RouterBridgeProtocol._internal();
  factory RouterBridgeProtocol() => _instance;
  RouterBridgeProtocol._internal();

  /// Передает данные через роутер по TCP
  Future<bool> sendViaRouter(String data, String targetIp, {int port = 55556}) async {
    try {
      final socket = await Socket.connect(targetIp, port, timeout: const Duration(seconds: 5));
      socket.add(utf8.encode('$data\n'));
      await socket.flush();
      socket.destroy();
      print("🛰️ [RouterProtocol] Data sent to $targetIp:$port");
      return true;
    } catch (e) {
      print("❌ [RouterProtocol] Send error: $e");
      return false;
    }
  }

  /// Обнаруживает устройства в локальной сети роутера
  /// Сканирует подсеть для поиска других устройств меш-сети
  Future<List<String>> discoverDevicesInNetwork() async {
    try {
      final localIp = await NativeMeshService.getLocalIpAddress();
      if (localIp == null) return [];

      // Извлекаем подсеть (например, 192.168.1.1 -> 192.168.1)
      final parts = localIp.split('.');
      if (parts.length != 4) return [];

      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      final devices = <String>[];

      // Сканируем первые 10 адресов в подсети (быстрое сканирование)
      for (int i = 1; i <= 10; i++) {
        final ip = '$subnet.$i';
        if (ip == localIp) continue; // Пропускаем свой IP

        try {
          final socket = await Socket.connect(ip, 55556, timeout: const Duration(milliseconds: 500));
          devices.add(ip);
          socket.destroy();
        } catch (_) {
          // Устройство не отвечает или не является частью меш-сети
        }
      }

      return devices;
    } catch (e) {
      print("❌ [RouterProtocol] Discovery error: $e");
      return [];
    }
  }

  /// Отправляет batch сообщений через роутер
  Future<bool> sendBatch(List<Map<String, dynamic>> messages, String targetIp) async {
    try {
      final batch = {
        'type': 'BATCH_MESSAGE',
        'messages': messages,
        'count': messages.length,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      final data = jsonEncode(batch);
      return await sendViaRouter(data, targetIp);
    } catch (e) {
      print("❌ [RouterProtocol] Batch send error: $e");
      return false;
    }
  }
}
