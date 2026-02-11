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
import 'security_config.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IOWebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _streamController =
      StreamController.broadcast();
  Timer? _reconnectTimer;

  bool _isConnecting = false;
  bool _isAlive = false;
  String? _cachedToken;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Stream<Map<String, dynamic>> get stream => _streamController.stream;

  Future<void> initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);
    await _notifications.initialize(initSettings);
  }

  Future<void> ensureConnected() async {
    if (!_isAlive || _channel == null) {
      await connect();
    }
  }

  Future<void> connect() async {
    if (_isConnecting || NetworkMonitor().currentRole == MeshRole.GHOST) return;
    _isConnecting = true;

    try {
      _cachedToken ??= await Vault.read('auth_token');
      if (_cachedToken == null) {
        _isConnecting = false;
        return;
      }

      final String secureWsUrl = "${SecurityConfig.backendWsOrigin}?token=$_cachedToken";
      _log("🌐 Handshaking with ${SecurityConfig.backendHost}");

      // Используем runZonedGuarded или try-catch вокруг самого подключения
      _channel = IOWebSocketChannel.connect(
        Uri.parse(secureWsUrl),
        pingInterval: const Duration(seconds: 10),
      );

      // ОШИБКА ГАСИТСЯ ЗДЕСЬ:
      _channel!.stream.listen(
        (message) => _handleIncoming(message),
        onDone: () => _cleanup(),
        onError: (error) {
          _log("📡 WebSocket unreachable (Handled): $error");
          _cleanup();
        },
      );

      _isAlive = true;
    } catch (e) {
      _log("⚠️ WS Connect block failed: $e");
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _handleIncoming(dynamic raw) async {
    try {
      final data = jsonDecode(raw);

      if (data['type'] == 'newMessage' && data['message'] != null) {
        var msg = data['message'];
        final String chatId = msg['chatRoomId'] ?? "GLOBAL";
        final String senderId = msg['senderId'].toString();
        final String myId = locator.isRegistered<ApiService>()
            ? locator<ApiService>().currentUserId
            : '';

        // Расшифровка
        if (msg['isEncrypted'] == true) {
          final encryption = locator<EncryptionService>();
          final key = await encryption.getChatKey(chatId);
          try {
            msg['content'] = await encryption.decrypt(msg['content'], key);
          } catch (e) {
            msg['content'] = "[Decryption Failed]";
          }
        }

        if (senderId != myId && myId.isNotEmpty) {
          _showStealthNotification(chatId,
              isDirect: !chatId.contains("GLOBAL"));
        }
      }

      if (data['type'] == 'MASS_EMERGENCY') {
        _log("🚨 GLOBAL SOS caught in sector ${data['data']['sectorId']}");
      }

      _streamController.add(data);
    } catch (e) {
      _log("❌ WS-Parse Error: $e");
    }
  }

  Future<void> _showStealthNotification(String id,
      {bool isDirect = false}) async {
    String title = isDirect ? 'Incoming Secure Pulse' : 'System Sync';
    String nodeRef = id.length > 4 ? id.substring(0, 4) : id;
    String body = 'Security packet synchronized. Node: $nodeRef';

    const androidDetails = AndroidNotificationDetails(
      'memento_channel',
      'Security Updates',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      showWhen: true,
    );
    await _notifications.show(DateTime.now().millisecond, title, body,
        const NotificationDetails(android: androidDetails));
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      _reconnectTimer = Timer(const Duration(seconds: 20), () => connect());
    }
  }

  void _cleanup() {
    _isAlive = false;
    _channel = null;
  }

  Future<void> send(Map<String, dynamic> data) async {
    await ensureConnected();
    if (_channel != null && _isAlive) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (e) {
        _isAlive = false;
        _log("❌ Send failed.");
      }
    }
  }

  void _log(String msg) {
    final timestamp =
        DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    print("[$timestamp] 🌐 [WebSocket] $msg");
    try {
      locator<MeshService>().addLog("🌐 [Cloud] $msg");
    } catch (_) {}
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _cachedToken = null;
    _isAlive = false;
    _channel?.sink.close();
    _channel = null;
  }
}
