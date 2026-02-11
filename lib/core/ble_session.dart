import 'ble_hardware_strategy.dart';

/// BLE Session Ownership — single owner for all BLE/GATT operations.
/// Only the owner may: stop/start scan, advertise, connect, send, reset.
/// All other attempts → [BLE][SKIP] Session owned by <owner>
enum BleSessionOwner {
  none,
  gossip,
  cascade,
  batchSend,
}

/// Hard GATT FSM states for client session.
/// IDLE → CONNECTING → CONNECTED → DISCOVERED → TRANSFERRING → DONE → IDLE
enum BleGattSessionState {
  IDLE,
  CONNECTING,
  CONNECTED,
  DISCOVERED,
  TRANSFERRING,
  DONE,
}

/// Single global BLE transaction FSM — one GATT lifecycle at a time.
/// No scan/adv/connect allowed outside IDLE. Subsystems must respect this.
///
/// INVARIANT: At least one peer must remain PERIPHERAL during BLE negotiation.
/// PERIPHERAL must NOT enter QUIET_PRE_CONNECT; only the peer that becomes CENTRAL does.
enum BleTransactionState {
  IDLE,
  QUIET_PRE_CONNECT,
  CONNECTING,
  STABILIZING_POST_CONNECT,
  DISCOVERING,
  TRANSFERRING,
  LISTENING,
  DISCONNECTING,
  QUIET_POST_DISCONNECT,
}

/// Callback после успешной отправки одного фрагмента (для BLE resume).
typedef OnFragmentSent = void Function(String messageId, int index, int total);

/// Centralized BLE message queue.
/// All modules MUST enqueue here — no direct sendMessage() calls.
/// Single consumer processes queue, acquires owner, runs connect→discover→write.
class BleSendQueueEntry {
  final String deviceId;
  final List<String> messages;
  /// Для resume: id сообщений в порядке [messages]. Если не null, в sendMultipleMessages отправляются только фрагменты с индекса sentFragmentIndex+1.
  final List<String>? messageIds;
  final List<int>? sentFragmentIndices;
  final OnFragmentSent? onFragmentSent;
  /// ADAPTIVE: Huawei break-glass — single attempt, ≤12s connect, then long cooldown on failure.
  final bool isHuaweiBreakGlass;
  /// ADAPTIVE: Pair-specific write/notify. When non-null: use for write; on first failure switch once then abort.
  final BleWriteStrategy? writeStrategy;

  BleSendQueueEntry(
    this.deviceId,
    this.messages, {
    this.messageIds,
    this.sentFragmentIndices,
    this.onFragmentSent,
    this.isHuaweiBreakGlass = false,
    this.writeStrategy,
  });
}
