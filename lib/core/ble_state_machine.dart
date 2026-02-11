import 'event_bus_service.dart';

/// BLE Finite State Machine
/// Enforces valid state transitions — single-direction, NO overlap.
/// [BLE][STATE] logging for audit compliance.

/// 🔒 BLE ROLE GATE: Single owner of BLE stack at any time.
/// GATT server lifecycle is independent from advertising and scanning — GATT server stays ON during app runtime.
enum BleRole {
  /// No BLE owner — safe to become CENTRAL or PERIPHERAL.
  IDLE,

  /// We are GATT client: our advertising=OFF, scan=OFF; GATT server remains ON (never stopped when switching to CENTRAL).
  CENTRAL,

  /// We are GATT server + advertising: connectGatt is FORBIDDEN; peer keeps advertising until link established.
  PERIPHERAL,
}

enum BleState {
  IDLE,
  GATT_STARTING, // Bridge: GATT server starting
  GATT_READY, // Bridge: GATT server ready (single-shot)
  ADVERTISING,
  SCANNING,
  CONNECTING,
  CONNECTED,
  SERVICES_READY, // Client: discoverServices done, safe to write
  TRANSFERRING, // Client: writing/reading
}

class BleStateMachine {
  BleState _state = BleState.IDLE;

  /// 🔒 Current BLE role — only one owner at a time.
  BleRole _role = BleRole.IDLE;
  final EventBusService _eventBus = EventBusService();

  BleState get state => _state;
  BleRole get role => _role;

  /// Check if transition is valid (one-direction, no cycles mid-flow)
  bool _isValidTransition(BleState from, BleState to) {
    if (from == to) return true; // NOOP
    switch (from) {
      case BleState.IDLE:
        return to == BleState.GATT_STARTING ||
            to == BleState.ADVERTISING ||
            to == BleState.SCANNING ||
            to == BleState.CONNECTING;
      case BleState.GATT_STARTING:
        return to == BleState.GATT_READY || to == BleState.IDLE;
      case BleState.GATT_READY:
        return to == BleState.ADVERTISING || to == BleState.IDLE;
      case BleState.ADVERTISING:
        return to == BleState.IDLE ||
            to == BleState.CONNECTING ||
            to == BleState.CONNECTED;
      case BleState.SCANNING:
        return to == BleState.IDLE || to == BleState.CONNECTING;
      case BleState.CONNECTING:
        return to == BleState.CONNECTED || to == BleState.IDLE;
      case BleState.CONNECTED:
        return to == BleState.SERVICES_READY || to == BleState.IDLE;
      case BleState.SERVICES_READY:
        return to == BleState.TRANSFERRING || to == BleState.IDLE;
      case BleState.TRANSFERRING:
        return to == BleState.IDLE;
    }
  }

  /// Transition to new state. Same state → NOOP + log.
  /// Updates _role: CONNECTING/... → CENTRAL; ADVERTISING/GATT_* → PERIPHERAL; IDLE → IDLE.
  Future<void> transition(BleState to) async {
    if (_state == to) {
      print('[BLE][SKIP] transition skipped (already $to)');
      return;
    }
    if (!_isValidTransition(_state, to)) {
      print('[BLE][SKIP] invalid transition $_state -> $to');
      throw StateError('Invalid BLE state transition: $_state -> $to');
    }
    final prev = _state;
    _state = to;
    _updateRoleFromState(to);
    _eventBus.bus.fire(BleStateChangedEvent(to));
    print('[BLE][STATE] $prev -> $to (role: $_role)');
  }

  /// Force transition (error recovery only)
  Future<void> forceTransition(BleState to) async {
    final prev = _state;
    _state = to;
    _updateRoleFromState(to);
    _eventBus.bus.fire(BleStateChangedEvent(to));
    print('[GATT][STATE] force $prev -> $to (role: $_role)');
  }

  void _updateRoleFromState(BleState s) {
    switch (s) {
      case BleState.IDLE:
        _role = BleRole.IDLE;
        break;
      case BleState.GATT_STARTING:
      case BleState.GATT_READY:
      case BleState.ADVERTISING:
        _role = BleRole.PERIPHERAL;
        break;
      case BleState.SCANNING:
        _role = BleRole.IDLE;
        break;
      case BleState.CONNECTING:
      case BleState.CONNECTED:
      case BleState.SERVICES_READY:
      case BleState.TRANSFERRING:
        _role = BleRole.CENTRAL;
        break;
    }
  }

  Future<void> reset() async => await forceTransition(BleState.IDLE);

  bool isInState(BleState state) => _state == state;

  bool canAdvertise() =>
      _state == BleState.IDLE || _state == BleState.GATT_READY;
  bool canScan() => _state == BleState.IDLE;

  /// 🔒 Only allow connect when role is IDLE (we will enter CENTRAL) or already CENTRAL.
  bool canConnect() =>
      _state == BleState.IDLE ||
      _state == BleState.ADVERTISING ||
      _state == BleState.SCANNING;

  /// 🔒 In CENTRAL role: no GATT server, no advertising, no scan before connect.
  bool get isCentralRole => _role == BleRole.CENTRAL;
  bool get isPeripheralRole => _role == BleRole.PERIPHERAL;

  /// Safe to write to characteristic (client)
  bool get canWrite =>
      _state == BleState.SERVICES_READY || _state == BleState.TRANSFERRING;

  /// GATT server ready (Bridge)
  bool get isGattServerReady => _state == BleState.GATT_READY;
}
