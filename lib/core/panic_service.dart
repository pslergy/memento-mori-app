import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'locator.dart';
import 'local_db_service.dart';

class PanicService {
  static const _storage = FlutterSecureStorage();
  static const String _panicFlagKey = 'panic_protocol_activated';

  /// Проверяет, был ли активирован паник-протокол
  static Future<bool> isPanicProtocolActivated() async {
    final flag = await _storage.read(key: _panicFlagKey);
    return flag == 'true';
  }

  /// Сбрасывает флаг паник-протокола
  static Future<void> resetPanicFlag() async {
    await _storage.delete(key: _panicFlagKey);
    print("✅ [PANIC] Panic protocol flag reset");
  }

  /// ПОЛНАЯ ЗАЧИСТКА
  /// Удаляет сообщения за 24 часа, устанавливает флаг и закрывает приложение
  static Future<void> killSwitch(BuildContext context) async {
    print("--- [PANIC PROTOCOL INITIATED] ---");

    try {
      // 1. Удаляем сообщения за последние 24 часа
      final db = locator<LocalDatabaseService>();
      await db.deleteMessagesLast24Hours();
    } catch (e) {
      print("⚠️ [PANIC] Failed to delete messages: $e");
    }

    // 2. Устанавливаем флаг паник-протокола (НЕ удаляем токены, чтобы можно было войти)
    await _storage.write(key: _panicFlagKey, value: 'true');
    print("🚩 [PANIC] Panic protocol flag set - will require calculator + biometric on next launch");

    // 3. Визуальный эффект сброса
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SYSTEM PURGED'),
          backgroundColor: Colors.red,
          duration: Duration(milliseconds: 500),
        ),
      );
    }

    // 4. Жесткое завершение процесса
    // При следующем запуске будет запрошен калькулятор и биометрия
    await Future.delayed(const Duration(milliseconds: 200));
    SystemChannels.platform.invokeMethod('SystemNavigator.pop');
  }
}