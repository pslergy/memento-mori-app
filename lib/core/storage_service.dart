import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'decoy/vault_interface.dart';

class StorageService {
  // ТАКТИЧЕСКИЙ ХОД: На Tecno/Huawei отключаем encryptedSharedPreferences,
  // так как они ломают чтение при перезагрузке.
  static const _options = AndroidOptions(
    encryptedSharedPreferences: false,
    resetOnError: true,
  );

  static const storage = FlutterSecureStorage(aOptions: _options);
}

/// 👻 Бэкап Ghost-идентичности в SharedPreferences.
/// На Huawei FlutterSecureStorage может не сохранять данные между перезапусками — SharedPreferences надёжнее.
const _ghostPrefix = '_ghost_bak_';

class GhostBackup {
  static const ghostKeys = [
    'auth_token',
    'user_id',
    'user_name',
    'user_deathDate',
    'user_birthDate',
  ];

  static Future<void> save(
    String userId,
    String deathDate,
    String birthDate, {
    String? userName,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${_ghostPrefix}auth_token', 'GHOST_MODE_ACTIVE');
      await prefs.setString('${_ghostPrefix}user_id', userId);
      await prefs.setString('${_ghostPrefix}user_deathDate', deathDate);
      await prefs.setString('${_ghostPrefix}user_birthDate', birthDate);
      if (userName != null && userName.trim().isNotEmpty) {
        await prefs.setString('${_ghostPrefix}user_name', userName.trim());
      }
      print("👻 [GhostBackup] Saved to SharedPreferences (Huawei fallback)");
    } catch (e) {
      print("⚠️ [GhostBackup] Save failed: $e");
    }
  }

  static Future<String?> read(String key) async {
    if (!ghostKeys.contains(key)) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_ghostPrefix$key');
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, String>?> readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('${_ghostPrefix}user_id');
      if (userId == null || userId.isEmpty) return null;
      return {
        'auth_token': prefs.getString('${_ghostPrefix}auth_token') ?? 'GHOST_MODE_ACTIVE',
        'user_id': userId,
        'user_name': prefs.getString('${_ghostPrefix}user_name') ?? '',
        'user_deathDate': prefs.getString('${_ghostPrefix}user_deathDate') ?? '',
        'user_birthDate': prefs.getString('${_ghostPrefix}user_birthDate') ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// Стереть все ключи с префиксом `_ghost_bak_` (при полном сбросе REAL).
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toRemove = prefs
          .getKeys()
          .where((k) => k.startsWith(_ghostPrefix))
          .toList();
      for (final k in toRemove) {
        await prefs.remove(k);
      }
    } catch (_) {}
  }
}

/// 🔒 SECURE VAULT: Хранит чувствительные данные в зашифрованном хранилище.
///
/// SECURITY INVARIANT: When [VaultInterface] is registered (mode-aware bootstrap),
/// all read/write delegates to the mode-scoped vault. No shared storage across modes.
class Vault {
  static VaultInterface? get _scopedVault {
    try {
      if (GetIt.instance.isRegistered<VaultInterface>()) {
        return GetIt.instance<VaultInterface>();
      }
    } catch (_) {}
    return null;
  }

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences:
          false, // Отключаем для Tecno/Huawei совместимости
      resetOnError: true, // Сбросить при ошибке декриптации (лучше чем краш)
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Ключи, которые содержат чувствительные данные
  static const _sensitiveKeys = [
    'auth_token',
    'user_id',
    'landing_pass',
    'refresh_token',
    'session_id',
  ];

  static bool _migrationCompleted = false;

  /// 🔄 Мигрирует данные из SharedPreferences в SecureStorage (однократно)
  static Future<void> _migrateIfNeeded() async {
    if (_migrationCompleted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final migrationKey = '_vault_migrated_v2';

      // Проверяем, была ли миграция
      if (prefs.getBool(migrationKey) == true) {
        _migrationCompleted = true;
        return;
      }

      print(
          "🔄 [VAULT] Starting migration from SharedPreferences to SecureStorage...");

      // Мигрируем все чувствительные ключи
      for (final key in _sensitiveKeys) {
        final oldValue = prefs.getString(key);
        if (oldValue != null && oldValue.isNotEmpty) {
          await _storage.write(key: key, value: oldValue);
          await prefs.remove(key); // Удаляем из незащищенного хранилища
          print("  ✅ [VAULT] Migrated: $key");
        }
      }

      // Отмечаем миграцию завершенной
      await prefs.setBool(migrationKey, true);
      _migrationCompleted = true;
      print("✅ [VAULT] Migration completed successfully");
    } catch (e) {
      print("⚠️ [VAULT] Migration error (non-fatal): $e");
      _migrationCompleted = true; // Не блокируем работу при ошибке
    }
  }

  /// 🔒 Записывает значение в ЗАШИФРОВАННОЕ хранилище.
  /// Для чувствительных ключей дублируем в fallback (_storage), чтобы на Huawei при рассинхроне scoped чтение с fallback находило данные.
  static Future<void> write(dynamic key, dynamic value) async {
    if (key == null || value == null) return;
    final keyStr = key.toString();
    final valueStr = value.toString();
    final scoped = _scopedVault;
    if (scoped != null) {
      await scoped.write(keyStr, valueStr);
      if (_sensitiveKeys.contains(keyStr)) {
        try {
          await _storage.write(key: keyStr, value: valueStr);
        } catch (_) {}
      }
      return;
    }
    await _migrateIfNeeded();
    try {
      await _storage.write(key: keyStr, value: valueStr);
      // 🔒 НЕ логируем значения чувствительных ключей
      if (_sensitiveKeys.contains(keyStr)) {
        print("💾 [VAULT-WRITE] $keyStr: ***SECURED***");
      } else {
        print("💾 [VAULT-WRITE] $keyStr: $valueStr");
      }
    } catch (e) {
      print("❌ [VAULT-WRITE] Error writing $keyStr: $e");
      // Fallback: пытаемся сбросить и записать заново
      try {
        await _storage.delete(key: keyStr);
        await _storage.write(key: keyStr, value: valueStr);
        print("✅ [VAULT-WRITE] Retry succeeded for $keyStr");
      } catch (e2) {
        print("❌ [VAULT-WRITE] Retry also failed: $e2");
      }
    }
  }

  /// 🔒 Читает значение из ЗАШИФРОВАННОГО хранилища.
  /// Если scoped возвращает null и ключ чувствительный — пробуем fallback (_storage), затем SharedPreferences (Huawei).
  static Future<String?> read(dynamic key) async {
    if (key == null) return null;
    final keyStr = key.toString();
    final scoped = _scopedVault;
    if (scoped != null) {
      final res = await scoped.read(keyStr);
      if (res != null) return res;
      if (_sensitiveKeys.contains(keyStr)) {
        try {
          final fallback = await _storage.read(key: keyStr);
          if (fallback != null && fallback.isNotEmpty) {
            await scoped.write(keyStr, fallback);
            print("📖 [VAULT-READ] $keyStr: ***SECURED*** (from fallback, synced)");
            return fallback;
          }
        } catch (_) {}
      }
      if (GhostBackup.ghostKeys.contains(keyStr)) {
        final ghostVal = await GhostBackup.read(keyStr);
        if (ghostVal != null && ghostVal.isNotEmpty) {
          await scoped.write(keyStr, ghostVal);
          print("📖 [VAULT-READ] $keyStr: *** (from GhostBackup)");
          return ghostVal;
        }
      }
      return null;
    }
    await _migrateIfNeeded();
    try {
      var res = await _storage.read(key: keyStr);
      if (res == null && GhostBackup.ghostKeys.contains(keyStr)) {
        res = await GhostBackup.read(keyStr);
        if (res != null) await _storage.write(key: keyStr, value: res);
      }
      if (_sensitiveKeys.contains(keyStr)) {
        print("📖 [VAULT-READ] $keyStr: ${res != null ? '***SECURED***' : 'null'}");
      } else {
        print("📖 [VAULT-READ] $keyStr: $res");
      }
      return res;
    } catch (e) {
      print("❌ [VAULT-READ] Error reading $keyStr: $e");
      return null;
    }
  }

  /// 🔒 Удаляет конкретный ключ
  static Future<void> delete(dynamic key) async {
    if (key == null) return;
    final keyStr = key.toString();
    final scoped = _scopedVault;
    if (scoped != null) {
      await scoped.delete(keyStr);
      return;
    }
    try {
      await _storage.delete(key: keyStr);
      print("🗑️ [VAULT-DELETE] $keyStr");
    } catch (e) {
      print("❌ [VAULT-DELETE] Error deleting $keyStr: $e");
    }
  }

  /// ☢️ Полная очистка ВСЕХ данных (текущего режима)
  static Future<void> deleteAll() async {
    final scoped = _scopedVault;
    if (scoped != null) {
      await scoped.deleteAll();
      return;
    }
    try {
      await _storage.deleteAll();
      print("☢️ [VAULT] ALL SECURE DATA WIPED.");

      // Также очищаем SharedPreferences (для полной очистки)
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      _migrationCompleted = false;
      print("☢️ [VAULT] SharedPreferences also cleared.");
    } catch (e) {
      print("❌ [VAULT] Error during deleteAll: $e");
    }
  }

  /// 🔍 Проверяет наличие ключа
  static Future<bool> containsKey(dynamic key) async {
    if (key == null) return false;
    final scoped = _scopedVault;
    if (scoped != null) return scoped.containsKey(key.toString());
    await _migrateIfNeeded();
    try {
      return await _storage.containsKey(key: key.toString());
    } catch (e) {
      return false;
    }
  }
}
