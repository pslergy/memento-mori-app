// lib/core/models/device_capability.dart
//
// Capability detection layer for deterministic Wi‑Fi Direct orchestration.
// Published via BLE advertising payload extension (short flag bitmask).
// Log tag: [CAPABILITY]

/// Device capability flags for BLE advertising and Wi‑Fi fallback policy.
class DeviceCapability {
  const DeviceCapability({
    required this.blePeripheral,
    required this.bleCentral,
    required this.wifiP2pSupported,
    required this.wifiP2pEnabled,
    required this.wifiLikelyUnstableCentral,
  });

  final bool blePeripheral;
  final bool bleCentral;
  final bool wifiP2pSupported;
  final bool wifiP2pEnabled;
  final bool wifiLikelyUnstableCentral;

  /// Bitmask for BLE manufacturerData extension (1 byte).
  /// bit0: blePeripheral, bit1: bleCentral, bit2: wifiP2pSupported,
  /// bit3: wifiP2pEnabled, bit4: wifiLikelyUnstableCentral
  int toCapabilityByte() {
    int b = 0;
    if (blePeripheral) b |= 1 << 0;
    if (bleCentral) b |= 1 << 1;
    if (wifiP2pSupported) b |= 1 << 2;
    if (wifiP2pEnabled) b |= 1 << 3;
    if (wifiLikelyUnstableCentral) b |= 1 << 4;
    return b & 0xFF;
  }

  /// Parse capability byte from BLE advertising (e.g. last byte of manufacturerData 0xFFFF).
  static DeviceCapability fromCapabilityByte(int byte) {
    final b = byte & 0xFF;
    return DeviceCapability(
      blePeripheral: (b & (1 << 0)) != 0,
      bleCentral: (b & (1 << 1)) != 0,
      wifiP2pSupported: (b & (1 << 2)) != 0,
      wifiP2pEnabled: (b & (1 << 3)) != 0,
      wifiLikelyUnstableCentral: (b & (1 << 4)) != 0,
    );
  }

  /// True if peer is likely Huawei/Honor (use for GO policy).
  bool get isHuaweiLike => wifiLikelyUnstableCentral;
}
