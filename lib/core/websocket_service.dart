import 'dart:async';
import 'dart:convert';
import 'dart:io'; // Добавь для проверки платформы
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // 🔥 Уведомления
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';
import 'encryption_service.dart';
import 'locator.dart';
import 'network_monitor.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  final StreamController _streamController = StreamController.broadcast();
  Timer? _reconnectTimer;

  // 🔥 Плагин уведомлений
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  Stream get stream => _streamController.stream;

  // Инициализация уведомлений (вызови в main.dart или при старте приложения)
  Future<void> initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);
    await _notifications.initialize(initSettings);
  }

  Future<void> connect() async {
    if (_channel != null) return;

    try {
      // ПРОВЕРКА: Если мы в режиме GHOST, даже не пытаемся стучать в интернет
      if (NetworkMonitor().currentRole == MeshRole.GHOST) {
        print("📡 [WebSocket] System in GHOST mode. Cloud handshake skipped.");
        return;
      }

      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'auth_token');
      if (token == null) return;

      // Используем cast для предотвращения ошибок типизации в потоке
      _channel = WebSocketChannel.connect(
        Uri.parse('wss://89.125.131.63:3000?token=$token'),
      );

      _channel!.stream.listen(
            (message) => _handleIncoming(message),
        onDone: () {
          print("📡 [WebSocket] Connection closed.");
          _channel = null;
          _scheduleReconnect();
        },
        onError: (error) {
          // 🔥 ИСПРАВЛЕНО: Ловим ошибку сети (errno 101) и не даем ей вылететь
          print("📡 [WebSocket] Link unavailable: $error");
          _channel = null;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      print("📡 [WebSocket] Handshake failed: $e");
      _scheduleReconnect();
    }
  }

  Future<void> _handleIncoming(dynamic raw) async {
    try {
      final data = jsonDecode(raw);

      if (data['type'] == 'newMessage' && data['message'] != null) {
        var msg = data['message'];
        final String chatId = msg['chatRoomId'] ?? "GLOBAL";
        final String senderId = msg['senderId'].toString();

        // 🔥 ПОЛУЧАЕМ НАШ ID ИЗ КЭША API СЕРВИСА
        final String myId = locator<ApiService>().currentUserId;

        // 1. Расшифровка (как и раньше)
        if (msg['isEncrypted'] == true) {
          final encryption = locator<EncryptionService>();
          final key = await encryption.getChatKey(chatId);
          try {
            msg['content'] = await encryption.decrypt(msg['content'], key);
          } catch (e) { msg['content'] = "[Decryption Failure]"; }
        }

        // 2. 🔥 ГЛАВНЫЙ ФИЛЬТР: Шлем уведомление ТОЛЬКО если отправитель — НЕ МЫ
        if (senderId != myId && myId.isNotEmpty) {
          print("🔔 [Notification] New message from node: $senderId");
          _showStealthNotification(chatId, isDirect: !chatId.contains("GLOBAL"));
        } else {
          print("🔕 [Notification] Own message detected. Suppressing alert.");
        }
      }

      _streamController.add(data);
    } catch (e) {
      print("❌ [WS] Incoming packet error: $e");
    }
  }

  // 🔥 ИСПРАВЛЕННЫЙ МЕТОД: Добавлен именованный параметр isDirect
  Future<void> _showStealthNotification(String id, {bool isDirect = false}) async {
    // Маскируем заголовок в зависимости от типа чата
    String title = isDirect ? 'Incoming Secure Pulse' : 'System Sync';
    String body = 'Security packet synchronized. Node: ${id.substring(0, 4)}';

    const androidDetails = AndroidNotificationDetails(
      'memento_channel', 'Security Updates',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: false,
    );
    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecond,
      title,
      body,
      details,
    );
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () => connect());
  }

  Future<void> send(Map<String, dynamic> data) async {
    if (_channel == null) return;
    try {
      if (data.containsKey('content') && data['content'] is String) {
        final encryption = locator<EncryptionService>();
        final String chatId = data['chatId'] ?? "GLOBAL";
        final key = await encryption.getChatKey(chatId);
        data['content'] = await encryption.encrypt(data['content'], key);
        data['isEncrypted'] = true;
      }
      _channel!.sink.add(jsonEncode(data));
    } catch (e) {
      print("❌ [WS] Send error: $e");
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
  }
}