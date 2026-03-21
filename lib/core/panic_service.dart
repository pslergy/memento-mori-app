import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'panic/panic_storage_keys.dart';
import 'panic/secure_purge_flow.dart';

class PanicService {
  static const _storage = FlutterSecureStorage();

  /// Алиас для [kPanicProtocolActivatedStorageKey].
  static const String panicFlagStorageKey = kPanicProtocolActivatedStorageKey;

  /// Проверяет, был ли активирован паник-протокол
  static Future<bool> isPanicProtocolActivated() async {
    final flag = await _storage.read(key: kPanicProtocolActivatedStorageKey);
    return flag == 'true';
  }

  /// Сбрасывает флаг паник-протокола
  static Future<void> resetPanicFlag() async {
    await _storage.delete(key: kPanicProtocolActivatedStorageKey);
    print("✅ [PANIC] Panic protocol flag reset");
  }

  /// Мягкая паника: только флаг + выход из процесса. Данные REAL на диске не трогаются.
  static Future<void> killSwitch(BuildContext context) async {
    print("--- [PANIC PROTOCOL INITIATED] (soft) ---");

    await _storage.write(key: kPanicProtocolActivatedStorageKey, value: 'true');
    print(
        "🚩 [PANIC] Panic protocol flag set - calculator + biometric on next launch; messages neutral until reveal code");

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SYSTEM PURGED'),
          backgroundColor: Colors.red,
          duration: Duration(milliseconds: 500),
        ),
      );
    }

    await Future.delayed(const Duration(milliseconds: 200));
    SystemChannels.platform.invokeMethod('SystemNavigator.pop');
  }

  /// Полное стирание профиля REAL + пересборка DI + экран калькулятора.
  /// Хэши калькулятора в отдельном storage не затрагиваются.
  ///
  /// [context] опционален (навигация через [appNavigatorKey]).
  static Future<void> hardPurgeRealData([BuildContext? context]) async {
    print("--- [PANIC PROTOCOL INITIATED] (hard REAL purge) ---");
    try {
      await hardPurgeRealAndNavigateToCalculator();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('hardPurgeRealData: $e\n$st');
      }
    }
  }
}
