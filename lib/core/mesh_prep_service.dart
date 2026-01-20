import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class MeshPrepService {
  /// Тот самый метод, который ищет SplashScreen
  static Future<bool> requestTacticalPermissions() async {
    if (!Platform.isAndroid) return true;

    print("🛡️ [Security] Initiating Sequential Mandate...");

    // 1. Собираем список необходимых разрешений
    List<Permission> tacticalPermissions = [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.microphone,
    ];

    // 2. Для Android 13+ добавляем разрешение на устройства рядом
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      tacticalPermissions.add(Permission.nearbyWifiDevices);
    }

    // 3. Запрашиваем по очереди (Android лучше переваривает одиночные запросы)
    for (var permission in tacticalPermissions) {
      final status = await permission.request();
      if (!status.isGranted) {
        print("❌ [Security] Mandate rejected for: ${permission.toString()}");
        // Можно не выходить сразу, а дать юзеру шанс разрешить остальные
      }
    }

    // 4. Проверка финального статуса (всё ли нам дали?)
    bool locationOk = await Permission.location.isGranted;
    bool btOk = await Permission.bluetoothConnect.isGranted && await Permission.bluetoothScan.isGranted;

    // Специфичная проверка для Android 13
    bool nearbyOk = (androidInfo.version.sdkInt >= 33)
        ? await Permission.nearbyWifiDevices.isGranted
        : true;

    if (locationOk && btOk && nearbyOk) {
      print("✅ [Security] ALL SYSTEMS AUTHORIZED.");

      // Попутно просим выключить оптимизацию батареи (не критично, но желательно)
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      return true;
    }

    return false;
  }
}