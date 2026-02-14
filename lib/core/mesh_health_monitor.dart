// lib/core/mesh_health_monitor.dart
//
// Mesh Health Score (0–100). DIAGNOSTIC ONLY in v1.
// Does not modify transport, routing, BLE connect(), Wi-Fi, or advertising.
// Log tag: [HEALTH]

/// Diagnostic health score 0–100. Observation layer only.
class MeshHealthMonitor {
  MeshHealthMonitor();

  int bleCentralTimeouts = 0;
  int bleAdvFailures = 0;
  int bleRestarts = 0;
  int wifiFailures = 0;
  int successfulConnections = 0;

  DateTime lastDecay = DateTime.now();

  int get score {
    int base = 100;

    base -= (bleCentralTimeouts * 8);
    base -= (bleAdvFailures * 12);
    base -= (bleRestarts * 2);
    base -= (wifiFailures * 6);
    base += (successfulConnections * 2);

    if (base > 100) base = 100;
    if (base < 0) base = 0;

    return base;
  }

  void recordBleCentralTimeout() => bleCentralTimeouts++;
  void recordBleAdvFailure() => bleAdvFailures++;
  void recordBleRestart() => bleRestarts++;
  void recordWifiFailure() => wifiFailures++;
  void recordSuccessfulConnection() => successfulConnections++;

  void decayIfNeeded() {
    if (DateTime.now().difference(lastDecay).inSeconds > 60) {
      bleCentralTimeouts = (bleCentralTimeouts * 0.5).round();
      bleAdvFailures = (bleAdvFailures * 0.5).round();
      bleRestarts = (bleRestarts * 0.5).round();
      wifiFailures = (wifiFailures * 0.5).round();
      successfulConnections = (successfulConnections * 0.5).round();
      lastDecay = DateTime.now();
    }
  }
}

/// Shared instance for diagnostic hooks. Do not use for routing or timing decisions.
final MeshHealthMonitor meshHealthMonitor = MeshHealthMonitor();
