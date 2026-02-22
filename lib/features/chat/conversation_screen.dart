import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import '../../core/encryption_service.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/mesh_service.dart';
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
import '../../dev_tools/room_timeline_debugger.dart';
import '../profile/user_profile_screen.dart';

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

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      clientTempId: json['clientTempId']?.toString(),
      content: json['content'] ?? '',
      senderId: json['senderId']?.toString() ?? '',
      senderUsername: json['senderUsername'] ?? 'Nomad',
      createdAt: parsedDate,
      receivedAt: parsedReceivedAt,
      vectorClock: parsedVectorClock,
      sequenceNumber: seqNum,
      previousHash: prevHash?.isEmpty == true ? null : prevHash,
      forkOfId: forkOf?.isEmpty == true ? null : forkOf,
      isLocal: isLocal,
      crdtId: crdtId?.isEmpty == true ? null : crdtId,
      status: json['status'] ?? 'SENT',
    );
  }

  /// [Optimistic] Replace with updated status/crdtId/isLocal without changing list order.
  ChatMessage copyWith({String? status, String? crdtId, bool? isLocal}) {
    return ChatMessage(
      id: id,
      clientTempId: clientTempId,
      content: content,
      senderId: senderId,
      senderUsername: senderUsername,
      createdAt: createdAt,
      receivedAt: receivedAt,
      vectorClock: vectorClock,
      sequenceNumber: sequenceNumber,
      previousHash: previousHash,
      forkOfId: forkOfId,
      status: status ?? this.status,
      hasWarning: hasWarning,
      isLocal: isLocal ?? this.isLocal,
      crdtId: crdtId != null ? crdtId : this.crdtId,
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
  final VoidCallback? onRetry;
  /// При тапе по нику отправителя (только для чужих сообщений).
  final void Function(String senderId, String? senderUsername)? onSenderTap;

  const MessageBubble({
    super.key,
    required this.message,
    required this.index,
    required this.messages,
    required this.currentUserId,
    this.onRetry,
    this.onSenderTap,
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
    final emojiOnly = isEmojiOnly(message.content);
    final pos = getGroupPosition(messages, index);
    // Emoji-only: always render as single (no grouped look).
    final effectivePos = emojiOnly ? GroupPosition.single : pos;
    final (radius, verticalPadding, showSenderName, bottomMargin) =
        groupStyle(effectivePos, isMe, emojiOnly);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: verticalPadding,
        bottom: verticalPadding + bottomMargin,
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
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
              ),
            ),
            if (effectivePos == GroupPosition.single ||
                effectivePos == GroupPosition.last) ...[
              const SizedBox(height: 2),
              if (isMe)
                message.status == MessageStatus.failed
                    ? InkWell(
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
                    : Text(
                        MessageStatus.getDisplayText(message.status),
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 8),
                      ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConversationScreenState extends State<ConversationScreen> {
  final GhostController _ghostController = GhostController();
  final ScrollController _scrollController = ScrollController();
  final ApiService _apiService = ApiService();
  final Set<String> _processedIds = {};

  StreamSubscription? _socketSubscription;
  StreamSubscription? _meshSubscription;
  String? _chatId;
  String? _currentUserId;

  bool _isKeyboardVisible = false;
  List<ChatMessage> _messages = [];
  bool _isLoadingHistory = true;
  bool _isLocalMode = false;
  bool _isSending = false;
  RoomState _roomState = RoomState.active;

  PanicPhase _panicPhase = PanicPhase.normal;
  TimedPanicController? _panicController;

  /// [UX] Show "↓ New messages" when user scrolled up and a new message arrived. Cleared on tap or after safeAutoScroll.
  bool _hasNewMessagesWhenNotNearBottom = false;

  void _onPanicPhaseChanged() {
    if (mounted && _panicController != null) {
      setState(() {
        _panicPhase = _panicController!.phase;
        if (_panicPhase != PanicPhase.normal) _isKeyboardVisible = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (locator.isRegistered<TimedPanicController>()) {
      _panicController = locator<TimedPanicController>();
      _panicPhase = _panicController!.phase;
      _panicController!.addListener(_onPanicPhaseChanged);
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
    // Ensure SESSION (ApiService, MeshService) so locator<> never throws on this screen.
    if (!locator.isRegistered<MeshService>()) {
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

  void _updateRoomState() {
    if (!locator.isRegistered<MeshService>()) {
      if (mounted)
        setState(() {
          _roomState = RoomStateHelper.fromNetworkStatus(
              hasInternet: false, isSyncing: false);
        });
      return;
    }
    final networkMonitor = NetworkMonitor();
    final hasInternet = networkMonitor.currentRole == MeshRole.BRIDGE;
    final mesh = locator<MeshService>();
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
    if (_currentUserId == null || _currentUserId!.isEmpty) {
      if (mounted) setState(() => _isLoadingHistory = false);
      return;
    }

    // 2. УНИФИКАЦИЯ КАНАЛА (The ID Unifier)
    if (widget.friendId == "GLOBAL" ||
        widget.chatRoomId == "THE_BEACON_GLOBAL") {
      _chatId = "THE_BEACON_GLOBAL";
    } else if (widget.chatRoomId == "BEACON_NEARBY" || widget.friendId == "BEACON_NEARBY") {
      _chatId = "BEACON_NEARBY";
    } else if (widget.chatRoomId != null && BeaconCountryHelper.isBeaconChat(widget.chatRoomId)) {
      _chatId = widget.chatRoomId!; // THE_BEACON_XX по стране
    } else {
      _chatId =
          RoomIdNormalizer.canonicalDmRoomId(_currentUserId!, widget.friendId);
    }

    // 🔒 CORE must be ready so getMessages decrypts with same salt (after cold start / reinstall: camouflage → code → chat).
    for (int i = 0; i < 25; i++) {
      if (locator.isRegistered<EncryptionService>() ||
          locator.isRegistered<VaultInterface>()) break;
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
    }

    // 3. МГНОВЕННЫЙ ЦИКЛ SQLITE (getMessages returns [] if CORE still not ready)
    // The Beacon (любая страна) и Рядом: ограничиваем последними 500 сообщениями
    final history = (BeaconCountryHelper.isBeaconChat(_chatId) || _chatId == 'BEACON_NEARBY')
        ? await db.getMessages(_chatId!, limit: 500)
        : await db.getMessages(_chatId!);
    setState(() {
      _messages = history;
      _isLoadingHistory = false;
    });
    _scrollToBottom();
    _listenToChannels();
  }

  void _listenToChannels() {
    // --- 📡 КАНАЛ 1: CLOUD (WebSocket) ---
    _socketSubscription = WebSocketService().stream.listen((payload) {
      if (payload['type'] == 'newMessage') {
        final msg = payload['message'];
        // Принимаем, если ID комнаты совпадает или это Глобал
        if (msg['chatRoomId'] == _chatId) {
          _processMessagePacket(msg, fromCloud: true);
        }
      }
    });

    // --- 👻 КАНАЛ 2: MESH (Gossip/P2P) ---
    if (locator.isRegistered<MeshService>()) {
      if (kDebugMode) debugPrint("[BLE-DIAG] ConversationScreen: subscribing to messageStream (chatId=$_chatId)");
      _meshSubscription = locator<MeshService>().messageStream.listen((packet) {
        final String incomingChatId = (packet['chatId'] ?? "").toString();
        final String senderId = (packet['senderId'] ?? "").toString();

        // Нормализация ID в ядре: сравнение по каноническому roomId (GHOST_MAC_MAC)
        // 🔥 BEACON cross-match: THE_BEACON_GLOBAL показываем в любом beacon-чате (Global, по стране THE_BEACON_XX) и в "Рядом"
        bool isMatch = RoomIdNormalizer.roomIdsMatch(incomingChatId, _chatId) ||
            (incomingChatId.toUpperCase() == "THE_BEACON_GLOBAL" &&
                (BeaconCountryHelper.isBeaconChat(_chatId) || _chatId == "BEACON_NEARBY")) ||
            (incomingChatId == "BEACON_NEARBY" && _chatId == "BEACON_NEARBY") ||
            (incomingChatId == "BEACON_NEARBY" && _chatId == "THE_BEACON_GLOBAL") ||
            RoomIdNormalizer.normalizePeerId(senderId) ==
                RoomIdNormalizer.normalizePeerId(widget.friendId);

        if (kDebugMode) debugPrint("[BLE-DIAG] ConversationScreen: message received chatId=$incomingChatId currentScreenChatId=$_chatId isMatch=$isMatch");
        if (isMatch) {
          _processMessagePacket(packet, fromCloud: false);
        }
      });
    }

    // --- 📋 CRDT sync: сообщения пришли через LOG_ENTRIES (в БД уже есть), UI перезагружаем из БД ---
    EventBusService().on<ChatSyncCompletedEvent>(_onChatSyncCompleted);
  }

  void _onChatSyncCompleted(ChatSyncCompletedEvent event) async {
    if (!mounted || _chatId == null) return;
    final match = event.chatId == _chatId;
    if (!match) return;
    final db = LocalDatabaseService();
    final history = (BeaconCountryHelper.isBeaconChat(_chatId) || _chatId == 'BEACON_NEARBY')
        ? await db.getMessages(_chatId!, limit: 500)
        : await db.getMessages(_chatId!);
    if (mounted) {
      final anchor = _getTopVisibleMessageId();
      setState(() => _messages = history);
      _restoreAnchor(anchor);
      safeAutoScroll();
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

    // 3. [Optimistic] Не дублировать: если уже есть локальная запись с этим crdtId — не создавать новую
    if (_messages.any((m) => m.crdtId == msgId)) return;

    String content = data['content']?.toString() ?? data['data']?.toString() ?? "";
    final String originalContent = content;

    // 3. РАСШИФРОВКА (E2EE): mesh in THE_BEACON_GLOBAL is always encrypted with shared key — decrypt so we never show ciphertext
    bool decryptFailed = false;
    final bool isEncryptedFlag = data['isEncrypted'] == true || data['isEncrypted'] == 1;
    final bool shouldDecrypt = isEncryptedFlag ||
        (!fromCloud && (BeaconCountryHelper.isBeaconChat(_chatId) || _chatId == 'BEACON_NEARBY') && content.isNotEmpty && content.length >= 20 && !content.contains(' '));
    if (shouldDecrypt) {
      try {
        final key = await encryption.getChatKey(_chatId!);
        final decrypted = await encryption.decrypt(content, key);
        content = decrypted.isNotEmpty ? decrypted : "[Secure Signal: Captured but Locked]";
        if (decrypted.isEmpty || decrypted == "[Secure message unavailable]") decryptFailed = true;
      } catch (e) {
        content = "[Secure Signal: Captured but Locked]";
        decryptFailed = true;
      }
    }

    final int tsMs = data['ts'] ??
        data['timestamp'] ??
        DateTime.now().millisecondsSinceEpoch;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(tsMs);

    final newMessage = ChatMessage(
      id: msgId,
      content: content,
      senderId: data['senderId'] ?? "GHOST",
      senderUsername: data['senderUsername'] ?? "Nomad",
      createdAt: createdAt,
      status: fromCloud ? "CLOUD" : "MESH",
    );

    // 4. СОХРАНЕНИЕ В ЛОКАЛЬНЫЙ СТЕК: при неудачной расшифровке сохраняем исходный шифртекст (contentAlreadyEncrypted: true),
    // чтобы не затирать в БД плейсхолдером и дать повторную попытку расшифровки при следующей загрузке.
    if (decryptFailed && originalContent.isNotEmpty && originalContent.length >= 20 && !originalContent.contains(' ')) {
      final msgToStore = ChatMessage(
        id: msgId,
        content: originalContent,
        senderId: data['senderId'] ?? "GHOST",
        senderUsername: data['senderUsername'] ?? "Nomad",
        createdAt: createdAt,
        status: fromCloud ? "CLOUD" : "MESH",
      );
      await db.saveMessage(msgToStore, _chatId!, contentAlreadyEncrypted: true);
    } else {
      await db.saveMessage(newMessage, _chatId!);
    }

    if (mounted) {
      final wasNearBottom = isNearBottom();
      setState(() {
        _messages.add(newMessage);
        _messages.sort((a, b) {
          final timeCompare = a.createdAt.compareTo(b.createdAt);
          if (timeCompare != 0) return timeCompare;
          final authorCompare = a.senderId.compareTo(b.senderId);
          if (authorCompare != 0) return authorCompare;
          return a.id.compareTo(b.id);
        });
        if (!wasNearBottom) _hasNewMessagesWhenNotNearBottom = true;
      });
      HapticFeedback.lightImpact();
      if (wasNearBottom) safeAutoScroll();
      if (locator.isRegistered<TimedPanicController>()) {
        locator<TimedPanicController>().recordActivity();
      }
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
    if (locator.isRegistered<MeshService>()) {
      if (kDebugMode) debugPrint("[BLE-DIAG] ConversationScreen: subscribing to messageStream (chatId=$_chatId)");
      _meshSubscription =
          locator<MeshService>().messageStream.listen((offlineData) async {
        if (!mounted) return;

        final String incomingChatId = (offlineData['chatId'] ?? "").toString();
        final String incomingSenderId =
            (offlineData['senderId'] ?? "").toString();

        // Нормализация ID в ядре: сравнение по каноническому roomId
        // 🔥 BEACON cross-match: THE_BEACON_GLOBAL показываем в любом beacon-чате (Global, THE_BEACON_XX по стране) и в "Рядом"
        bool isMatch = RoomIdNormalizer.roomIdsMatch(incomingChatId, _chatId) ||
            (incomingChatId.toUpperCase() == "THE_BEACON_GLOBAL" &&
                (widget.friendId == "GLOBAL" || BeaconCountryHelper.isBeaconChat(_chatId) || _chatId == "BEACON_NEARBY")) ||
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
        final key = await encryption.getChatKey(_chatId!);
        final decrypted = await encryption.decrypt(content, key);
        content = decrypted.isNotEmpty ? decrypted : "[Secure Message Captured]";
        if (decrypted.isEmpty || decrypted == "[Secure message unavailable]") decryptFailed = true;
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
      senderUsername: data['senderUsername'] ?? "Nomad",
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
        senderUsername: data['senderUsername'] ?? "Nomad",
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
        _messages.add(newMessage);
        _messages.sort((a, b) {
          final timeCompare = a.createdAt.compareTo(b.createdAt);
          if (timeCompare != 0) return timeCompare;
          final authorCompare = a.senderId.compareTo(b.senderId);
          if (authorCompare != 0) return authorCompare;
          return a.id.compareTo(b.id);
        });
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
      if (locator.isRegistered<MeshService>()) {
        locator<MeshService>().addLog(
            "[OUTBOX] Send blocked: userId=${_currentUserId != null} chatId=${_chatId != null}");
      }
      return;
    }

    setState(() => _isSending = true);
    final db = LocalDatabaseService();
    if (!locator.isRegistered<MeshService>()) {
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
      );
      setState(() => _messages.add(myMsg));
      _ghostController.clear();
      safeAutoScroll();
      await db.saveMessage(myMsg, _chatId!);
      await db.addToOutbox(myMsg, _chatId!);
      if (mounted)
        setState(() {
          myMsg.status = "OFFLINE_QUEUED";
          _isSending = false;
        });
      return;
    }
    final mesh = locator<MeshService>();
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
        crdtId: null);

    // Optimistic insert: show immediately, do not wait for transport
    setState(() => _messages.add(myMsg));
    _ghostController.clear();
    safeAutoScroll();

    await db.saveMessage(myMsg, _chatId!);

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
        if (locator.isRegistered<MeshService>())
          locator<MeshService>().requestAutoScanForOutbox();
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
    if (!locator.isRegistered<MeshService>()) return;
    final mesh = locator<MeshService>();
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
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _isLoadingHistory
                      ? const Center(
                          child:
                              CircularProgressIndicator(color: Colors.cyanAccent))
                      : NotificationListener<ScrollNotification>(
                          onNotification: (_) {
                            if (locator.isRegistered<TimedPanicController>()) {
                              locator<TimedPanicController>().recordActivity();
                            }
                            return false;
                          },
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            cacheExtent: 800,
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
                                  onRetry: () => _retryFailedMessage(message),
                                  onSenderTap: (senderId, senderUsername) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => UserProfileScreen(
                                          userId: senderId,
                                          displayName: senderUsername,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
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
                              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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
            _buildInputZone(),
            if (_isKeyboardVisible && _panicPhase == PanicPhase.normal)
              GhostKeyboard(controller: _ghostController, onSend: _sendMessage),
          ],
        ),
      ),
    );
  }

  Widget _buildInputZone() {
    final inputDisabled = _panicPhase != PanicPhase.normal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Color(0xFF0D0D0D)),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: inputDisabled
                  ? null
                  : () =>
                      setState(() => _isKeyboardVisible = !_isKeyboardVisible),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(25)),
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
          const SizedBox(width: 10),
          CircleAvatar(
            backgroundColor: inputDisabled ? Colors.white24 : Colors.redAccent,
            child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white),
                onPressed: inputDisabled ? null : _sendMessage),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(_scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
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
      if (isNearBottom()) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onTyping() {
    // В оффлайне typing-индикаторы не шлем для экономии заряда
  }

  void _sendMessagesReadEvent() {}

  @override
  void dispose() {
    _panicController?.removeListener(_onPanicPhaseChanged);
    // Восстанавливаем системную навигацию при выходе
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    _socketSubscription?.cancel();
    _meshSubscription?.cancel();
    EventBusService().off<ChatSyncCompletedEvent>(_onChatSyncCompleted);
    _ghostController.dispose();
    _scrollController.dispose();
    SecurityService.disableSecureMode();
    super.dispose();
  }
}
