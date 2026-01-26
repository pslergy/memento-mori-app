import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  // ТАКТИЧЕСКИЙ ХОД: На Tecno/Huawei отключаем encryptedSharedPreferences,
  // так как они ломают чтение при перезагрузке.
  static const _options = AndroidOptions(
    encryptedSharedPreferences: false,
    resetOnError: true,
  );

  static const storage = FlutterSecureStorage(aOptions: _options);
}

/// 🔒 SECURE VAULT: Хранит чувствительные данные в зашифрованном хранилище
/// 
/// КРИТИЧНО: Использует FlutterSecureStorage вместо SharedPreferences!
/// - Android: AES-256 шифрование через KeyStore
/// - iOS: Keychain Services
/// 
/// МИГРАЦИЯ: При первом запуске переносит данные из старого SharedPreferences
class Vault {
  // 🔒 Secure Storage с оптимальными настройками для проблемных устройств
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: false, // Отключаем для Tecno/Huawei совместимости
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
      
      print("🔄 [VAULT] Starting migration from SharedPreferences to SecureStorage...");
      
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

  /// 🔒 Записывает значение в ЗАШИФРОВАННОЕ хранилище
  static Future<void> write(dynamic key, dynamic value) async {
    if (key == null || value == null) return;
    
    await _migrateIfNeeded();
    
    final keyStr = key.toString();
    final valueStr = value.toString();
    
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

  /// 🔒 Читает значение из ЗАШИФРОВАННОГО хранилища
  static Future<String?> read(dynamic key) async {
    if (key == null) return null;
    
    await _migrateIfNeeded();
    
    final keyStr = key.toString();
    
    try {
      final res = await _storage.read(key: keyStr);
      // 🔒 НЕ логируем значения чувствительных ключей
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
    try {
      await _storage.delete(key: keyStr);
      print("🗑️ [VAULT-DELETE] $keyStr");
    } catch (e) {
      print("❌ [VAULT-DELETE] Error deleting $keyStr: $e");
    }
  }

  /// ☢️ Полная очистка ВСЕХ данных
  static Future<void> deleteAll() async {
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
    
    await _migrateIfNeeded();
    
    try {
      return await _storage.containsKey(key: key.toString());
    } catch (e) {
      return false;
    }
  }
}