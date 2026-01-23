import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'discovery_context_service.dart';
import 'models/uplink_candidate.dart';
import 'mesh_service.dart';
import 'bluetooth_service.dart';
import 'ultrasonic_service.dart';
import 'locator.dart';

/// Connection Stabilizer - локальный менеджер для стабилизации подключения к BRIDGE
/// 
/// Принцип: "Discovery produces signals. Stabilizer ensures connection."
/// 
/// Этот сервис:
/// - Ловит найденный BRIDGE (по MAC / token / serviceUUID)
/// - Ждёт, пока advertising станет стабильным
/// - Повторяет попытки BLE GATT до успеха, не блокируя основной поток discovery
/// - При неудаче переключается на TCP или Sonar
/// - Работает локально на GHOST (один стабилизатор на активный коннект)
class ConnectionStabilizer {
  static final ConnectionStabilizer _instance = ConnectionStabilizer._internal();
  factory ConnectionStabilizer() => _instance;
  ConnectionStabilizer._internal();
  
  /// Активные стабилизаторы (MAC -> StabilizerTask)
  final Map<String, StabilizerTask> _activeStabilizers = {};
  
  /// Максимальное время ожидания стабилизации (5-10 секунд)
  static const Duration maxStabilizationTime = Duration(seconds: 8);
  
  /// Интервал проверки advertising (200ms)
  static const Duration checkInterval = Duration(milliseconds: 200);
  
  /// Минимальное количество подтверждений advertising для стабилизации
  static const int minConfirmations = 3;
  
  /// Запустить стабилизацию для BRIDGE кандидата
  /// 
  /// Возвращает true, если стабилизация запущена, false если уже активна
  bool startStabilization(UplinkCandidate bridge) {
    if (!bridge.isBridge || !bridge.isValid) {
      print("⏸️ [Stabilizer] Invalid BRIDGE candidate: ${bridge.id}");
      return false;
    }
    
    // Проверяем, не активен ли уже стабилизатор для этого MAC
    if (_activeStabilizers.containsKey(bridge.mac)) {
      final existing = _activeStabilizers[bridge.mac]!;
      if (!existing.isExpired) {
        print("⏸️ [Stabilizer] Stabilization already active for ${bridge.mac}");
        return false;
      } else {
        // Удаляем истёкший стабилизатор
        existing.cancel();
        _activeStabilizers.remove(bridge.mac);
      }
    }
    
    // Создаём новый стабилизатор
    final task = StabilizerTask(bridge);
    _activeStabilizers[bridge.mac] = task;
    
    // Запускаем стабилизацию асинхронно (не блокируя discovery)
    unawaited(_runStabilization(task));
    
    print("✅ [Stabilizer] Started stabilization for BRIDGE: ${bridge.id} (MAC: ${bridge.mac.substring(bridge.mac.length - 8)})");
    return true;
  }
  
  /// Остановить стабилизацию для MAC адреса
  void stopStabilization(String mac) {
    final task = _activeStabilizers.remove(mac);
    task?.cancel();
    print("🛑 [Stabilizer] Stopped stabilization for MAC: ${mac.substring(mac.length - 8)}");
  }
  
  /// Остановить все активные стабилизаторы
  void stopAll() {
    for (final task in _activeStabilizers.values) {
      task.cancel();
    }
    _activeStabilizers.clear();
    print("🛑 [Stabilizer] Stopped all stabilizers");
  }
  
  /// Основной цикл стабилизации
  Future<void> _runStabilization(StabilizerTask task) async {
    final startTime = DateTime.now();
    int confirmationCount = 0;
    String? lastConfirmedToken;
    ScanResult? stableScanResult;
    
    print("🔄 [Stabilizer] Starting stabilization cycle for ${task.bridge.id}");
    
    try {
      // Этап 1: Ожидание стабилизации advertising
      while (DateTime.now().difference(startTime) < maxStabilizationTime) {
        await Future.delayed(checkInterval);
        
        try {
          // Проверяем последние scan results
          final lastScanResults = await FlutterBluePlus.lastScanResults;
          ScanResult? matchingResult;
          
          for (final result in lastScanResults) {
            final resultMac = result.device.remoteId.str;
            if (resultMac == task.bridge.mac) {
              final advName = result.advertisementData.localName ?? "";
              final platformName = result.device.platformName;
              final effectiveName = advName.isEmpty ? platformName : advName;
              final hasService = result.advertisementData.serviceUuids
                  .any((uuid) => uuid.toString().toLowerCase().contains("bf27730d"));
              
              // 🔥 Улучшение: Проверяем manufacturerData как fallback (для пустого localName)
              final mfData = result.advertisementData.manufacturerData[0xFFFF];
              final isBridgeByMfData = mfData != null && 
                  mfData.length >= 2 && 
                  mfData[0] == 0x42 && 
                  mfData[1] == 0x52; // "BR" = BRIDGE
              
              // Проверяем, что advertising активен (через имя, service UUID или manufacturerData)
              final isActive = (effectiveName.startsWith("M_") || hasService || isBridgeByMfData) && 
                              (effectiveName.isNotEmpty || isBridgeByMfData);
              
              if (isActive) {
                matchingResult = result;
                
                // Извлекаем токен из advertising name (если есть)
                String? currentToken;
                if (effectiveName.startsWith("M_") && effectiveName.contains("BRIDGE")) {
                  final parts = effectiveName.split("_");
                  if (parts.length >= 5 && parts[3] == "BRIDGE") {
                    currentToken = parts[4];
                  }
                }
                
                // 🔥 Улучшение: Если имя пустое, но есть manufacturerData - считаем стабильным
                if (effectiveName.isEmpty && isBridgeByMfData) {
                  confirmationCount++;
                  stableScanResult = result;
                  if (confirmationCount >= minConfirmations) {
                    print("✅ [Stabilizer] Advertising stabilized via manufacturerData after ${confirmationCount} confirmations");
                    break;
                  }
                } else if (currentToken != null) {
                  // Проверяем стабильность токена
                  if (lastConfirmedToken == null) {
                    lastConfirmedToken = currentToken;
                    confirmationCount = 1;
                    stableScanResult = result;
                    print("✅ [Stabilizer] First token confirmation: ${currentToken.length > 8 ? currentToken.substring(0, 8) : currentToken}...");
                  } else if (currentToken == lastConfirmedToken) {
                    confirmationCount++;
                    stableScanResult = result; // Обновляем стабильный результат
                    if (confirmationCount >= minConfirmations) {
                      print("✅ [Stabilizer] Advertising stabilized after ${confirmationCount} confirmations");
                      break; // Advertising стабилизирован
                    }
                  } else {
                    // Токен изменился - сбрасываем счётчик
                    final oldTokenPreview = lastConfirmedToken.length > 8 ? lastConfirmedToken.substring(0, 8) : lastConfirmedToken;
                    final newTokenPreview = currentToken.length > 8 ? currentToken.substring(0, 8) : currentToken;
                    print("⚠️ [Stabilizer] Token changed: $oldTokenPreview... -> $newTokenPreview...");
                    lastConfirmedToken = currentToken;
                    confirmationCount = 1;
                    stableScanResult = result;
                  }
                } else if (effectiveName.isNotEmpty) {
                  // Нет токена, но advertising активен (есть имя)
                  confirmationCount++;
                  stableScanResult = result;
                  if (confirmationCount >= minConfirmations) {
                    print("✅ [Stabilizer] Advertising stabilized (no token) after ${confirmationCount} confirmations");
                    break;
                  }
                }
              }
            }
          }
          
          // Если advertising стабилизирован, переходим к подключению
          if (confirmationCount >= minConfirmations && stableScanResult != null) {
            print("🎯 [Stabilizer] Advertising stable, attempting connection...");
            await _attemptConnection(task, stableScanResult!);
            return; // Успешно подключились
          }
          
        } catch (e) {
          // Продолжаем попытки
          if (task.isExpired) {
            print("⏸️ [Stabilizer] Task expired, stopping");
            return;
          }
        }
      }
      
      // Этап 2: Timeout - пробуем TCP fallback
      print("⏱️ [Stabilizer] Stabilization timeout, trying TCP fallback");
      await _attemptTcpFallback(task);
      
    } catch (e) {
      print("❌ [Stabilizer] Error during stabilization: $e");
    } finally {
      // Очищаем стабилизатор
      _activeStabilizers.remove(task.bridge.mac);
      task.markCompleted();
    }
  }
  
  /// Попытка подключения через BLE GATT
  Future<void> _attemptConnection(StabilizerTask task, ScanResult scanResult) async {
    try {
      final meshService = locator<MeshService>();
      final discoveryContext = locator<DiscoveryContextService>();
      
      // Обновляем контекст с актуальным ScanResult
      discoveryContext.updateFromBleScan(scanResult);
      
      // Пытаемся подключиться через каскадный протокол
      print("🔗 [Stabilizer] Attempting BLE GATT connection...");
      await meshService.executeCascadeRelay(scanResult, task.bridge.hops);
      
      print("✅ [Stabilizer] Connection attempt completed");
    } catch (e) {
      print("❌ [Stabilizer] BLE GATT connection failed: $e");
      // Fallback на TCP
      await _attemptTcpFallback(task);
    }
  }
  
  /// Попытка подключения через TCP fallback
  Future<void> _attemptTcpFallback(StabilizerTask task) async {
    try {
      final bridge = task.bridge;
      
      if (bridge.ip == null || bridge.port == null || bridge.bridgeToken == null) {
        print("⏸️ [Stabilizer] TCP info not available, trying Sonar fallback");
        await _attemptSonarFallback(task);
        return;
      }
      
      print("🌐 [Stabilizer] Attempting TCP connection: ${bridge.ip}:${bridge.port}");
      final meshService = locator<MeshService>();
      
      // Используем _handleMagnetWave для TCP подключения
      await meshService.handleMagnetWave(
        bridge.bridgeToken!,
        bridge.port!,
        DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch,
      );
      
      print("✅ [Stabilizer] TCP connection attempt completed");
    } catch (e) {
      print("❌ [Stabilizer] TCP fallback failed: $e");
      // Последний fallback - Sonar
      await _attemptSonarFallback(task);
    }
  }
  
  /// Попытка через Sonar fallback
  Future<void> _attemptSonarFallback(StabilizerTask task) async {
    try {
      print("🔊 [Stabilizer] Attempting Sonar fallback");
      final ultrasonicService = locator<UltrasonicService>();
      await ultrasonicService.transmitFrame("REQ:${task.bridge.id}");
      print("✅ [Stabilizer] Sonar fallback completed");
    } catch (e) {
      print("❌ [Stabilizer] Sonar fallback failed: $e");
    }
  }
  
  /// Получить статистику активных стабилизаторов
  Map<String, dynamic> getStats() {
    return {
      'active': _activeStabilizers.length,
      'stabilizers': _activeStabilizers.keys.map((mac) => mac.substring(mac.length - 8)).toList(),
    };
  }
}

/// Задача стабилизации для конкретного BRIDGE
class StabilizerTask {
  final UplinkCandidate bridge;
  final DateTime createdAt;
  bool _isCancelled = false;
  bool _isCompleted = false;
  
  StabilizerTask(this.bridge) : createdAt = DateTime.now();
  
  bool get isExpired => DateTime.now().difference(createdAt) > ConnectionStabilizer.maxStabilizationTime;
  bool get isCancelled => _isCancelled;
  bool get isCompleted => _isCompleted;
  
  void cancel() {
    _isCancelled = true;
  }
  
  void markCompleted() {
    _isCompleted = true;
  }
}
