import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

class PanicService {
  static const _storage = FlutterSecureStorage();

  /// ПОЛНАЯ ЗАЧИСТКА
  /// Удаляет токены и закрывает приложение
  static Future<void> killSwitch(BuildContext context) async {
    print("--- [PANIC PROTOCOL INITIATED] ---");

    // 1. Стираем ключи доступа
    await _storage.deleteAll();

    // 2. (Опционально) Можно отправить на сервер сигнал "Я скомпрометирован",
    // чтобы сервер удалил чаты удаленно, но это опасно (может не быть сети).

    // 3. Визуальный эффект сброса (опционально)
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
    // В Android это убьет приложение.
    // При перезапуске юзер попадет в калькулятор, а вход будет невозможен (токен удален).
    await Future.delayed(const Duration(milliseconds: 200));
    SystemChannels.platform.invokeMethod('SystemNavigator.pop');
  }
}