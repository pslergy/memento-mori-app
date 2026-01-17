import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import 'locator.dart';
import 'mesh_service.dart';

enum BleAdvertiseState {
  idle,
  starting,
  advertising,
  connecting,
  connected,
  stopping,
}

class BluetoothMeshService {
  final String SERVICE_UUID = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
  final String CHAR_UUID    = "c22d1e32-0310-4062-812e-89025078da9c";

  final Queue<_BtTask> _taskQueue = Queue();
  final Set<String> _pendingDevices = {};
  bool _isProcessingQueue = false;

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  BleAdvertiseState _advState = BleAdvertiseState.idle;
  String? _cachedModel;

  BleAdvertiseState get state => _advState;

  // ======================================================
  // ⚡ AUTO-LINK LOGIC
  // ======================================================

  Future<void> sendMessage(BluetoothDevice device, String message) async {
    final id = device.remoteId.str;
    if (_pendingDevices.contains(id)) return;

    _pendingDevices.add(id);
    _taskQueue.add(_BtTask(device, message));
    _processQueue();
  }

  /// Прямое подключение для обмена RoutingPulse (4 байта)
  Future<void> quickLinkAndPing(BluetoothDevice device, Uint8List pulse) async {
    if (_advState == BleAdvertiseState.connecting) return;
    _advState = BleAdvertiseState.connecting;
    _log("⚡ Auto-Link triggered for ${device.remoteId}");

    try {
      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      if (Platform.isAndroid) await device.requestMtu(247);

      final services = await device.discoverServices();
      final targetService = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      final targetChar = targetService.characteristics.firstWhere((c) => c.uuid.toString() == CHAR_UUID);

      await targetChar.write(pulse, withoutResponse: true);
      _log("🛰️ Tactical pulse delivered to ${device.remoteId}");
    } catch (e) {
      _log("⚠️ QuickLink failed: $e");
    } finally {
      try { await device.disconnect(); } catch (_) {}
      _advState = BleAdvertiseState.idle;
    }
  }


  // ======================================================
  // 📡 PERIPHERAL MODE (Advertising)
  // ======================================================

  Future<void> startAdvertising(String myName) async {
    if (_advState != BleAdvertiseState.idle) return;
    _advState = BleAdvertiseState.starting;

    try {
      // ПРИНУДИТЕЛЬНО СБРАСЫВАЕМ старое вещание перед стартом
      await _blePeripheral.stop();
      await Future.delayed(const Duration(milliseconds: 200));

      final data = AdvertiseData(
        serviceUuid: SERVICE_UUID,
        localName: myName,
        includeDeviceName: false, // 🔥 ВАЖНО: Ставим FALSE. Это сэкономит 20+ байт.

      );

      await _blePeripheral.start(advertiseData: data);
      _advState = BleAdvertiseState.advertising;
      _log("📡 FSM → ADVERTISING ACTIVE");
    } catch (e) {
      _log("❌ BLE Start Error (Status 1 Fix): $e");
      _advState = BleAdvertiseState.idle;
    }
  }

  Future<void> stopAdvertising() async {
    if (_advState != BleAdvertiseState.advertising) return;
    _advState = BleAdvertiseState.stopping;
    try {
      await _blePeripheral.stop();
    } finally {
      _advState = BleAdvertiseState.idle;
      _log("💤 FSM → IDLE");
    }
  }

  // ======================================================
  // 🧠 QUEUE & RESILIENCE
  // ======================================================

  Future<void> _processQueue() async {
    if (_isProcessingQueue || _taskQueue.isEmpty) return;
    _isProcessingQueue = true;

    while (_taskQueue.isNotEmpty) {
      final task = _taskQueue.removeFirst();
      _pendingDevices.remove(task.device.remoteId.str);
      await _sendWithDynamicRetries(task.device, task.message);
      await Future.delayed(const Duration(milliseconds: 800));
    }
    _isProcessingQueue = false;
  }

  // Внутри BluetoothMeshService.dart -> _sendWithDynamicRetries

  // Внутри BluetoothMeshService.dart

  // Внутри BluetoothMeshService

  Future<void> _sendWithDynamicRetries(BluetoothDevice device, String message) async {
    _log("🚀 [PREDATOR] Locking radio for GATT ATTACK...");

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        // 🔥 ШАГ 1: Ставим статус "CONNECTING" до любых await
        _advState = BleAdvertiseState.connecting;

        // 🔥 ШАГ 2: УБИВАЕМ СКАН И ЖДЕМ (Android HAL Reset)
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(seconds: 3)); // Даем чипу 3 секунды "тишины"

        _log("🔗 GATT Attempt $attempt/3...");

        await device.connect(
          timeout: const Duration(seconds: 20),
          autoConnect: false,
        );

        _log("✅ [CONNECTED] Radio link stable. Offloading data...");

        // ЗАПРОС ПРИОРИТЕТА
        if (Platform.isAndroid) {
          await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
          await Future.delayed(const Duration(milliseconds: 1000));
        }

        final services = await device.discoverServices();
        final s = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
        final c = s.characteristics.firstWhere((c) => c.uuid.toString() == CHAR_UUID);

        await c.write(utf8.encode(message), withoutResponse: false);

        _log("💎 [SUCCESS] DATA TRANSFERRED VIA MESH!");

        await device.disconnect();
        _advState = BleAdvertiseState.idle;
        return;

      } catch (e) {
        _log("⚠️ GATT Attempt $attempt failed: $e");
        await device.disconnect();
        _advState = BleAdvertiseState.idle; // Освобождаем, чтобы Оркестратор мог попробовать в след. раз
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<String> _getDeviceModel() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return "${a.manufacturer} ${a.model}";
    }
    return "iOS";
  }

  void _log(String msg) {
    print("🦷 [BT-Mesh] $msg");
    locator<MeshService>().addLog("🦷 [BT] $msg");
  }
}

class _BtTask {
  final BluetoothDevice device;
  final String message;
  _BtTask(this.device, this.message);
}