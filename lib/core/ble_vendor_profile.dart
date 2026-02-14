// lib/core/ble_vendor_profile.dart
//
// Vendor Profile Layer + BLE Stability Metric.
// Does NOT modify BLE transport, GATT, connect(), or Wi-Fi.
// Log tags: [BLE-PROFILE] [BLE-STABILITY] [BLE-SAFE-MODE]

/// Per-vendor BLE advertising and central retry limits.
class BleVendorProfile {
  const BleVendorProfile({
    required this.advRestartCooldownMs,
    required this.stopStartDelayMs,
    required this.maxAdvRestartsPerMinute,
    required this.allowStrategyCascade,
    required this.centralRetryCooldownMs,
  });

  final int advRestartCooldownMs;
  final int stopStartDelayMs;
  final int maxAdvRestartsPerMinute;
  final bool allowStrategyCascade;
  final int centralRetryCooldownMs;
}

/// Resolves vendor profile from manufacturer string. Store result at startup.
BleVendorProfile resolveVendorProfile(String manufacturer) {
  final m = manufacturer.toLowerCase();

  if (m.contains('huawei') || m.contains('honor')) {
    return const BleVendorProfile(
      advRestartCooldownMs: 6000,
      stopStartDelayMs: 500,
      maxAdvRestartsPerMinute: 5,
      allowStrategyCascade: false,
      centralRetryCooldownMs: 15000,
    );
  }

  if (m.contains('xiaomi') || m.contains('redmi')) {
    return const BleVendorProfile(
      advRestartCooldownMs: 3500,
      stopStartDelayMs: 300,
      maxAdvRestartsPerMinute: 10,
      allowStrategyCascade: false,
      centralRetryCooldownMs: 8000,
    );
  }

  return const BleVendorProfile(
    advRestartCooldownMs: 2500,
    stopStartDelayMs: 200,
    maxAdvRestartsPerMinute: 15,
    allowStrategyCascade: true,
    centralRetryCooldownMs: 5000,
  );
}

/// BLE stability metric. Decay after 60s. Used to double cooldown when unstable.
class BleStabilityMonitor {
  int advStartFailures = 0;
  int centralTimeouts = 0;
  int recentRestarts = 0;
  DateTime lastReset = DateTime.now();
  DateTime? lastCentralTimeoutTime;

  bool get isUnstable => advStartFailures >= 2 || centralTimeouts >= 3;

  void recordAdvFailure() {
    advStartFailures++;
  }

  void recordCentralTimeout() {
    centralTimeouts++;
    lastCentralTimeoutTime = DateTime.now();
  }

  void recordRestart() {
    recentRestarts++;
  }

  void decay() {
    if (DateTime.now().difference(lastReset).inSeconds > 60) {
      advStartFailures = 0;
      centralTimeouts = 0;
      recentRestarts = 0;
      lastReset = DateTime.now();
    }
  }

  /// Returns remaining cooldown (positive) if central retry should wait; otherwise Duration.zero.
  Duration centralRetryRemainingCooldown(int cooldownMs) {
    if (lastCentralTimeoutTime == null) return Duration.zero;
    final elapsed = DateTime.now().difference(lastCentralTimeoutTime!).
        inMilliseconds;
    if (elapsed >= cooldownMs) return Duration.zero;
    return Duration(milliseconds: cooldownMs - elapsed);
  }
}
