import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';
import 'encryption_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'network_monitor.dart';


class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IOWebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _streamController = StreamController.broadcast();
  Timer? _reconnectTimer;

  bool _isConnecting = false;
  bool _isAlive = false;
  String? _cachedToken; // Кэш для предотвращения лишних VAULT-READ

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  final String _wsUrl = "wss://89.125.131.63:3000";

  Stream<Map<String, dynamic>> get stream => _streamController.stream.cast<Map<String, dynamic>>();

  /// Инициализация уведомлений
  Future<void> initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);
    await _notifications.initialize(initSettings);
  }

  /// Проверка живого соединения (Критично для Huawei/Tecno)
  Future<void> ensureConnected() async {
    if (!_isAlive || _channel == null) {
      print("🔄 [WebSocket-Monitor] Link inactive. Reconnecting...");
      await connect();
    }
  }

  /// Основной метод подключения
  Future<void> connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      // 1. Проверка режима (если оффлайн - выходим)
      if (NetworkMonitor().currentRole == MeshRole.GHOST) {
        print("📡 [WebSocket] System in GHOST mode. Cloud handshake skipped.");
        _isAlive = false;
        return;
      }

      // 2. Получение токена (сначала из кэша, потом из памяти)
      _cachedToken ??= await Vault.read('auth_token');

      if (_cachedToken == null || _cachedToken == 'GHOST_MODE_ACTIVE') {
        print("👤 [WebSocket] No valid Cloud token found.");
        _isAlive = false;
        return;
      }

      print("🌐 [WebSocket] Connecting to Command Center...");

      // 3. Создание сокета
      _channel = IOWebSocketChannel.connect(
        Uri.parse('$_wsUrl?token=$_cachedToken'),
        pingInterval: const Duration(seconds: 10), // Защита от Doze-mode
      );

      _isAlive = true;

      // 4. Слушатель потока
      _channel!.stream.listen(
            (message) {
          _isAlive = true;
          _handleIncoming(message);
        },
        onDone: () {
          print("🔌 [WebSocket] Connection closed by server.");
          _cleanup();
          _scheduleReconnect();
        },
        onError: (error) {
          print("❌ [WebSocket] Connection error: $error");
          _cleanup();
          _scheduleReconnect();
        },
      );

      print("✅ [WebSocket] Cloud Link Established.");

    } catch (e) {
      print("📡 [WebSocket] Critical failure: $e");
      _cleanup();
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  /// Обработка входящих пакетов
  Future<void> _handleIncoming(dynamic raw) async {
    try {
      final data = jsonDecode(raw);

      if (data['type'] == 'newMessage' && data['message'] != null) {
        var msg = data['message'];
        final String chatId = msg['chatRoomId'] ?? "GLOBAL";
        final String senderId = msg['senderId'].toString();
        final String myId = locator<ApiService>().currentUserId;

        // Расшифровка, если пакет защищен
        if (msg['isEncrypted'] == true) {
          final encryption = locator<EncryptionService>();
          final key = await encryption.getChatKey(chatId);
          try {
            msg['content'] = await encryption.decrypt(msg['content'], key);
          } catch (e) {
            msg['content'] = "[Secure Packet: Decryption required]";
          }
        }
        if (data['type'] == 'MASS_EMERGENCY') {
          _log("🚨 GLOBAL ALERT: Mass SOS detected in sector ${data['data']['sectorId']}");
          _streamController.add(data); // Пробрасываем в UI
        }

        // Уведомление, если сообщение не от нас
        if (senderId != myId && myId.isNotEmpty) {
          _showStealthNotification(chatId, isDirect: !chatId.contains("GLOBAL"));
        }
      }

      _streamController.add(data);
    } catch (e) {
      print("❌ [WS-Parse] Error: $e");
    }
  }

  /// Маскированное уведомление
  Future<void> _showStealthNotification(String id, {bool isDirect = false}) async {
    String title = isDirect ? 'Incoming Secure Pulse' : 'System Sync';
    String nodeRef = id.length > 4 ? id.substring(0, 4) : id;
    String body = 'Security packet synchronized. Node: $nodeRef';

    const androidDetails = AndroidNotificationDetails(
      'memento_channel', 'Security Updates',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(DateTime.now().millisecond, title, body, details);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 10), () => connect());
  }

  void _cleanup() {
    _isAlive = false;
    _channel = null;
  }

  /// Отправка данных
  Future<void> send(Map<String, dynamic> data) async {
    await ensureConnected();
    if (_channel != null && _isAlive) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (e) {
        print("❌ [WS-Send] Failed: $e");
        _isAlive = false;
      }
    }
  }

  void _log(String msg) {
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    print("[$timestamp] 🌐 [WebSocket] $msg");

    // Пробрасываем лог в общий терминал MeshService через locator
    try {
      locator<MeshService>().addLog("🌐 [Cloud] $msg");
    } catch (e) {
      // Игнорируем, если MeshService еще не инициализирован
    }
  }

  /// Полный сброс (при логауте)
  void disconnect() {
    _reconnectTimer?.cancel();
    _cachedToken = null;
    _isAlive = false;
    _channel?.sink.close();
    _channel = null;
  }
}