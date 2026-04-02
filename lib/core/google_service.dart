import 'package:flutter/services.dart';

class GooglePlayServices {
  static const MethodChannel _channel = MethodChannel('google_play_services');

  static Future<bool> isAvailable() async {
    try {
      final bool result = await _channel.invokeMethod("isAvailable");
      return result;
    } catch (e) {
      print("Google Check Error: $e");
      return false; // Если ошибка - считаем, что сервисов нет
    }
  }
}