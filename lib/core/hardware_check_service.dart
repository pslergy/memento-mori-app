import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

/// Сервис для проверки возможностей железа перед поднятием сервера
/// Определяет, может ли устройство поднять TCP сервер или лучше использовать прямое подключение
class HardwareCheckService {
  static final HardwareCheckService _instance = HardwareCheckService._internal();
  factory HardwareCheckService() => _instance;
  HardwareCheckService._internal();

  bool? _canHostServer;
  String? _deviceBrand;
  String? _deviceModel;

  /// Проверяет, может ли устройство поднять TCP сервер
  /// Возвращает true, если устройство способно, false - если лучше использовать прямое подключение
  Future<bool> canHostServer() async {
    if (_canHostServer != null) {
      return _canHostServer!;
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _deviceBrand = androidInfo.brand.toLowerCase();
        _deviceModel = androidInfo.model.toLowerCase();
        
        // Список бюджетных устройств, которые могут не справиться с сервером
        final budgetBrands = ['xiaomi', 'redmi', 'honor', 'huawei', 'tecno', 'infinix', 'realme', 'oppo', 'vivo'];
        final budgetKeywords = ['lite', 'a', 'c', 'e', 'go', 'play'];
        
        final isBudgetBrand = budgetBrands.any((brand) => _deviceBrand!.contains(brand));
        final isBudgetModel = budgetKeywords.any((keyword) => _deviceModel!.contains(keyword));
        
        // Проверяем версию Android (старые версии могут иметь проблемы)
        final androidVersion = androidInfo.version.sdkInt ?? 0;
        final isOldAndroid = androidVersion < 26; // Android 8.0
        
        // Проверяем количество ядер процессора (примерная оценка)
        // Для бюджетных устройств с 2-4 ядрами лучше не поднимать сервер
        // Это можно определить по модели или другим признакам
        
        // Если это бюджетное устройство или старая версия Android
        if ((isBudgetBrand && isBudgetModel) || isOldAndroid) {
          _canHostServer = false;
          print("⚠️ [HardwareCheck] Budget device detected ($_deviceBrand $_deviceModel). Preferring direct connection.");
          return false;
        }
        
        // Если это бюджетный бренд, но не бюджетная модель - проверяем дополнительно
        if (isBudgetBrand && !isBudgetModel) {
          // Для Xiaomi/Honor среднего класса - можно попробовать, но с осторожностью
          _canHostServer = true;
          print("ℹ️ [HardwareCheck] Mid-range device ($_deviceBrand $_deviceModel). Server hosting enabled with caution.");
          return true;
        }
        
        // Для остальных устройств - разрешаем поднимать сервер
        _canHostServer = true;
        print("✅ [HardwareCheck] Device capable of hosting server ($_deviceBrand $_deviceModel).");
        return true;
      } else {
        // Для iOS и других платформ - разрешаем по умолчанию
        _canHostServer = true;
        return true;
      }
    } catch (e) {
      print("⚠️ [HardwareCheck] Error checking hardware: $e. Defaulting to server hosting.");
      // В случае ошибки - разрешаем поднимать сервер (лучше попробовать, чем не работать)
      _canHostServer = true;
      return true;
    }
  }

  /// Получает информацию об устройстве для логирования
  Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return {
          'brand': androidInfo.brand,
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'androidVersion': androidInfo.version.sdkInt,
          'device': androidInfo.device,
        };
      }
      
      return {'platform': 'unknown'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Сбрасывает кэш (для повторной проверки)
  void resetCache() {
    _canHostServer = null;
    _deviceBrand = null;
    _deviceModel = null;
  }
}
