import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read-only facts from device + doc (brand, sdk, manufacturer quirks).
/// Policy stays in HardwareCheckService; this is structural only for future separation.
class DeviceFacts {
  const DeviceFacts({
    this.brand,
    this.model,
    this.sdk,
    required this.isHuaweiOrHonorFromDoc,
    required this.preferGattPeripheralFromDoc,
    required this.canHostServerFromDoc,
  });
  final String? brand;
  final String? model;
  final int? sdk;
  final bool isHuaweiOrHonorFromDoc;
  final bool preferGattPeripheralFromDoc;
  final bool canHostServerFromDoc;
}

/// Единая «документация» по классам поведения устройства (вендор/модель/sdk).
/// Все решения о подключениях (TCP-сервер, BLE Central/Peripheral, порядок каналов)
/// читаются отсюда. Не менять результат для известных устройств (Tecno→Huawei и т.д.).
class _DeviceConnectionProfile {
  const _DeviceConnectionProfile({
    required this.canHostServer,
    required this.preferBleOverWifi,
    required this.preferGattPeripheral,
    required this.isHuaweiOrHonor,
  });
  final bool canHostServer;
  final bool preferBleOverWifi;
  final bool preferGattPeripheral;
  final bool isHuaweiOrHonor;
}

/// Сервис для проверки возможностей железа перед поднятием сервера
/// Определяет, может ли устройство поднять TCP сервер или лучше использовать прямое подключение
class HardwareCheckService {
  static final HardwareCheckService _instance = HardwareCheckService._internal();
  factory HardwareCheckService() => _instance;
  HardwareCheckService._internal();

  String? _deviceBrand;
  String? _deviceModel;
  int? _deviceSdk;
  _DeviceConnectionProfile? _cachedProfile;
  /// Doc-only profile (no adaptation overlay); for DeviceFacts and future policy.
  _DeviceConnectionProfile? _docProfile;

  /// Самоадаптация: score по отпечатку (N failures → same boolean as before).
  /// Threshold 2: after 2 failures, preferGattPeripheral override for non-known-good vendors.
  static const int _kBleCentralFailureThreshold = 2;
  static const String _kPrefBleCentralFailures = 'ble_central_failure_count';
  final Map<String, int> _bleCentralFailureCountByFingerprint = {};
  bool _bleFailuresLoaded = false;

  /// Load persisted BLE central failure counts. Call from _ensureDeviceInfo or before first use.
  Future<void> _loadPersistedBleFailures() async {
    if (_bleFailuresLoaded) return;
    _bleFailuresLoaded = true;
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_kPrefBleCentralFailures);
      if (json == null || json.isEmpty) return;
      final map = jsonDecode(json) as Map<String, dynamic>?;
      if (map == null) return;
      for (final e in map.entries) {
        if (e.value is int) _bleCentralFailureCountByFingerprint[e.key] = e.value as int;
      }
    } catch (_) {}
  }

  /// Persist BLE central failure counts (after recording a failure).
  Future<void> _persistBleFailures() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefBleCentralFailures, jsonEncode(_bleCentralFailureCountByFingerprint));
    } catch (_) {}
  }

  /// True if this device has had >2 BLE central timeouts (persisted). Used for capability bitmask.
  Future<bool> get bleCentralUnstable async {
    await _ensureDeviceInfo();
    await _loadPersistedBleFailures();
    final fp = await getDeviceFingerprint();
    if (fp == 'unknown') return false;
    return _bleCentralFailureScoreForFingerprint(fp) > 2;
  }

  /// Отпечаток устройства для кэша самоадаптации. Вызывать после _ensureDeviceInfo().
  Future<String> getDeviceFingerprint() async {
    await _ensureDeviceInfo();
    if (_deviceBrand == null || _deviceModel == null) return 'unknown';
    return '${_deviceBrand!}|${_deviceModel!}|${_deviceSdk ?? 0}';
  }

  int _bleCentralFailureScoreForFingerprint(String fp) {
    return _bleCentralFailureCountByFingerprint[fp] ?? 0;
  }

  /// Вызвать при неудаче попытки BLE Central (connect timeout/error). После _kBleCentralFailureThreshold
  /// неудач для этого отпечатка в профиле включается preferGattPeripheral (не инициировать GATT).
  /// Persists count so capability survives restart. Не трогаем известные вендоры (Huawei/Tecno/Xiaomi).
  Future<void> recordBleCentralFailure() async {
    if (!Platform.isAndroid) return;
    await _loadPersistedBleFailures();
    final fp = await getDeviceFingerprint();
    if (fp == 'unknown') return;
    _bleCentralFailureCountByFingerprint[fp] =
        _bleCentralFailureScoreForFingerprint(fp) + 1;
    await _persistBleFailures();
    if (_bleCentralFailureScoreForFingerprint(fp) >= _kBleCentralFailureThreshold) {
      _cachedProfile = null;
    }
  }

  /// Вендоры, которые по документации хорошо инициируют GATT (Tecno→Huawei и т.д.). Не переопределяем из кэша.
  static bool _isKnownGoodCentralBrand(String brand) {
    const good = ['tecno', 'infinix', 'xiaomi', 'redmi', 'poco'];
    return good.any((b) => brand.contains(b));
  }

  /// Один раз загружаем device info и строим профиль по «документации».
  /// Логика совпадает с CONNECTION_PATTERNS_SNAPSHOT.md — не менять результат.
  Future<void> _ensureDeviceInfo() async {
    if (_cachedProfile != null) return;
    await _loadPersistedBleFailures();
    try {
      if (!Platform.isAndroid) {
        _cachedProfile = const _DeviceConnectionProfile(
          canHostServer: true,
          preferBleOverWifi: false,
          preferGattPeripheral: false,
          isHuaweiOrHonor: false,
        );
        _docProfile = _cachedProfile;
        return;
      }
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _deviceBrand = androidInfo.brand.toLowerCase();
      _deviceModel = androidInfo.model.toLowerCase();
      _deviceSdk = androidInfo.version.sdkInt;
      final docP = _buildProfileFromDoc();
      _docProfile = docP;
      var p = docP;
      final fp = '$_deviceBrand|$_deviceModel|$_deviceSdk';
      if (_bleCentralFailureScoreForFingerprint(fp) >= _kBleCentralFailureThreshold &&
          !p.preferGattPeripheral &&
          !_isKnownGoodCentralBrand(_deviceBrand ?? '')) {
        p = _DeviceConnectionProfile(
          canHostServer: p.canHostServer,
          preferBleOverWifi: p.preferBleOverWifi,
          preferGattPeripheral: true,
          isHuaweiOrHonor: p.isHuaweiOrHonor,
        );
      }
      _cachedProfile = p;
    } catch (e) {
      print("⚠️ [HardwareCheck] Error checking hardware: $e. Defaulting to server hosting.");
      _cachedProfile = const _DeviceConnectionProfile(
        canHostServer: true,
        preferBleOverWifi: false,
        preferGattPeripheral: false,
        isHuaweiOrHonor: false,
      );
      _docProfile = _cachedProfile;
    }
  }

  /// Read-only facts (brand, sdk, doc-based quirks). No policy; structural only.
  Future<DeviceFacts> getDeviceFacts() async {
    await _ensureDeviceInfo();
    final doc = _docProfile;
    if (doc == null) {
      return const DeviceFacts(
        isHuaweiOrHonorFromDoc: false,
        preferGattPeripheralFromDoc: false,
        canHostServerFromDoc: true,
      );
    }
    return DeviceFacts(
      brand: _deviceBrand,
      model: _deviceModel,
      sdk: _deviceSdk,
      isHuaweiOrHonorFromDoc: doc.isHuaweiOrHonor,
      preferGattPeripheralFromDoc: doc.preferGattPeripheral,
      canHostServerFromDoc: doc.canHostServer,
    );
  }

  /// Малоразмерная «документация»: вендор/модель/sdk → флаги. Результат эквивалентен старой логике.
  _DeviceConnectionProfile _buildProfileFromDoc() {
    final brand = _deviceBrand ?? '';
    final model = _deviceModel ?? '';
    final sdk = _deviceSdk!;

    const budgetBrands = ['xiaomi', 'redmi', 'honor', 'huawei', 'tecno', 'infinix', 'realme', 'oppo', 'vivo'];
    const budgetKeywords = ['lite', 'a', 'c', 'e', 'go', 'play'];
    const weakBleOverWifiBrands = ['huawei', 'honor', 'xiaomi', 'redmi', 'tecno', 'infinix', 'poco', 'realme'];
    const badCentralBrands = ['huawei', 'honor'];

    final isBudgetBrand = budgetBrands.any((b) => brand.contains(b));
    final isBudgetModel = budgetKeywords.any((k) => model.contains(k));
    final isOldAndroid = sdk < 26;
    final canHostServer = !((isBudgetBrand && isBudgetModel) || isOldAndroid);
    final preferBleOverWifi = weakBleOverWifiBrands.any((b) => brand.contains(b));
    final preferGattPeripheral = badCentralBrands.any((b) => brand.contains(b));
    final isHuaweiOrHonor = brand.contains('huawei') || brand.contains('honor');

    return _DeviceConnectionProfile(
      canHostServer: canHostServer,
      preferBleOverWifi: preferBleOverWifi,
      preferGattPeripheral: preferGattPeripheral,
      isHuaweiOrHonor: isHuaweiOrHonor,
    );
  }

  /// Проверяет, может ли устройство поднять TCP сервер
  /// Возвращает true, если устройство способно, false - если лучше использовать прямое подключение
  Future<bool> canHostServer() async {
    await _ensureDeviceInfo();
    final p = _cachedProfile!;
    if (Platform.isAndroid && _deviceBrand != null && _deviceModel != null) {
      const budgetBrands = ['xiaomi', 'redmi', 'honor', 'huawei', 'tecno', 'infinix', 'realme', 'oppo', 'vivo'];
      const budgetKeywords = ['lite', 'a', 'c', 'e', 'go', 'play'];
      final isBudgetBrand = budgetBrands.any((b) => _deviceBrand!.contains(b));
      final isBudgetModel = budgetKeywords.any((k) => _deviceModel!.contains(k));
      if (!p.canHostServer) {
        print("⚠️ [HardwareCheck] Budget device detected ($_deviceBrand $_deviceModel). Preferring direct connection.");
      } else if (isBudgetBrand && !isBudgetModel) {
        print("ℹ️ [HardwareCheck] Mid-range device ($_deviceBrand $_deviceModel). Server hosting enabled with caution.");
      } else {
        print("✅ [HardwareCheck] Device capable of hosting server ($_deviceBrand $_deviceModel).");
      }
    }
    return p.canHostServer;
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

  /// Сбрасывает кэш (для повторной проверки). Не сбрасывает _bleCentralFailureCountByFingerprint.
  void resetCache() {
    _deviceBrand = null;
    _deviceModel = null;
    _deviceSdk = null;
    _cachedProfile = null;
    _docProfile = null;
  }

  /// 🔥 СЛАБОЕ ЖЕЛЕЗО: приоритет BLE над Wi-Fi Direct.
  /// Huawei, Xiaomi и др. зависают на Wi-Fi Direct — BLE стабильнее.
  Future<bool> preferBleOverWifi() async {
    await _ensureDeviceInfo();
    return _cachedProfile!.preferBleOverWifi;
  }

  /// 🔥 Устройства, на которых BLE GATT в роли CENTRAL стабильно таймаутит (connect 20s).
  /// Такие устройства не должны инициировать подключение — только ждать входа (PERIPHERAL).
  /// Tecno→Huawei: Tecno инициирует, Huawei ждёт — не менять.
  Future<bool> preferGattPeripheral() async {
    await _ensureDeviceInfo();
    return _cachedProfile!.preferGattPeripheral;
  }

  /// 🔒 HUAWEI BLE POLICY: True for Huawei/Honor. Used for strict role arbitration:
  /// Central must stop advertising + GATT server before connectGatt; no adv until Central session done.
  Future<bool> isHuaweiOrHonor() async {
    await _ensureDeviceInfo();
    return _cachedProfile!.isHuaweiOrHonor;
  }
}
