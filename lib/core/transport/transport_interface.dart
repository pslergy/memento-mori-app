// lib/core/transport/transport_interface.dart
//
// Abstract contract for mesh transports (BLE, Wi‑Fi Direct, Cloud, LoRa).
// No FSM or routing changes. New transports implement this interface.

/// Transport type for mesh layer identification.
enum TransportType {
  BLE,
  WIFI_DIRECT,
  CLOUD,
  LORA,
}

/// Packet envelope: same shape as gossip/processIncomingPacket (Map).
typedef TransportPacket = Map<String, dynamic>;

/// Callback for incoming packets (e.g. from native or mock).
typedef OnPacketCallback = void Function(TransportPacket packet);

/// Contract for a mesh transport. Implemented by BLE, Wi‑Fi Direct, Cloud, LoRa (skeleton).
abstract class TransportInterface {
  /// Start the transport (e.g. discovery, listener). No-op allowed.
  Future<void> start();

  /// Stop the transport. No-op allowed.
  Future<void> stop();

  /// Send one envelope. Caller serializes if needed; transport may enforce max payload.
  Future<void> send(TransportPacket packet);

  /// Register callback for received packets. Replaces previous if any.
  void onPacket(OnPacketCallback callback);

  /// Whether the transport is ready to send (e.g. connected, not disabled).
  bool isAvailable();

  /// Which transport this is (for logging and optional routing).
  TransportType getTransportType();
}
