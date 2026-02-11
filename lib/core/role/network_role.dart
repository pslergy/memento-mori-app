// lib/core/role/network_role.dart
// NetworkRole: assigned by backend or inferred (no internet = GHOST).
// InternetStatus: presence vs backend confirmation.

/// Node role. BRIDGE only when backend assigns a valid lease.
enum NetworkRole {
  GHOST,
  CLIENT,
  BRIDGE,
}

/// Internet presence vs backend-confirmed connectivity.
enum InternetStatus {
  OFFLINE,
  ONLINE_UNCONFIRMED,
  ONLINE_CONFIRMED,
}
