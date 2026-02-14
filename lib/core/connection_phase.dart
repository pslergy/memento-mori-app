// lib/core/connection_phase.dart
//
// Global connection authority layer: single atomic phase for BLE, Wi‑Fi, Relay, Scan.
// No relay, no advertising restart, no scan restart, no Wi‑Fi discovery may occur
// during connecting_ble or transferring_ble.

/// Global connection phase. Must be atomic and globally respected.
enum ConnectionPhase {
  idle,
  arbitration,
  connecting_ble,
  transferring_ble,
  wifi_arbitration,
  wifi_pending_enable, // Wi‑Fi fallback waiting for P2P to be enabled (do not stop BLE).
  connecting_wifi,
  transferring_wifi,
}

/// Controller for [ConnectionPhase]. Injected via locator; used by MeshService and BluetoothMeshService.
class ConnectionPhaseController {
  ConnectionPhase _phase = ConnectionPhase.idle;
  void Function(String message)? _logCallback;

  ConnectionPhase get current => _phase;

  /// True when BLE connect or transfer is in progress — no relay, no adv restart, no scan restart.
  bool get isBleActive =>
      _phase == ConnectionPhase.connecting_ble ||
      _phase == ConnectionPhase.transferring_ble;

  /// True when Wi‑Fi connect or transfer is in progress (includes arbitration and pending enable).
  bool get isWifiActive =>
      _phase == ConnectionPhase.wifi_arbitration ||
      _phase == ConnectionPhase.wifi_pending_enable ||
      _phase == ConnectionPhase.connecting_wifi ||
      _phase == ConnectionPhase.transferring_wifi;

  /// True when any connect/transfer is in progress (BLE or Wi‑Fi).
  bool get isActive => isBleActive || isWifiActive;

  void setLog(void Function(String message) log) {
    _logCallback = log;
  }

  /// Transition to [next] and log. Use this for strict phase logging.
  void transitionTo(ConnectionPhase next, [void Function(String message)? log]) {
    final prev = _phase;
    _phase = next;
    final logger = log ?? _logCallback;
    if (logger != null) {
      logger(
          "[CONNECTION-PHASE] $prev → $next (isBleActive=${next == ConnectionPhase.connecting_ble || next == ConnectionPhase.transferring_ble})");
    }
  }

  /// Set phase without logging (e.g. internal use when log not yet set).
  void setPhase(ConnectionPhase phase) {
    _phase = phase;
  }
}
