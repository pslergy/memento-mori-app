import 'package:flutter/services.dart';

class SecurityService {
  static const _channel = MethodChannel('memento/security');

  static Future<void> changeIcon(String iconName) async {
    try {
      // iconName должен быть "Calculator" или "Notes"
      await _channel.invokeMethod('changeIcon', {'targetIcon': iconName});
    } catch (e) {
      print("❌ [Camouflage] Failed to switch: $e");
    }
  }


  /// Включает режим защиты (блокирует скриншоты и скрывает превью в списке задач)
  static Future<void> enableSecureMode() async {
    try {
      await _channel.invokeMethod('enableSecureMode');
      print("🛡️ [Security] Secure Mode: ACTIVATED");
    } catch (e) {
      print("❌ [Security] Failed to enable secure mode: $e");
    }
  }

  /// Отключает защиту
  static Future<void> disableSecureMode() async {
    try {
      await _channel.invokeMethod('disableSecureMode');
      print("🔓 [Security] Secure Mode: DEACTIVATED");
    } catch (e) {
      print("❌ [Security] Failed to disable secure mode: $e");
    }
  }
}