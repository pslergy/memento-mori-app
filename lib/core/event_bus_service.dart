import 'models/signal_node.dart';
import 'ble_state_machine.dart';

/// Simple Event Bus implementation
/// Replaces external event_bus package with lightweight custom implementation
class EventBusService {
  static final EventBusService _instance = EventBusService._internal();
  factory EventBusService() => _instance;
  EventBusService._internal();

  final Map<Type, List<Function>> _listeners = {};

  /// Subscribe to event type
  void on<T>(void Function(T event) listener) {
    _listeners.putIfAbsent(T, () => []).add(listener);
  }

  /// Unsubscribe from event type
  void off<T>(void Function(T event) listener) {
    _listeners[T]?.remove(listener);
  }

  /// Fire event to all listeners
  void fire<T>(T event) {
    final listeners = _listeners[T];
    if (listeners != null) {
      for (final listener in listeners) {
        try {
          (listener as void Function(T))(event);
        } catch (e) {
          print('❌ [EventBus] Error in listener: $e');
        }
      }
    }
  }

  /// Get event bus instance (for compatibility)
  EventBusService get bus => this;
}

// ==========================================
// Event Definitions
// ==========================================

/// Message received event
class MessageReceivedEvent {
  final Map<String, dynamic> data;
  
  MessageReceivedEvent(this.data);
}

/// Nodes discovered event
class NodesDiscoveredEvent {
  final List<SignalNode> nodes;
  
  NodesDiscoveredEvent(this.nodes);
}

/// Status/log event
class StatusEvent {
  final String message;
  
  StatusEvent(this.message);
}

/// Link request event
class LinkRequestEvent {
  final String requestId;
  
  LinkRequestEvent(this.requestId);
}

/// BLE state changed event
class BleStateChangedEvent {
  final BleState state;
  
  BleStateChangedEvent(this.state);
}

/// Outbox transition 0 → 1: first message added. Used for discovery boost (scan/adv).
class OutboxFirstMessageEvent {}

/// Outbox became empty (1 → 0). Used to refresh BLE advertisement intent flag.
class OutboxEmptyEvent {}

/// CRDT LOG_ENTRIES merge completed for a chat — UI should reload messages from DB for this chat.
/// Fired when messages were merged via BEACON-SYNC (no OFFLINE_MSG stream), so conversation screen must refresh.
class ChatSyncCompletedEvent {
  final String chatId;
  ChatSyncCompletedEvent(this.chatId);
}
