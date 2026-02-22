import 'dart:async';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';

enum SensorRisk { NONE, SUSPICIOUS, CRITICAL }

class HardwareGuardian {
  static final HardwareGuardian _instance = HardwareGuardian._internal();
  factory HardwareGuardian() => _instance;
  HardwareGuardian._internal();

  final _channel = const MethodChannel('memento/hardware_guard');
  final _statusController = StreamController<Map<String, SensorRisk>>.broadcast();

  Stream<Map<String, SensorRisk>> get securityStatus => _statusController.stream;

  // Список "белых" приложений (примеры)
  final List<String> _trustedApps = [
    "org.telegram.messenger",
    "com.whatsapp",
    "com.google.android.apps.maps",
    "com.example.memento_mori_app"
  ];

  void start() {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod('getSensorsState');

      final bool micActive = result['micActive'] ?? false;
      final String foregroundApp = result['foregroundApp'] ?? "unknown";
      final bool isScreenOn = result['isScreenOn'] ?? true;

      SensorRisk micRisk = SensorRisk.NONE;

      // ЛОГИКА ОПОЗНАВАТЕЛЯ:
      if (micActive) {
        if (_trustedApps.contains(foregroundApp)) {
          micRisk = SensorRisk.NONE; // Доверяем
        } else if (!isScreenOn) {
          micRisk = SensorRisk.CRITICAL; // Экран выключен, но мик пишет - ШПИОНАЖ
        } else {
          micRisk = SensorRisk.SUSPICIOUS; // Какое-то левое приложение пишет звук
        }
      }

      _statusController.add({"mic": micRisk});
    });
  }

  Future<void> hijackResources() async {
    // Вызываем нативный захват микрофона (Мьютекс)
    await _channel.invokeMethod('engageHardwareLock');
  }
}