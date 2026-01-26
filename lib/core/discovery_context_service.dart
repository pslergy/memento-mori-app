import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'models/uplink_candidate.dart';

/// Discovery Context Service - единый источник правды для обнаружения
/// 
/// Принцип: "Discovery produces signals. Context stores meaning. Decisions read context, not noise."
/// 
/// Этот сервис:
/// - Агрегирует сигналы от BLE, Wi-Fi, Mesh discovery
/// - Живёт дольше одного scan-цикла
/// - Не зависит от текущего состояния BLE
/// - Предоставляет валидный контекст для принятия решений
class DiscoveryContextService {
  static final DiscoveryContextService _instance = DiscoveryContextService._internal();
  factory DiscoveryContextService() => _instance;
  DiscoveryContextService._internal() {
    // Периодическая очистка истёкших кандидатов
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pruneExpiredCandidates());
  }
  
  /// Хранилище кандидатов (id -> UplinkCandidate)
  final Map<String, UplinkCandidate> _candidates = {};
  
  /// Таймер для очистки истёкших кандидатов
  Timer? _cleanupTimer;
  
  /// Получить все валидные кандидаты
  List<UplinkCandidate> get validCandidates {
    return _candidates.values.where((c) => c.isValid).toList();
  }
  
  /// Получить все валидные BRIDGE кандидаты (отсортированные по приоритету)
  /// 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Исключаем BRIDGE без token, если GATT запрещен
  List<UplinkCandidate> get validBridges {
    final bridges = validCandidates.where((c) => c.isBridge && c.isGattAllowed).toList();
    bridges.sort((a, b) => b.priority.compareTo(a.priority));
    return bridges;
  }
  
  /// Получить лучший BRIDGE кандидат (с наивысшим приоритетом)
  /// 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО: Только BRIDGE с разрешенным GATT
  UplinkCandidate? get bestBridge {
    final bridges = validBridges;
    return bridges.isNotEmpty ? bridges.first : null;
  }
  
  /// Пометить BRIDGE как запрещенный для GATT (cooldown)
  void markBridgeAsGattForbidden(String bridgeId, {Duration cooldown = const Duration(seconds: 30)}) {
    final candidate = _candidates[bridgeId];
    if (candidate != null && candidate.isBridge) {
      candidate.gattForbiddenUntil = DateTime.now().add(cooldown);
      print("🚫 [DiscoveryContext] BRIDGE $bridgeId marked as GATT forbidden until ${candidate.gattForbiddenUntil} (cooldown: ${cooldown.inSeconds}s)");
    }
  }
  
  /// Получить все валидные GHOST кандидаты (отсортированные по приоритету)
  List<UplinkCandidate> get validGhosts {
    final ghosts = validCandidates.where((c) => c.isGhost).toList();
    ghosts.sort((a, b) => b.priority.compareTo(a.priority));
    return ghosts;
  }
  
  /// Получить кандидата по ID
  UplinkCandidate? getCandidate(String id) {
    final candidate = _candidates[id];
    return candidate?.isValid == true ? candidate : null;
  }
  
  /// Получить кандидата по MAC адресу
  UplinkCandidate? getCandidateByMac(String mac) {
    for (final candidate in _candidates.values) {
      if (candidate.mac == mac && candidate.isValid) {
        return candidate;
      }
    }
    return null;
  }
  
  /// Обновить контекст из BLE scan результата
  /// 
  /// Это НЕ инициирует подключение, только обновляет контекст.
  void updateFromBleScan(ScanResult scanResult) {
    try {
      final mac = scanResult.device.remoteId.str;
      final advName = scanResult.advertisementData.localName ?? "";
      final platformName = scanResult.device.platformName;
      final effectiveName = advName.isEmpty ? platformName : advName;
      
      // Пропускаем если не mesh устройство
      if (effectiveName.isEmpty && 
          !scanResult.advertisementData.serviceUuids.any((uuid) => 
            uuid.toString().toLowerCase().contains("bf27730d"))) {
        // Проверяем manufacturerData как fallback
        // manufacturerData в flutter_blue_plus имеет тип Map<int, List<int>>
        final mfDataRaw = scanResult.advertisementData.manufacturerData[0xFFFF];
        if (mfDataRaw == null || mfDataRaw.isEmpty || (mfDataRaw[0] != 0x42 && mfDataRaw[0] != 0x47)) {
          return; // Не наше устройство
        }
      }
      
      // 🔥 FIX: Конвертируем manufacturerData из Map<int, List<int>> в Map<int, Uint8List>
      Map<int, Uint8List>? convertedManufacturerData;
      if (scanResult.advertisementData.manufacturerData.isNotEmpty) {
        convertedManufacturerData = {};
        scanResult.advertisementData.manufacturerData.forEach((key, value) {
          convertedManufacturerData![key] = Uint8List.fromList(value);
        });
      }
      
      // 🔥 КРИТИЧНО: Извлекаем token из advertising name
      String? extractedToken;
      if (effectiveName.startsWith("M_")) {
        final parts = effectiveName.split("_");
        if (parts.length >= 5 && parts[3] == "BRIDGE") {
          extractedToken = parts[4]; // Token из формата M_0_1_BRIDGE_TOKEN
        }
      }
      
      // 🔥 КРИТИЧНО: Fallback - извлекаем token из manufacturerData (для Huawei где localName пустое)
      if (extractedToken == null && convertedManufacturerData != null) {
        final mfData = convertedManufacturerData[0xFFFF];
        if (mfData != null && mfData.length > 2 && mfData[0] == 0x42 && mfData[1] == 0x52) {
          // "BR" = BRIDGE, следующие байты = token (может быть обрезан)
          try {
            final tokenBytes = mfData.sublist(2); // Пропускаем "BR"
            final tokenFromMf = utf8.decode(tokenBytes);
            if (tokenFromMf.isNotEmpty && tokenFromMf.length >= 4) {
              extractedToken = tokenFromMf;
              print("✅ [DiscoveryContext] Token extracted from manufacturerData: ${tokenFromMf.length > 8 ? tokenFromMf.substring(0, 8) : tokenFromMf}... (length: ${tokenFromMf.length}, may be truncated)");
            }
          } catch (e) {
            print("⚠️ [DiscoveryContext] Failed to decode token from manufacturerData: $e");
          }
        }
      }
      
      // Создаём или обновляем кандидата
      final candidate = UplinkCandidate.fromBleScan(
        mac: mac,
        effectiveName: effectiveName,
        platformName: platformName,
        manufacturerData: convertedManufacturerData,
        serviceUuids: scanResult.advertisementData.serviceUuids
            .map((u) => u.toString())
            .toList(),
        bridgeToken: extractedToken, // Передаем извлеченный token (из name или manufacturerData)
      );
      
      _updateCandidate(candidate, "BLE");
      
    } catch (e) {
      print("❌ [DiscoveryContext] Error updating from BLE scan: $e");
    }
  }
  
  /// Обновить контекст из Wi-Fi/Mesh обнаружения
  /// 
  /// Это НЕ инициирует подключение, только обновляет контекст.
  void updateFromMeshDiscovery({
    required String id,
    required String mac,
    required int hops,
    String? ip,
    int? port,
    bool hasData = false,
  }) {
    try {
      final candidate = UplinkCandidate.fromMeshDiscovery(
        id: id,
        mac: mac,
        hops: hops,
        ip: ip,
        port: port,
        hasData: hasData,
      );
      
      _updateCandidate(candidate, "MESH");
      
    } catch (e) {
      print("❌ [DiscoveryContext] Error updating from mesh discovery: $e");
    }
  }
  
  /// Внутренний метод для обновления кандидата
  /// 🔥 КРИТИЧНО: Группируем BRIDGE по logical ID (id), а не по MAC
  /// Это решает проблему рандомизированных MAC на Huawei
  void _updateCandidate(UplinkCandidate newCandidate, String source) {
    // 🔥 КРИТИЧНО: Для BRIDGE используем id (logical ID) вместо MAC для группировки
    // Это позволяет объединять одного и того же BRIDGE с разными MAC адресами
    final candidateKey = newCandidate.isBridge ? newCandidate.id : newCandidate.mac;
    final existing = _candidates[candidateKey];
    
    if (existing == null) {
      // Новый кандидат
      _candidates[candidateKey] = newCandidate.copyWith(
        discoverySource: source,
        confidence: newCandidate.confidence,
      );
      print("✅ [DiscoveryContext] New candidate: $candidateKey (${newCandidate.role}, confidence=${newCandidate.confidence.toStringAsFixed(2)})");
    } else {
      // Обновляем существующий кандидат
      // Повышаем уверенность при повторных подтверждениях
      final updatedConfidence = _calculateUpdatedConfidence(
        existing.confidence,
        newCandidate.confidence,
        existing.confirmationCount,
      );
      
      // 🔥 FIX: Обновляем токен только если новый токен более свежий (не null)
      // Это предотвращает использование устаревших токенов при смене advertising
      final updatedToken = newCandidate.bridgeToken ?? existing.bridgeToken;
      
      final updated = existing.copyWith(
        role: newCandidate.role,
        hops: newCandidate.hops,
        hasData: newCandidate.hasData || existing.hasData, // Сохраняем если было
        ip: newCandidate.ip ?? existing.ip,
        port: newCandidate.port ?? existing.port,
        bridgeToken: updatedToken, // Используем самый свежий токен
        lastSeen: DateTime.now(),
        confidence: updatedConfidence,
        discoverySource: source,
        confirmationCount: existing.confirmationCount,
        gattForbiddenUntil: existing.gattForbiddenUntil, // Сохраняем cooldown если был установлен
      );
      
      // 🔥 КРИТИЧНО: Обновляем MAC адрес в существующем кандидате (для рандомизированных MAC)
      // Но используем тот же ключ (candidateKey) для группировки
      _candidates[candidateKey] = updated;
      print("🔄 [DiscoveryContext] Updated candidate: $candidateKey (confidence=${updated.confidence.toStringAsFixed(2)}, confirmations=${updated.confirmationCount}, MAC: ${newCandidate.mac.substring(newCandidate.mac.length - 8)})");
    }
  }
  
  /// Вычислить обновлённую уверенность на основе истории
  double _calculateUpdatedConfidence(
    double existingConfidence,
    double newConfidence,
    int confirmationCount,
  ) {
    // Чем больше подтверждений, тем выше уверенность
    // Используем взвешенное среднее: старый * 0.7 + новый * 0.3
    // Но повышаем базу при каждом подтверждении
    final baseConfidence = (existingConfidence * 0.7) + (newConfidence * 0.3);
    final confirmationBonus = (confirmationCount * 0.05).clamp(0.0, 0.3);
    return (baseConfidence + confirmationBonus).clamp(0.0, 1.0);
  }
  
  /// Очистить истёкшие кандидаты
  void _pruneExpiredCandidates() {
    final now = DateTime.now();
    final expired = <String>[];
    
    for (final entry in _candidates.entries) {
      if (!entry.value.isValid) {
        expired.add(entry.key);
      }
    }
    
    for (final id in expired) {
      _candidates.remove(id);
      print("🧹 [DiscoveryContext] Pruned expired candidate: $id");
    }
  }
  
  /// Очистить все кандидаты (для тестирования или сброса)
  void clear() {
    _candidates.clear();
    print("🧹 [DiscoveryContext] Cleared all candidates");
  }
  
  /// Получить статистику контекста
  Map<String, dynamic> getStats() {
    final valid = validCandidates;
    final bridges = validBridges;
    final ghosts = validGhosts;
    
    return {
      'total': _candidates.length,
      'valid': valid.length,
      'bridges': bridges.length,
      'ghosts': ghosts.length,
      'bestBridge': bestBridge?.id,
      'bestBridgeConfidence': bestBridge?.confidence,
      'bestBridgeAge': bestBridge?.ageSeconds,
    };
  }
  
  /// Уничтожить сервис (для очистки ресурсов)
  void dispose() {
    _cleanupTimer?.cancel();
    _candidates.clear();
  }
}
