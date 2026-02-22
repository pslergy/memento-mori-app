// lib/core/ios_ble_transport.dart
//
// iOS-only BLE Central transport: connect to Android mesh (BRIDGE/GHOST), receive via notify,
// send via write. Same UUIDs and packet format as Android bluetooth_service.dart.
// Does NOT modify bluetooth_service.dart or any Android code. All logic guarded by Platform.isIOS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'locator.dart';
import 'mesh_service.dart';

/// Same UUIDs as Android BluetoothMeshService (bluetooth_service.dart). Do not change.
const String _serviceUuid = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
const String _charUuid = "c22d1e32-0310-4062-812e-89025078da9c";

/// iOS BLE Central: connect to one mesh peer, receive (notify) and send (write).
/// Contract: 4-byte big-endian length + JSON payload; write in 60-byte chunks.
class IosBleTransport {
  IosBleTransport._();
  static final IosBleTransport _instance = IosBleTransport._();
  factory IosBleTransport() => _instance;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _notifySub;

  final List<int> _notifyBuffer = [];
  int _notifyExpectedLength = -1;

  bool get hasConnectedPeer {
    if (!Platform.isIOS) return false;
    return _device != null &&
        _characteristic != null &&
        (_device!.isConnected == true);
  }

  /// Start connection loop: scan → connect → discover → subscribe to notify. Call only on iOS.
  Future<void> start() async {
    if (!Platform.isIOS) return;
    unawaited(_connectLoop());
  }

  Future<void> _connectLoop() async {
    if (!Platform.isIOS) return;
    while (true) {
      try {
        if (hasConnectedPeer) {
          await Future.delayed(const Duration(seconds: 20));
          continue;
        }
        await _connectOnce();
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 15));
    }
  }

  Future<void> _connectOnce() async {
    if (!Platform.isIOS) return;
    try {
      BluetoothDevice? target;
      final results = FlutterBluePlus.lastScanResults;
      for (final r in results) {
        if (_isMeshDevice(r)) {
          target = r.device;
          break;
        }
      }
      if (target == null) {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
        await Future.delayed(const Duration(seconds: 6));
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
        final after = FlutterBluePlus.lastScanResults;
        for (final r in after) {
          if (_isMeshDevice(r)) {
            target = r.device;
            break;
          }
        }
      }
      if (target == null) return;

      await target.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      final services = await target.discoverServices();
      BluetoothService? svc;
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == _serviceUuid.toLowerCase()) {
          svc = s;
          break;
        }
      }
      if (svc == null) {
        await target.disconnect();
        return;
      }
      BluetoothCharacteristic? chr;
      for (final c in svc.characteristics) {
        if (c.uuid.toString().toLowerCase() == _charUuid.toLowerCase()) {
          chr = c;
          break;
        }
      }
      if (chr == null) {
        await target.disconnect();
        return;
      }

      _device = target;
      _characteristic = chr;
      _notifyBuffer.clear();
      _notifyExpectedLength = -1;

      await chr.setNotifyValue(true);
      _notifySub?.cancel();
      final peerAddress = target.remoteId.str;
      _notifySub = chr.lastValueStream.listen(
        (value) => _onNotifyChunk(peerAddress, value),
        onError: (_) {},
      );

      target.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _notifySub?.cancel();
          _notifySub = null;
          _device = null;
          _characteristic = null;
          _notifyBuffer.clear();
          _notifyExpectedLength = -1;
        }
      });
    } catch (_) {
      _device = null;
      _characteristic = null;
      _notifySub?.cancel();
      _notifySub = null;
    }
  }

  bool _isMeshDevice(ScanResult r) {
    final adv = r.advertisementData;
    final hasUuid = adv.serviceUuids.any((u) =>
        u.toString().toLowerCase().contains(_serviceUuid.replaceAll("-", "").substring(0, 8)));
    if (hasUuid) return true;
    final mf = adv.manufacturerData;
    final raw = mf[0xFFFF];
    if (raw != null && raw.length >= 2) {
      if (raw[0] == 0x42 && raw[1] == 0x52) return true;
      if (raw[0] == 0x47 && raw[1] == 0x48) return true;
      if (raw[0] == 0x52 && raw[1] == 0x4C) return true;
    }
    return false;
  }

  /// Same parsing as Android _onNotifyChunkFromBridge: 4-byte length (big-endian) + JSON.
  void _onNotifyChunk(String bridgeAddress, List<int> chunk) {
    if (!Platform.isIOS || chunk.isEmpty) return;
    _notifyBuffer.addAll(chunk);
    if (_notifyExpectedLength < 0 && _notifyBuffer.length >= 4) {
      _notifyExpectedLength = (_notifyBuffer[0] << 24) |
          (_notifyBuffer[1] << 16) |
          (_notifyBuffer[2] << 8) |
          _notifyBuffer[3];
    }
    while (_notifyExpectedLength >= 0 &&
        _notifyBuffer.length >= 4 + _notifyExpectedLength) {
      final payload = _notifyBuffer.sublist(4, 4 + _notifyExpectedLength);
      _notifyBuffer.removeRange(0, 4 + _notifyExpectedLength);
      _notifyExpectedLength = -1;
      if (_notifyBuffer.length >= 4) {
        _notifyExpectedLength = (_notifyBuffer[0] << 24) |
            (_notifyBuffer[1] << 16) |
            (_notifyBuffer[2] << 8) |
            _notifyBuffer[3];
      }
      try {
        final jsonStr = utf8.decode(payload);
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        map['senderIp'] = bridgeAddress;
        if (locator.isRegistered<MeshService>()) {
          locator<MeshService>().processIncomingPacket(map);
        }
      } catch (_) {}
    }
  }

  /// Send one JSON message to connected peer. Same framing as Android: 4-byte length + payload, 60-byte chunks.
  Future<void> writeToPeer(String payloadJson) async {
    if (!Platform.isIOS) return;
    final c = _characteristic;
    if (c == null || _device == null || _device!.isConnected != true) return;
    try {
      final payload = utf8.encode(payloadJson);
      final framed = _createFramedMessage(payload);
      const int chunkSize = 60;
      for (int j = 0; j < framed.length; j += chunkSize) {
        final end = (j + chunkSize < framed.length) ? j + chunkSize : framed.length;
        final chunk = framed.sublist(j, end);
        await c.write(chunk, withoutResponse: true);
        if (end < framed.length) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {}
  }

  Uint8List _createFramedMessage(List<int> jsonPayload) {
    final payloadLength = jsonPayload.length;
    final header = Uint8List(4);
    header[0] = (payloadLength >> 24) & 0xFF;
    header[1] = (payloadLength >> 16) & 0xFF;
    header[2] = (payloadLength >> 8) & 0xFF;
    header[3] = payloadLength & 0xFF;
    final framed = Uint8List(4 + payloadLength);
    framed.setRange(0, 4, header);
    framed.setRange(4, 4 + payloadLength, jsonPayload);
    return framed;
  }

  void stop() {
    if (!Platform.isIOS) return;
    _notifySub?.cancel();
    _notifySub = null;
    if (_device != null) {
      _device!.disconnect();
      _device = null;
    }
    _characteristic = null;
    _notifyBuffer.clear();
    _notifyExpectedLength = -1;
  }
}
