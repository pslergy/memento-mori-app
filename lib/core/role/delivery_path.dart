// lib/core/role/delivery_path.dart
// Exactly one path per message. Resolved by MessageRouter.

enum DeliveryPath {
  /// Message goes to backend (only BRIDGE with valid lease).
  backendDirect,

  /// Message goes via mesh DTN (BLE, Wi-Fi Direct, Sonar).
  meshDtn,
}
