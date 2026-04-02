/// Ephemeral BLE route to a logical peer (stable [deviceUuid]).
/// MAC rotates (RPA); RSSI and recency pick the best connect target.
class PeerEndpoint {
  final String mac;
  final int rssi;
  final int lastSeenMs;

  const PeerEndpoint({
    required this.mac,
    required this.rssi,
    required this.lastSeenMs,
  });
}
