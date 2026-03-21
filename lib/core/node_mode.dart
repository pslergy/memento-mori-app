// lib/core/node_mode.dart
//
// NodeMode layer: allows passive relay mode without initiating connections.
// Does not modify ConnectionPhase or transport discipline.

enum NodeMode {
  active,
  passive_relay,
}

/// Controller for [NodeMode]. Injected via locator; used by MeshService to gate initiation.
class NodeModeController {
  NodeMode _mode = NodeMode.active;

  NodeMode get current => _mode;

  void setMode(NodeMode mode) {
    _mode = mode;
  }

  /// True if this node may initiate BLE or Wi-Fi connections.
  /// passive_relay → false (accept inbound only).
  bool canInitiate() => _mode == NodeMode.active;

  /// True if this node may participate in arbitration (enter BLE arbitration phase).
  /// passive_relay → false (skip cascade/arbitration).
  bool canParticipateInArbitration() => _mode == NodeMode.active;
}
