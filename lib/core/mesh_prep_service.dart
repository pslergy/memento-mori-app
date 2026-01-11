import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class MeshPrepService {
  static Future<bool> readyForGlobalTest() async {
    if (!Platform.isAndroid) return true;

    // 1. Проверка разрешений
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
    ].request();

    if (statuses.values.any((s) => s.isDenied)) return false;

    // 2. Проверка оптимизации батареи (Критично для Tecno!)
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    return true;
  }
}