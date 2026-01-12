import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/guardian_service.dart';
import 'package:memento_mori_app/core/panic_service.dart';
import 'package:memento_mori_app/core/websocket_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/security_service.dart'; // 🔥 Импорт твоего сервиса

import '../../core/encryption_service.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/mesh_service.dart';
import '../../core/models/signal_node.dart';
import '../../core/native_mesh_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';

// --- Модель сообщения ---
class ChatMessage {
  final String id;
  final String? clientTempId;
  final String content;
  final String senderId;
  final String? senderUsername;
  final DateTime createdAt;
  String status;
  bool hasWarning = false;

  ChatMessage({
    required this.id,
    this.clientTempId,
    required this.content,
    required this.senderId,
    this.senderUsername,
    required this.createdAt,
    this.status = 'SENT',
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final senderData = json['sender'];
    return ChatMessage(
      id: json['id']?.toString() ?? '',
      clientTempId: json['clientTempId'] ?? json['client_temp_id'],
      content: json['content'] ?? '',
      senderId: json['senderId'] ?? senderData?['id'] ?? '',
      senderUsername: json['senderUsername'] ?? senderData?['username'] ?? 'Nomad',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      status: json['status'] ?? 'SENT',
    );
  }

  // 🔥 ТОТ САМЫЙ МЕТОД, КОТОРОГО НЕ ХВАТАЛО
  // Превращает объект обратно в Map для корректной работы API-слоя в оффлайне
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'clientTempId': clientTempId,
      'content': content,
      'senderId': senderId,
      'senderUsername': senderUsername,
      'createdAt': createdAt.toIso8601String(),
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
  final MeshService _meshService = locator<MeshService>();

  Map<String, String> _typingUsers = {};

  StreamSubscription? _socketSubscription;
  StreamSubscription? _meshSubscription; // ✅ Подписка на Mesh
  String? _chatId;
  String? _currentUserId;

  bool _isKeyboardVisible = false;
  List<ChatMessage> _messages = [];
  bool _isLoadingHistory = true;
  bool _isEphemeral = false;
  bool _isLocalMode = false;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    // 🔥 ВКЛЮЧАЕМ ЗАЩИТУ ЭКРАНА (Блокировка скриншотов и превью)
    SecurityService.enableSecureMode();

    _initializeChat();
    _ghostController.addListener(_onTyping);
  }

  bool _isRetrying = false; // Добавь это поле в начало класса State

  Future<void> _initializeChat() async {
    if (mounted) setState(() => _isLoadingHistory = true);

    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();
    // Временный буфер для дедупликации сообщений
    final Map<String, ChatMessage> uniqueMessages = {};

    // Очищаем кэш обработанных ID для новой сессии чата
    _processedIds.clear();

    try {
      // 1. УСТАНОВКА ЛИЧНОСТИ ПОЛЬЗОВАТЕЛЯ
      try {
        final me = await _apiService.getMe();
        _currentUserId = me['id'];
      } catch (e) {
        // Если сервера нет — достаем ID из сейфа или генерируем оффлайн-ID
        String? savedId = await const FlutterSecureStorage().read(key: 'user_id');

        if (savedId != null) {
          _currentUserId = savedId;
        } else {
          // Если мы совсем "чистые", генерируем временный ID на основе устройства
          final deviceInfo = DeviceInfoPlugin();
          String hardwareId = "UNKNOWN";

          if (Platform.isAndroid) {
            final androidInfo = await deviceInfo.androidInfo;
            hardwareId = androidInfo.id; // На Android это стабильный ID сборки/устройства
          } else if (Platform.isIOS) {
            final iosInfo = await deviceInfo.iosInfo;
            hardwareId = iosInfo.identifierForVendor ?? "IOS_GHOST";
          }

          // Делаем ID коротким и узнаваемым для оффлайна
          _currentUserId = "GHOST_${hardwareId.hashCode.abs().toString().substring(0, 4)}";
        }
        _isLocalMode = true;
      }

      // 2. ОПРЕДЕЛЕНИЕ ТАКТИЧЕСКОГО КАНАЛА (_chatId)
      if (widget.friendId == "GLOBAL") {
        // 🔥 ЕДИНЫЙ ID ДЛЯ ВСЕХ УСТРОЙСТВ В OFFLINE
        _chatId = "THE_BEACON_GLOBAL";
      } else if (widget.chatRoomId != null) {
        // Если ID пришел из списка чатов или поиска
        _chatId = widget.chatRoomId;
      } else if (widget.friendId.isNotEmpty) {
        // Если мы зашли в личку, но ID комнаты еще не знаем
        if (NetworkMonitor().currentRole == MeshRole.BRIDGE && !_isLocalMode) {
          // В онлайне просим сервер создать/найти комнату
          final chatData = await _apiService.findOrCreateChat(widget.friendId);
          _chatId = chatData['id'];
          _isEphemeral = chatData['isEphemeral'] ?? false;
        } else {
          // В оффлайне генерируем детерминированный ID (GHOST_id1_id2)
          List<String> ids = [_currentUserId!, widget.friendId];
          ids.sort(); // Сортировка - залог того, что на обоих телах ID совпадет
          _chatId = "GHOST_${ids[0]}_${ids[1]}";
          print("🆔 [Chat] Active Mesh ID: $_chatId");

        }
      }

      if (_chatId == null) return;

      // --- ☢️ ШАГ 1: МГНОВЕННЫЙ ВЫВОД ИЗ SQLITE (Для скорости) ---
      final localMessages = await db.getMessages(_chatId!);
      for (var m in localMessages) {
        // Ключ: ID сообщения (UUID или tempId)
        uniqueMessages[m.id] = m;
        _processedIds.add(m.id);
        if (m.clientTempId != null) _processedIds.add(m.clientTempId!);
      }

      if (mounted) {
        setState(() {
          _messages = uniqueMessages.values.toList();
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          // Если в базе уже что-то есть, скрываем лоадер сразу для комфорта
          if (_messages.isNotEmpty) _isLoadingHistory = false;
        });
        _scrollToBottom();
      }

      // --- ☢️ ШАГ 2: СИНХРОНИЗАЦИЯ С ОБЛАКОМ (Если есть BRIDGE) ---
      if (!_isLocalMode && NetworkMonitor().currentRole == MeshRole.BRIDGE) {
        WebSocketService().send({'type': 'joinChat', 'chatId': _chatId});

        try {
          // Запрашиваем историю с сервера
          final List<dynamic> serverHistory = await _apiService.getMessages(_chatId!);
          final key = await encryption.getChatKey("OFFLINE_TACTICAL_CHANNEL");
          bool hasNewData = false;

          for (var raw in serverHistory) {
            final String serverId = raw['id']?.toString() ?? '';
            final String tempId = raw['clientTempId'] ?? raw['client_temp_id'] ?? '';

            // 🔥 ПРОВЕРКА НА ДУБЛИКАТ: Если ID уже в списке — пропускаем
            if (_processedIds.contains(serverId) || (tempId.isNotEmpty && _processedIds.contains(tempId))) {
              continue;
            }

            String content = raw['content'] ?? "";
            if (raw['isEncrypted'] == true) {
              try {
                content = await encryption.decrypt(content, key);
              } catch (e) {
                content = "[Decryption Error]";
              }
            }

            // Создаем модель и сохраняем в локальную БД
            final msg = ChatMessage.fromJson({...raw, 'content': content});
            uniqueMessages[msg.id] = msg;
            _processedIds.add(msg.id);
            await db.saveMessage(msg, _chatId!);
            hasNewData = true;
          }

          // Обновляем UI только если подгрузились новые сообщения
          if (mounted && hasNewData) {
            setState(() {
              _messages = uniqueMessages.values.toList();
              _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
              _isLoadingHistory = false;
            });
            _scrollToBottom();
          }
        } catch (e) {
          // Обработка 403 Forbidden (если сессия на сервере протухла)
          if (e.toString().contains("404")) {
            print("🛡️ [Chat] Room not on server yet. Staying in Local-First mode.");
            // Просто выключаем лоадер, данные из SQLite уже загружены в Шаге 1
            if (mounted) setState(() => _isLoadingHistory = false);
            _isRetrying = true;
            if (widget.friendId.isNotEmpty && widget.friendId != "GLOBAL") {
              final newChat = await _apiService.findOrCreateChat(widget.friendId);
              _chatId = newChat['id'];
              _initializeChat(); // Перезапуск
              return;
            }
          }
        }
      }
    } catch (e) {
      print("❌ [ChatInit] Critical: $e");
    } finally {
      // Это сработает всегда: включаем прослушку и убираем экран загрузки
      if (mounted) {
        setState(() => _isLoadingHistory = false);
        _listenToSocket(); // Запускаем WebSocket и Mesh слушатели
        if (_chatId != null) _sendMessagesReadEvent();
      }
    }
  }




  bool _isOnlyEmoji(String text) {
    if (text.isEmpty) return false;
    // Удаляем невидимые символы и пробелы
    final cleanText = text.replaceAll(RegExp(r'\s+'), '');
    // Регулярное выражение для всех видов эмодзи (включая флаги и составные)
    final emojiRegExp = RegExp(r'^(\u00a9|\u00ae|[\u2000-\u3300]|\ud83c[\ud000-\udfff]|\ud83d[\ud000-\udfff]|\ud83e[\ud000-\udfff])+$');
    return emojiRegExp.hasMatch(cleanText);
  }


  void _listenToSocket() {
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();

    // --- 📡 КАНАЛ ОБЛАКА (WebSocket) ---
    _socketSubscription = WebSocketService().stream.listen((data) async {
      if (!mounted) return;

      if (data['type'] == 'newMessage') {
        if (_chatId != null && data['message']['chatRoomId'] == _chatId) {
          var msgMap = data['message'];
          final String serverId = msgMap['id'].toString();
          final String incomingTempId = (msgMap['clientTempId'] ?? msgMap['client_temp_id'] ?? "").toString();

          if (_processedIds.contains(serverId) || (incomingTempId.isNotEmpty && _processedIds.contains(incomingTempId))) {
            return;
          }

          final int existingIndex = _messages.indexWhere((m) {
            return m.id == serverId || (incomingTempId.isNotEmpty && m.id == incomingTempId) ||
                (m.senderId == _currentUserId && m.content == msgMap['content']);
          });

          if (existingIndex != -1) {
            _processedIds.add(serverId);
            setState(() {
              _messages[existingIndex] = ChatMessage.fromJson(msgMap);
              _messages[existingIndex].status = 'SENT';
            });
            await db.saveMessage(_messages[existingIndex], _chatId!);
            return;
          }

          _processedIds.add(serverId);

          if (msgMap['isEncrypted'] == true) {
            final key = await encryption.getChatKey(_chatId!);
            try {
              msgMap['content'] = await encryption.decrypt(msgMap['content'], key);
            } catch (e) {
              msgMap['content'] = "[Decryption Error]";
            }
          }

          final newMessage = ChatMessage.fromJson(msgMap);
          await db.saveMessage(newMessage, _chatId!);

          setState(() {
            _messages.add(newMessage);
            _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          });
          _scrollToBottom();
          if (newMessage.senderId != _currentUserId) _sendMessagesReadEvent();
        }
      }
    });

    // --- 👻 КАНАЛ MESH (ОФФЛАЙН / P2P) ---
    _meshSubscription = MeshService().messageStream.listen((offlineData) async {
      if (!mounted) return;

      // 1. ИЗВЛЕЧЕНИЕ ТАКТИЧЕСКИХ ДАННЫХ
      final String incomingSenderId = offlineData['senderId'] ?? "";
      final String senderIp = offlineData['senderIp'] ?? "";
      final String incomingChatId = offlineData['chatId'] ?? "";

      // 🛑 ШАГ 1: ЗАЩИТА ОТ ВНУТРЕННЕГО ЭХО
      // Если ID мой И это локальный сигнал (без IP) - игнорируем.
      // Если IP есть - значит это моя вторая трубка шлет сигнал извне. ПУСКАЕМ!
      if (incomingSenderId == _currentUserId && (senderIp.isEmpty || senderIp == "127.0.0.1")) {
        print("🔁 [UI] Internal loopback suppressed.");
        return;
      }

      // 🔥 ШАГ 2: ВЫЧИСЛЕНИЕ ЛОГИКИ МАТЧИНГА (isGlobal / isDirect)
      // Проверяем, относится ли пакет к нашему "Маяку"
      bool isGlobal = (widget.friendId == "GLOBAL") &&
          (incomingChatId == "GLOBAL" || incomingChatId == "THE_BEACON_GLOBAL");

      // Проверяем, личное ли это сообщение от текущего друга
      bool isDirect = (incomingSenderId == widget.friendId) ||
          (incomingChatId == _chatId && _chatId != null);

      // Амнистия: если мы соединены по P2P, принимаем всё, что прилетает в этот экран
      bool isMeshForceAccept = _meshService.isP2pConnected && widget.friendId != "GLOBAL";

      if (isGlobal || isDirect || isMeshForceAccept) {
        // Уникальный ID для дедупликации (защита от Burst-дублей)
        final String meshMsgId = "mesh_${offlineData['timestamp']}_$incomingSenderId";
        if (_processedIds.contains(meshMsgId)) return;
        _processedIds.add(meshMsgId);

        print("🎯 [UI] ACCEPTED pulse from $incomingSenderId via ${senderIp.isEmpty ? 'P2P' : senderIp}");

        String content = offlineData['content'] ?? "";

        // 🔥 ШАГ 3: УМНАЯ РАСШИФРОВКА С ФОЛБЕКОМ
        try {
          // Пытаемся расшифровать ключом текущей комнаты (или Маяка)
          String keyId = (widget.friendId == "GLOBAL") ? "THE_BEACON_GLOBAL" : (_chatId ?? "THE_BEACON_GLOBAL");
          final key = await encryption.getChatKey(keyId);
          content = await encryption.decrypt(content, key);

          // Если расшифровка не удалась (текст остался прежним), пробуем ключ из самого пакета
          if (content == offlineData['content'] && incomingChatId.isNotEmpty) {
            final fallbackKey = await encryption.getChatKey(incomingChatId == "GLOBAL" ? "THE_BEACON_GLOBAL" : incomingChatId);
            content = await encryption.decrypt(content, fallbackKey);
          }
        } catch (e) {
          content = "[Decryption Failure]";
        }

        final msg = ChatMessage(
          id: meshMsgId,
          content: content,
          senderId: incomingSenderId,
          senderUsername: offlineData['senderUsername'] ?? "Nomad",
          createdAt: DateTime.fromMillisecondsSinceEpoch(offlineData['timestamp'] ?? DateTime.now().millisecondsSinceEpoch),
          status: "MESH_LINK",
        );

        // 🔥 ШАГ 4: СИНХРОНИЗАЦИЯ БАЗЫ
        // Сохраняем в БД под тем ID, который сейчас открыт на экране, чтобы ListView его увидел
        final String activeChatId = (widget.friendId == "GLOBAL") ? "THE_BEACON_GLOBAL" : (_chatId ?? "THE_BEACON_GLOBAL");
        await db.saveMessage(msg, activeChatId);

        setState(() {
          _messages.add(msg);
          // Сортируем, чтобы оффлайн-пакеты встали на свои места во времени
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        });
        _scrollToBottom();
      } else {
        print("🚫 [UI] Ignored: Sender $incomingSenderId doesn't match current channel ${widget.friendId}");
      }
    });
  }

  void _sendMessagesReadEvent() {
    if (_chatId != null) {
      WebSocketService().send({'type': 'messagesRead', 'chatId': _chatId});
    }
  }



  void _sendMessage() async {
    final text = _ghostController.value.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    final db = LocalDatabaseService();
    final encryption = locator<EncryptionService>();
    final meshService = locator<MeshService>();

    // 1. Подготовка ID и Сообщения
    final String targetChatId = (widget.friendId == "GLOBAL" || widget.chatRoomId == "THE_BEACON_GLOBAL")
        ? "THE_BEACON_GLOBAL" : (_chatId ?? "GLOBAL");
    final String tempId = "temp_${DateTime.now().millisecondsSinceEpoch}";

    final myMessage = ChatMessage(
        id: tempId, content: text, senderId: _currentUserId ?? "ME",
        createdAt: DateTime.now(), status: "SENDING"
    );

    _ghostController.clear();
    setState(() { _messages.add(myMessage); });
    await db.saveMessage(myMessage, targetChatId);

    // 2. ОПРЕДЕЛЯЕМ ПУТИ ПЕРЕДАЧИ
    final bool canUseCloud = NetworkMonitor().currentRole == MeshRole.BRIDGE;
    final bool canUseMesh = meshService.isP2pConnected;

    // 🔥 ГИБРИДНЫЙ ВЫСТРЕЛ
    try {
      final key = await encryption.getChatKey(targetChatId);
      final encrypted = await encryption.encrypt(text, key);

      // Готовим оффлайн пакет
      final offlinePacket = jsonEncode({
        'type': 'OFFLINE_MSG',
        'chatId': targetChatId,
        'content': encrypted,
        'isEncrypted': true,
        'senderId': _currentUserId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'clientTempId': tempId,
      });

      // --- А. Шлем в Облако (если есть инет) ---
      if (canUseCloud) {
        await WebSocketService().send({
          "type": "message", "chatId": targetChatId,
          "content": text, "clientTempId": tempId
        });
        myMessage.status = "SENT";
      }

      // --- Б. Шлем в Mesh (всегда, если есть коннект, даже если мы онлайн!) ---
      if (canUseMesh) {
        String targetIp = meshService.lastKnownPeerIp;
        if (targetIp.isEmpty && !meshService.isHost) targetIp = "192.168.49.1";

        if (targetIp.isNotEmpty) {
          for (int i = 0; i < 3; i++) {
            await NativeMeshService.sendTcp(offlinePacket, host: targetIp);
            await Future.delayed(const Duration(milliseconds: 100));
          }
          if (!canUseCloud) myMessage.status = "MESH_LINK";
        }
      }

      // Если совсем нет путей - в инкубатор
      if (!canUseCloud && !canUseMesh) {
        await db.addToOutbox(myMessage, targetChatId);
        myMessage.status = "PENDING_RELAY";
      }

    } catch (e) {
      print("❌ Send Error: $e");
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
    _scrollToBottom();
  }



  void _log(String message) {
    // Выводим в консоль для отладки
    print("[ChatUI] $message");

    // Опционально: показываем пользователю маленькую плашку снизу
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 1),
          backgroundColor: Colors.grey[900],
        ),
      );
    }
  }

  void _toggleKeyboard() {
    setState(() {
      _isKeyboardVisible = !_isKeyboardVisible;
    });
    if (_isKeyboardVisible) _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(widget.friendName),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
                : ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
            ),
          ),
          _buildFakeInput(),
          if (_isKeyboardVisible)
            GhostKeyboard(controller: _ghostController, onSend: _sendMessage),
        ],
      ),
    );
  }

  void _onTyping() {
    if (_chatId != null) {
      WebSocketService().send({'type': 'typing_start', 'chatId': _chatId});
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Widget _buildTypingIndicator() {
    if (_typingUsers.isEmpty) return const SizedBox.shrink();
    String text = _typingUsers.values.length <= 3
        ? "${_typingUsers.values.join(", ")} is typing..."
        : "${_typingUsers.values.length} agents typing...";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      alignment: Alignment.centerLeft,
      child: Text(text, style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontStyle: FontStyle.italic)),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isMe = message.senderId == _currentUserId;
    final bool emojiOnly = _isOnlyEmoji(message.content);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // НИК ОТПРАВИТЕЛЯ (Кликабельный переход в профиль)
          if (!isMe)
            GestureDetector(
              onTap: () {
                // ПЕРЕХОД В ПРОФИЛЬ
                print("🔗 Requesting profile for: ${message.senderId}");
                // Здесь будет навигация:
                // Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileViewScreen(userId: message.senderId)));
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  "${message.senderUsername ?? "Nomad"} >",
                  style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5
                  ),
                ),
              ),
            ),

          // ТЕЛО СООБЩЕНИЯ
          GestureDetector(
            onLongPress: () {
              // 🔥 КОПИРОВАНИЕ В БУФЕР ОБМЕНА
              Clipboard.setData(ClipboardData(text: message.content));
              HapticFeedback.vibrate(); // Короткая вибрация-подтверждение
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Signal payload copied to clipboard"),
                    duration: Duration(seconds: 1),
                    backgroundColor: Color(0xFF1A1A1A),
                  )
              );
            },
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: emojiOnly
                  ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Text(
                    message.content,
                    style: const TextStyle(fontSize: 45) // Большой смайл без пузыря
                ),
              )
                  : Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMe ? Colors.redAccent.withOpacity(0.85) : Colors.grey[900],
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 0),
                    bottomRight: Radius.circular(isMe ? 0 : 16),
                  ),
                  border: isMe ? null : Border.all(color: Colors.white10, width: 0.5),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 2, offset: const Offset(0, 1))
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                        message.content,
                        style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.2)
                    ),
                    if (isMe) ...[
                      const SizedBox(height: 4),
                      Icon(
                        message.status == 'READ' ? Icons.done_all : Icons.done,
                        size: 11,
                        color: message.status == 'READ' ? Colors.cyanAccent : Colors.white38,
                      )
                    ]
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFakeInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF121212), border: Border(top: BorderSide(color: Colors.grey[900]!, width: 0.5))),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _isKeyboardVisible = !_isKeyboardVisible),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(24)),
                child: AnimatedBuilder(
                  animation: _ghostController,
                  builder: (context, _) => Text(
                    _ghostController.value.isEmpty ? "Broadcast message..." : _ghostController.value,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _ghostController.value.isEmpty ? Colors.grey[600] : Colors.white),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(backgroundColor: Colors.redAccent, child: IconButton(icon: const Icon(Icons.send, color: Colors.white), onPressed: _sendMessage)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _meshSubscription?.cancel();
    _ghostController.dispose();
    _scrollController.dispose();
    SecurityService.disableSecureMode();
    super.dispose();
  }
}