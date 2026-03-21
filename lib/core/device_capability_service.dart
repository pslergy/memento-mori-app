// lib/core/device_capability_service.dart
//
// Capability detection for Wi‑Fi Direct orchestration. Used at startup and for BLE advertising.
// Log tag: [CAPABILITY]

import 'dart:io';

import 'hardware_check_service.dart';
import 'models/device_capability.dart';
import 'native_mesh_service.dart';

/// Builds [DeviceCapability] for this device. Used by BLE advertising and Wi‑Fi policy.
class DeviceCapabilityService {
  DeviceCapabilityService._();

  static final HardwareCheckService _hw = HardwareCheckService();

  /// Detect and return current device capability. Call at startup and when building BLE payload.
  static Future<DeviceCapability> getCapability() async {
    final isAndroid = Platform.isAndroid;
    // BLE peripheral: we can advertise / host GATT (we have the path; consider available on Android).
    final blePeripheral = isAndroid;
    // BLE central: we are willing to initiate GATT (not preferGattPeripheral).
    final preferPeripheral = await _hw.preferGattPeripheral();
    final bleCentral = !preferPeripheral;
    // WifiP2pManager availability.
    final wifiP2pSupported = isAndroid;
    // Wifi + P2P enabled state (from native).
    bool wifiP2pEnabled = false;
    if (isAndroid) {
      try {
        wifiP2pEnabled = await NativeMeshService.checkP2pState();
      } catch (_) {}
    }
    // Huawei/Honor: likely unstable as BLE central → set flag for GO policy.
    final isHuawei = await _hw.isHuaweiOrHonor();
    final wifiLikelyUnstableCentral = isHuawei;

    final cap = DeviceCapability(
      blePeripheral: blePeripheral,
      bleCentral: bleCentral,
      wifiP2pSupported: wifiP2pSupported,
      wifiP2pEnabled: wifiP2pEnabled,
      wifiLikelyUnstableCentral: wifiLikelyUnstableCentral,
    );
    return cap;
  }

  /// Whether this device should be Wi‑Fi GO when peer or self is Huawei (Huawei MUST be GO).
  static Future<bool> isHuaweiLikeDevice() async {
    return _hw.isHuaweiOrHonor();
  }
}
