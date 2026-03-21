// Real device testing mode for MeshCoreEngine.
// Debug hooks only — no core logic changes.
// Use on real Android devices with BLE, Wi-Fi Direct, Sonar.

/// Enable real-device mesh debug mode.
/// When true: extra logging, MeshDebugScreen, manual actions.
bool meshDebugMode = true;

/// Debug log — only when meshDebugMode. Call from engine hooks.
void meshDebugLog(String msg, {void Function(String)? addToEngine}) {
  if (!meshDebugMode) return;
  final full = '[MESH-DEBUG] $msg';
  // ignore: avoid_print
  print(full);
  addToEngine?.call(full);
}
