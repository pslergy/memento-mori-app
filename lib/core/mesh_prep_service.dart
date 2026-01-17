import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class MeshPrepService {
  static Future<bool> requestTacticalPermissions() async {
    if (!Platform.isAndroid) return true;

    // Запрашиваем всё одним пакетом
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,           // Для Wi-Fi Direct и BLE
      Permission.bluetoothScan,      // BLE поиск
      Permission.bluetoothConnect,   // GATT соединение
      Permission.bluetoothAdvertise, // BLE вещание
      Permission.nearbyWifiDevices,  // Android 13+ Wi-Fi Mesh
      Permission.microphone,         // Сонар
    ].request();

    // Проверяем, не отказал ли юзер в чем-то критическом
    bool allGranted = statuses.values.every((status) => status.isGranted);

    if (allGranted) {
      print("🛡️ [Security] Universal mandate granted. System is authorized.");
    }
    return allGranted;
  }
}