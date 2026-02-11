import 'dart:typed_data';
import 'dart:convert';

/// Uplink Candidate - устойчивый контекст обнаружения
/// 
/// Это не "устройство", не "соединение", а кандидат на uplink.
/// Живёт дольше одного scan-цикла и не зависит от текущего состояния BLE.
class UplinkCandidate {
  /// Уникальный идентификатор кандидата (MAC адрес или ID)
  final String id;
  
  /// MAC адрес устройства (меняется при BLE rotation; для подключения брать из свежего scan)
  final String mac;
  
  /// Стабильный UUID устройства (8-byte hash в hex из manufacturerData); для подключения по UUID, не по MAC
  final String? deviceUuid;
  
  /// Роль устройства (BRIDGE или GHOST)
  final String role; // "BRIDGE" или "GHOST"
  
  /// Количество hops до интернета (0 = BRIDGE, >0 = GHOST)
  final int hops;
  
  /// Есть ли данные для передачи (queue pressure)
  final bool hasData;
  
  /// IP адрес (если известен, для TCP подключения)
  final String? ip;
  
  /// Порт (если известен, для TCP подключения)
  final int? port;
  
  /// Зашифрованный токен BRIDGE (если известен)
  final String? bridgeToken;

  /// Wi-Fi Direct passphrase (из manufacturerData BRIDGE, для connect)
  final String? wifiDirectPassphrase;

  /// Wi-Fi Direct network name / SSID (из manufacturerData BRIDGE)
  final String? wifiDirectNetworkName;
  
  /// Время последнего подтверждения (когда кандидат был обнаружен)
  final DateTime lastSeen;
  
  /// Время создания кандидата
  final DateTime createdAt;
  
  /// Уровень доверия (0.0 - 1.0)
  /// Основан на:
  /// - Сигнале (BLE, Wi-Fi, Mesh)
  /// - Роли (BRIDGE > GHOST)
  /// - Истории (сколько раз подтверждён)
  /// - Времени с последнего подтверждения
  double confidence;
  
  /// Источники обнаружения (BLE, Wi-Fi, Mesh)
  final Set<String> discoverySources;
  
  /// Количество подтверждений (сколько раз был обнаружен)
  int confirmationCount;
  
  /// TTL (Time To Live) - срок жизни кандидата в секундах
  static const int defaultTtl = 60; // 1 минута по умолчанию
  final int ttlSeconds;
  
  /// 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: BRIDGE без token = GATT запрещен
  /// Время до которого GATT подключение к этому BRIDGE запрещено
  DateTime? gattForbiddenUntil;
  
  /// Проверка, запрещен ли GATT для этого кандидата
  bool get isGattForbidden {
    if (!isBridge || bridgeToken != null) return false;
    if (gattForbiddenUntil == null) return false;
    return DateTime.now().isBefore(gattForbiddenUntil!);
  }
  
  /// Проверка, разрешен ли GATT для этого кандидата
  bool get isGattAllowed {
    if (!isBridge) return true; // GHOST всегда разрешен
    if (bridgeToken != null) return true; // BRIDGE с token разрешен
    return !isGattForbidden; // BRIDGE без token запрещен если в cooldown
  }
  
  /// Приоритет (выше = важнее)
  /// BRIDGE > RELAY > GHOST. Внутри роли: выше confidence = выше приоритет.
  int get priority {
    if (role == "BRIDGE") {
      return (1000 + (confidence * 100)).toInt(); // BRIDGE: 1000-1100
    }
    if (role == "RELAY") {
      return (500 + (confidence * 100)).toInt(); // RELAY: 500-600
    }
    return (confidence * 100).toInt(); // GHOST: 0-100
  }
  
  /// Проверка, валиден ли кандидат (не истёк ли TTL)
  bool get isValid {
    final now = DateTime.now();
    final age = now.difference(lastSeen).inSeconds;
    return age < ttlSeconds;
  }
  
  /// Проверка, является ли кандидат BRIDGE
  bool get isBridge => role == "BRIDGE" || hops == 0;
  
  /// Проверка, является ли кандидат RELAY (призрак-релеятор с GATT)
  bool get isRelay => role == "RELAY";
  
  /// Проверка, является ли кандидат GHOST (не BRIDGE и не RELAY)
  bool get isGhost => role == "GHOST" || (hops > 0 && role != "RELAY");
  
  /// Возраст кандидата в секундах
  int get ageSeconds => DateTime.now().difference(lastSeen).inSeconds;
  
  /// Строковое представление для логирования
  @override
  String toString() {
    return "UplinkCandidate(id=$id, role=$role, hops=$hops, confidence=${confidence.toStringAsFixed(2)}, "
           "sources=${discoverySources.join(',')}, confirmations=$confirmationCount, age=${ageSeconds}s)";
  }
  
  UplinkCandidate({
    required this.id,
    required this.mac,
    this.deviceUuid,
    required this.role,
    required this.hops,
    this.hasData = false,
    this.ip,
    this.port,
    this.bridgeToken,
    this.wifiDirectPassphrase,
    this.wifiDirectNetworkName,
    DateTime? lastSeen,
    DateTime? createdAt,
    this.confidence = 0.5,
    Set<String>? discoverySources,
    this.confirmationCount = 1,
    this.ttlSeconds = defaultTtl,
    this.gattForbiddenUntil,
  }) : lastSeen = lastSeen ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now(),
       discoverySources = discoverySources ?? <String>{};
  
  /// Обновить кандидата новыми данными обнаружения
  UplinkCandidate copyWith({
    String? mac,
    String? role,
    int? hops,
    bool? hasData,
    String? ip,
    int? port,
    String? bridgeToken,
    String? wifiDirectPassphrase,
    String? wifiDirectNetworkName,
    DateTime? lastSeen,
    double? confidence,
    String? discoverySource,
    int? confirmationCount,
    int? ttlSeconds,
    DateTime? gattForbiddenUntil,
  }) {
    // Создаем новый Set с источниками обнаружения
    final Set<String> newSources;
    if (discoverySource != null) {
      newSources = Set<String>.from(discoverySources);
      newSources.add(discoverySource);
    } else {
      newSources = discoverySources;
    }
    
    final newConfidence = confidence ?? this.confidence;
    final newConfirmationCount = confirmationCount != null 
        ? confirmationCount 
        : (this.confirmationCount + 1);
    
    return UplinkCandidate(
      id: id,
      mac: mac ?? this.mac,
      deviceUuid: deviceUuid,
      role: role ?? this.role,
      hops: hops ?? this.hops,
      hasData: hasData ?? this.hasData,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      bridgeToken: bridgeToken ?? this.bridgeToken,
      wifiDirectPassphrase: wifiDirectPassphrase ?? this.wifiDirectPassphrase,
      wifiDirectNetworkName: wifiDirectNetworkName ?? this.wifiDirectNetworkName,
      lastSeen: lastSeen ?? DateTime.now(),
      createdAt: createdAt,
      confidence: newConfidence,
      discoverySources: newSources,
      confirmationCount: newConfirmationCount,
      gattForbiddenUntil: gattForbiddenUntil ?? this.gattForbiddenUntil,
      ttlSeconds: ttlSeconds ?? this.ttlSeconds,
    );
  }
  
  /// Создать кандидата из BLE scan результата
  factory UplinkCandidate.fromBleScan({
    required String mac,
    required String effectiveName,
    String? platformName,
    Map<int, Uint8List>? manufacturerData,
    List<String>? serviceUuids,
    String? ip,
    int? port,
    String? bridgeToken,
    String? wifiDirectPassphrase,
    String? wifiDirectNetworkName,
  }) {
    String role = "GHOST";
    int hops = 99;
    bool hasData = false;
    String peerId = mac.length >= 4 ? mac.substring(mac.length - 4) : mac;
    double confidence = 0.3; // Низкая уверенность для BLE (может быть пустое имя)
    
    // 🔥 КРИТИЧНО: Извлекаем token из advertising name
    String? extractedToken;
    
    // Парсинг тактического имени
    if (effectiveName.startsWith("M_")) {
      final parts = effectiveName.split("_");
      if (parts.length >= 4) {
        hops = int.tryParse(parts[1]) ?? 99;
        hasData = parts[2] == "1";
        peerId = parts[3];
        
        // 🔥 КРИТИЧНО: Извлекаем token из формата M_0_1_BRIDGE_TOKEN
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          extractedToken = parts[4];
          bridgeToken = extractedToken; // Сохраняем token
        }
        
        if (hops == 0) {
          role = "BRIDGE";
          confidence = extractedToken != null ? 0.9 : 0.6; // Высокая уверенность если есть token
        } else if (parts.length >= 4 && parts[3] == "RELAY") {
          role = "RELAY";
          peerId = parts.length >= 5 ? parts[4] : "RL";
          confidence = 0.6; // Призрак-релеятор (принимает GATT)
        } else {
          role = "GHOST";
          confidence = 0.5;
        }
      }
    }
    
    // 🔥 КРИТИЧНО: Проверка manufacturerData (fallback если имя пустое)
    // Для рандомизированных MAC на Huawei используем manufacturerData для определения BRIDGE
    String? logicalId;
    String? parsedWifiPassphrase;
    String? parsedWifiNetworkName;
    if (effectiveName.isEmpty && manufacturerData != null) {
      final mfData = manufacturerData[0xFFFF];
      if (mfData != null && mfData.length >= 2) {
        if (mfData[0] == 0x42 && mfData[1] == 0x52) {
          // "BR" = BRIDGE
          role = "BRIDGE";
          hops = 0;
          
          // 🔥 КРИТИЧНО: Извлекаем token и passphrase из manufacturerData
          // Формат: [0x42, 0x52, ...token, 0x7C, ...passphrase(8)] или [0x42, 0x52, ...token]
          if (mfData.length > 2) {
            int tokenEnd = mfData.indexOf(0x7C, 2); // 0x7C = разделитель token|passphrase
            final tokenBytes = tokenEnd > 2 ? mfData.sublist(2, tokenEnd) : mfData.sublist(2);
            if (tokenEnd > 2 && mfData.length >= tokenEnd + 1 + 8) {
              try {
                final passphraseFromMf = utf8.decode(mfData.sublist(tokenEnd + 1, tokenEnd + 9)).trim();
                if (passphraseFromMf.isNotEmpty) parsedWifiPassphrase = passphraseFromMf;
              } catch (_) {}
            }
            try {
              // Декодируем token как UTF-8
              final extractedTokenFromMf = utf8.decode(tokenBytes);
              print("🔍 [UplinkCandidate] Decoded manufacturerData: ${extractedTokenFromMf.length} chars, raw: ${extractedTokenFromMf}");
              
              // 🔥 КРИТИЧНО: Токен в manufacturerData обрезан (максимум 18 байт)
              // Это префикс полного токена, но его достаточно для идентификации BRIDGE
              if (extractedTokenFromMf.isNotEmpty && extractedTokenFromMf.length >= 4) {
                extractedToken = extractedTokenFromMf;
                bridgeToken = extractedTokenFromMf; // Сохраняем обрезанный токен из manufacturerData
                print("✅ [UplinkCandidate] Token prefix extracted from manufacturerData: ${extractedTokenFromMf.length > 8 ? extractedTokenFromMf.substring(0, 8) : extractedTokenFromMf}... (length: ${extractedTokenFromMf.length}, note: may be truncated)");
                confidence = 0.85; // Высокая уверенность если есть token (даже обрезанный)
              } else {
                // Если token слишком короткий, используем как logical ID
                logicalId = tokenBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
                peerId = logicalId; // Используем logical ID вместо MAC
                confidence = 0.6; // Средняя уверенность для manufacturerData без token
                print("⚠️ [UplinkCandidate] Token too short (${extractedTokenFromMf.length} chars), using as logical ID");
              }
            } catch (e) {
              // Если не удалось декодировать как UTF-8, используем как logical ID
              logicalId = tokenBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
              peerId = logicalId;
              confidence = 0.6;
              print("⚠️ [UplinkCandidate] Failed to decode token from manufacturerData: $e");
            }
          } else {
            confidence = 0.6; // Средняя уверенность для manufacturerData без token
            print("⚠️ [UplinkCandidate] manufacturerData too short (${mfData.length} bytes), no token");
          }
        } else if (mfData[0] == 0x52 && mfData[1] == 0x4C) {
          // "RL" = RELAY (призрак-релеятор с GATT)
          role = "RELAY";
          hops = 255;
          confidence = 0.5;
        } else if (mfData[0] == 0x47 && mfData[1] == 0x48) {
          // "GH" = GHOST
          role = "GHOST";
          hops = 99;
          confidence = 0.4;
        }
      }
    }
    
    // 🔥 WI-FI DIRECT: Парсим passphrase из manufacturerData для BRIDGE (когда effectiveName не пустое)
    if (role == "BRIDGE" && parsedWifiPassphrase == null && manufacturerData != null) {
      final mfData = manufacturerData[0xFFFF];
      if (mfData != null && mfData.length >= 12) {
        final sepIdx = mfData.indexOf(0x7C, 2);
        if (sepIdx > 2 && mfData.length >= sepIdx + 9) {
          try {
            final p = utf8.decode(mfData.sublist(sepIdx + 1, sepIdx + 9)).trim();
            if (p.isNotEmpty) parsedWifiPassphrase = p;
          } catch (_) {}
        }
      }
    }

    // 🔥 Device UUID: из manufacturerData GH/RL (bytes 2..10 = 8 bytes hash) — стабильный ID при ротации MAC
    String? deviceUuidHex;
    if (manufacturerData != null) {
      final mf = manufacturerData[0xFFFF];
      if (mf != null && mf.length >= 10 &&
          ((mf[0] == 0x47 && mf[1] == 0x48) || (mf[0] == 0x52 && mf[1] == 0x4C))) {
        deviceUuidHex = mf.sublist(2, 10).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
    }

    // 🔥 КРИТИЧНО: Используем logical ID вместо MAC для идентификации BRIDGE; для GHOST — deviceUuid если есть
    final candidateId = deviceUuidHex ?? logicalId ?? peerId;

    // Если есть service UUID - повышаем уверенность
    if (serviceUuids != null && serviceUuids.isNotEmpty) {
      confidence += 0.1;
    }

    return UplinkCandidate(
      id: candidateId,
      mac: mac,
      deviceUuid: deviceUuidHex,
      role: role,
      hops: hops,
      hasData: hasData,
      ip: ip,
      port: port,
      bridgeToken: bridgeToken ?? extractedToken,
      wifiDirectPassphrase: wifiDirectPassphrase ?? parsedWifiPassphrase,
      wifiDirectNetworkName: wifiDirectNetworkName ?? parsedWifiNetworkName,
      confidence: confidence.clamp(0.0, 1.0),
      discoverySources: {"BLE"},
      ttlSeconds: role == "BRIDGE" ? 120 : 60,
    );
  }
  
  /// Создать кандидата из Wi-Fi/Mesh обнаружения
  factory UplinkCandidate.fromMeshDiscovery({
    required String id,
    required String mac,
    required int hops,
    String? ip,
    int? port,
    bool hasData = false,
  }) {
    return UplinkCandidate(
      id: id,
      mac: mac,
      role: hops == 0 ? "BRIDGE" : "GHOST",
      hops: hops,
      hasData: hasData,
      ip: ip,
      port: port,
      confidence: 0.7, // Высокая уверенность для Wi-Fi/Mesh
      discoverySources: {"MESH"},
      ttlSeconds: hops == 0 ? 120 : 60,
    );
  }
}
