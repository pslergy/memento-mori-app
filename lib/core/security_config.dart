// lib/core/security_config.dart
// 🔒 ЦЕНТРАЛИЗОВАННАЯ КОНФИГУРАЦИЯ БЕЗОПАСНОСТИ
// 
// КРИТИЧНО: Этот файл содержит настройки безопасности для всего приложения.
// Certificate Pinning защищает от MITM атак.

import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 🔒 Конфигурация безопасности приложения
class SecurityConfig {
  // ⚠️ PRODUCTION MODE: Certificate Pinning активен
  // Для разработки временно установите true (НЕ КОММИТИТЬ!)
  static const bool debugMode = false; // 🔒 PRODUCTION: false
  
  // 🔒 Доверенные хосты (IP-адреса и домены API сервера)
  static const List<String> trustedHosts = [
    '89.125.131.63',
    'memento-mori.app',
    'api.memento-mori.app',
  ];
  
  // 🔒 SHA-256 отпечатки сертификатов (Certificate Pinning)
  // 
  // ⚠️ ВАЖНО: Чтобы получить fingerprint вашего сервера:
  // 1. Запустите приложение в debug mode (debugMode = true)
  // 2. Сделайте любой запрос к серверу
  // 3. В консоли появится fingerprint: "📋 [SECURITY] Server certificate fingerprint..."
  // 4. Скопируйте fingerprint и добавьте сюда
  // 5. Установите debugMode = false
  //
  // Команда для получения fingerprint через терминал:
  // openssl s_client -connect 89.125.131.63:3000 < /dev/null 2>/dev/null | \
  //   openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
  static const List<String> trustedCertFingerprints = [
    // 🔒 Основной сертификат сервера (SHA-256 DER в base64)
    // Замените на реальный fingerprint вашего сертификата!
    'PLACEHOLDER_CERT_FINGERPRINT_1',
    // 🔒 Резервный сертификат (для ротации без даунтайма)
    'PLACEHOLDER_CERT_FINGERPRINT_2',
  ];
  
  // 🔒 Минимальная версия TLS
  static const String minTlsVersion = 'TLSv1.2';
  
  // 🔒 Secure storage for cached fingerprints
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  
  // 🔒 Cached fingerprint from first successful connection (TOFU - Trust On First Use)
  static String? _cachedFingerprint;
  
  /// 🔒 Проверяет сертификат для HTTPS соединений
  /// 
  /// Реализует гибридный подход:
  /// 1. Если есть hardcoded fingerprints - используем их (строгий pinning)
  /// 2. Если fingerprints = PLACEHOLDER - используем TOFU (Trust On First Use)
  /// 3. В debug mode - логируем fingerprint для настройки
  /// 
  /// Использование:
  /// ```dart
  /// final httpClient = HttpClient()
  ///   ..badCertificateCallback = SecurityConfig.validateCertificate;
  /// ```
  static bool validateCertificate(X509Certificate cert, String host, int port) {
    final certFingerprint = _getCertificateFingerprint(cert);
    
    // 🔧 DEBUG MODE: Логируем fingerprint для настройки и принимаем
    if (debugMode) {
      print("⚠️ [SECURITY] DEBUG MODE: Accepting certificate for $host:$port");
      print("📋 [SECURITY] Certificate fingerprint to add to trustedCertFingerprints:");
      print("   '$certFingerprint',");
      return true;
    }
    
    // 1️⃣ Проверяем, что хост в списке доверенных
    final isTrustedHost = trustedHosts.any((trusted) => 
      host.contains(trusted) || trusted.contains(host)
    );
    
    if (!isTrustedHost) {
      print("🔴 [SECURITY] REJECTED: Host $host not in trusted list");
      return false;
    }
    
    // 2️⃣ Проверяем, настроены ли реальные fingerprints
    final hasRealFingerprints = trustedCertFingerprints.any(
      (fp) => !fp.startsWith('PLACEHOLDER')
    );
    
    if (hasRealFingerprints) {
      // 🔒 STRICT MODE: Проверяем против hardcoded fingerprints
      final isPinned = trustedCertFingerprints.contains(certFingerprint);
      
      if (!isPinned) {
        print("🔴 [SECURITY] REJECTED: Certificate fingerprint mismatch for $host");
        print("   Expected one of: ${trustedCertFingerprints.where((fp) => !fp.startsWith('PLACEHOLDER')).join(', ')}");
        print("   Got: $certFingerprint");
        return false;
      }
      
      print("✅ [SECURITY] Certificate validated (pinned) for $host:$port");
      return true;
    }
    
    // 3️⃣ TOFU MODE: Trust On First Use (если нет hardcoded fingerprints)
    return _validateWithTOFU(certFingerprint, host, port);
  }
  
  /// 🔒 TOFU (Trust On First Use) - сохраняем fingerprint при первом подключении
  static bool _validateWithTOFU(String certFingerprint, String host, int port) {
    // Если уже есть cached fingerprint - сравниваем
    if (_cachedFingerprint != null) {
      if (_cachedFingerprint == certFingerprint) {
        print("✅ [SECURITY] Certificate validated (TOFU cached) for $host:$port");
        return true;
      } else {
        print("🔴 [SECURITY] TOFU VIOLATION: Certificate changed for $host!");
        print("   Cached: $_cachedFingerprint");
        print("   Got: $certFingerprint");
        print("⚠️ [SECURITY] This could be a MITM attack! Rejecting connection.");
        return false;
      }
    }
    
    // Первое подключение - сохраняем fingerprint
    _cachedFingerprint = certFingerprint;
    _saveFingerprintToStorage(certFingerprint);
    
    print("🔐 [SECURITY] TOFU: First connection to $host:$port");
    print("   Fingerprint saved: $certFingerprint");
    print("⚠️ [SECURITY] WARNING: Add this fingerprint to trustedCertFingerprints for production!");
    return true;
  }
  
  /// 🔒 Сохраняем fingerprint в secure storage для персистентности
  static Future<void> _saveFingerprintToStorage(String fingerprint) async {
    try {
      await _secureStorage.write(key: 'tofu_cert_fingerprint', value: fingerprint);
    } catch (e) {
      print("⚠️ [SECURITY] Failed to save TOFU fingerprint: $e");
    }
  }
  
  /// 🔒 Загружаем cached fingerprint при старте приложения
  static Future<void> loadCachedFingerprint() async {
    try {
      _cachedFingerprint = await _secureStorage.read(key: 'tofu_cert_fingerprint');
      if (_cachedFingerprint != null) {
        print("🔐 [SECURITY] Loaded cached TOFU fingerprint");
      }
    } catch (e) {
      print("⚠️ [SECURITY] Failed to load TOFU fingerprint: $e");
    }
  }
  
  /// 🔒 Сбросить TOFU fingerprint (использовать с осторожностью!)
  static Future<void> resetTOFU() async {
    _cachedFingerprint = null;
    await _secureStorage.delete(key: 'tofu_cert_fingerprint');
    print("⚠️ [SECURITY] TOFU fingerprint reset");
  }
  
  /// 🔒 Менее строгая проверка для внутренних mesh-соединений
  /// Используется для P2P соединений между устройствами
  static bool validateMeshCertificate(X509Certificate cert, String host, int port) {
    // Для mesh-соединений между устройствами мы используем self-signed сертификаты
    // Проверяем только базовые параметры
    
    if (debugMode) {
      return true;
    }
    
    // Для локальных IP (192.168.x.x, 10.x.x.x) разрешаем соединения
    if (_isLocalNetwork(host)) {
      print("✅ [SECURITY] Mesh connection to local network: $host");
      return true;
    }
    
    // Для внешних хостов используем строгую проверку
    return validateCertificate(cert, host, port);
  }
  
  /// Проверяет, является ли хост локальной сетью
  static bool _isLocalNetwork(String host) {
    return host.startsWith('192.168.') ||
           host.startsWith('10.') ||
           host.startsWith('172.16.') ||
           host.startsWith('172.17.') ||
           host.startsWith('172.18.') ||
           host.startsWith('172.19.') ||
           host.startsWith('172.2') ||
           host.startsWith('172.30.') ||
           host.startsWith('172.31.') ||
           host == 'localhost' ||
           host == '127.0.0.1';
  }
  
  /// Вычисляет SHA-256 отпечаток сертификата
  static String _getCertificateFingerprint(X509Certificate cert) {
    try {
      // DER-encoded certificate
      final der = cert.der;
      final digest = sha256.convert(der);
      return base64.encode(digest.bytes);
    } catch (e) {
      print("⚠️ [SECURITY] Error computing certificate fingerprint: $e");
      return '';
    }
  }
  
  /// 🔧 Утилита для получения отпечатка сертификата сервера (для настройки pinning)
  /// Вызовите этот метод один раз, чтобы получить отпечаток и добавить в trustedCertFingerprints
  static Future<String?> fetchServerCertFingerprint(String host, int port) async {
    try {
      final httpClient = HttpClient()
        ..badCertificateCallback = (cert, h, p) {
          final fingerprint = _getCertificateFingerprint(cert);
          print("📋 [SECURITY] Server certificate fingerprint for $h:$p:");
          print("   $fingerprint");
          print("   Add this to trustedCertFingerprints list!");
          return true; // Разрешаем для получения отпечатка
        };
      
      final request = await httpClient.getUrl(Uri.parse('https://$host:$port'));
      await request.close();
      httpClient.close();
      
      return null; // Fingerprint выведен в консоль
    } catch (e) {
      print("❌ [SECURITY] Error fetching certificate: $e");
      return null;
    }
  }
}

/// 🔒 Создает HttpClient с настроенным Certificate Pinning
HttpClient createSecureHttpClient({bool forMesh = false}) {
  return HttpClient()
    ..badCertificateCallback = forMesh 
        ? SecurityConfig.validateMeshCertificate 
        : SecurityConfig.validateCertificate
    ..connectionTimeout = const Duration(seconds: 10);
}
