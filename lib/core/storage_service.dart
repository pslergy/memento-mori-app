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



class Vault {
  // Просто принимаем два аргумента по порядку
  static Future<void> write(dynamic key, dynamic value) async {
    if (key == null || value == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key.toString(), value.toString());
    print("💾 [VAULT-WRITE] $key: $value");
  }

  // Просто принимаем один аргумент
  static Future<String?> read(dynamic key) async {
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final res = prefs.getString(key.toString());
    print("📖 [VAULT-READ] $key: $res");
    return res;
  }

  static Future<void> deleteAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    print("☢️ [VAULT] ALL DATA WIPED.");
  }
}