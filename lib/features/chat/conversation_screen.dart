import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import 'package:memento_mori_app/core/websocket_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/security_service.dart';

import '../../core/encryption_service.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/mesh_service.dart';
import '../../core/native_mesh_service.dart';
import '../../core/message_status.dart';
import '../../core/room_state.dart';
import '../../core/room_state.dart' show RoomStateHelper;
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../../dev_tools/room_timeline_debugger.dart';

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
  String status;
  bool hasWarning = false;

  ChatMessage({
    required this.id,
    this.clientTempId,
    required this.content,
    required this.senderId,
    this.senderUsername,
    required this.createdAt,
    this.receivedAt,
    this.vectorClock,
    this.status = 'SENT',
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

    return ChatMessage(
      // Принудительно в String, если база вернула числовой ID
      id: json['id']?.toString() ?? '',
      clientTempId: json['clientTempId']?.toString(),
      content: json['content'] ?? '',
      senderId: json['senderId']?.toString() ?? '',
      senderUsername: json['senderUsername'] ?? 'Nomad',
      createdAt: parsedDate,
      receivedAt: parsedReceivedAt,
      vectorClock: parsedVectorClock,
      status: json['status'] ?? 'SENT',
    );
  }

  Map<String, dynamic> toJson() {
    return {
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

  @override
  void initState() {
    super.initState();
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
    _initializeChat();
    _updateRoomState();
    // Слушаем изменения сетевого статуса
    NetworkMonitor().onRoleChanged.listen((_) => _updateRoomState());
  }

  void _updateRoomState() {
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
    final api = locator<ApiService>();

    // 1. ЛИЧНОСТЬ: Кто я сегодня?
    _currentUserId = api.currentUserId;

    // 2. УНИФИКАЦИЯ КАНАЛА (The ID Unifier)
    if (widget.friendId == "GLOBAL" || widget.chatRoomId == "THE_BEACON_GLOBAL") {
      _chatId = "THE_BEACON_GLOBAL"; // Единый ID для всей планеты
    } else {
      // Для лички сортируем ID, чтобы у обоих участников ID комнаты СОВПАЛ
      List<String> ids = [_currentUserId!, widget.friendId];
      ids.sort();
      _chatId = "GHOST_${ids[0]}_${ids[1]}";
    }

    // 3. МГНОВЕННЫЙ ЦИКЛ SQLITE
    final history = await db.getMessages(_chatId!);
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
        if (msg['chatRoomId'] == _chatId || (msg['chatRoomId'] == "THE_BEACON_GLOBAL" && _chatId == "THE_BEACON_GLOBAL")) {
          _processMessagePacket(msg, fromCloud: true);
        }
      }
    });

    // --- 👻 КАНАЛ 2: MESH (Gossip/P2P) ---
    _meshSubscription = locator<MeshService>().messageStream.listen((packet) {
      final String incomingChatId = packet['chatId'] ?? "";
      final String senderId = packet['senderId'] ?? "";

      // Логика фильтрации: Пакет наш, если это Глобал или прямая личка
      bool isMatch = incomingChatId == _chatId ||
          (incomingChatId == "THE_BEACON_GLOBAL" && _chatId == "THE_BEACON_GLOBAL") ||
          senderId == widget.friendId;

      if (isMatch) {
        _processMessagePacket(packet, fromCloud: false);
      }
    });
  }

  void _processMessagePacket(Map<String, dynamic> data, {required bool fromCloud}) async {
    final encryption = locator<EncryptionService>();
    final db = LocalDatabaseService();

    // 1. ДЕДУПЛИКАЦИЯ: канонический ID = h
    final String msgId = data['h']?.toString() ?? data['clientTempId']?.toString() ?? data['id']?.toString() ?? '';
    if (msgId.isEmpty || _processedIds.contains(msgId)) return;
    _processedIds.add(msgId);

    // 2. ЗАЩИТА ОТ ЭХА
    if (data['senderId'] == _currentUserId) return;

    String content = data['content'] ?? "";

    // 3. РАСШИФРОВКА (E2EE)
    if (data['isEncrypted'] == true) {
      try {
        final key = await encryption.getChatKey(_chatId!);
        content = await encryption.decrypt(content, key);
      } catch (e) {
        content = "[Secure Signal: Captured but Locked]";
      }
    }

    final int tsMs = data['ts'] ?? data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(tsMs);

    final newMessage = ChatMessage(
      id: msgId,
      content: content,
      senderId: data['senderId'] ?? "GHOST",
      senderUsername: data['senderUsername'] ?? "Nomad",
      createdAt: createdAt,
      status: fromCloud ? "CLOUD" : "MESH",
    );

    // 4. СОХРАНЕНИЕ В ЛОКАЛЬНЫЙ СТЕК
    await db.saveMessage(newMessage, _chatId!);

    if (mounted) {
      setState(() {
        _messages.add(newMessage);
        // Сортировка по (created_at, author_id, message_id)
        _messages.sort((a, b) {
          final timeCompare = a.createdAt.compareTo(b.createdAt);
          if (timeCompare != 0) return timeCompare;
          final authorCompare = a.senderId.compareTo(b.senderId);
          if (authorCompare != 0) return authorCompare;
          return a.id.compareTo(b.id);
        });
      });
      HapticFeedback.lightImpact(); // Вибрация при получении
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }


  void _listenToComms() {
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();

    // --- 📡 КАНАЛ CLOUD (WebSocket) ---
    _socketSubscription = WebSocketService().stream.listen((data) async {
      if (data['type'] == 'newMessage' && data['message']['chatRoomId'] == _chatId) {
        _handleIncomingData(data['message'], isFromCloud: true);
      }
    });

    // --- 👻 КАНАЛ MESH (P2P) ---
    _meshSubscription = locator<MeshService>().messageStream.listen((offlineData) async {
      if (!mounted) return;

      final String incomingChatId = (offlineData['chatId'] ?? "").toString().toUpperCase();
      final String incomingSenderId = (offlineData['senderId'] ?? "").toString();

      // Фильтр: Пакет для этой комнаты?
      bool isMatch = incomingChatId == _chatId?.toUpperCase() ||
          (incomingChatId == "THE_BEACON_GLOBAL" && widget.friendId == "GLOBAL") ||
          incomingSenderId == widget.friendId;

      if (isMatch) {
        _handleIncomingData(offlineData, isFromCloud: false);
      }
    });
  }

  // Единый обработчик входящих данных
  void _handleIncomingData(Map<String, dynamic> data, {required bool isFromCloud}) async {
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();

    // Канонический ID: h, alias clientTempId/id (не генерировать из timestamp)
    final String msgId = data['h']?.toString() ?? data['clientTempId']?.toString() ?? data['id']?.toString() ?? '';
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
            orElse: () => ChatMessage(id: '', content: '', senderId: '', createdAt: DateTime.now()),
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

    String content = data['content'] ?? "";

    // Расшифровка
    if (data['isEncrypted'] == true || !isFromCloud) {
      try {
        final key = await encryption.getChatKey(_chatId!);
        final decrypted = await encryption.decrypt(content, key);
        if (decrypted.isNotEmpty) content = decrypted;
      } catch (e) {
        content = "[Secure Message Captured]";
      }
    }

    final now = DateTime.now();
    // Сортировка по ts (время создания), не по времени приёма
    final int tsMs = data['ts'] ?? data['timestamp'] ?? now.millisecondsSinceEpoch;
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

    await db.saveMessage(newMessage, _chatId!);

    if (mounted) {
      HapticFeedback.lightImpact(); // Тактильный сигнал о приеме
      setState(() {
        _messages.add(newMessage);
        // Сортировка: 1) ts (createdAt), 2) senderId, 3) h (id)
        _messages.sort((a, b) {
          final timeCompare = a.createdAt.compareTo(b.createdAt);
          if (timeCompare != 0) return timeCompare;
          final authorCompare = a.senderId.compareTo(b.senderId);
          if (authorCompare != 0) return authorCompare;
          return a.id.compareTo(b.id);
        });
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _sendMessage() async {
    final text = _ghostController.value.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    final mesh = locator<MeshService>();
    final db = LocalDatabaseService();

    final now = DateTime.now();
    final String tempId = "temp_${now.millisecondsSinceEpoch}";
    
    // 🔄 vectorClock: используется ТОЛЬКО для синхронизации
    // "Какие сообщения мне не хватает", "до какого момента я в курсе"
    // НЕ используется для UI-логики или сортировки
    final vectorClock = <String, int>{
      _currentUserId!: now.millisecondsSinceEpoch,
    };
    
    final myMsg = ChatMessage(
        id: tempId,
        content: text,
        senderId: _currentUserId!,
        senderUsername: "Me",
      createdAt: now,
      receivedAt: null, // 📊 receivedAt: только для статистики/отладки, НЕ для сортировки
      vectorClock: vectorClock, // 🔄 Только для синхронизации
        status: MessageStatus.sentLocal
    );

    // Сначала показываем у себя (Optimistic UI)
    setState(() => _messages.add(myMsg));
    _ghostController.clear();
    _scrollToBottom();

    // Сохраняем в БД со статусом SENDING
    await db.saveMessage(myMsg, _chatId!);

    try {
      // 🔥 УЛЬТРА-ОТПРАВКА (Cloud + Mesh + Sonar)
      await mesh.sendAuto(
        content: text,
        chatId: _chatId,
        receiverName: widget.friendName,
        messageId: tempId, // Передаем ID для обновления статуса
      );

      // Статус обновляется внутри sendAuto на DELIVERED_TO_NETWORK
      // Обновляем статус в зависимости от канала доставки
      final newStatus = mesh.isP2pConnected 
          ? MessageStatus.deliveredMesh 
          : (NetworkMonitor().currentRole == MeshRole.BRIDGE 
              ? MessageStatus.deliveredServer 
              : MessageStatus.deliveredMesh);
      
      setState(() {
        myMsg.status = newStatus;
      });
      await db.updateMessageStatus(tempId, newStatus);

    } catch (e) {
      setState(() => myMsg.status = "OFFLINE_QUEUED");
      await db.addToOutbox(myMsg, _chatId!); // В инкубатор!
    } finally {
      if (mounted) setState(() => _isSending = false);
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
                      widget.friendName,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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
      body: Column(
        children: [
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
            ),
          ),
          _buildInputZone(),
          if (_isKeyboardVisible)
            GhostKeyboard(controller: _ghostController, onSend: _sendMessage),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final bool isMe = message.senderId == _currentUserId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe) Text("${message.senderUsername} >", style: const TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isMe ? Colors.redAccent.withOpacity(0.8) : const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Text(message.content, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
            const SizedBox(height: 2),
            if (isMe) Text(
              MessageStatus.getDisplayText(message.status),
              style: const TextStyle(color: Colors.white24, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputZone() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Color(0xFF0D0D0D)),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _isKeyboardVisible = !_isKeyboardVisible),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(25)),
                child: AnimatedBuilder(
                  animation: _ghostController,
                  builder: (context, _) => Text(
                    _ghostController.value.isEmpty ? "Emit signal..." : _ghostController.value,
                    style: TextStyle(color: _ghostController.value.isEmpty ? Colors.white10 : Colors.white),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          CircleAvatar(
            backgroundColor: Colors.redAccent,
            child: IconButton(icon: const Icon(Icons.send, color: Colors.white), onPressed: _sendMessage),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _onTyping() {
    // В оффлайне typing-индикаторы не шлем для экономии заряда
  }

  void _sendMessagesReadEvent() {}

  @override
  void dispose() {
    // Восстанавливаем системную навигацию при выходе
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    _socketSubscription?.cancel();
    _meshSubscription?.cancel();
    _ghostController.dispose();
    _scrollController.dispose();
    SecurityService.disableSecureMode();
    super.dispose();
  }
}