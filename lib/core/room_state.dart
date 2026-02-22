/// Room state for UI
/// Human-readable representation, not technical
enum RoomState {
  /// 🟢 Active - room is working normally
  active,
  
  /// 🕓 Syncing - data exchange in progress
  syncing,
  
  /// ⚠️ No connection - offline mode
  offline,
}

extension RoomStateExtension on RoomState {
  String get displayText {
    switch (this) {
      case RoomState.active:
        return '🟢 Активна';
      case RoomState.syncing:
        return '🕓 Синхронизируется';
      case RoomState.offline:
        return '⚠️ Нет соединения';
    }
  }
  
  String get shortText {
    switch (this) {
      case RoomState.active:
        return '🟢';
      case RoomState.syncing:
        return '🕓';
      case RoomState.offline:
        return '⚠️';
    }
  }
}

/// Utility for determining room state
class RoomStateHelper {
  /// Determines room state based on network status
  static RoomState fromNetworkStatus({
    required bool hasInternet,
    required bool isSyncing,
  }) {
    if (hasInternet && !isSyncing) {
      return RoomState.active;
    } else if (isSyncing) {
      return RoomState.syncing;
    } else {
      return RoomState.offline;
    }
  }
}
