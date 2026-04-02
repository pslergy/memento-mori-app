// lib/core/network_phase.dart
//
// Network phase enum — shared to avoid circular imports.

/// Global network phase — источник истины для порядка запуска подсистем.
enum NetworkPhase {
  boot,
  localDiscovery,
  localLinkSetup,
  localTransfer,
  uplinkAvailable,
  bridgeActive,
  idle,
}
