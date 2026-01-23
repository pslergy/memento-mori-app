import 'event_bus_service.dart';

/// BLE Finite State Machine
/// Enforces valid state transitions
enum BleState {
  IDLE,
  ADVERTISING,
  SCANNING,
  CONNECTING,
  CONNECTED,
}

class BleStateMachine {
  BleState _state = BleState.IDLE;
  final EventBusService _eventBus = EventBusService();
  
  BleState get state => _state;
  
  /// Check if transition is valid
  bool _isValidTransition(BleState from, BleState to) {
    switch (from) {
      case BleState.IDLE:
        return to == BleState.ADVERTISING || 
               to == BleState.SCANNING ||
               to == BleState.CONNECTING;
      
      case BleState.ADVERTISING:
        return to == BleState.IDLE || 
               to == BleState.CONNECTING ||
               to == BleState.CONNECTED;
      
      case BleState.SCANNING:
        return to == BleState.IDLE || 
               to == BleState.CONNECTING;
      
      case BleState.CONNECTING:
        return to == BleState.CONNECTED || 
               to == BleState.IDLE;
      
      case BleState.CONNECTED:
        return to == BleState.IDLE;
    }
  }
  
  /// Transition to new state
  Future<void> transition(BleState to) async {
    if (!_isValidTransition(_state, to)) {
      throw StateError('Invalid BLE state transition: $_state -> $to');
    }
    
    final previousState = _state;
    _state = to;
    
    // Emit state change event
    _eventBus.bus.fire(BleStateChangedEvent(to));
    
    print('🔄 [BLE-FSM] State transition: $previousState -> $to');
  }
  
  /// Force transition (use with caution, for error recovery)
  Future<void> forceTransition(BleState to) async {
    final previousState = _state;
    _state = to;
    _eventBus.bus.fire(BleStateChangedEvent(to));
    print('⚠️ [BLE-FSM] Force transition: $previousState -> $to');
  }
  
  /// Reset to IDLE (for error recovery)
  Future<void> reset() async {
    await forceTransition(BleState.IDLE);
  }
  
  /// Check if in specific state
  bool isInState(BleState state) => _state == state;
  
  /// Check if can perform action
  bool canAdvertise() => _state == BleState.IDLE;
  bool canScan() => _state == BleState.IDLE;
  bool canConnect() => _state == BleState.IDLE || 
                       _state == BleState.ADVERTISING || 
                       _state == BleState.SCANNING;
}
