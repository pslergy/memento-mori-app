import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import 'package:memento_mori_app/core/websocket_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/security_service.dart';

import '../../core/decoy/app_mode.dart';
import '../../core/decoy/timed_panic_controller.dart';
import '../../core/decoy/vault_interface.dart';
import '../../core/panic/panic_display_service.dart';
import '../../core/panic/panic_neutral_phrases.dart';
import '../../core/panic_service.dart';
import '../../core/encryption_service.dart';
import '../../core/double_ratchet/dr_dh_peer_pins.dart';
import '../../core/double_ratchet/dr_install_pre_key.dart';
import '../../core/double_ratchet/dr_peer_bundle_cache.dart';
import '../../core/double_ratchet_scaffold.dart';
import '../../core/message_crypto_facade.dart';
import '../../core/message_signing_service.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/mesh_core_engine.dart';
import '../../core/mesh_pairing_proximity_hint.dart';
import '../../core/bluetooth_service.dart';
import '../../core/time/mesh_clock_display_adjust.dart';
import '../../core/dm_chat_id.dart';
import '../../core/dm_session_ui_guard.dart';
import '../../core/room_id_normalizer.dart';
import '../../core/beacon_country_helper.dart';
import '../../core/message_status.dart';
import '../../core/router/router_connection_service.dart';
import '../../core/room_state.dart';
import '../../core/room_state.dart' show RoomStateHelper;
import '../../core/event_bus_service.dart';
import '../../core/module_status_panel.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

import '../../dev_tools/room_timeline_debugger.dart';
import '../profile/user_profile_screen.dart';
import '../ui/messenger_expectations_info.dart';

/// [ListenableBuilder] требует listenable; если CORE ещё без [MeshClockDisplayAdjust] — no-op.
final _noopListenableForClockUi = _NoopListenable();

class _NoopListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

// --- Модель сообщения ---
class ChatMessage {
  final String id;
  final String? clientTempId;
  final String content;
  final String senderId;
  final String? senderUsername;
  final DateTime createdAt;
  final DateTime? receivedAt;
  final Map<String, int>? vectorClock; // Vector clock для конфликт-разрешения
  final int? sequenceNumber; // CRDT: monotonic per author per chat
  final String? previousHash; // CRDT: hash of previous entry in same author chain
  final String? forkOfId; // CRDT: if set, this is a divergent branch copy
  String status;
  bool hasWarning = false;
  /// Optimistic send: true for message inserted before transport confirm. UI/dedup only.
  final bool isLocal;
  /// After CRDT/transport confirm, stable id (for dedup). Null while sending.
  final String? crdtId;
  /// Ответ на сообщение (только локально/БД; транспорт не меняется).
  final String? replyToId;
  final String? replyPreview;
  /// UI: текст ещё не расшифрован (BEACON_NEARBY fast open); не показывать ciphertext.
  final bool contentPendingDecrypt;

  ChatMessage({
    required this.id,
    this.clientTempId,
    required this.content,
    required this.senderId,
    this.senderUsername,
    required this.createdAt,
    this.receivedAt,
    this.vectorClock,
    this.sequenceNumber,
    this.previousHash,
    this.forkOfId,
    this.status = 'SENT',
    this.hasWarning = false,
    this.isLocal = false,
    this.crdtId,
    this.replyToId,
    this.replyPreview,
    this.contentPendingDecrypt = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // 🔥 ТАКТИЧЕСКИЙ ФИКС: Безопасно парсим дату из любого типа
    DateTime parsedDate;
    var rawDate = json['createdAt'];

    if (rawDate is int) {
      parsedDate = DateTime.fromMillisecondsSinceEpoch(rawDate);
    } else if (rawDate is String) {
      parsedDate = DateTime.tryParse(rawDate) ?? DateTime.now();
    } else {
      parsedDate = DateTime.now();
    }

    DateTime? parsedReceivedAt;
    var rawReceivedAt = json['receivedAt'];
    if (rawReceivedAt != null) {
      if (rawReceivedAt is int) {
        parsedReceivedAt = DateTime.fromMillisecondsSinceEpoch(rawReceivedAt);
      } else if (rawReceivedAt is String) {
        parsedReceivedAt = DateTime.tryParse(rawReceivedAt);
      }
    }

    Map<String, int>? parsedVectorClock;
    var rawVectorClock = json['vectorClock'];
    if (rawVectorClock != null) {
      if (rawVectorClock is String) {
        try {
          parsedVectorClock = Map<String, int>.from(jsonDecode(rawVectorClock));
        } catch (e) {
          // Игнорируем ошибки парсинга
        }
      } else if (rawVectorClock is Map) {
        parsedVectorClock = Map<String, int>.from(rawVectorClock);
      }
    }

    int? seqNum;
    if (json['sequence_number'] != null) {
      seqNum = json['sequence_number'] is int
          ? json['sequence_number'] as int
          : int.tryParse(json['sequence_number'].toString());
    } else if (json['sequenceNumber'] != null) {
      seqNum = json['sequenceNumber'] is int
          ? json['sequenceNumber'] as int
          : int.tryParse(json['sequenceNumber'].toString());
    }
    final prevHash = json['previous_hash']?.toString() ?? json['previousHash']?.toString();
    final forkOf = json['fork_of_id']?.toString() ?? json['forkOfId']?.toString();

    final isLocal = json['isLocal'] == true;
    final crdtId = json['crdtId']?.toString();
    final replyToId = json['reply_to_id']?.toString() ?? json['replyToId']?.toString();
    final replyPreview = json['reply_preview']?.toString() ?? json['replyPreview']?.toString();

    return ChatMessage(
      id: json['id']?.toString() ?? json['h']?.toString() ?? '',
      clientTempId: json['clientTempId']?.toString(),
      content: json['content'] ?? '',
      senderId: json['senderId']?.toString() ?? '',
      senderUsername: json['senderUsername'] ?? 'User',
      createdAt: parsedDate,
      receivedAt: parsedReceivedAt,
      vectorClock: parsedVectorClock,
      sequenceNumber: seqNum,
      previousHash: prevHash?.isEmpty == true ? null : prevHash,
      forkOfId: forkOf?.isEmpty == true ? null : forkOf,
      isLocal: isLocal,
      crdtId: crdtId?.isEmpty == true ? null : crdtId,
      replyToId: replyToId?.isEmpty == true ? null : replyToId,
      replyPreview: replyPreview?.isEmpty == true ? null : replyPreview,
      status: json['status'] ?? 'SENT',
      contentPendingDecrypt: json['contentPendingDecrypt'] == true,
    );
  }

  /// [Optimistic] Replace with updated status/crdtId/isLocal without changing list order.
  ChatMessage copyWith({String? status, String? crdtId, bool? isLocal, String? replyToId, String? replyPreview, String? content, bool? contentPendingDecrypt}) {
    return ChatMessage(
      id: id,
      clientTempId: clientTempId,
      content: content ?? this.content,
      senderId: senderId,
      senderUsername: senderUsername,
      createdAt: createdAt,
      receivedAt: receivedAt,
      replyToId: replyToId ?? this.replyToId,
      replyPreview: replyPreview ?? this.replyPreview,
      vectorClock: vectorClock,
      sequenceNumber: sequenceNumber,
      previousHash: previousHash,
      forkOfId: forkOfId,
      status: status ?? this.status,
      hasWarning: hasWarning,
      isLocal: isLocal ?? this.isLocal,
      crdtId: crdtId != null ? crdtId : this.crdtId,
      contentPendingDecrypt: contentPendingDecrypt ?? this.contentPendingDecrypt,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'clientTempId': clientTempId,
      'content': content,
      'senderId': senderId,
      'senderUsername': senderUsername,
      'createdAt': createdAt.toIso8601String(),
      'receivedAt': receivedAt?.toIso8601String(),
      'vectorClock': vectorClock != null ? jsonEncode(vectorClock) : null,
      'status': status,
    };
    if (sequenceNumber != null) m['sequenceNumber'] = sequenceNumber;
    if (previousHash != null) m['previousHash'] = previousHash;
    if (forkOfId != null) m['forkOfId'] = forkOfId;
    return m;
  }
}

class ConversationScreen extends StatefulWidget {
  final String friendId;
  final String friendName;
  final String? chatRoomId;

  const ConversationScreen({
    super.key,
    required this.friendId,
    required this.friendName,
    this.chatRoomId,
  });

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

/// [UI] Message grouping position for bubble styling only. Computed in builder.
enum GroupPosition { single, first, middle, last }

/// [UI] Single message bubble. Grouping, emoji detection, and visual render only.
/// Scroll, setState, transport, CRDT stay in ConversationScreen.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final int index;
  final List<ChatMessage> messages;
  final String? currentUserId;
  /// Только отображение: смещение mesh-оценки часов для чужих сообщений ([MeshClockDisplayAdjust]).
  final DateTime Function(ChatMessage message) displayTimeForBubble;
  final VoidCallback? onRetry;
  /// При тапе по нику отправителя (только для чужих сообщений).
  final void Function(String senderId, String? senderUsername)? onSenderTap;
  /// Долгое нажатие — «Ответить» (не меняет транспорт).
  final VoidCallback? onLongPress;

  static final DateFormat _bubbleTimeFormat = DateFormat('HH:mm');

  const MessageBubble({
    super.key,
    required this.message,
    required this.index,
    required this.messages,
    required this.currentUserId,
    required this.displayTimeForBubble,
    this.onRetry,
    this.onSenderTap,
    this.onLongPress,
  });

  static GroupPosition getGroupPosition(List<ChatMessage> list, int index) {
    if (index < 0 || index >= list.length) return GroupPosition.single;
    final current = list[index];
    final prev = index > 0 ? list[index - 1] : null;
    final next = index + 1 < list.length ? list[index + 1] : null;
    const maxGapMinutes = 5;
    bool belongsWith(ChatMessage? a, ChatMessage? b) {
      if (a == null || b == null) return false;
      if (a.senderId != b.senderId) return false;
      final gap = b.createdAt.difference(a.createdAt).inMinutes.abs();
      return gap < maxGapMinutes;
    }
    final hasPrev = belongsWith(prev, current);
    final hasNext = belongsWith(current, next);
    if (!hasPrev && !hasNext) return GroupPosition.single;
    if (hasPrev && hasNext) return GroupPosition.middle;
    if (hasPrev) return GroupPosition.last;
    return GroupPosition.first;
  }

  static (BorderRadius, double, bool, double) groupStyle(
      GroupPosition pos, bool isMe, bool emojiOnly) {
    const r = 15.0;
    const rSmall = 4.0;
    const rEmoji = 20.0;
    const rSmallEmoji = 6.0;
    final R = emojiOnly ? rEmoji : r;
    final rs = emojiOnly ? rSmallEmoji : rSmall;
    switch (pos) {
      case GroupPosition.single:
        return (BorderRadius.circular(R), 7.0, true, 0.0);
      case GroupPosition.first:
        return (
          BorderRadius.only(
            topLeft: Radius.circular(R),
            topRight: Radius.circular(R),
            bottomLeft: Radius.circular(rs),
            bottomRight: Radius.circular(rs),
          ),
          4.0,
          true,
          0.0,
        );
      case GroupPosition.middle:
        return (BorderRadius.all(Radius.circular(rs)), 1.5, false, 0.0);
      case GroupPosition.last:
        return (
          BorderRadius.only(
            topLeft: Radius.circular(rs),
            topRight: Radius.circular(rs),
            bottomLeft: Radius.circular(R),
            bottomRight: Radius.circular(R),
          ),
          1.0,
          false,
          5.0,
        );
    }
  }

  static bool isEmojiOnly(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final emojiRegex = RegExp(
      r'^(?:\p{Emoji_Presentation}|\p{Emoji}\uFE0F)(?:\s?(?:\p{Emoji_Presentation}|\p{Emoji}\uFE0F)){0,2}$',
      unicode: true,
    );
    return emojiRegex.hasMatch(trimmed);
  }

  static Widget _buildStatusIcon(String status) {
    final content = status == MessageStatus.sending
        ? const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 8),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white70,
                ),
              ),
            ],
          )
        : const SizedBox.shrink();
    return KeyedSubtree(key: ValueKey(status), child: content);
  }

  @override
  Widget build(BuildContext context) {
    final isMe = message.senderId == currentUserId;
    final emojiOnly =
        !message.contentPendingDecrypt && isEmojiOnly(message.content);
    final pos = getGroupPosition(messages, index);
    // Emoji-only: always render as single (no grouped look).
    final effectivePos = emojiOnly ? GroupPosition.single : pos;
    final (radius, verticalPadding, showSenderName, bottomMargin) =
        groupStyle(effectivePos, isMe, emojiOnly);

    Widget content = Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showSenderName && !isMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: InkWell(
                  onTap: onSenderTap != null
                      ? () => onSenderTap!(message.senderId, message.senderUsername)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                    child: Text(
                      '${message.senderUsername} >',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedOpacity(
              opacity: message.status == MessageStatus.sending ? 0.7 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: EdgeInsets.all(emojiOnly ? 8 : 12),
                decoration: BoxDecoration(
                  color: isMe
                      ? Colors.redAccent.withOpacity(0.8)
                      : const Color(0xFF1A1A1A),
                  borderRadius: radius,
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.replyToId != null && (message.replyPreview?.isNotEmpty ?? false))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(6),
                            border: Border(left: BorderSide(color: Colors.redAccent.withOpacity(0.6), width: 2)),
                          ),
                          child: Text(
                            message.replyPreview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                    Flexible(
                      child: message.contentPendingDecrypt
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white.withOpacity(0.65),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '…',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.5),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              message.content,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: emojiOnly ? 40 : 14,
                              ),
                              textAlign: emojiOnly ? TextAlign.center : null,
                            ),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _buildStatusIcon(message.status),
                    ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (effectivePos == GroupPosition.single ||
                effectivePos == GroupPosition.last) ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment:
                    isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  Text(
                    _bubbleTimeFormat.format(displayTimeForBubble(message)),
                    style: const TextStyle(
                        color: Colors.white24, fontSize: 9),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 6),
                    if (message.status == MessageStatus.failed)
                      InkWell(
                        onTap: onRetry,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.refresh,
                                  color: Colors.redAccent, size: 16),
                              SizedBox(width: 4),
                              Text('Retry',
                                  style: TextStyle(
                                      color: Colors.redAccent, fontSize: 10)),
                            ],
                          ),
                        ),
                      )
                    else
                      Text(
                        MessageStatus.getDisplayText(message.status),
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 8),
                      ),
                  ],
                ],
              ),
            ],
      ],
    );
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: verticalPadding,
        bottom: verticalPadding + bottomMargin,
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          child: content,
        ),
      ),
    );
  }
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final GhostController _ghostController = GhostController();
  final ScrollController _scrollController = ScrollController();
  final ApiService _apiService = ApiService();
  final Set<String> _processedIds = {};

  StreamSubscription? _socketSubscription;
  StreamSubscription? _meshSubscription;
  String? _chatId;
  String? _currentUserId;
  /// Старые `dm_*` в SQLite до выравнивания с mesh — подмешиваем в историю.
  final Set<String> _dmHistoryMergeIds = {};

  bool _isKeyboardVisible = false;
  List<ChatMessage> _messages = [];
  bool _isLoadingHistory = true;
  /// Смещение для [LocalDatabaseService.getMessagesPaged] (уже загружено «сверху» по DESC).
  int _historySqlOffset = 0;
  bool _hasMoreOlderMessages = true;
  bool _isLoadingOlderMessages = false;
  bool _isLocalMode = false;
  bool _isSending = false;
  RoomState _roomState = RoomState.active;

  PanicPhase _panicPhase = PanicPhase.normal;
  TimedPanicController? _panicController;
  bool _showPanicRevealButton = false;

  /// [UX] Show "↓ New messages" when user scrolled up and a new message arrived. Cleared on tap or after safeAutoScroll.
  bool _hasNewMessagesWhenNotNearBottom = false;

  /// EMUI: `GestureDetector.onTap` иногда не срабатывает после AFK; дублируем открытие клавиатуры через pointer.
  Offset? _emitFieldPointerDown;

  /// Отдельная зона для кнопки «клавиатура» — не смешивать с полем ввода (Huawei).
  Offset? _keyboardOpenPointerDown;

  /// Первый заход в чат: последние N (как в Telegram — остальное по скроллу вверх).
  static const int _kConversationInitialLimit = 28;
  /// BEACON_NEARBY: расшифровка пачками после первого кадра (не блокировать спиннер).
  static const int _kNearbyDecryptBatchSize = 4;
  int _nearbyDecryptGen = 0;
  /// Подгрузка более старых сообщений при скролле к верху.
  static const int _kConversationOlderPageSize = 32;
  /// Потолок сообщений в памяти списка (как раньше ~450).
  static const int _kConversationHistoryMax = 450;
  /// Порог от верха списка для запроса старой истории.
  static const double _kLoadOlderScrollPx = 320;

  /// Локальная метка времени последней мутации истории (см. [LocalDatabaseService.getChatHistorySnapshot]).
  String _localHistoryUpdatedLabel = '';

  /// Последняя CRDT-синхронизация с соседом (mesh), если движок зарегистрирован.
  String _meshCrdtSyncLabel = '';

  /// Ответ на сообщение (только UI + БД; транспорт не меняется).
  ChatMessage? _replyingTo;

  /// Фаза 3 DR: только для `dm_*` (см. [ratchetEligibleChatId]).
  bool _drHandshakeActive = false;
  bool _drWireV1Enabled = false;
  bool _drSettingsBusy = false;
  String _drRootSourceHint = '';
  /// Фаза 6: отображение доверия (TOFU / bundle / свой Ed25519).
  String _drTofuPeerHint = '';
  String _drPeerBundleHint = '';
  String _drMyEd25519Hint = '';
  bool _pairingProximityHintHeld = false;
  /// Сколько исходящих сообщений осталось до ротации ключа (DH); `null` если не DM или не DH-корень.
  int? _dmMessagesUntilRotation;

  static final DateFormat _localHistoryTimeFormat = DateFormat('dd.MM.yyyy HH:mm');

  /// Время под пузырьком: для mesh применяется [MeshClockDisplayAdjust] (только UI).
  /// Личка mesh: ввод заблокирован, пока нет завершённого DR_DH (X25519).
  bool get _dmMeshComposerLocked {
    final cid = _chatId;
    if (cid == null || !ratchetEligibleChatId(cid)) return false;
    return !_drHandshakeActive;
  }

  DateTime _bubbleDisplayTime(ChatMessage m) {
    if (!locator.isRegistered<MeshClockDisplayAdjust>()) return m.createdAt;
    return locator<MeshClockDisplayAdjust>().bubbleDisplayTime(
      createdAt: m.createdAt,
      senderId: m.senderId,
      localUserId: _currentUserId,
    );
  }

  List<ChatMessage> _mergeMessagesById(
      List<ChatMessage> primary, Iterable<ChatMessage> more) {
    final byId = <String, ChatMessage>{};
    for (final m in primary) {
      byId[m.id] = m;
    }
    for (final m in more) {
      byId.putIfAbsent(m.id, () => m);
    }
    return byId.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> _refreshLocalHistoryMeta() async {
    if (_chatId == null) return;
    final snap = await LocalDatabaseService().getChatHistorySnapshot(_chatId!);
    if (!mounted) return;
    final String line;
    if (snap.lastMutationAtMs <= 0) {
      line = 'История на устройстве: пока нет отметки обновления';
    } else {
      final t = _localHistoryTimeFormat.format(
          DateTime.fromMillisecondsSinceEpoch(snap.lastMutationAtMs));
      line = 'История на устройстве обновлена: $t';
    }
    String meshLine = '';
    if (locator.isRegistered<MeshCoreEngine>()) {
      final t = locator<MeshCoreEngine>().lastCrdtChatSyncTime;
      meshLine = t == null
          ? 'Соседи (mesh): синхронизация в этой сессии ещё не завершалась'
          : 'Соседи (mesh), последний обмен: ${_localHistoryTimeFormat.format(t)}';
    }
    setState(() {
      _localHistoryUpdatedLabel = line;
      _meshCrdtSyncLabel = meshLine;
    });
  }

  void _onPanicPhaseChanged() {
    if (!mounted || _panicController == null) return;
    final next = _panicController!.phase;
    // [TimedPanicController.recordActivity] вызывает notifyListeners() даже если фаза не менялась
    // (только сброс idle-таймера). setState в этот момент из ScrollNotification → «Build scheduled during frame».
    final mustHideKeyboard =
        next != PanicPhase.normal && _isKeyboardVisible;
    if (next == _panicPhase && !mustHideKeyboard) return;
    setState(() {
      _panicPhase = next;
      if (next != PanicPhase.normal) _isKeyboardVisible = false;
    });
  }

  void _onPanicDisplayChanged() {
    if (mounted) {
      _updatePanicRevealButton();
      if (locator.isRegistered<PanicDisplayService>() &&
          locator<PanicDisplayService>().showRealContent) {
        _reloadMessagesForReveal();
      }
    }
  }

  Future<void> _updatePanicRevealButton() async {
    final panic = await PanicService.isPanicProtocolActivated();
    final hasService = locator.isRegistered<PanicDisplayService>();
    final show = panic && hasService && !locator<PanicDisplayService>().showRealContent;
    if (mounted && _showPanicRevealButton != show) {
      setState(() => _showPanicRevealButton = show);
    }
  }

  Future<void> _reloadMessagesForReveal() async {
    if (_chatId == null) return;
    final db = LocalDatabaseService();
    // После снятия паники показываем широкое окно расшифрованной истории.
    final history = await db.getMessages(
      _chatId!,
      limit: _kConversationHistoryMax,
      substituteContent: false,
    );
    if (mounted) {
      setState(() {
        _messages = history;
        _historySqlOffset = history.length;
        _hasMoreOlderMessages = history.length >= _kConversationHistoryMax;
      });
      unawaited(_refreshLocalHistoryMeta());
    }
  }

  static int _compareChatMessages(ChatMessage a, ChatMessage b) {
    final timeCompare = a.createdAt.compareTo(b.createdAt);
    if (timeCompare != 0) return timeCompare;
    final authorCompare = a.senderId.compareTo(b.senderId);
    if (authorCompare != 0) return authorCompare;
    return a.id.compareTo(b.id);
  }

  void _insertMessageInOrder(ChatMessage msg) {
    var lo = 0;
    var hi = _messages.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compareChatMessages(_messages[mid], msg) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _messages.insert(lo, msg);
  }

  Future<void> _loadOlderMessages() async {
    if (_chatId == null || _isLoadingHistory) return;
    if (_isLoadingOlderMessages) return;
    if (!_hasMoreOlderMessages) return;
    if (_messages.length >= _kConversationHistoryMax) return;

    final batchLimit = math.min(
      _kConversationOlderPageSize,
      _kConversationHistoryMax - _messages.length,
    );
    if (batchLimit <= 0) return;

    _isLoadingOlderMessages = true;
    if (mounted) setState(() {});

    final oldPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    final oldMax = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    try {
      final substitute = await _shouldSubstitute();
      if (!mounted) return;
      final db = LocalDatabaseService();
      final older = await db.getMessagesPaged(
        _chatId!,
        batchLimit,
        _historySqlOffset,
        substituteContent: substitute,
      );
      if (!mounted) return;

      if (older.isEmpty) {
        if (mounted) setState(() => _hasMoreOlderMessages = false);
        return;
      }

      if (mounted) {
        setState(() {
          _messages = [...older, ..._messages];
          _historySqlOffset += older.length;
          _hasMoreOlderMessages = older.length >= batchLimit &&
              _messages.length < _kConversationHistoryMax;
        });
      }

      if (_scrollController.hasClients && oldMax > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          final newMax = _scrollController.position.maxScrollExtent;
          final delta = newMax - oldMax;
          final target = oldPixels + delta;
          final pos = _scrollController.position;
          _scrollController.jumpTo(
            target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
          );
        });
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('⚠️ [Chat] _loadOlderMessages: $e');
        debugPrint('$st');
      }
      if (mounted) setState(() => _hasMoreOlderMessages = false);
    } finally {
      _isLoadingOlderMessages = false;
      if (mounted) setState(() {});
    }
  }

  /// Подгрузка старых сообщений по позиции скролла (надёжнее, чем только ScrollUpdateNotification).
  void _maybeLoadOlderOnScroll() {
    if (!mounted) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels <= _kLoadOlderScrollPx &&
        _hasMoreOlderMessages &&
        !_isLoadingOlderMessages &&
        !_isLoadingHistory &&
        _messages.length < _kConversationHistoryMax) {
      unawaited(_loadOlderMessages());
    }
  }

  void _showRevealCodeDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Показать реальные сообщения'),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Введите код'),
          onSubmitted: (_) => _submitRevealCode(controller.text, ctx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => _submitRevealCode(controller.text, ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitRevealCode(String code, BuildContext dialogContext) async {
    if (!locator.isRegistered<PanicDisplayService>()) return;
    final ok = await locator<PanicDisplayService>().revealIfCodeMatches(code);
    if (mounted && dialogContext.mounted) {
      Navigator.pop(dialogContext);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Реальные сообщения показаны')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Неверный код'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadOlderOnScroll);
    WidgetsBinding.instance.addObserver(this);
    if (locator.isRegistered<TimedPanicController>()) {
      _panicController = locator<TimedPanicController>();
      _panicPhase = _panicController!.phase;
      _panicController!.addListener(_onPanicPhaseChanged);
    }
    _updatePanicRevealButton();
    if (locator.isRegistered<PanicDisplayService>()) {
      locator<PanicDisplayService>().addListener(_onPanicDisplayChanged);
    }
    // 🔥 FIX: Скрываем системную навигацию при инициализации экрана чата
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top], // Показываем только статус-бар
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    SecurityService.enableSecureMode(); // Защита от скриншотов
    // Ensure SESSION (ApiService, MeshCoreEngine) so locator<> never throws on this screen.
    if (!locator.isRegistered<MeshCoreEngine>()) {
      if (!locator.isRegistered<VaultInterface>()) {
        setupCoreLocator(AppMode.REAL);
      }
      setupSessionLocator(AppMode.REAL);
    }
    _initializeChat();
    _updateRoomState();
    // Слушаем изменения сетевого статуса
    NetworkMonitor().onRoleChanged.listen((_) => _updateRoomState());
  }

  /// Huawei/EMUI: после background → resume часто сбрасывают navigation bar и «теряют»
  /// hit-test по InkWell у кастомной клавиатуры. Повторяем immersive UI и форсируем rebuild.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Сброс Ghost Keyboard только при реальном уходе в фон. НЕ используем [inactive]:
    // на Huawei/EMUI при тапах, жестах и системных оверлеях часто приходит краткий inactive —
    // клавиатура «пропадает», хотя приложение на экране.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (mounted && _isKeyboardVisible) {
        setState(() => _isKeyboardVisible = false);
      }
    }
    if (state != AppLifecycleState.resumed) return;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// Открыть GhostKeyboard (не toggle — избегаем рассинхрона после AFK/OEM).
  void _openGhostKeyboard() {
    if (_panicPhase != PanicPhase.normal) return;
    if (_dmMeshComposerLocked) return;
    // Huawei/EMUI: setState из onTap/onPointerUp иногда отбрасывается ареной жестов — выносим на следующий микротаск.
    Future<void>.microtask(() {
      if (!mounted || _panicPhase != PanicPhase.normal) return;
      setState(() => _isKeyboardVisible = true);
      // Двойной кадр: после появления панели EMUI не всегда обновляет hit-test.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      });
    });
  }

  void _onEmitFieldPointerUp(Offset position, {required bool inputDisabled}) {
    if (inputDisabled || _panicPhase != PanicPhase.normal) return;
    final start = _emitFieldPointerDown;
    _emitFieldPointerDown = null;
    if (start == null) return;
    if ((position - start).distance < 32) {
      _openGhostKeyboard();
    }
  }

  void _closeGhostKeyboard() {
    if (!_isKeyboardVisible) return;
    setState(() => _isKeyboardVisible = false);
  }

  void _updateRoomState() {
    if (!locator.isRegistered<MeshCoreEngine>()) {
      if (mounted)
        setState(() {
          _roomState = RoomStateHelper.fromNetworkStatus(
              hasInternet: false, isSyncing: false);
        });
      return;
    }
    final networkMonitor = NetworkMonitor();
    final hasInternet = networkMonitor.currentRole == MeshRole.BRIDGE;
    final mesh = locator<MeshCoreEngine>();
    final isSyncing = mesh.isP2pConnected;

    if (mounted) {
      setState(() {
        _roomState = RoomStateHelper.fromNetworkStatus(
          hasInternet: hasInternet,
          isSyncing: isSyncing,
        );
      });
    }
  }

  Future<void> _initializeChat() async {
    final db = LocalDatabaseService();
    // OFFLINE SAFE: единый источник user_id (Cloud или Ghost). BEACON FIX: после выхода/входа Ghost должен видеть свои сообщения.
    _currentUserId = await getCurrentUserIdSafe();
    if (!mounted) return;
    if (_currentUserId == null || _currentUserId!.isEmpty) {
      if (mounted) setState(() => _isLoadingHistory = false);
      return;
    }

    _dmHistoryMergeIds.clear();

    // 2. УНИФИКАЦИЯ КАНАЛА (The ID Unifier)
    if (widget.friendId == "GLOBAL" ||
        widget.chatRoomId == "THE_BEACON_GLOBAL") {
      _chatId = "THE_BEACON_GLOBAL";
    } else if (widget.chatRoomId == "BEACON_NEARBY" || widget.friendId == "BEACON_NEARBY") {
      _chatId = "BEACON_NEARBY";
    } else if (widget.chatRoomId != null && BeaconCountryHelper.isBeaconChat(widget.chatRoomId)) {
      _chatId = widget.chatRoomId!; // THE_BEACON_XX по стране
    } else if (widget.chatRoomId != null && widget.chatRoomId!.startsWith('dm_')) {
      // Канонический dm как в mesh: GHOST_ / короткий mesh-id дают один hash после [meshStableIdForDm].
      final stable = canonicalDirectChatId(
        meshStableIdForDm(_currentUserId!),
        meshStableIdForDm(widget.friendId),
      );
      final opened = normalizeDmChatId(widget.chatRoomId!);
      _chatId = stable;
      if (opened != normalizeDmChatId(stable)) {
        _dmHistoryMergeIds.add(opened);
      }
    } else {
      _chatId =
          RoomIdNormalizer.canonicalDmRoomId(_currentUserId!, widget.friendId);
    }

    // Реал-тайм: [messageStream] — broadcast без буфера. Если подписаться только после
    // await getMessages(), mesh-события за это время теряются → сообщение видно после перезахода.
    if (mounted) {
      _listenToChannels();
    }

    // 🔒 CORE must be ready so getMessages decrypts with same salt (after cold start / reinstall: camouflage → code → chat).
    // До 16×25ms ≈ 400ms — дальше getMessages всё равно вернёт [] до регистрации CORE.
    for (int i = 0; i < 16; i++) {
      if (locator.isRegistered<EncryptionService>() ||
          locator.isRegistered<VaultInterface>()) break;
      await Future.delayed(const Duration(milliseconds: 25));
      if (!mounted) return;
    }

    // 3. SQLITE + расшифровка: сначала последние [_kConversationInitialLimit], старее — по скроллу вверх.
    final substitute = await _shouldSubstitute();
    if (!mounted) return;

    List<ChatMessage> history;
    List<Map<String, dynamic>>? nearbyDeferredRows;
    if (_chatId == 'BEACON_NEARBY' && !substitute) {
      final fast = await db.getMessagesShellsForDeferredDecrypt(
        _chatId!,
        limit: _kConversationInitialLimit,
      );
      if (!mounted) return;
      history = fast.shells;
      nearbyDeferredRows = fast.rows;
    } else {
      history = await db.getMessages(
        _chatId!,
        limit: _kConversationInitialLimit,
        substituteContent: substitute,
      );
      if (_dmHistoryMergeIds.isNotEmpty) {
        for (final alt in _dmHistoryMergeIds) {
          final more = await db.getMessages(
            alt,
            limit: _kConversationInitialLimit,
            substituteContent: substitute,
          );
          history = _mergeMessagesById(history, more);
        }
        history.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (history.length > _kConversationInitialLimit) {
          history = history.sublist(
              history.length - _kConversationInitialLimit);
        }
      }
      if (!mounted) return;
    }
    setState(() {
      _messages = history;
      _historySqlOffset = history.length;
      _hasMoreOlderMessages = history.length >= _kConversationInitialLimit;
      _isLoadingHistory = false;
    });
    _scheduleScrollToBottom(jump: true);
    unawaited(_refreshLocalHistoryMeta());
    unawaited(_loadDrSettings());
    // Pairing hint должен быть active до авто INIT — иначе has_outbox в adv и очередь DR не синхронны со сканером.
    unawaited(_syncPairingProximityHintThenAutoDrInit());
    unawaited(_updatePanicRevealButton());
    // Черновик: восстановление по chatId (локально, не трогает транспорт).
    if (_chatId != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final draft = prefs.getString('draft_$_chatId');
        if (mounted && (draft?.isNotEmpty ?? false)) {
          _ghostController.setText(draft!);
        }
      } catch (_) {}
    }
    if (nearbyDeferredRows != null) {
      unawaited(_runNearbyDeferredDecrypt(nearbyDeferredRows));
    }
  }

  /// Пачками подставляет расшифрованный текст; новый заход / sync отменяет устаревшие итерации.
  Future<void> _runNearbyDeferredDecrypt(List<Map<String, dynamic>> rows) async {
    if (_chatId != 'BEACON_NEARBY' || rows.isEmpty) return;
    final gen = ++_nearbyDecryptGen;
    final db = LocalDatabaseService();
    for (var i = 0; i < rows.length; i += _kNearbyDecryptBatchSize) {
      if (!mounted || gen != _nearbyDecryptGen) return;
      final end = math.min(i + _kNearbyDecryptBatchSize, rows.length);
      final batch = rows.sublist(i, end);
      final decrypted = await db.decryptMessageMaps(_chatId!, batch);
      if (!mounted || gen != _nearbyDecryptGen) return;
      setState(() {
        final byId = {for (final m in decrypted) m.id: m};
        _messages = [
          for (final msg in _messages) byId[msg.id] ?? msg,
        ];
      });
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _syncPairingProximityHintThenAutoDrInit() async {
    await _syncPairingProximityHint();
    if (!mounted) return;
    await _maybeAutoSendDrDhInitAfterOpen();
  }

  /// Пока личка не имеет готового DR — держим оркестратор в режиме «pairing + BLE scan».
  Future<void> _syncPairingProximityHint() async {
    final cid = _chatId;
    if (cid == null || !ratchetEligibleChatId(cid)) return;
    if (widget.friendId == 'GLOBAL' || widget.friendId == 'BEACON_NEARBY') return;
    if (!locator.isRegistered<DoubleRatchetCoordinator>()) return;
    final coord = locator<DoubleRatchetCoordinator>();
    final st = await coord.loadState(cid);
    if (!mounted) return;
    if (st != null && st.handshakeComplete) {
      final src = st.opaque['drRootSource']?.toString() ?? '';
      if (src == kDoubleRatchetRootSourceDhBundle ||
          src == kDoubleRatchetRootSourceDh) {
        return;
      }
    }
    MeshPairingProximityHint.enter();
    _pairingProximityHintHeld = true;
    if (locator.isRegistered<BluetoothMeshService>()) {
      final bt = locator<BluetoothMeshService>();
      bt.requestAdvertisingIntentRefresh();
      unawaited(bt.ensureGattServerForPairing());
    }
    if (locator.isRegistered<MeshCoreEngine>()) {
      unawaited(locator<MeshCoreEngine>()
          .startNearbyPeersRadar(includeWifiDirect: false));
    }
  }

  /// Авто DR_DH_INIT при открытии лички. См. [MeshCoreEngine.startDrHandshakeWithPeerAfterFriendshipAccepted].
  Future<void> _maybeAutoSendDrDhInitAfterOpen() async {
    final cid = _chatId;
    if (cid == null || !ratchetEligibleChatId(cid)) return;
    if (widget.friendId.isEmpty ||
        widget.friendId == 'GLOBAL' ||
        widget.friendId == 'BEACON_NEARBY') {
      return;
    }
    if (!locator.isRegistered<MeshCoreEngine>()) return;
    await locator<MeshCoreEngine>()
        .startDrHandshakeWithPeerAfterFriendshipAccepted(widget.friendId);
    if (mounted) unawaited(_loadDrSettings());
  }

  Future<void> _loadDrSettings() async {
    if (_chatId == null || !ratchetEligibleChatId(_chatId!)) return;
    if (!locator.isRegistered<DoubleRatchetCoordinator>()) return;
    final coord = locator<DoubleRatchetCoordinator>();
    final st = await coord.loadState(_chatId!);
    final wire = await DoubleRatchetUserPrefs.wireV1EnabledForChat(_chatId!);
    final src = st?.opaque['drRootSource']?.toString() ?? '';
    String hint = '';
    if (st != null && st.handshakeComplete) {
      if (src == kDoubleRatchetRootSourceDhBundle) {
        hint = 'Корень: X25519 + pre-key (фаза 7)';
      } else if (src == kDoubleRatchetRootSourceDh) {
        hint = 'Корень: X25519 (DH)';
      } else if (src == kDoubleRatchetRootSourceLegacy) {
        hint = 'Корень: из AES чата (legacy)';
      }
    }
    final tofuPin = await DrDhPeerPins.getPin(widget.friendId);
    final bundleSeen = await DrPeerBundlePreKeyCache.getForPeer(widget.friendId);
    String tofuH = '';
    if (tofuPin != null && tofuPin.isNotEmpty) {
      tofuH = tofuPin.length > 16 ? '${tofuPin.substring(0, 14)}…' : tofuPin;
    }
    String bundleH = '';
    if (bundleSeen != null && bundleSeen.isNotEmpty) {
      bundleH =
          bundleSeen.length > 16 ? '${bundleSeen.substring(0, 14)}…' : bundleSeen;
    }
    String myEd = '';
    try {
      final signSvc = MessageSigningService();
      await signSvc.initialize();
      final pub = await signSvc.getPublicKeyBase64();
      if (pub != null && pub.isNotEmpty) {
        myEd = pub.length > 16 ? '${pub.substring(0, 14)}…' : pub;
      }
    } catch (_) {}
    int? rotationRemaining;
    if (st != null &&
        st.handshakeComplete &&
        _chatId != null &&
        ratchetEligibleChatId(_chatId!)) {
      if (src == kDoubleRatchetRootSourceDhBundle ||
          src == kDoubleRatchetRootSourceDh) {
        final c =
            await DmSessionUiGuard.getOutboundCountSinceHandshake(_chatId!);
        rotationRemaining =
            DmSessionUiGuard.outboundMessagesBeforeRotation - c;
        if (rotationRemaining < 0) rotationRemaining = 0;
      }
    }
    if (!mounted) return;
    setState(() {
      _drHandshakeActive = st?.handshakeComplete ?? false;
      _drWireV1Enabled = wire;
      _drRootSourceHint = hint;
      _drTofuPeerHint = tofuH;
      _drPeerBundleHint = bundleH;
      _drMyEd25519Hint = myEd;
      _dmMessagesUntilRotation = rotationRemaining;
    });
  }

  Future<void> _maybeRecordDmOutboundAndRotate() async {
    final cid = _chatId;
    if (cid == null || !ratchetEligibleChatId(cid)) return;
    if (!locator.isRegistered<DoubleRatchetCoordinator>()) return;
    final coord = locator<DoubleRatchetCoordinator>();
    final st = await coord.loadState(cid);
    final root = st?.opaque['drRootSource']?.toString() ?? '';
    final fromDh = root == kDoubleRatchetRootSourceDh ||
        root == kDoubleRatchetRootSourceDhBundle;
    if (st == null || !st.handshakeComplete || !fromDh) return;
    if (!locator.isRegistered<MeshCoreEngine>()) return;
    final rotated = await DmSessionUiGuard.recordOutboundSuccessfulSend(
      chatId: cid,
      onRotationRequired: () async {
        await locator<MeshCoreEngine>()
            .forceDmRekeyAfterOutboundQuota(widget.friendId);
      },
    );
    if (!mounted) return;
    if (rotated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Отправлено 10 сообщений: выполняется ротация ключа (DR_DH).',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
    await _loadDrSettings();
    if (rotated) {
      unawaited(_syncPairingProximityHint());
    }
  }

  Future<void> _drCopyPeerTofuFull(ScaffoldMessengerState messenger) async {
    final full = await DrDhPeerPins.getPin(widget.friendId);
    if (full == null || full.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Нет закреплённого TOFU-ключа пира')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: full));
    messenger.showSnackBar(
      const SnackBar(content: Text('Ed25519 пира скопирован в буфер')),
    );
  }

  Future<void> _drCopyPeerBundleFull(ScaffoldMessengerState messenger) async {
    final full = await DrPeerBundlePreKeyCache.getForPeer(widget.friendId);
    if (full == null || full.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Нет сохранённого pre-key bundle пира (после INIT/ACK)'),
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: full));
    messenger.showSnackBar(
      const SnackBar(content: Text('X25519 pre-key пира скопирован')),
    );
  }

  Future<void> _drCopyMyEd25519Full(ScaffoldMessengerState messenger) async {
    try {
      final signSvc = MessageSigningService();
      await signSvc.initialize();
      final pub = await signSvc.getPublicKeyBase64();
      if (pub == null || pub.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Ключ подписи недоступен')),
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: pub));
      messenger.showSnackBar(
        const SnackBar(content: Text('Ваш Ed25519 скопирован')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось прочитать ключ подписи')),
      );
    }
  }

  Future<void> _drResetTofuAndBundle(
    ScaffoldMessengerState messenger,
    void Function(void Function()) setModal,
  ) async {
    await DrDhPeerPins.clearPin(widget.friendId);
    await DrPeerBundlePreKeyCache.clearForPeer(widget.friendId);
    await _loadDrSettings();
    setModal(() {});
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'TOFU и кэш bundle сброшены. При смене устройства пира — снова INIT/ACK.',
        ),
      ),
    );
  }

  Future<void> _drRotateInstallPreKey(
    ScaffoldMessengerState messenger,
    void Function(void Function()) setModal,
  ) async {
    await DrInstallPreKey.rotateInstallPreKey();
    await _loadDrSettings();
    setModal(() {});
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Device pre-key сменён; новый уйдёт в следующем DR_DH INIT/ACK.',
        ),
      ),
    );
  }

  Future<void> _showDoubleRatchetSheet() async {
    if (_chatId == null || !ratchetEligibleChatId(_chatId!)) return;
    await _loadDrSettings();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModal) {
            return SafeArea(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    const Text(
                      'Усиленное шифрование (ratchet)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Один и тот же chatId у пары, сессия ratchet при необходимости у обоих. '
                      'Handshake идёт по mesh/gossip (и при наличии — как у вас настроен транспорт); '
                      'отдельного сервера ключей нет — без доставки DR_DH INIT/ACK пиры не договорятся. '
                      'Отправка сообщений crypto v1 — отдельным переключателем.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    ),
                    if (_drRootSourceHint.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _drRootSourceHint,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.tealAccent.shade100,
                        ),
                      ),
                    ],
                    const Divider(height: 20),
                    Text(
                      'Доверие к пиру (TOFU / pre-key)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Colors.grey.shade300,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Первый удачный Ed25519 пира для DR_DH запоминается (TOFU). '
                      'Друг сменил телефон или ключ — нажмите «Сбросить доверие» и снова X25519 handshake. '
                      'Ротация своего pre-key — если хотите, чтобы следующий INIT/ACK ушёл с новым bundle.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _drTofuPeerHint.isEmpty
                          ? 'TOFU пира: не закреплён'
                          : 'TOFU пира: $_drTofuPeerHint',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                    Text(
                      _drPeerBundleHint.isEmpty
                          ? 'Pre-key пира: нет в кэше'
                          : 'Pre-key пира: $_drPeerBundleHint',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                    Text(
                      _drMyEd25519Hint.isEmpty
                          ? 'Ваш Ed25519: —'
                          : 'Ваш Ed25519: $_drMyEd25519Hint',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                    Wrap(
                      spacing: 4,
                      runSpacing: 0,
                      children: [
                        TextButton(
                          onPressed: _drSettingsBusy
                              ? null
                              : () => _drCopyPeerTofuFull(messenger),
                          child: const Text('Копировать TOFU'),
                        ),
                        TextButton(
                          onPressed: _drSettingsBusy
                              ? null
                              : () => _drCopyPeerBundleFull(messenger),
                          child: const Text('Копировать pre-key пира'),
                        ),
                        TextButton(
                          onPressed: _drSettingsBusy
                              ? null
                              : () => _drCopyMyEd25519Full(messenger),
                          child: const Text('Копировать свой Ed25519'),
                        ),
                        TextButton(
                          onPressed: _drSettingsBusy
                              ? null
                              : () =>
                                  _drResetTofuAndBundle(messenger, setModal),
                          child: Text(
                            'Сбросить доверие',
                            style: TextStyle(color: Colors.orange.shade200),
                          ),
                        ),
                        TextButton(
                          onPressed: _drSettingsBusy
                              ? null
                              : () =>
                                  _drRotateInstallPreKey(messenger, setModal),
                          child: const Text('Ротация device pre-key'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.key_rounded),
                      title: const Text('X25519 handshake (фаза 4)'),
                      subtitle: const Text(
                        'INIT/ACK: v2 — Ed25519 + TOFU; с bundle — корень HKDF фазы 7 (T1‖T2‖T3 + pre-key). '
                        'Без bundle / старый пир — один X25519 DH (фаза 4). v1 wire — только HMAC; gossip TTL.',
                      ),
                      onTap: _drSettingsBusy
                          ? null
                          : () async {
                              setModal(() => _drSettingsBusy = true);
                              setState(() => _drSettingsBusy = true);
                              try {
                                if (!locator
                                        .isRegistered<DoubleRatchetCoordinator>() ||
                                    !locator.isRegistered<MeshCoreEngine>()) {
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Нужны mesh и координатор DR',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                final coord =
                                    locator<DoubleRatchetCoordinator>();
                                await coord.clearDhPendingIfStale(
                                  _chatId!,
                                  maxAge: const Duration(seconds: 90),
                                );
                                final pkt = await coord.buildDhInitPacket(
                                  _chatId!,
                                  widget.friendId,
                                );
                                if (!mounted) return;
                                if (pkt == null) {
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Не удалось подготовить INIT: проверьте chatId, user_id и что это личка dm_*. '
                                        'В debug смотрите лог [DR_DH] buildDhInitPacket.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                await locator<MeshCoreEngine>()
                                    .sendDrDhPacket(widget.friendId, pkt);
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Отправлен DR_DH_INIT. Дождитесь ACK по mesh/транспорту. '
                                      'Если подпись пира не сходится — «Сбросить доверие» и повторите.',
                                    ),
                                  ),
                                );
                                await _loadDrSettings();
                                setModal(() {});
                              } finally {
                                if (mounted) {
                                  setModal(() => _drSettingsBusy = false);
                                  setState(() => _drSettingsBusy = false);
                                }
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Сессия ratchet'),
                      subtitle: const Text('Локальный ключ из текущего AES чата'),
                      value: _drHandshakeActive,
                      onChanged: _drSettingsBusy
                          ? null
                          : (v) async {
                              setModal(() => _drSettingsBusy = true);
                              setState(() => _drSettingsBusy = true);
                              try {
                                final coord = locator<DoubleRatchetCoordinator>();
                                if (v) {
                                  final ok = await coord
                                      .bootstrapSymmetricFromLegacyDmKey(
                                    _chatId!,
                                    widget.friendId,
                                  );
                                  if (!mounted) return;
                                  if (!ok) {
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Не удалось включить (проверьте chatId и user_id)',
                                        ),
                                      ),
                                    );
                                  }
                                } else {
                                  await coord.clearSession(_chatId!);
                                  await DmSessionUiGuard.resetOutboundCount(
                                    _chatId!,
                                  );
                                  await DoubleRatchetUserPrefs.setWireV1ForChat(
                                    _chatId!,
                                    false,
                                  );
                                }
                                await _loadDrSettings();
                                setModal(() {});
                              } finally {
                                if (mounted) {
                                  setModal(() => _drSettingsBusy = false);
                                  setState(() => _drSettingsBusy = false);
                                }
                              }
                            },
                    ),
                    SwitchListTile(
                      title: const Text('Отправлять crypto v1'),
                      subtitle: const Text('Иначе только приём v1 от пира'),
                      value: _drWireV1Enabled,
                      onChanged: (!_drHandshakeActive || _drSettingsBusy)
                          ? null
                          : (v) async {
                              await DoubleRatchetUserPrefs.setWireV1ForChat(
                                _chatId!,
                                v,
                              );
                              await _loadDrSettings();
                              setModal(() {});
                            },
                    ),
                  ],
                ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<bool> _shouldSubstitute() async {
    if (!await PanicService.isPanicProtocolActivated()) return false;
    if (!locator.isRegistered<PanicDisplayService>()) return true;
    return !locator<PanicDisplayService>().showRealContent;
  }

  void _saveDraft() {
    if (_chatId == null) return;
    final text = _ghostController.value.trim();
    if (text.isEmpty) return;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('draft_$_chatId', text);
    });
  }

  void _listenToChannels() {
    _socketSubscription?.cancel();
    _meshSubscription?.cancel();
    EventBusService().off<ChatSyncCompletedEvent>(_onChatSyncCompleted);
    EventBusService().off<MessageReceivedEvent>(_onMessageBusOfflineMessage);

    if (_chatId == null) return;

    // --- 📡 КАНАЛ 1: CLOUD (WebSocket) ---
    _socketSubscription = WebSocketService().stream.listen((payload) {
      if (payload['type'] == 'newMessage') {
        final raw = payload['message'];
        if (raw is! Map) return;
        final msg = Map<String, dynamic>.from(raw);
        final room = (msg['chatId'] ?? msg['chatRoomId'])?.toString() ?? '';
        if (room.isEmpty) return;
        if (room == _chatId || RoomIdNormalizer.roomIdsMatch(room, _chatId)) {
          _processMessagePacket(msg, fromCloud: true);
        }
      }
    });

    // --- 👻 КАНАЛ 2: MESH + EventBus (OFFLINE_MSG дублируется из [PacketProcessor]; дедуп — [_processedIds]) ---
    if (locator.isRegistered<MeshCoreEngine>()) {
      if (kDebugMode) {
        debugPrint(
            "[BLE-DIAG] ConversationScreen: subscribing to messageStream (chatId=$_chatId)");
      }
      _meshSubscription = locator<MeshCoreEngine>()
          .messageStream
          .listen(_dispatchLiveMeshPacket);
    }

    EventBusService().on<ChatSyncCompletedEvent>(_onChatSyncCompleted);
    EventBusService().on<MessageReceivedEvent>(_onMessageBusOfflineMessage);
  }

  void _onMessageBusOfflineMessage(MessageReceivedEvent e) {
    final t = e.data['type']?.toString() ?? '';
    if (t != 'OFFLINE_MSG' && t != 'SOS') return;
    _dispatchLiveMeshPacket(Map<String, dynamic>.from(e.data));
  }

  void _dispatchLiveMeshPacket(Map<String, dynamic> packet) {
    if (!mounted || _chatId == null) return;

    if (packet['type'] == 'DR_DH_SESSION_OK') {
      final cid = packet['chatId']?.toString() ?? '';
      final cidOk = cid.isNotEmpty &&
          (cid == _chatId ||
              (_currentUserId != null &&
                  incomingDmMatchesMyChatWithPeer(
                      cid, _currentUserId!, widget.friendId)));
      if (cidOk) {
        unawaited(_loadDrSettings());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Сессия X25519 (DH) установлена'),
            ),
          );
        }
      }
      return;
    }

    final String incomingChatId =
        (packet['chatId'] ?? packet['chatRoomId'] ?? '').toString();
    final String senderId = (packet['senderId'] ?? "").toString();

    final bool dmWireMatch = _currentUserId != null &&
        incomingChatId.trim().startsWith('dm_') &&
        widget.friendId != 'GLOBAL' &&
        widget.friendId != 'BEACON_NEARBY' &&
        !BeaconCountryHelper.isBeaconChat(widget.friendId) &&
        (incomingDmMatchesMyChatWithPeer(
                incomingChatId, _currentUserId!, widget.friendId) ||
            (senderId.isNotEmpty &&
                incomingDmMatchesMyChatWithPeer(
                    incomingChatId, _currentUserId!, senderId)));

    final bool isMatch = RoomIdNormalizer.roomIdsMatch(incomingChatId, _chatId) ||
        (incomingChatId.toUpperCase() == "THE_BEACON_GLOBAL" &&
            (BeaconCountryHelper.isBeaconChat(_chatId) ||
                _chatId == "BEACON_NEARBY")) ||
        (incomingChatId == "BEACON_NEARBY" && _chatId == "BEACON_NEARBY") ||
        (incomingChatId == "BEACON_NEARBY" && _chatId == "THE_BEACON_GLOBAL") ||
        RoomIdNormalizer.normalizePeerId(senderId) ==
            RoomIdNormalizer.normalizePeerId(widget.friendId) ||
        dmWireMatch;

    if (kDebugMode) {
      debugPrint(
          "[BLE-DIAG] ConversationScreen: mesh packet chatId=$incomingChatId screen=$_chatId isMatch=$isMatch");
    }
    if (isMatch) {
      _processMessagePacket(packet, fromCloud: false);
    }
  }

  void _onChatSyncCompleted(ChatSyncCompletedEvent event) async {
    if (!mounted || _chatId == null) return;
    final match = RoomIdNormalizer.roomIdsMatch(event.chatId, _chatId) ||
        event.chatId == _chatId;
    if (!match) return;
    final db = LocalDatabaseService();
    final substitute = await _shouldSubstitute();
    List<ChatMessage> history;
    List<Map<String, dynamic>>? nearbyDeferredRows;
    if (_chatId == 'BEACON_NEARBY' && !substitute) {
      final fast = await db.getMessagesShellsForDeferredDecrypt(
        _chatId!,
        limit: _kConversationInitialLimit,
      );
      history = fast.shells;
      nearbyDeferredRows = fast.rows;
    } else {
      history = await db.getMessages(
        _chatId!,
        limit: _kConversationInitialLimit,
        substituteContent: substitute,
      );
    }
    if (mounted) {
      final anchor = _getTopVisibleMessageId();
      setState(() {
        _messages = history;
        _historySqlOffset = history.length;
        _hasMoreOlderMessages = history.length >= _kConversationInitialLimit;
      });
      _restoreAnchor(anchor);
      safeAutoScroll();
      unawaited(_refreshLocalHistoryMeta());
      if (nearbyDeferredRows != null) {
        unawaited(_runNearbyDeferredDecrypt(nearbyDeferredRows));
      }
    }
  }

  void _processMessagePacket(Map<String, dynamic> data,
      {required bool fromCloud}) async {
    final encryption = locator<EncryptionService>();
    final db = LocalDatabaseService();

    // 1. ДЕДУПЛИКАЦИЯ: канонический ID = h
    final String msgId = data['h']?.toString() ??
        data['clientTempId']?.toString() ??
        data['id']?.toString() ??
        '';
    if (msgId.isEmpty || _processedIds.contains(msgId)) return;
    _processedIds.add(msgId);

    // 2. ЗАЩИТА ОТ ЭХА
    if (data['senderId'] == _currentUserId) return;

    final wireRoom = normalizeDmChatId(
        (data['chatId'] ?? data['chatRoomId'] ?? '').toString());
    final senderSid = data['senderId']?.toString() ?? '';
    // Пишем в тот же chatRoomId, что у открытой лички в chat_rooms — иначе после рестарта
    // getMessages(_chatId) не видит входящие, сохранённые под другим dm_* от wire senderId.
    final String storageChatId = _chatId!;

    // 3. [Optimistic] Не дублировать: если уже есть локальная запись с этим crdtId — не создавать новую
    if (_messages.any((m) => m.crdtId == msgId)) return;

    String content = data['content']?.toString() ?? data['data']?.toString() ?? "";
    final String originalContent = content;

    // 3. РАСШИФРОВКА (E2EE): mesh in THE_BEACON_GLOBAL is always encrypted with shared key — decrypt so we never show ciphertext
    bool decryptFailed = false;
    final bool isEncryptedFlag = data['isEncrypted'] == true || data['isEncrypted'] == 1;
    final bool looksEncryptedPayload = content.isNotEmpty &&
        content.length >= 20 &&
        !content.contains(' ') &&
        !content.startsWith('[');
    final bool dmMeshMaybeCipher = !fromCloud &&
        _chatId != null &&
        _chatId!.toLowerCase().startsWith('dm_') &&
        looksEncryptedPayload;
    final bool shouldDecrypt = isEncryptedFlag ||
        dmMeshMaybeCipher ||
        (!fromCloud &&
            (BeaconCountryHelper.isBeaconChat(_chatId) ||
                _chatId == 'BEACON_NEARBY') &&
            looksEncryptedPayload);
    final substitute = await _shouldSubstitute();
    if (substitute) {
      content = neutralPhraseForId(msgId);
    } else if (shouldDecrypt) {
      try {
        final cv = parseTransportCryptoVersion(data['cryptoVersion']);
        final dh = normalizeDrHeader(data['drHeader']);
        late final List<String> decryptIds;
        if (!fromCloud &&
            wireRoom.startsWith('dm_') &&
            _currentUserId != null &&
            senderSid.isNotEmpty) {
          final extras = <String>[];
          if (widget.friendId.isNotEmpty &&
              widget.friendId != 'GLOBAL' &&
              widget.friendId != 'BEACON_NEARBY' &&
              !BeaconCountryHelper.isBeaconChat(widget.friendId)) {
            extras.add(widget.friendId);
          }
          try {
            final alias = await db.getDirectDmPeerStoredAlias(
                _currentUserId!, senderSid);
            if (alias != null && alias.isNotEmpty) extras.add(alias);
          } catch (_) {}
          final ordered = <String>[];
          void addDm(String id) {
            final n = normalizeDmChatId(id);
            if (n.startsWith('dm_') && !ordered.contains(n)) {
              ordered.add(n);
            }
          }

          addDm(storageChatId);
          try {
            addDm(await db.resolveDmStorageChatIdForMeshPacket(
              wireOrResolvedChatId: wireRoom,
              senderId: senderSid,
            ));
          } catch (_) {}
          for (final id in dmDecryptChatIdCandidatesMerged(
            wireChatId: wireRoom,
            myUserId: _currentUserId!,
            messageSenderId: senderSid,
            additionalPeerRepresentations: extras,
          )) {
            addDm(id);
          }
          decryptIds = ordered;
        } else {
          decryptIds = <String>[storageChatId];
        }
        String decrypted = '';
        final facade = locator.isRegistered<MessageCryptoFacade>()
            ? locator<MessageCryptoFacade>()
            : null;
        final encOnly = locator.isRegistered<EncryptionService>()
            ? encryption
            : null;
        for (final tryChat in decryptIds) {
          final attempt = await decryptChatPayloadForTransport(
            chatId: tryChat,
            ciphertext: content,
            cryptoVersion: cv,
            drHeader: dh,
            facade: facade,
            encryption: facade != null ? null : encOnly,
          );
          if (attempt.isNotEmpty) {
            decrypted = attempt;
            break;
          }
        }
        final dmDecryptOk = decrypted.isNotEmpty &&
            decrypted != kDecryptionFailurePlaceholder;
        content =
            dmDecryptOk ? decrypted : "[Secure Signal: Captured but Locked]";
        if (!dmDecryptOk) decryptFailed = true;
      } catch (e) {
        content = "[Secure Signal: Captured but Locked]";
        decryptFailed = true;
      }
    }

    final int tsMs = data['ts'] ??
        data['timestamp'] ??
        DateTime.now().millisecondsSinceEpoch;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(tsMs);

    if (!fromCloud && locator.isRegistered<MeshClockDisplayAdjust>()) {
      locator<MeshClockDisplayAdjust>().observeRemoteSample(
        senderUnixMs: tsMs,
        localReceiveUnixMs: DateTime.now().millisecondsSinceEpoch,
        senderId: data['senderId']?.toString() ?? '',
        myUserId: _currentUserId,
      );
    }

    final newMessage = ChatMessage(
      id: msgId,
      content: content,
      senderId: data['senderId'] ?? "GHOST",
      senderUsername: data['senderUsername'] ?? "User",
      createdAt: createdAt,
      status: fromCloud ? "CLOUD" : "MESH",
    );

    // 4. СОХРАНЕНИЕ: в режиме подмены — сохраняем encrypted; при неудачной расшифровке — исходный шифртекст.
    if (substitute && originalContent.isNotEmpty) {
      final msgToStore = ChatMessage(
        id: msgId,
        content: originalContent,
        senderId: data['senderId'] ?? "GHOST",
        senderUsername: data['senderUsername'] ?? "User",
        createdAt: createdAt,
        status: fromCloud ? "CLOUD" : "MESH",
      );
      await db.saveMessage(msgToStore, storageChatId, contentAlreadyEncrypted: true);
    } else if (decryptFailed && originalContent.isNotEmpty && originalContent.length >= 20 && !originalContent.contains(' ')) {
      final msgToStore = ChatMessage(
        id: msgId,
        content: originalContent,
        senderId: data['senderId'] ?? "GHOST",
        senderUsername: data['senderUsername'] ?? "User",
        createdAt: createdAt,
        status: fromCloud ? "CLOUD" : "MESH",
      );
      await db.saveMessage(msgToStore, storageChatId, contentAlreadyEncrypted: true);
    } else {
      await db.saveMessage(newMessage, storageChatId);
    }

    if (mounted) {
      final wasNearBottom = isNearBottom();
      setState(() {
        _insertMessageInOrder(newMessage);
        if (!wasNearBottom) _hasNewMessagesWhenNotNearBottom = true;
      });
      HapticFeedback.lightImpact();
      if (wasNearBottom) safeAutoScroll();
      if (locator.isRegistered<TimedPanicController>()) {
        locator<TimedPanicController>().recordActivity();
      }
      unawaited(_refreshLocalHistoryMeta());
    }
  }

  void _listenToComms() {
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();

    // --- 📡 КАНАЛ CLOUD (WebSocket) ---
    _socketSubscription = WebSocketService().stream.listen((data) async {
      if (data['type'] == 'newMessage' &&
          data['message']['chatRoomId'] == _chatId) {
        _handleIncomingData(data['message'], isFromCloud: true);
      }
    });

    // --- 👻 КАНАЛ MESH (P2P) ---
    if (locator.isRegistered<MeshCoreEngine>()) {
      if (kDebugMode) debugPrint("[BLE-DIAG] ConversationScreen: subscribing to messageStream (chatId=$_chatId)");
      _meshSubscription =
          locator<MeshCoreEngine>().messageStream.listen((offlineData) async {
        if (!mounted) return;

        final String incomingChatId = (offlineData['chatId'] ?? "").toString();
        final String incomingSenderId =
            (offlineData['senderId'] ?? "").toString();

        // Нормализация ID в ядре: сравнение по каноническому roomId
        // 🔥 BEACON cross-match: THE_BEACON_GLOBAL ↔ BEACON_NEARBY показываем в обоих чатах
        bool isMatch = RoomIdNormalizer.roomIdsMatch(incomingChatId, _chatId) ||
            (incomingChatId.toUpperCase() == "THE_BEACON_GLOBAL" &&
                widget.friendId == "GLOBAL") ||
            (incomingChatId.toUpperCase() == "THE_BEACON_GLOBAL" && _chatId == "BEACON_NEARBY") ||
            (incomingChatId == "BEACON_NEARBY" && _chatId == "THE_BEACON_GLOBAL") ||
            RoomIdNormalizer.normalizePeerId(incomingSenderId) ==
                RoomIdNormalizer.normalizePeerId(widget.friendId);

        if (kDebugMode) debugPrint("[BLE-DIAG] ConversationScreen: message received chatId=$incomingChatId currentScreenChatId=$_chatId isMatch=$isMatch");
        if (isMatch) {
          _handleIncomingData(offlineData, isFromCloud: false);
        } else if (incomingChatId.isNotEmpty &&
            _chatId != null &&
            incomingChatId.toUpperCase() != "THE_BEACON_GLOBAL") {
          debugPrint(
              "🚫 [UI] Filtered: Packet(${incomingChatId.length > 20 ? '${incomingChatId.substring(0, 20)}...' : incomingChatId}) doesn't match Screen($_chatId)");
        }
      });
    }
  }

  // Единый обработчик входящих данных
  void _handleIncomingData(Map<String, dynamic> data,
      {required bool isFromCloud}) async {
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();

    // Канонический ID: h, alias clientTempId/id (не генерировать из timestamp)
    final String msgId = data['h']?.toString() ??
        data['clientTempId']?.toString() ??
        data['id']?.toString() ??
        '';
    if (msgId.isEmpty) return;
    final String senderId = data['senderId'] ?? "Unknown";

    // Если это наше собственное сообщение, полученное обратно - обновляем статус
    if (senderId == _currentUserId && msgId.startsWith("temp_")) {
      final newStatus = isFromCloud
          ? MessageStatus.deliveredServer
          : MessageStatus.deliveredMesh;
      await db.updateMessageStatus(msgId, newStatus);
      // Обновляем статус в UI
      if (mounted) {
        setState(() {
          final existingMsg = _messages.firstWhere(
            (m) => m.id == msgId,
            orElse: () => ChatMessage(
                id: '', content: '', senderId: '', createdAt: DateTime.now()),
          );
          if (existingMsg.id == msgId) {
            existingMsg.status = isFromCloud
                ? MessageStatus.deliveredServer
                : MessageStatus.deliveredMesh;
          }
        });
      }
      return; // Не добавляем эхо своего сообщения
    }

    if (_processedIds.contains(msgId)) return;
    _processedIds.add(msgId);

    // Use 'content' or fallback to 'data' (e.g. BLE-assembled payload)
    String content = data['content']?.toString() ?? data['data']?.toString() ?? "";
    final String originalContent = content;

    // Расшифровка: always replace content with decrypted result so we never show ciphertext
    bool decryptFailed = false;
    if (data['isEncrypted'] == true || !isFromCloud) {
      try {
        final cv = parseTransportCryptoVersion(data['cryptoVersion']);
        final dh = normalizeDrHeader(data['drHeader']);
        final String decrypted;
        if (locator.isRegistered<MessageCryptoFacade>()) {
          decrypted = await locator<MessageCryptoFacade>().decryptForChat(
            chatId: _chatId!,
            ciphertext: content,
            cryptoVersion: cv,
            drHeader: dh,
          );
        } else {
          final key = await encryption.getChatKey(_chatId!);
          decrypted = await encryption.decrypt(content, key);
        }
        final decryptOk = decrypted.isNotEmpty &&
            decrypted != "[Secure message unavailable]";
        content = decryptOk ? decrypted : "[Secure Message Captured]";
        if (!decryptOk) decryptFailed = true;
      } catch (e) {
        content = "[Secure Message Captured]";
        decryptFailed = true;
      }
    }

    final now = DateTime.now();
    // Сортировка по ts (время создания), не по времени приёма
    final int tsMs =
        data['ts'] ?? data['timestamp'] ?? now.millisecondsSinceEpoch;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(tsMs);

    if (!isFromCloud && locator.isRegistered<MeshClockDisplayAdjust>()) {
      locator<MeshClockDisplayAdjust>().observeRemoteSample(
        senderUnixMs: tsMs,
        localReceiveUnixMs: DateTime.now().millisecondsSinceEpoch,
        senderId: senderId,
        myUserId: _currentUserId,
      );
    }

    // Парсим vector clock если есть
    Map<String, int>? vectorClock;
    if (data['vectorClock'] != null) {
      try {
        if (data['vectorClock'] is String) {
          vectorClock = Map<String, int>.from(jsonDecode(data['vectorClock']));
        } else if (data['vectorClock'] is Map) {
          vectorClock = Map<String, int>.from(data['vectorClock']);
        }
      } catch (e) {
        // Игнорируем ошибки парсинга
      }
    }

    final newMessage = ChatMessage(
      id: msgId,
      content: content,
      senderId: senderId,
      senderUsername: data['senderUsername'] ?? "User",
      createdAt: createdAt,
      receivedAt: now, // 📊 только для логов/статистики, НЕ для сортировки
      vectorClock: vectorClock, // 🔄 Только для синхронизации
      status: isFromCloud ? "SENT" : "MESH_LINK",
    );

    // При неудачной расшифровке сохраняем исходный шифртекст, чтобы не затирать БД плейсхолдером
    if (decryptFailed && originalContent.isNotEmpty && originalContent.length >= 20 && !originalContent.contains(' ')) {
      final msgToStore = ChatMessage(
        id: msgId,
        content: originalContent,
        senderId: senderId,
        senderUsername: data['senderUsername'] ?? "User",
        createdAt: createdAt,
        receivedAt: now,
        vectorClock: vectorClock,
        status: isFromCloud ? "SENT" : "MESH_LINK",
      );
      await db.saveMessage(msgToStore, _chatId!, contentAlreadyEncrypted: true);
    } else {
      await db.saveMessage(newMessage, _chatId!);
    }

    if (mounted) {
      final wasNearBottom = isNearBottom();
      HapticFeedback.lightImpact();
      setState(() {
        _insertMessageInOrder(newMessage);
        if (!wasNearBottom) _hasNewMessagesWhenNotNearBottom = true;
      });
      if (wasNearBottom) safeAutoScroll();
      if (locator.isRegistered<TimedPanicController>()) {
        locator<TimedPanicController>().recordActivity();
      }
    }
  }

  static int? _lastBeaconSendTimeMs;

  /// Задержка The Beacon: 60 сек при отправке в облако, 10 сек при только меш.
  int _beaconCooldownSec() {
    if (!locator.isRegistered<NetworkMonitor>()) return 10;
    final role = NetworkMonitor().currentRole;
    final hasLease = NetworkMonitor().hasValidBridgeLease;
    if (role == MeshRole.BRIDGE && hasLease) return 60;
    try {
      final router = RouterConnectionService().connectedRouter;
      if (router != null && router.hasInternet) return 60;
    } catch (_) {}
    return 10;
  }

  void _sendMessage() async {
    if (locator.isRegistered<TimedPanicController>()) {
      locator<TimedPanicController>().recordActivity();
      if (_panicPhase != PanicPhase.normal) return;
    }
    if (_dmMeshComposerLocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Личка по mesh: сначала завершите обмен ключами (DR_DH). '
              'Откройте «Усиленное шифрование» при необходимости.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    final text = _ghostController.value.trim();
    if (text.isEmpty || _isSending) return;
    // Задержка The Beacon: 60 сек (инет) / 10 сек (только меш)
    if (BeaconCountryHelper.isBeaconChat(_chatId)) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _lastBeaconSendTimeMs;
      final cooldownSec = _beaconCooldownSec();
      if (last != null) {
        final elapsedSec = (now - last) ~/ 1000;
        if (elapsedSec < cooldownSec && mounted) {
          final remain = cooldownSec - elapsedSec;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('В The Beacon можно отправить сообщение через $remain сек'),
              backgroundColor: Colors.orange[800],
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
      }
    }
    if (_currentUserId == null || _chatId == null) {
      if (locator.isRegistered<MeshCoreEngine>()) {
        locator<MeshCoreEngine>().addLog(
            "[OUTBOX] Send blocked: userId=${_currentUserId != null} chatId=${_chatId != null}");
      }
      return;
    }

    setState(() => _isSending = true);
    final db = LocalDatabaseService();
    final replyPreview = _replyingTo != null
        ? (_replyingTo!.content.length > 50 ? _replyingTo!.content.substring(0, 50) + '...' : _replyingTo!.content)
        : null;
    final replyToId = _replyingTo?.id;

    if (!locator.isRegistered<MeshCoreEngine>()) {
      final now = DateTime.now();
      final String tempId = "temp_${now.millisecondsSinceEpoch}";
      final myMsg = ChatMessage(
        id: tempId,
        content: text,
        senderId: _currentUserId!,
        senderUsername: "Me",
        createdAt: now,
        status: MessageStatus.sending,
        isLocal: true,
        replyToId: replyToId,
        replyPreview: replyPreview,
      );
      setState(() {
        _insertMessageInOrder(myMsg);
        _replyingTo = null;
      });
      _ghostController.clear();
      safeAutoScroll();
      await db.saveMessage(myMsg, _chatId!);
      unawaited(_refreshLocalHistoryMeta());
      await db.addToOutbox(myMsg, _chatId!);
      if (mounted)
        setState(() {
          myMsg.status = "OFFLINE_QUEUED";
          _isSending = false;
        });
      return;
    }
    final mesh = locator<MeshCoreEngine>();
    mesh.addLog(
        "[OUTBOX] Sending via sendAuto: chatId=$_chatId length=${text.length}");

    final now = DateTime.now();
    final String tempId = "temp_${now.millisecondsSinceEpoch}";

    final vectorClock = <String, int>{
      _currentUserId!: now.millisecondsSinceEpoch,
    };

    final myMsg = ChatMessage(
        id: tempId,
        content: text,
        senderId: _currentUserId!,
        senderUsername: "Me",
        createdAt: now,
        receivedAt: null,
        vectorClock: vectorClock,
        status: MessageStatus.sending,
        isLocal: true,
        crdtId: null,
        replyToId: replyToId,
        replyPreview: replyPreview);

    // Optimistic insert: show immediately, do not wait for transport
    setState(() {
      _insertMessageInOrder(myMsg);
      _replyingTo = null;
    });
    _ghostController.clear();
    safeAutoScroll();

    await db.saveMessage(myMsg, _chatId!);
    unawaited(_refreshLocalHistoryMeta());

    if (BeaconCountryHelper.isBeaconChat(_chatId)) {
      _lastBeaconSendTimeMs = DateTime.now().millisecondsSinceEpoch;
    }

    try {
      await mesh.sendAuto(
        content: text,
        chatId: _chatId,
        receiverName: widget.friendName,
        messageId: tempId,
      );

      final newStatus = mesh.isP2pConnected
          ? MessageStatus.deliveredMesh
          : (NetworkMonitor().currentRole == MeshRole.BRIDGE
              ? MessageStatus.deliveredServer
              : MessageStatus.deliveredMesh);

      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) _messages[i] = _messages[i].copyWith(status: newStatus, crdtId: tempId, isLocal: false);
        });
      }
      await db.updateMessageStatus(tempId, newStatus);
      await _maybeRecordDmOutboundAndRotate();
    } on DmMeshKeyAgreementRequiredException catch (_) {
      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) {
            _messages[i] = _messages[i].copyWith(status: MessageStatus.failed);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Личка по mesh: сначала обмен ключами (⋮ → усиленное шифрование → отправить INIT). '
              'Без X25519+Ed25519 сообщение не уходит — иначе перехватчик мог бы читать обманный «шифр».',
            ),
            duration: Duration(seconds: 7),
          ),
        );
      }
      mesh.addLog(
          '[OUTBOX] sendAuto blocked: DM mesh requires DR_DH session (X25519 root)');
    } catch (e) {
      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) _messages[i] = _messages[i].copyWith(status: MessageStatus.failed);
        });
      }
      mesh.addLog("[OUTBOX] sendAuto failed: $e → adding to outbox (fallback)");
      try {
        await db.addToOutbox(myMsg, _chatId!); // В инкубатор!
        mesh.addLog("[OUTBOX] Fallback addToOutbox OK: id=$tempId");
        print(
            "📤 [SEND] sendAuto failed → message in outbox, requesting auto-scan");
        if (locator.isRegistered<MeshCoreEngine>())
          locator<MeshCoreEngine>().requestAutoScanForOutbox();
      } catch (e2) {
        mesh.addLog("[OUTBOX] Fallback addToOutbox FAILED: $e2");
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Retry send for a failed message. Same temporaryLocalId, no new message.
  Future<void> _retryFailedMessage(ChatMessage message) async {
    if (message.status != MessageStatus.failed) return;
    if (_currentUserId == null || _chatId == null) return;
    if (!locator.isRegistered<MeshCoreEngine>()) return;
    final mesh = locator<MeshCoreEngine>();
    final db = LocalDatabaseService();
    final tempId = message.id;
    setState(() {
      final i = _messages.indexWhere((m) => m.id == tempId);
      if (i >= 0) _messages[i] = _messages[i].copyWith(status: MessageStatus.sending);
    });
    try {
      await mesh.sendAuto(
        content: message.content,
        chatId: _chatId,
        receiverName: widget.friendName,
        messageId: tempId,
      );
      final newStatus = mesh.isP2pConnected
          ? MessageStatus.deliveredMesh
          : (NetworkMonitor().currentRole == MeshRole.BRIDGE
              ? MessageStatus.deliveredServer
              : MessageStatus.deliveredMesh);
      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) _messages[i] = _messages[i].copyWith(status: newStatus, crdtId: tempId, isLocal: false);
        });
      }
      await db.updateMessageStatus(tempId, newStatus);
      await _maybeRecordDmOutboundAndRotate();
    } on DmMeshKeyAgreementRequiredException catch (_) {
      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) {
            _messages[i] = _messages[i].copyWith(status: MessageStatus.failed);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала завершите обмен ключами (DR_DH) для этой лички, затем повторите отправку.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          final i = _messages.indexWhere((m) => m.id == tempId);
          if (i >= 0) _messages[i] = _messages[i].copyWith(status: MessageStatus.failed);
        });
      }
      try {
        await db.addToOutbox(message, _chatId!);
        mesh.requestAutoScanForOutbox();
      } catch (_) {}
    }
  }

  // --- UI Виджеты ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 🔥 FIX: Убираем системную навигацию через extendBody
      extendBody: true,
      extendBodyBehindAppBar: false,
      // 🔥 FIX: Отключаем автоматическую подстройку под клавиатуру (для Ghost Keyboard)
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        actions: [
          if (_chatId != null && ratchetEligibleChatId(_chatId!))
            IconButton(
              icon: Icon(
                Icons.enhanced_encryption,
                color: _drHandshakeActive
                    ? Colors.lightGreenAccent
                    : Colors.white70,
              ),
              tooltip: 'Ratchet E2EE',
              onPressed: _drSettingsBusy ? null : _showDoubleRatchetSheet,
            ),
          if (_showPanicRevealButton)
            IconButton(
              icon: const Icon(Icons.lock_open),
              tooltip: 'Показать реальные сообщения',
              onPressed: _showRevealCodeDialog,
            ),
        ],
        title: GestureDetector(
          onLongPress: () {
            // Dev tool: Long press to open timeline debugger
            if (_chatId != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RoomTimelineDebugger(roomId: _chatId!),
                ),
              );
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      BeaconCountryHelper.isBeaconChat(_chatId)
                          ? 'THE BEACON · ${BeaconCountryHelper.beaconCountryDisplayName(_chatId)}'
                          : widget.friendName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    _roomState.shortText,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              Text(
                _roomState.displayText,
                style: TextStyle(
                  fontSize: 8,
                  color: _roomState == RoomState.active
                      ? Colors.green
                      : _roomState == RoomState.syncing
                          ? Colors.orange
                          : Colors.redAccent,
                  letterSpacing: 1,
                ),
              ),
              if (_localHistoryUpdatedLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  _localHistoryUpdatedLabel,
                  style: TextStyle(
                    fontSize: 7,
                    color: Colors.grey.shade600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              if (_meshCrdtSyncLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  _meshCrdtSyncLabel,
                  style: TextStyle(
                    fontSize: 7,
                    color: Colors.grey.shade700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      body: Listener(
        onPointerDown: (_) {
          if (locator.isRegistered<TimedPanicController>()) {
            locator<TimedPanicController>().recordActivity();
          }
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: ModuleStatusPanel(compact: true),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: MessengerExpectationsInfo.buildConversationExpansion(),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _isLoadingHistory
                      ? const Center(
                          child:
                              CircularProgressIndicator(color: Colors.cyanAccent))
                      : NotificationListener<ScrollNotification>(
                          onNotification: (ScrollNotification n) {
                            if (locator.isRegistered<TimedPanicController>()) {
                              locator<TimedPanicController>().recordActivity();
                            }
                            return false;
                          },
                          child: ListenableBuilder(
                            listenable:
                                locator.isRegistered<MeshClockDisplayAdjust>()
                                    ? locator<MeshClockDisplayAdjust>()
                                    : _noopListenableForClockUi,
                            builder: (context, _) {
                              return ListView.builder(
                                controller: _scrollController,
                                // Clamping: на части прошивок Bouncing/OEM-физика даёт рывки вместе с animateTo.
                                physics: const ClampingScrollPhysics(),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                cacheExtent: 400,
                                itemCount: _messages.length,
                                itemBuilder: (context, index) {
                                  final message = _messages[index];
                                  return KeyedSubtree(
                                    key: ValueKey(message.id),
                                    child: MessageBubble(
                                      message: message,
                                      index: index,
                                      messages: _messages,
                                      currentUserId: _currentUserId,
                                      displayTimeForBubble: _bubbleDisplayTime,
                                      onRetry: () =>
                                          _retryFailedMessage(message),
                                      onSenderTap:
                                          (senderId, senderUsername) {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => UserProfileScreen(
                                              userId: senderId,
                                              displayName: senderUsername,
                                            ),
                                          ),
                                        );
                                      },
                                      onLongPress: () {
                                        setState(() => _replyingTo = message);
                                      },
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                  if (!_isLoadingHistory && _isLoadingOlderMessages)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        minHeight: 2,
                        color: Colors.cyanAccent,
                        backgroundColor: Colors.white10,
                      ),
                    ),
                  if (_hasNewMessagesWhenNotNearBottom)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 12,
                      child: Center(
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(24),
                          color: Colors.redAccent.withOpacity(0.9),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () {
                              setState(() => _hasNewMessagesWhenNotNearBottom = false);
                              _scheduleScrollToBottom(jump: false);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.arrow_downward,
                                      color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Text("New messages",
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_dmMeshComposerLocked &&
                _chatId != null &&
                ratchetEligibleChatId(_chatId!))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Material(
                  color: Colors.deepOrange.shade900.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline,
                            color: Colors.orange.shade200, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Обмен ключами не завершён: дождитесь DR_DH или откройте «Усиленное шифрование».',
                            style: TextStyle(
                                color: Colors.orange.shade100, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_dmMessagesUntilRotation != null &&
                _dmMessagesUntilRotation! > 0 &&
                !_dmMeshComposerLocked &&
                _chatId != null &&
                ratchetEligibleChatId(_chatId!))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Material(
                  color: Colors.cyan.shade900.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.autorenew,
                            color: Colors.cyanAccent.shade100, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'До ротации ключа: $_dmMessagesUntilRotation сообщ.',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            _buildInputZone(),
            if (_isKeyboardVisible &&
                _panicPhase == PanicPhase.normal &&
                !_dmMeshComposerLocked)
              GhostKeyboard(controller: _ghostController, onSend: _sendMessage),
          ],
        ),
      ),
    );
  }

  Widget _buildInputZone() {
    final inputDisabled =
        _panicPhase != PanicPhase.normal || _dmMeshComposerLocked;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Color(0xFF0D0D0D)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyingTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border(left: BorderSide(color: Colors.redAccent.withOpacity(0.6), width: 2)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_replyingTo!.senderUsername ?? 'User'}: ${(_replyingTo!.replyPreview ?? _replyingTo!.content).length > 40 ? (_replyingTo!.replyPreview ?? _replyingTo!.content).substring(0, 40) + '...' : (_replyingTo!.replyPreview ?? _replyingTo!.content)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                            onPressed: () => setState(() => _replyingTo = null),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              if (!inputDisabled) ...[
                // EMUI: не использовать Tooltip — перехватывает/long-press мешает тапу. Только Listener + Semantics.
                Semantics(
                  button: true,
                  label: 'Клавиатура',
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _keyboardOpenPointerDown = e.position,
                    onPointerCancel: (_) => _keyboardOpenPointerDown = null,
                    onPointerUp: (e) {
                      final start = _keyboardOpenPointerDown;
                      _keyboardOpenPointerDown = null;
                      if (start == null) return;
                      if ((e.position - start).distance > 40) return;
                      _openGhostKeyboard();
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: _isKeyboardVisible
                            ? const Color(0x33FF3B30)
                            : const Color(0xFF1A1A1A),
                        border: Border.all(
                          color: _isKeyboardVisible
                              ? Colors.redAccent
                              : Colors.white24,
                          width: _isKeyboardVisible ? 1.5 : 1,
                        ),
                        boxShadow: _isKeyboardVisible
                            ? [
                                BoxShadow(
                                  color: Colors.redAccent.withValues(alpha: 0.2),
                                  blurRadius: 12,
                                  spreadRadius: 0,
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.keyboard_rounded,
                        color: _isKeyboardVisible
                            ? Colors.redAccent
                            : Colors.white70,
                        size: 26,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    if (!inputDisabled) _emitFieldPointerDown = e.position;
                  },
                  onPointerCancel: (_) => _emitFieldPointerDown = null,
                  onPointerUp: (e) =>
                      _onEmitFieldPointerUp(e.position, inputDisabled: inputDisabled),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: inputDisabled ? null : _openGhostKeyboard,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          )),
                      child: AnimatedBuilder(
                        animation: _ghostController,
                        builder: (context, _) => Text(
                          _ghostController.value.isEmpty
                              ? "Emit signal..."
                              : _ghostController.value,
                          style: TextStyle(
                              color: _ghostController.value.isEmpty
                                  ? Colors.white10
                                  : Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_isKeyboardVisible && !inputDisabled) ...[
                IconButton(
                  tooltip: 'Hide keyboard',
                  onPressed: _closeGhostKeyboard,
                  icon: const Icon(Icons.keyboard_hide,
                      color: Colors.white54, size: 22),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 6),
              CircleAvatar(
                backgroundColor:
                    inputDisabled ? Colors.white24 : Colors.redAccent,
                child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: inputDisabled ? null : _sendMessage),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Прокрутка вниз после того, как [ListView] уже в дереве (иначе [hasClients] == false — типичный баг при открытии чата).
  void _scheduleScrollToBottom({required bool jump}) {
    var framesWithoutClients = 0;

    void tick() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scrollController.hasClients) {
          if (framesWithoutClients < 12) {
            framesWithoutClients++;
            tick();
          }
          return;
        }
        final max = _scrollController.position.maxScrollExtent;
        if (jump) {
          _scrollController.jumpTo(max);
          // Второй кадр: maxScrollExtent часто дорастает после первого layout (EMUI / разная высота пузырей).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scrollController.hasClients) return;
            final m2 = _scrollController.position.maxScrollExtent;
            if ((m2 - _scrollController.position.pixels).abs() > 1.0) {
              _scrollController.jumpTo(m2);
            }
          });
        } else {
          _scrollController.animateTo(
            max,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }

    tick();
  }

  /// [UX] Approximate id of the message at top of viewport. Used to restore scroll after reorder/replace.
  String? _getTopVisibleMessageId() {
    if (!_scrollController.hasClients) return null;
    final firstVisibleIndex =
        (_scrollController.offset / 60).floor(); // приблизительно
    if (firstVisibleIndex >= 0 && firstVisibleIndex < _messages.length) {
      return _messages[firstVisibleIndex].id;
    }
    return null;
  }

  /// [UX] Restore scroll so the message [anchorId] is at top (approx). No-op if anchor not in list.
  void _restoreAnchor(String? anchorId) {
    if (anchorId == null) return;
    final index = _messages.indexWhere((m) => m.id == anchorId);
    if (index == -1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(index * 60.0);
    });
  }

  /// [UX] True if view is within 120px of bottom. Used to decide whether to auto-scroll on new message.
  bool isNearBottom() {
    if (!_scrollController.hasClients) return false;
    const threshold = 120.0;
    return _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - threshold;
  }

  /// [UX] Scroll to bottom only if user was already near bottom. Called after new message at end; never during build or sync after setState.
  void safeAutoScroll() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (!isNearBottom()) return;
      // Двойной кадр: maxScrollExtent на части устройств обновляется после первого layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        if (!isNearBottom()) return;
        final max = _scrollController.position.maxScrollExtent;
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      });
    });
  }

  void _onTyping() {
    // В оффлайне typing-индикаторы не шлем для экономии заряда
  }

  void _sendMessagesReadEvent() {}

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _panicController?.removeListener(_onPanicPhaseChanged);
    if (locator.isRegistered<PanicDisplayService>()) {
      locator<PanicDisplayService>().removeListener(_onPanicDisplayChanged);
    }
    _saveDraft();
    // Восстанавливаем системную навигацию при выходе
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    _socketSubscription?.cancel();
    _meshSubscription?.cancel();
    EventBusService().off<ChatSyncCompletedEvent>(_onChatSyncCompleted);
    EventBusService().off<MessageReceivedEvent>(_onMessageBusOfflineMessage);
    _ghostController.dispose();
    _scrollController.removeListener(_maybeLoadOlderOnScroll);
    _scrollController.dispose();
    SecurityService.disableSecureMode();
    if (_pairingProximityHintHeld) {
      MeshPairingProximityHint.leave();
      if (locator.isRegistered<BluetoothMeshService>()) {
        locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
      }
    }
    super.dispose();
  }
}
