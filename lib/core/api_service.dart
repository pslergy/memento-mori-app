// lib/core/api_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:memento_mori_app/core/storage_service.dart';


import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'models/ad_packet.dart';
import 'network_monitor.dart';
import 'native_mesh_service.dart';

class ApiService {
  final String _baseUrl = 'https://89.125.131.63:3000/api';
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true, // Более надежный режим для Tecno/Xiaomi
    ),
  );
  static const String _torProxy = "SOCKS5 127.0.0.1:9050";
  bool _useTor = false;
  static String? _memoizedToken;
  static String? _cachedUserId;
  String get currentUserId => _cachedUserId ?? "";

  // ✅ БЕЗОПАСНЫЙ МЕТОД ЧТЕНИЯ (Защита от красного экрана)
  Future<String?> _safeRead(String key) async {
  try {
  return await Vault.read( key);
  } catch (e) {
  print("☢️ [Storage] Decryption failed for key: $key. Wiping corrupted data...");
  // Если случился BAD_DECRYPT — стираем всё, чтобы приложение не "умерло" навсегда

  return null;
  }
  }

  bool get isGhostMode => _memoizedToken == 'GHOST_MODE_ACTIVE';

  Future<Map<String, String>> _getHeaders() async {
    _memoizedToken ??= await _safeRead('auth_token');

    return {
      'Content-Type': 'application/json',
      'Host': 'update.microsoft.com',
      // Если мы призраки - не шлем левый токен серверу
      if (_memoizedToken != null && !isGhostMode) 'Authorization': 'Bearer $_memoizedToken',
    };
  }

  // Не забудь поправить метод loadSavedIdentity
  Future<void> loadSavedIdentity() async {
    _cachedUserId = await Vault.read('user_id'); // Используем Vault!
    _memoizedToken = await Vault.read('auth_token');

    if (isGhostMode) {
      print("👻 [Auth] GHOST PROTOCOL DETECTED. Network bypass enabled.");
    } else if (_memoizedToken != null) {
      print("🌐 [Auth] Cloud Token detected.");
    } else {
      print("👤 [Auth] No Identity. Login required.");
    }
  }



  // Добавь проверку: авторизован ли пользователь (для Auth Gate)
  bool get isAuthenticated => _cachedUserId != null;



  static void init() {
    print("🚀 [ApiService] Initializing Network Systems...");
    NetworkMonitor().start();
    NativeMeshService.init();
  }

  IOClient _createHttpClient() {
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    httpClient.connectionTimeout = const Duration(seconds: 10);
    if (_useTor) {
      httpClient.findProxy = (uri) => _torProxy;
    }
    return IOClient(httpClient);
  }

  // ===========================================================================
  // 🧠 УМНАЯ МАРШРУТИЗАЦИЯ (DIRECT -> CACHE -> MESH)
  // ===========================================================================




  Future<dynamic> _makeRequest({
    required String method,
    required String endpoint,
    dynamic body,
  }) async {
    // Если мы Призрак - НИКАКОГО HTTP. Сразу в оффлайн-обработку.
    if (isGhostMode) {
      return _handleOfflineFlow(method, endpoint, body);
    }

    // Если мы не призрак, проверяем роль и шлем запрос
    final currentRole = NetworkMonitor().currentRole;
    if (currentRole == MeshRole.BRIDGE) {
      try {
        return await _sendDirectHttp(method, endpoint, body);
      } catch (e) {
        return _handleOfflineFlow(method, endpoint, body);
      }
    } else {
      return _handleOfflineFlow(method, endpoint, body);
    }
  }

  // 🔥 ЛОГИКА ВЫЖИВАНИЯ: Если нет сети, пробуем Mesh, если нет Mesh — отдаем из SQLite
  /// Логика выживания: Фолбек для оффлайна
  Future<dynamic> _handleOfflineFlow(String method, String endpoint, dynamic body) async {
    final db = LocalDatabaseService();
    final mesh = locator<MeshService>();

    // 🔥 ИНЪЕКЦИЯ ДЛЯ ОФФЛАЙНА
    if (endpoint == '/chats' && method == 'GET') {
      _log("📦 [API] Hard-injecting Beacon into offline list.");

      List<Map<String, dynamic>> offlineList = [
        {
          'id': 'THE_BEACON_GLOBAL',
          'name': 'THE BEACON (Global SOS)',
          'type': 'GLOBAL',
          'lastMessage': {'content': 'Mesh Active.', 'createdAt': DateTime.now().toIso8601String()},
          'otherUser': null
        }
      ];

      // Добавляем соседей, которых видим по Mesh
      for (var node in mesh.nearbyNodes) {
        if (currentUserId.isEmpty) continue;
        List<String> ids = [currentUserId, node.id];
        ids.sort();
        offlineList.add({
          'id': "GHOST_${ids[0]}_${ids[1]}",
          'name': node.name,
          'type': 'DIRECT',
          'otherUser': {'id': node.id, 'username': node.name}
        });
      }
      return offlineList;
    }

    // История сообщений из SQLite
    if (endpoint.contains('/messages') && method == 'GET') {
      final String chatId = endpoint.split('/')[2];
      final localMsgs = await db.getMessages(chatId);
      return localMsgs.map((m) => m.toJson()).toList();
    }

    // Профиль (Identity Recovery)
    if (endpoint == '/users/me' && method == 'GET') {
      final ghostId = await Vault.read('user_id');
      final ghostName = await Vault.read('user_name') ?? "Ghost";
      return {'id': ghostId ?? "LOCAL_NODE", 'username': ghostName, 'isGhost': true};
    }

    return [];
  }


  Future<dynamic> _sendDirectHttp(String method, String endpoint, dynamic body) async {
    final client = _createHttpClient();
    final url = Uri.parse('$_baseUrl$endpoint');
    final token = await Vault.read( 'auth_token');

    final headers = {
      'Content-Type': 'application/json',
      'Host': 'update.microsoft.com', // Маскировка трафика
      if (token != null) 'Authorization': 'Bearer $token',
    };

    dynamic encodedBody = (body != null && body is! String) ? jsonEncode(body) : body;

    try {
      http.Response response;
      if (method == 'POST') {
        response = await client.post(url, headers: headers, body: encodedBody).timeout(const Duration(seconds: 10));
      } else if (method == 'GET') {
        response = await client.get(url, headers: headers).timeout(const Duration(seconds: 10));
      } else {
        throw Exception("Method not implemented");
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body.isEmpty ? {} : jsonDecode(response.body);
      } else {
        throw Exception('Server Error: ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  Future<void> syncAdsFromServer() async {
    try {
      print("📡 [AdSync] Connecting to VPS for tactical ads...");

      // 1. Делаем запрос
      final response = await _sendDirectHttp('GET', '/ads', null);

      if (response == null || response is! List) {
        print("⚠️ [AdSync] Empty or invalid response from server.");
        return;
      }

      final db = LocalDatabaseService();
      int count = 0;

      for (var adJson in response) {
        try {
          // Принудительно конвертируем в Map
          final Map<String, dynamic> adMap = Map<String, dynamic>.from(adJson);
          final ad = AdPacket.fromJson(adMap);

          // 2. Сохраняем в SQLite
          await db.saveAd(ad);
          count++;
        } catch (e) {
          print("❌ [AdSync] Failed to parse single ad: $e");
        }
      }

      print("✅ [AdSync] Successfully cached $count ads from Cloud.");
    } catch (e) {
      print("❌ [AdSync] Critical Sync Error: $e");
    }
  }

  // Хелпер для конвертации (если нужно)
  Map<String, dynamic> rawToMap(dynamic data) => Map<String, dynamic>.from(data);

  Future<dynamic> _sendViaMesh(String method, String endpoint, dynamic body) async {
    try {
      final token = _memoizedToken ?? await Vault.read( 'auth_token');
      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'
      };

      // Ждем ответа от соседа
      final response = await locator<MeshService>().sendThroughMesh(
          '/api$endpoint',
          method,
          headers,
          body is String ? body : (body != null ? jsonEncode(body) : null)
      );

      // Проверяем, что в ответе есть тело
      return response['body'] ?? {};

    } catch (e) {
      // 🔥 ГЛАВНОЕ: Вместо выброса исключения, возвращаем "пустой" результат
      print("⚠️ [MeshBridge] Target node did not respond: $e");

      // Если это запрос списка чатов или частот — возвращаем пустой массив
      if (endpoint.contains('trending') || endpoint.contains('chats')) {
        return [];
      }
      // В противном случае возвращаем null или ошибку в виде Map
      return {'error': 'Offline: No bridge found'};
    }
  }



  Map<String, String> _getObfuscatedHeaders(String? token) {
    return {
      'Content-Type': 'application/json',
      // Маскируемся под домен из "белого списка"
      'Host': 'update.microsoft.com',
      // Используем стандартный браузерный User-Agent
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json',
      'Connection': 'keep-alive',
      if (token != null) 'Authorization': 'Bearer $token',
      // Добавляем случайную энтропию в заголовки, чтобы размер пакета всегда был разным
      // Это сбивает с толку алгоритмы анализа трафика по размеру
      'X-Static-Entropy': DateTime.now().millisecond.toString(),
    };
  }
  Future<void> syncOutbox() async {
    final db = LocalDatabaseService();
    final pendingMessages = await db.getPendingFromOutbox();

    if (pendingMessages.isEmpty) return;

    print("🔄 [Bridge] Found ${pendingMessages.length} pending signals. Synchronizing...");

    for (var raw in pendingMessages) {
      try {
        final String chatId = raw['chatRoomId'];

        // Шлем на сервер через стандартный метод
        await _sendDirectHttp('POST', '/chats/$chatId/messages', {
          'content': raw['content'],
          'isEncrypted': raw['isEncrypted'] == 1,
          'clientTempId': raw['id'], // Используем ID из оффлайна для дедупликации на сервере
        });

        // Если сервер принял - удаляем из очереди
        await db.removeFromOutbox(raw['id']);
        print("✅ [Bridge] Signal ${raw['id'].substring(0,8)} relayed to Cloud.");

      } catch (e) {
        print("⚠️ [Bridge] Relay failed for ${raw['id']}: $e");
        break; // Останавливаем, если сеть снова пропала
      }
    }
  }

  Future<void> syncGhostIdentity() async {
    final String? token = await Vault.read('auth_token');
    if (token != 'GHOST_MODE_ACTIVE') return; // Мы уже в онлайне

    _log("🧬 [Sync] Attempting to legalize Ghost Identity on Server...");

    final ghostId = await Vault.read('user_id');
    final ghostName = await Vault.read('user_name');

    // Шлем специальный запрос на "прописку" призрака
    final res = await _sendDirectHttp('POST', '/auth/ghost-sync', {
      'id': ghostId,
      'username': ghostName,
      // Тут можно передать публичный ключ для E2EE
    });

    if (res != null && res['token'] != null) {
      // Сервер выдал нам настоящий JWT!
      await Vault.write('auth_token', res['token']);
      _memoizedToken = res['token'];
      _log("✅ [Sync] Ghost identity is now official. JWT obtained.");
    }
  }

  void _log(String msg) {
    print("📡 [API-Service] $msg");
  }

  Future<void> legalizeIdentity() async {
    final pass = await Vault.read('landing_pass');
    final ghostId = await Vault.read('user_id');
    final email = await Vault.read('user_email');

    if (pass == null || ghostId == null) return;

    _log("🧬 [Legalization] Sending Landing Pass for $ghostId...");

    try {
      final res = await _sendDirectHttp('POST', '/auth/legalize', {
        'ghostId': ghostId,
        'email': email,
        'pass': pass,
      });

      if (res != null && res['status'] == 'verified') {
        _log("✅ Identity Legalized. Token upgraded.");
        await Vault.write('auth_token', res['token']);
        await Vault.write('auth_mode', 'citizen'); // Мы больше не призраки
      }
    } catch (e) {
      _log("⚠️ Legalization failed: $e");
    }
  }


  // Метод для переключения режима (например, из настроек)
  void setTorMode(bool enabled) {
    _useTor = enabled;
    print("🧅 [API] TOR Mode set to: $enabled");

    // ВАЖНО: Если мы переключили TOR, желательно
    // проверить доступность сети через NetworkMonitor().checkNow();
  }





  // Метод для полной очистки при логауте
  Future<void> logout() async {
    _memoizedToken = null;
    await _storage.deleteAll();
  }

  // ===========================================================================
  // 🧠 УМНАЯ МАРШРУТИЗАЦИЯ (DIRECT -> TOR -> MESH)
  // ===========================================================================



  // Вынес попытку TOR/Mesh в отдельный метод для чистоты
  Future<dynamic> _tryTorOrMesh(String method, String endpoint, dynamic body) async {
    if (!_useTor) {
      _useTor = true;
      try {
        final result = await _sendDirectHttp(method, endpoint, body);
        return result;
      } catch (e2) {
        _useTor = false;
        return _sendViaMesh(method, endpoint, body);
      }
    }
    return _sendViaMesh(method, endpoint, body);
  }







  Future<List<dynamic>> getAvailableGroups() async {
    return await _makeRequest(method: 'GET', endpoint: '/chats/available-groups');
  }

  // Запрос на вступление
  Future<Map<String, dynamic>> joinGroupRequest(String groupId) async {
    return await _makeRequest(
        method: 'POST',
        endpoint: '/chats/join-request',
        body: {'chatId': groupId}
    );
  }









  // ===========================================================================
  // 🛰️ ПУБЛИЧНЫЕ МЕТОДЫ API (С поддежкой GHOST/MESH режимов)
  // ===========================================================================

  /// ВХОД (Требует прямой связи с сервером)
  Future<Map<String, dynamic>> login(String email, String password) async {
    // Для логина мы используем прямую отправку, так как это критический узел безопасности
    final response = await _sendDirectHttp('POST', '/auth/login', {
      'email': email,
      'password': password
    });

    if (response != null && response['token'] != null) {
      _memoizedToken = response['token'];
      final user = response['user'];

      // Сразу кэшируем личность
      _cachedUserId = user['id'].toString();
      await Vault.write( 'auth_token',  _memoizedToken);
      await Vault.write( 'user_id',  _cachedUserId);
      await Vault.write( 'user_name',  user['username']);
    }
    return response;
  }

  /// ПОЛУЧИТЬ МОЙ ПРОФИЛЬ (С поддержкой оффлайна)
  Future<Map<String, dynamic>> getMe() async {
    try {
      // Пытаемся стучаться на сервер через роутер
      final response = await _makeRequest(method: 'GET', endpoint: '/users/me');

      if (response != null && response['id'] != null) {
        _cachedUserId = response['id'].toString();
        await Vault.write( 'user_id',  _cachedUserId);
        return response;
      }
      throw Exception("Invalid server response");
    } catch (e) {
      print("📡 [API] getMe failed, recovering from vault...");

      // ВОТ ЗДЕСЬ ФИКС: Если сервера нет, достаем из памяти и КЭШИРУЕМ в переменную
      final savedId = await _safeRead('user_id');
      final savedName = await _safeRead('user_name') ?? "Ghost";

      if (savedId != null) {
        _cachedUserId = savedId; // Обязательно обновляем кэш!
        return {'id': savedId, 'username': savedName, 'isGhost': true};
      }

      return {'id': "LOCAL_NODE", 'username': "Ghost", 'isGhost': true};
    }
  }

  Future<void> createOfflineIdentity(String username) async {
    final ghostId = "GHOST_${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}";

    await Vault.write( 'user_id',  ghostId);
    await Vault.write( 'user_name',  username);
    await Vault.write( 'auth_mode',  'offline');
    // Пишем фейковый токен, чтобы AuthGate не ругался на его отсутствие
    await Vault.write( 'auth_token',  'offline_stealth_token');

    _cachedUserId = ghostId;
    _memoizedToken = 'offline_stealth_token';

    print("🛡️ [Auth] Offline Identity Created: $ghostId");
  }

  /// СПИСОК ЧАТОВ
  /// СПИСОК ЧАТОВ (С защитой от исчезновения Маяка)
  /// СПИСОК ЧАТОВ (С защитой от исчезновения)
  Future<List<dynamic>> getChats() async {
    // 1. Создаем "Маяк" как константу
    final beacon = {
      'id': 'THE_BEACON_GLOBAL',
      'name': 'THE BEACON (Global SOS)',
      'type': 'GLOBAL', // Убедись, что это совпадает с типом во вкладке
      'isEphemeral': false,
      'lastMessage': {'content': 'Mesh Active. Frequency secured.', 'createdAt': DateTime.now().toIso8601String()},
      'otherUser': null
    };

    List<dynamic> chats = [];

    try {
      // 2. Пытаемся получить данные (через облако или кэш/меш)
      final response = await _makeRequest(method: 'GET', endpoint: '/chats');

      if (response is List) {
        chats = response;
      }
    } catch (e) {
      _log("📡 Isolated: Using local Beacon only.");
    }

    // 3. 🔥 ГАРАНТИЯ: Если в списке нет Маяка - вставляем его ПЕРВЫМ
    // Это сработает даже если сервер вернул 404, 500 или пустой []
    if (!chats.any((c) => c['id'] == 'THE_BEACON_GLOBAL')) {
      chats.insert(0, beacon);
    }

    return chats;
  }

  /// ИСТОРИЯ СООБЩЕНИЙ
  Future<List<dynamic>> getMessages(String chatId) async {
    return await _makeRequest(method: 'GET', endpoint: '/chats/$chatId/messages');
  }

  /// СОЗДАТЬ ЛИНК (Личный чат)
  Future<Map<String, dynamic>> findOrCreateChat(String friendId) async {
    return await _makeRequest(
        method: 'POST',
        endpoint: '/chats/direct',
        body: {'userId': friendId}
    );
  }

  /// СОЗДАТЬ ОТРЯД (Группа)
  Future<Map<String, dynamic>> createGroupChat(String name, List<String> userIds) async {
    return await _makeRequest(
        method: 'POST',
        endpoint: '/chats/group',
        body: {'name': name, 'userIds': userIds}
    );
  }

  /// ПОИСК СИГНАЛОВ (Пользователей)
  Future<List<dynamic>> searchUsers(String query) async {
    // Поиск работает только в онлайне или через Bridge
    return await _makeRequest(method: 'GET', endpoint: '/friends/search?query=$query');
  }

  /// ЗАПРОС НА УСТАНОВКУ СВЯЗИ (Дружба)
  Future<void> sendFriendRequest(String friendId) async {
    await _makeRequest(method: 'POST', endpoint: '/friends/add', body: {'friendId': friendId});
  }

  /// АКТИВНЫЕ ЧАСТОТЫ (Тренды)
  Future<List<dynamic>> getTrendingBranches() async {
    return await _makeRequest(method: 'GET', endpoint: '/chats/trending');
  }

  /// СЛОВАРЬ GUARDIAN (Цензурные фильтры)
  Future<Map<String, dynamic>> getGuardianDictionary() async {
    return await _makeRequest(method: 'GET', endpoint: '/guardian/dictionary');
  }

  /// ЖАЛОБА (Report)
  Future<void> sendReport({
    required String reason,
    required String reportedUserId,
    String? description,
    String? messageId
  }) async {
    await _makeRequest(
        method: 'POST',
        endpoint: '/reports',
        body: {
          'reason': reason,
          'reportedUserId': reportedUserId,
          'description': description,
          'messageId': messageId
        }
    );
  }

  /// ПРОТОКОЛ NUKE (Удаление аккаунта)
  Future<void> nukeAccount() async {
    await _makeRequest(method: 'DELETE', endpoint: '/users/nuke');
    // Стираем всё локально после команды серверу
    _memoizedToken = null;
    _cachedUserId = null;
    await _storage.deleteAll();
    await LocalDatabaseService().clearAll();
  }

  /// ГЕНЕРАЦИЯ ТРАФИКОВОГО ШУМА (DPI Deception)
  /// Запутывает системы анализа трафика, создавая фейковые запросы
  Future<void> generateTrafficNoise() async {
    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      final client = _createHttpClient();
      try {
        // Имитируем обычный поиск в Google, чтобы скрыть активность мессенджера
        await client.get(Uri.parse('https://www.google.com/search?q=weather+today+in+Amsterdam'))
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Ошибка шума не важна
      } finally {
        client.close();
      }
    }
  }


  /// ПОЛУЧИТЬ СПИСОК ДРУЗЕЙ (Для создания групп)
  Future<List<dynamic>> getFriends() async {
    try {
      // Пропускаем запрос через маршрутизатор (Direct -> Mesh -> Cache)
      final response = await _makeRequest(method: 'GET', endpoint: '/friends');

      // Если сервер или мост вернули данные — возвращаем их
      if (response is List) {
        return response;
      }
      return [];
    } catch (e) {
      print("⚠️ [API] Failed to fetch friends list: $e");
      // В будущем здесь можно добавить загрузку из локальной таблицы 'friends' в SQLite
      return [];
    }
  }

  // --- СИСТЕМНЫЕ МЕТОДЫ ---

  Future<Map<String, dynamic>> generateRecoveryPhrase() async {
    return await _makeRequest(method: 'POST', endpoint: '/auth/generate-recovery');
  }

  Future<Map<String, dynamic>> recoverAccount({
    required String email,
    required String recoveryPhrase,
    required String newPassword,
  }) async {
    return await _sendDirectHttp('POST', '/auth/recover', {
      'email': email,
      'recoveryPhrase': recoveryPhrase.trim().toLowerCase(),
      'newPassword': newPassword,
    });
  }}