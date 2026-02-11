// lib/core/ble_interaction_stats.dart
//
// Passive observation only: records BLE interaction facts for future
// policy use. NO logic depends on these stats; NO behavior change.
// WHY: reduces risk of hardcoded brand decisions by allowing later
// analysis and scored adaptation without touching runtime paths.

/// What the local device attempted in this BLE interaction.
enum BleAttemptedAction {
  scan,
  connect,
  write,
  notify,
}

/// Observed outcome (fact only).
enum BleInteractionResult {
  success,
  timeout,
  busy,
  failed,
}

/// Single fact record: who, what, result, when.
/// Used only for future policy; no branching on this data.
class BleInteractionStats {
  const BleInteractionStats({
    required this.peerId,
    this.peerBrand,
    this.peerRole,
    this.localRole,
    required this.attemptedAction,
    required this.result,
    required this.timestamp,
  });

  final String peerId;
  final String? peerBrand;
  final String? peerRole;
  final String? localRole;
  final BleAttemptedAction attemptedAction;
  final BleInteractionResult result;
  final DateTime timestamp;
}

/// Fire-and-forget recorder. Bounded in-memory ring.
const int _kMaxStored = 500;
const Duration _kAdaptiveWindow = Duration(minutes: 5);
const int _kAdaptiveFailureThreshold = 2;

final List<BleInteractionStats> _store = [];
int _storeIndex = 0;

void recordBleInteraction(BleInteractionStats stats) {
  if (_store.length < _kMaxStored) {
    _store.add(stats);
  } else {
    _store[_storeIndex % _kMaxStored] = stats;
    _storeIndex++;
  }
}

/// Count of recent GATT connect failures (failed/timeout) toward [peerId].
/// Used ONLY when both local and peer are non-Huawei; never affects Huawei/Honor.
int recentInitiationFailureCount(String peerId, {Duration? window}) {
  final w = window ?? _kAdaptiveWindow;
  final cutoff = DateTime.now().subtract(w);
  int n = 0;
  for (final s in _store) {
    if (s.peerId != peerId) continue;
    if (s.timestamp.isBefore(cutoff)) continue;
    if (s.attemptedAction != BleAttemptedAction.connect) continue;
    if (s.result == BleInteractionResult.failed ||
        s.result == BleInteractionResult.timeout) n++;
  }
  return n;
}

/// Prefer not to initiate GATT to this peer this round (extend scan / wait as PERIPHERAL).
/// Caller MUST only use when BOTH local and peer are NOT Huawei/Honor. Policy-locked for Huawei.
bool adaptivePreferNotToInitiateToPeer(String peerId) {
  return recentInitiationFailureCount(peerId) >= _kAdaptiveFailureThreshold;
}
