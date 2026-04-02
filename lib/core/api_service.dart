// lib/core/api_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:memento_mori_app/core/storage_service.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:memento_mori_app/core/security_config.dart'; // 🔒 SECURITY FIX
import 'package:synchronized/synchronized.dart';

import 'beacon_country_helper.dart';
import 'encryption_service.dart';
import 'exceptions.dart';
import 'local_db_service.dart';
import 'location_name_service.dart';
import 'internet/connection_attempt_logger.dart';
import 'internet/dart_io_http_stack.dart';
import 'internet/dpi_backend_channel_gate.dart';
import 'internet/dpi_backend_channel_policy.dart';
import 'internet/http_stack.dart';
import 'internet/mycelium_quic_client.dart';
import 'internet/mycelium_quic_policy.dart';
import 'internet/mycelium_runtime_healing.dart';
import 'internet/mycelium_transport_report.dart';
import 'internet/quic_transport_guard.dart';
import 'internet/tunnel_config.dart';
import 'internet/tunnel_config_provider.dart';
import 'locator.dart';
import 'mesh_core_engine.dart';
import 'room_id_normalizer.dart';
import 'models/ad_packet.dart';
import 'network_monitor.dart';
import 'native_mesh_service.dart';

// OFFLINE FIRST: Ghost identity creation using only Vault + EncryptionService. No ApiService required.
Future<void> createGhostIdentityLocal(String username, String email) async {
  if (!locator.isRegistered<EncryptionService>()) {
    throw StateError(
        'Ghost creation requires CORE locator (EncryptionService). Run setupCoreLocator before registration.');
  }
  final displayName = username.trim().isEmpty ? 'Traveler' : username.trim();
  final encryption = locator<EncryptionService>();
  final identity = await encryption.generateGhostIdentity(displayName);
  final String ghostId = identity['userId']!;
  final String landingPass =
      await encryption.generateLandingPass(email, ghostId);
  await Vault.write('user_id', ghostId);
  await Vault.write('user_name', displayName);
  await Vault.write('user_email', email);
  await Vault.write('landing_pass', landingPass);
  await Vault.write('auth_token', 'GHOST_MODE_ACTIVE');
  final deathDate =
      DateTime.now().add(const Duration(days: 365 * 75)).toIso8601String();
  final birthDate = DateTime(2000, 1, 1).toIso8601String();
  await Vault.write('user_deathDate', deathDate);
  await Vault.write('user_birthDate', birthDate);
  await GhostBackup.save(ghostId, deathDate, birthDate, userName: displayName);
}

class ApiService {
  String get _baseUrl => SecurityConfig.backendBaseUrl;
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true, // Более надежный режим для Tecno/Xiaomi
    ),
  );
  static const String _torProxy = "SOCKS5 127.0.0.1:9050";
  bool _useTor = false;
  bool _isSyncing = false;
  bool _syncAdsInFlight = false;
  static String? _memoizedToken;
  static String? _cachedUserId;
  String get currentUserId => _cachedUserId ?? "";

  // 🛡️ ANTICENSORSHIP: ephemeral token for mesh senderId (anonymous over-the-air)
  String? _ephemeralToken;
  DateTime? _ephemeralTokenExpiry;
  static const Duration _ephemeralTokenTtl = Duration(minutes: 50);
  String get meshSenderId => _ephemeralToken != null &&
          _ephemeralTokenExpiry != null &&
          DateTime.now().isBefore(_ephemeralTokenExpiry!)
      ? _ephemeralToken!
      : (_cachedUserId ?? 'GHOST_NODE');

  /// Fetches ephemeral token when connectivity exists. Call on login/BRIDGE.
  Future<void> fetchEphemeralTokenIfNeeded() async {
    if (isGhostMode) return;
    final now = DateTime.now();
    final refreshMargin = Duration(
        minutes: (_ephemeralTokenTtl.inMinutes ~/ 5).clamp(1, 15));
    if (_ephemeralToken != null &&
        _ephemeralTokenExpiry != null &&
        now.add(refreshMargin).isBefore(_ephemeralTokenExpiry!)) {
      return;
    }
    try {
      final res = await _sendDirectHttp('POST', '/auth/ephemeral-token', null);
      if (res is Map && res['ephemeralToken'] != null) {
        _ephemeralToken = res['ephemeralToken'] as String;
        _ephemeralTokenExpiry = DateTime.fromMillisecondsSinceEpoch(
            (res['expiresAt'] as num).toInt());
      }
    } catch (_) {}
  }

  // 🔒 Fix race conditions: Use Lock for atomic operations
  final _syncLock = Lock();

  // ✅ БЕЗОПАСНЫЙ МЕТОД ЧТЕНИЯ (Защита от красного экрана)
  Future<String?> _safeRead(String key) async {
    try {
      return await Vault.read(key);
    } catch (e) {
      print(
          "☢️ [Storage] Decryption failed for key: $key. Wiping corrupted data...");
      // Если случился BAD_DECRYPT — стираем всё, чтобы приложение не "умерло" навсегда

      return null;
    }
  }

  bool get isGhostMode => _memoizedToken == 'GHOST_MODE_ACTIVE';

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

  static Future<void> init() async {
    print("🚀 [ApiService] Initializing Network Systems...");

    // 🔒 SECURITY FIX: Load cached TOFU fingerprint on startup
    await SecurityConfig.loadCachedFingerprint();

    NetworkMonitor().start();
    NativeMeshService.init();
  }

  /// DPI-T06: фабрика из [HttpStack] (locator) или [DartIoHttpStack] до регистрации SESSION.
  http.Client _createHttpClient({bool forceDartIo = false}) {
    final params = HttpClientCreationParams(
      useTor: _useTor,
      torProxy: _torProxy,
      forceDartIo: forceDartIo,
    );
    if (locator.isRegistered<HttpStack>()) {
      return locator<HttpStack>().createClient(params);
    }
    return DartIoHttpStack().createClient(params);
  }

  static bool _isAccountDeletedError(Object e) {
    final s = e.toString();
    return s.contains('no longer exists') && s.contains('register again');
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

    final currentRole = NetworkMonitor().currentRole;
    final hasValidBridgeLease = NetworkMonitor().hasValidBridgeLease;
    if (currentRole == MeshRole.BRIDGE && hasValidBridgeLease) {
      try {
        return await _sendDirectHttp(method, endpoint, body);
      } catch (e) {
        return _handleOfflineFlow(method, endpoint, body);
      }
    }
    return _handleOfflineFlow(method, endpoint, body);
  }

  // 🔥 ЛОГИКА ВЫЖИВАНИЯ: Если нет сети, пробуем Mesh, если нет Mesh — отдаем из SQLite
  /// Логика выживания: Фолбек для оффлайна
  /// Логика выживания: Фолбек для оффлайна (Консолидация БД и Mesh-эфира)
  Future<dynamic> _handleOfflineFlow(
      String method, String endpoint, dynamic body) async {
    final db = LocalDatabaseService();
    final MeshCoreEngine? mesh = locator.isRegistered<MeshCoreEngine>()
        ? locator<MeshCoreEngine>()
        : null;

    // 1. ИСТОРИЯ СООБЩЕНИЙ (С учетом владельца)
    if (endpoint.contains('/messages') && method == 'GET') {
      final String chatId = endpoint.split('/')[2];
      // Метод getMessages уже должен внутри использовать currentUserId как фильтр ownerId
      final localMsgs = await db.getMessages(chatId);
      return localMsgs.map((m) => m.toJson()).toList();
    }

    // 2. СПИСОК ЧАТОВ (Гибридный: База + Эфир)
    if (endpoint == '/chats' && method == 'GET') {
      _log("📦 [API] Consolidating persistent and ephemeral chats...");

      // А. Начинаем с Глобального Маяка (всегда первый)
      List<Map<String, dynamic>> consolidatedList = [
        {
          'id': 'THE_BEACON_GLOBAL',
          'name': 'THE BEACON (Global SOS)',
          'type': 'GLOBAL',
          'lastMessage': {
            'content': 'Mesh Active. Frequency secured.',
            'createdAt': DateTime.now().toIso8601String()
          },
          'otherUser': null
        }
      ];

      // Б. Добавляем чаты из SQLite, принадлежащие ЭТОМУ пользователю
      final database = await db.database;
      final List<Map<String, dynamic>> localRooms = await database.query(
          'chat_rooms',
          where: 'ownerId = ?',
          whereArgs: [currentUserId]);

      // Добавляем их в общий список, избегая дублирования с Маяком
      for (var room in localRooms) {
        if (room['id'] != 'THE_BEACON_GLOBAL') {
          consolidatedList.add(Map<String, dynamic>.from(room));
        }
      }

      // В. Добавляем живых соседей из Mesh (которых нет в базе), если MeshCoreEngine доступен
      if (mesh != null) {
        for (var node in mesh.nearbyNodes) {
          if (currentUserId.isEmpty) continue;

          // Нормализация ID в ядре: канонический roomId для DM
          final String meshChatId =
              RoomIdNormalizer.canonicalDmRoomId(currentUserId, node.id);

          // Проверяем, нет ли уже такого чата в списке (чтобы не дублировать)
          bool exists = consolidatedList.any((c) => c['id'] == meshChatId);
          if (!exists) {
            consolidatedList.add({
              'id': meshChatId,
              'name': node.name,
              'type': 'DIRECT',
              'lastMessage': {
                'content': 'Signal detected via Mesh.',
                'createdAt': DateTime.now().toIso8601String()
              },
              'otherUser': {'id': node.id, 'username': node.name}
            });
          }
        }
      }
      return consolidatedList;
    }

    // 3. ПРОФИЛЬ (Identity Recovery)
    if (endpoint == '/users/me' && method == 'GET') {
      final ghostId = await Vault.read('user_id');
      final ghostName = await Vault.read('user_name') ?? "Ghost";
      return {
        'id': ghostId ?? "LOCAL_NODE",
        'username': ghostName,
        'isGhost': true,
        'status': 'STEALTH'
      };
    }

    return [];
  }

  /// SESSION: общий singleton из [locator]. До регистрации — локальный провайдер (экраны без mesh).
  static TunnelConfigProvider _resolveTunnelConfigProvider() {
    if (locator.isRegistered<TunnelConfigProvider>()) {
      return locator<TunnelConfigProvider>();
    }
    return TunnelConfigProvider();
  }

  final ConnectionAttemptLogger _connectionLogger = ConnectionAttemptLogger();
  final TunnelConfigProvider _tunnelConfig =
      ApiService._resolveTunnelConfigProvider();

  Future<http.Response> _dispatchDirectHttp(
    http.Client client,
    String method,
    Uri url,
    Map<String, String> headers,
    dynamic encodedBody,
  ) async {
    if (method == 'POST') {
      return client
          .post(url, headers: headers, body: encodedBody)
          .timeout(const Duration(seconds: 10));
    }
    if (method == 'GET') {
      return client
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 10));
    }
    throw Exception("Method not implemented");
  }

  /// 2xx → тело; иначе исключение (без смены транспорта — тот же [MyceliumTransportReport.effectiveTransport]).
  Future<dynamic> _finishDirectHttpResponse({
    required http.Response response,
    required TunnelConfig config,
    required MyceliumTransportReport tr,
    required DateTime start,
    required List<int?> failureBytesHolder,
  }) async {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      tr.elapsedMs = DateTime.now().difference(start).inMilliseconds;
      if (tr.effectiveTransport == 'quic') {
        tr.quicSucceeded = true;
        QuicTransportGuard.instance.recordQuicTransportSuccess();
        MyceliumRuntimeHealing.instance.onQuicTransportSucceeded();
      }
      DpiBackendChannelGate.resetOnHttpSuccess();
      _connectionLogger.logSuccess(config: config, transportReport: tr);
      return response.body.isEmpty ? {} : jsonDecode(response.body);
    }

    failureBytesHolder[0] = response.bodyBytes.length;
    String errorMessage = 'Server Error: ${response.statusCode}';
    String? errorCode;
    try {
      final errorBody = jsonDecode(response.body);
      errorMessage =
          errorBody['message'] ?? errorBody['error'] ?? errorMessage;
      errorCode = errorBody['code'] ?? errorBody['error'];
    } catch (_) {}

    if (response.statusCode == 401 &&
        (errorCode == 'USER_DELETED' || errorCode == 'AUTH_USER_NOT_FOUND')) {
      _log("🚫 [API] User deleted from database, clearing local token");
      await logout();
      throw Exception(
          'Your account no longer exists. Please register again.');
    }

    throw Exception('$errorMessage (${response.statusCode})');
  }

  Future<dynamic> _sendDirectHttp(
      String method, String endpoint, dynamic body) async {
    final url = Uri.parse('$_baseUrl$endpoint');
    dynamic encodedBody =
        (body != null && body is! String) ? jsonEncode(body) : body;

    final adaptiveOn = SecurityConfig.myceliumAdaptiveDonorSelectionEnabled;
    final runtimeHeal = SecurityConfig.myceliumRuntimeSelfHealingEnabled;
    final broken = MyceliumRuntimeHealing.instance.networkMode ==
        NetworkMode.broken;
    final maxAttempts = (adaptiveOn || runtimeHeal)
        ? (broken
            ? 2
            : SecurityConfig.myceliumDirectHttpFailoverMaxAttempts)
        : 1;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final forceDartIo = (adaptiveOn || runtimeHeal) && attempt == maxAttempts - 1;
      final token = await Vault.read('auth_token');
      final config = await _tunnelConfig.selectConfig();

      final headers = {
        'Content-Type': 'application/json',
        'Host': config.donorHost,
        if (token != null) 'Authorization': 'Bearer $token',
      };

      final start = DateTime.now();
      final failureBytesHolder = <int?>[null];
      final tr = MyceliumTransportReport();

      if (await MyceliumQuicPolicy.shouldAttemptQuicForNextRequest()) {
        tr.quicAttempted = true;
        final qClient = MyceliumQuicClient.tryCreateQuicPreferredClient();
        if (qClient != null) {
          try {
            final qResponse = await _dispatchDirectHttp(
              qClient, method, url, headers, encodedBody);
            tr.effectiveTransport = 'quic';
            final ok = await _finishDirectHttpResponse(
              response: qResponse,
              config: config,
              tr: tr,
              start: start,
              failureBytesHolder: failureBytesHolder,
            );
            return ok;
          } on Exception catch (e) {
            if (_isAccountDeletedError(e)) {
              rethrow;
            }
            QuicTransportGuard.instance.recordQuicTransportFailure();
            MyceliumRuntimeHealing.instance.onQuicTransportFailed();
            tr.tcpFallback = true;
            tr.lastErrorKind = e.runtimeType.toString();
            developer.log(
              'mycelium_quic fail → tcp: $e',
              name: 'mycelium_quic',
            );
          } finally {
            qClient.close();
          }
        }
      }

      tr.effectiveTransport = 'tcp';
      final client = _createHttpClient(forceDartIo: forceDartIo);
      try {
        final response =
            await _dispatchDirectHttp(client, method, url, headers, encodedBody);
        try {
          final ok = await _finishDirectHttpResponse(
            response: response,
            config: config,
            tr: tr,
            start: start,
            failureBytesHolder: failureBytesHolder,
          );
          return ok;
        } on Exception catch (e) {
          if (_isAccountDeletedError(e)) {
            rethrow;
          }
          final elapsed = DateTime.now().difference(start);
          final fb = failureBytesHolder[0] ?? 0;
          tr.elapsedMs = elapsed.inMilliseconds;
          _connectionLogger.logFailure(
            config: config,
            error: e,
            elapsed: elapsed,
            bytesTransferred: fb,
            transportReport: tr,
          );
          if (DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
                error: e,
                httpFailureBodyBytes: fb,
                elapsed: elapsed,
              )) {
            DpiBackendChannelGate.onEligibleForBackendChannelRotate();
          }
          if (attempt >= maxAttempts - 1) {
            rethrow;
          }
          _tunnelConfig.rotateDonorAfterHttpFailure();
          continue;
        }
      } on Exception catch (e) {
        if (_isAccountDeletedError(e)) {
          rethrow;
        }
        final elapsed = DateTime.now().difference(start);
        tr.elapsedMs = elapsed.inMilliseconds;
        _connectionLogger.logFailure(
          config: config,
          error: e,
          elapsed: elapsed,
          bytesTransferred: failureBytesHolder[0] ?? 0,
          transportReport: tr,
        );
        if (DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
              error: e,
              httpFailureBodyBytes: failureBytesHolder[0] ?? 0,
              elapsed: elapsed,
            )) {
          DpiBackendChannelGate.onEligibleForBackendChannelRotate();
        }
        if (attempt >= maxAttempts - 1) {
          rethrow;
        }
        _tunnelConfig.rotateDonorAfterHttpFailure();
        continue;
      } finally {
        client.close();
      }
    }
  }

  Future<void> syncAdsFromServer() async {
    if (_syncAdsInFlight) return;
    _syncAdsInFlight = true;
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
    } finally {
      _syncAdsInFlight = false;
    }
  }

  // Хелпер для конвертации (если нужно)
  Map<String, dynamic> rawToMap(dynamic data) =>
      Map<String, dynamic>.from(data);

  Future<void> syncOutbox() async {
    return await _syncLock.synchronized(() async {
      if (isGhostMode) {
        _log("👤 System in Stealth mode. Sync deferred until legalization.");
        return;
      }
      if (!NetworkMonitor().hasValidBridgeLease) {
        _log("[ROUTER] syncOutbox skipped: no valid BRIDGE lease");
        return;
      }
      if (_isSyncing) {
        _log("⏳ Sync already in progress. Skipping cycle.");
        return;
      }

      _isSyncing = true;

      try {
        final db = LocalDatabaseService();
        final pending = await db.getPendingFromOutbox();

        if (pending.isEmpty) return;

        _log(
            "🔄 [BRIDGE-PROTOCOL] Syncing ${pending.length} encrypted signals...");

        await fetchEphemeralTokenIfNeeded();

        // Кэшируем токен один раз на весь цикл синхронизации
        final String? token = await Vault.read('auth_token');
        if (token == null) return;

        for (var msg in pending) {
          try {
            final String chatId = msg['chatRoomId'];

            // Отправка (senderId для relay и ephemeral)
            final senderId = msg['senderId'];
            await _sendDirectHttp('POST', '/chats/$chatId/messages', {
              'content': msg['content'],
              'isEncrypted': msg['isEncrypted'] == 1,
              'clientTempId': msg['id'],
              if (senderId != null && senderId.toString().isNotEmpty)
                'senderId': senderId.toString(),
            });

            // СРАЗУ удаляем после успеха
            await db.removeFromOutbox(msg['id']);
            _log("✅ [RELAY-SUCCESS] Signal ${msg['id']} delivered.");
          } catch (e) {
            _log("❌ [RELAY-ERROR] Message ${msg['id']} failed: $e");
            // Если сервер вернул 409 (Conflict/Already exists), тоже удаляем из Outbox
            if (e.toString().contains("409"))
              await db.removeFromOutbox(msg['id']);
            break;
          }
        }
      } finally {
        _isSyncing = false; // Разблокировка
      }
    });
  }

  Future<void> legalizeGhostIdentity(String newUsername) async {
    final pass = await Vault.read('landing_pass');
    final ghostId = await Vault.read('user_id');
    final email = await Vault.read('user_email');

    try {
      final res = await _sendDirectHttp('POST', '/auth/legalize', {
        'ghostId': ghostId,
        'email': email,
        'pass': pass,
        'desiredUsername': newUsername, // Юзер может предложить новое имя
      });

      if (res != null && res['token'] != null) {
        // Успех: Мы теперь официальный гражданин Облака
        await Vault.write('auth_token', res['token']);
        await Vault.write('user_name', res['username']);
        await Vault.write('auth_mode', 'verified');
        _memoizedToken = res['token'];
      }
    } catch (e) {
      if (e.toString().contains("409")) {
        // 🔥 КРИТИЧЕСКИЙ КЕЙС: Ник занят!
        _log("⚠️ Legalization failed: Nickname already taken.");
        throw NicknameTakenException(); // Выбрасываем спец-ошибку для UI
      }
      rethrow;
    }
  }

  /// Глобальная регистрация в Облаке
  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required DateTime birthDate,
  }) async {
    final response = await _sendDirectHttp('POST', '/auth/register', {
      'username': username,
      'email': email,
      'password': password,
      'dateOfBirth': birthDate.toIso8601String(),
      'countryCode': 'RU', // Можно определять динамически
      'gender': 'MALE', // Можно добавить в UI позже
    });

    if (response != null && response['token'] != null) {
      final user = response['user'];
      _memoizedToken = response['token'];
      _cachedUserId = user['id'].toString();

      // Сохраняем "Бронь" в Vault
      await Vault.write('auth_token', _memoizedToken);
      await Vault.write('user_id', _cachedUserId);
      await Vault.write('user_name', user['username']);
      await Vault.write('user_deathDate', user['deathDate']);
      await Vault.write('user_birthDate', user['dateOfBirth']);

      return response; // Возвращаем Map, чтобы UI достал recoveryPhrase
    } else {
      throw Exception("Registration failed: Invalid response from server");
    }
  }

  // 🔥 СРАЗУ ДОБАВИМ И МЕТОД ПРОВЕРКИ НИКА, чтобы убрать вторую ошибку в UI
  Future<bool> checkUsernameAvailable(String username) async {
    try {
      final res = await _sendDirectHttp(
          'GET', '/users/check-username?username=$username', null);
      return res['available'] ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<void> sendAonymizedSOS() async {
    Position pos = await Geolocator.getCurrentPosition();

    // Огрубляем до 1.1 км (2 знака после запятой = ~1.1 км точность)
    double lat = double.parse(pos.latitude.toStringAsFixed(2));
    double lon = double.parse(pos.longitude.toStringAsFixed(2));
    String sectorId =
        "S_${lat.toString().replaceAll('.', '')}_${lon.toString().replaceAll('.', '')}";

    // Получаем название места (анонимно, только для зоны 1.1 км)
    final locationService = LocationNameService();
    String? locationName;
    try {
      locationName = await locationService.getLocationName(lat, lon);
    } catch (e) {
      print("⚠️ [SOS] Failed to get location name: $e");
    }

    final sosPayload = {
      "type": "SOS_SIGNAL",
      "sectorId": sectorId, // Сервер видит только это!
      "timestamp": DateTime.now().millisecondsSinceEpoch,
    };

    // Сохраняем в локальную БД для оффлайн работы
    final db = LocalDatabaseService();
    await db.saveSosSignal(
      sectorId: sectorId,
      locationName: locationName,
      lat: lat,
      lon: lon,
    );

    // Пытаемся отправить через Cloud + Mesh (если есть интернет)
    bool cloudSuccess = false;
    try {
      await _makeRequest(
              method: 'POST', endpoint: '/emergency/signal', body: sosPayload)
          .timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('SOS request timeout');
        },
      );
      cloudSuccess = true;
      print("✅ [SOS] Signal sent via Cloud");
    } catch (e) {
      print("⚠️ [SOS] Cloud send failed: $e");
    }

    // 🔥 FALLBACK: Если Cloud не работает - отправляем через Mesh (если зарегистрирован)
    if (!cloudSuccess && locator.isRegistered<MeshCoreEngine>()) {
      try {
        final mesh = locator<MeshCoreEngine>();
        final ultrasonic = locator<UltrasonicService>();

        // Отправляем через Mesh
        await mesh.sendAuto(
          content:
              "🚨 SOS: Sector $sectorId${locationName != null ? ' ($locationName)' : ''}",
          chatId: "THE_BEACON_GLOBAL",
          receiverName: "GLOBAL",
        );
        print("✅ [SOS] Signal sent via Mesh");

        // Также отправляем через Sonar для максимального покрытия
        try {
          await ultrasonic.transmitFrame("SOS:$sectorId");
          print("✅ [SOS] Signal sent via Sonar");
        } catch (e) {
          print("⚠️ [SOS] Sonar send failed: $e");
        }
      } catch (e) {
        print("❌ [SOS] Mesh send failed: $e");
        // Сигнал уже сохранен в БД, отправим позже при синхронизации
      }
    }
  }

  Future<void> initGhostMode(String username, String email) async {
    final encryption = locator<EncryptionService>();
    final displayName = username.trim().isEmpty ? 'Traveler' : username.trim();

    // 1. Генерируем "Призрака"
    final identity = await encryption.generateGhostIdentity(displayName);
    final String ghostId = identity['userId']!;

    // 2. Создаем посадочный талон (хеш, который знает только юзер и сервер в будущем)
    final String landingPass =
        await encryption.generateLandingPass(email, ghostId);

    // 3. Бронируем данные в Vault
    await Vault.write('user_id', ghostId);
    await Vault.write('user_name', displayName);
    await Vault.write('user_email', email);
    await Vault.write('landing_pass', landingPass);
    await Vault.write('auth_token', 'GHOST_MODE_ACTIVE');

    // 4. Считаем даты для Memento Mori (Memento Mori оффлайн-старт)
    final deathDate =
        DateTime.now().add(const Duration(days: 365 * 75)).toIso8601String();
    final birthDate = DateTime(2000, 1, 1).toIso8601String();
    await Vault.write('user_deathDate', deathDate);
    await Vault.write('user_birthDate', birthDate);

    await GhostBackup.save(ghostId, deathDate, birthDate, userName: displayName);

    _memoizedToken = 'GHOST_MODE_ACTIVE';
    _cachedUserId = ghostId;
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

  // 🔒 SECURITY FIX: Mask sensitive data in logs
  String _maskSensitive(String? value) {
    if (value == null || value.length < 8) return '***';
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
  }

  void _log(String msg) {
    print("📡 [API-Service] $msg");
  }

  void _logSecure(String msg, {String? sensitiveValue}) {
    if (sensitiveValue != null) {
      print("📡 [API-Service] $msg: ${_maskSensitive(sensitiveValue)}");
    } else {
      print("📡 [API-Service] $msg");
    }
  }

  /// ПРОТОКОЛ ЛЕГАЛИЗАЦИИ (LANDING PASS)
  /// Переводит оффлайн-личность (GHOST) в статус верифицированного аккаунта.
  /// Реализует атомарный переход с сохранением истории сообщений.
  Future<void> legalizeIdentity(String desiredUsername, String password) async {
    // 1. Извлекаем тактические данные из Vault
    final ghostId = await Vault.read('user_id');
    final email = await Vault.read('user_email');
    final pass = await Vault.read('landing_pass');

    _logSecure("🧬 Initiating Identity Legalization for Nomad",
        sensitiveValue: ghostId);

    try {
      // 2. Отправляем "Посадочный талон" на сервер
      final res = await _sendDirectHttp('POST', '/auth/legalize', {
        'ghostId': ghostId,
        'email': email,
        'pass': pass, // Крипто-хеш оффлайн сессии
        'desiredUsername': desiredUsername,
        'password': password,
      });

      if (res != null && res['token'] != null) {
        // 3. ОБНОВЛЕНИЕ ПРАВ ДОСТУПА
        // Сохраняем официальный JWT токен вместо GHOST_MODE_ACTIVE
        await Vault.write('auth_token', res['token']);

        // Обновляем имя (если оно было изменено сервером при конфликте)
        final String verifiedName = res['username'] ?? desiredUsername;
        await Vault.write('user_name', verifiedName);

        // Сбрасываем кэш токена в памяти сервиса
        _memoizedToken = res['token'];

        _log("✅ Identity Secured. Transitioning to Cloud Synchronized state.");

        // 4. СИНХРОНИЗАЦИЯ ОЧЕРЕДИ
        // Как только мы получили права, выгружаем все накопленные в лесу сообщения
        unawaited(syncOutbox());
      }
    } catch (e) {
      // 5. ОБРАБОТКА ТАКТИЧЕСКИХ ОШИБОК
      final String err = e.toString();

      if (err.contains("409")) {
        _log("⚠️ Conflict: Callsign already taken.");
        throw NicknameTakenException();
      }
      if (err.contains("401")) {
        _log("🚫 Auth Failed: Invalid password for existing account.");
        throw Exception("Invalid credentials for this email.");
      }

      _log("❌ Legalization Fault: $e");
      rethrow;
    }
  }

  // Метод для переключения режима (например, из настроек)
  void setTorMode(bool enabled) {
    _useTor = enabled;
    print("🧅 [API] TOR Mode set to: $enabled");

    // ВАЖНО: Если мы переключили TOR, желательно
    // проверить доступность сети через NetworkMonitor().checkNow();
  }

  // Метод для полной очистки при логауте. Uses Vault when mode-scoped so current mode only is wiped.
  Future<void> logout() async {
    _memoizedToken = null;
    _cachedUserId = null;
    await Vault.deleteAll();
    _log("🚪 [API] Logout completed - all tokens cleared");
  }

  Future<List<dynamic>> getAvailableGroups() async {
    return await _makeRequest(
        method: 'GET', endpoint: '/chats/trending');
  }

  // Запрос на вступление
  Future<Map<String, dynamic>> joinGroupRequest(String groupId) async {
    return await _makeRequest(
        method: 'POST',
        endpoint: '/chats/join-request',
        body: {'chatId': groupId});
  }

  // ===========================================================================
  // 🛰️ ПУБЛИЧНЫЕ МЕТОДЫ API (С поддежкой GHOST/MESH режимов)
  // ===========================================================================

  /// ВХОД (Требует прямой связи с сервером)
  Future<Map<String, dynamic>> login(String email, String password) async {
    // Для логина мы используем прямую отправку, так как это критический узел безопасности
    // Нормализуем email (убираем пробелы, приводим к нижнему регистру)
    final normalizedEmail = email.trim().toLowerCase();

    try {
      final response = await _sendDirectHttp('POST', '/auth/login',
          {'email': normalizedEmail, 'password': password});

      if (response != null && response['token'] != null) {
        _memoizedToken = response['token'];
        final user = response['user'];

        // Сразу кэшируем личность
        _cachedUserId = user['id'].toString();
        await Vault.write('auth_token', _memoizedToken);
        await Vault.write('user_id', _cachedUserId);
        await Vault.write('user_name', user['username']);
        unawaited(fetchEphemeralTokenIfNeeded());
      }
      return response;
    } catch (e) {
      // Улучшенная обработка ошибок
      final errorStr = e.toString();
      if (errorStr.contains('401') ||
          errorStr.contains('Invalid credentials')) {
        throw Exception('Invalid email or password');
      }
      if (errorStr.contains('400')) {
        throw Exception('Email and password are required');
      }
      throw Exception('Login failed: ${e.toString()}');
    }
  }

  /// ПОЛУЧИТЬ МОЙ ПРОФИЛЬ (С поддержкой оффлайна)
  Future<Map<String, dynamic>> getMe() async {
    try {
      // Пытаемся стучаться на сервер через роутер
      final response = await _makeRequest(method: 'GET', endpoint: '/users/me');

      if (response != null && response['id'] != null) {
        _cachedUserId = response['id'].toString();
        await Vault.write('user_id', _cachedUserId);
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

  // В ApiService.dart

  Future<void> createOfflineIdentity(String username, String email) async {
    final encryption = locator<EncryptionService>();

    // 1. Генерируем ключи личности
    final identity = await encryption.generateGhostIdentity(username);
    final String ghostId = identity['userId']!;

    // 2. Генерируем "Посадочный талон" для будущей легализации
    final String landingPass =
        await encryption.generateLandingPass(email, ghostId);

    // 3. Сохраняем всё в Vault (бронированное хранилище)
    await Vault.write('user_id', ghostId);
    await Vault.write('user_name', username);
    await Vault.write('user_email', email);
    await Vault.write('landing_pass', landingPass);
    await Vault.write('auth_token', 'GHOST_MODE_ACTIVE'); // Метка для системы

    _cachedUserId = ghostId;
    _memoizedToken = 'GHOST_MODE_ACTIVE';

    _log("👤 Ghost identity created locally. Status: STEALTH.");
  }

  /// СПИСОК ЧАТОВ
  /// Маяк подставляется с id по стране (THE_BEACON_XX / THE_BEACON_GLOBAL), чтобы Cloud-сообщения разделялись по странам.
  Future<List<dynamic>> getChats() async {
    final beaconId = BeaconCountryHelper.beaconChatIdForCountry();
    final beaconName = beaconId == 'THE_BEACON_GLOBAL'
        ? 'THE BEACON (Global SOS)'
        : 'THE BEACON · ${BeaconCountryHelper.beaconCountryDisplayName(beaconId)}';
    final beacon = {
      'id': beaconId,
      'name': beaconName,
      'type': 'GLOBAL',
      'isEphemeral': false,
      'lastMessage': {
        'content': 'Mesh Active. Frequency secured.',
        'createdAt': DateTime.now().toIso8601String()
      },
      'otherUser': null
    };

    List<dynamic> chats = [];

    try {
      int retries = 0;
      const maxRetries = 2;

      while (retries < maxRetries) {
        try {
          final response =
              await _makeRequest(method: 'GET', endpoint: '/chats').timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              throw TimeoutException('Request timeout');
            },
          );

          if (response is List) {
            chats = response;
            break;
          }
        } catch (e) {
          retries++;
          if (retries < maxRetries) {
            _log(
                "⚠️ [Tecno] Chat load failed, retrying in 2s... (attempt $retries/$maxRetries)");
            await Future.delayed(const Duration(seconds: 2));
          } else {
            _log("📡 Isolated: Using local Beacon only. Error: $e");
          }
        }
      }
    } catch (e) {
      _log("📡 Isolated: Using local Beacon only. Error: $e");
    }

    // ГАРАНТИЯ: в списке есть Маяк с id по стране (для разделения Cloud по странам)
    final hasBeacon = chats.any((c) =>
        c != null &&
        (c['id'] == beaconId ||
            c['id'] == 'THE_BEACON_GLOBAL' ||
            BeaconCountryHelper.isBeaconChat(c['id']?.toString())));
    if (!hasBeacon) {
      chats.insert(0, beacon);
    }

    if (chats.isEmpty) {
      chats.add(beacon);
    }

    return chats;
  }

  /// ИСТОРИЯ СООБЩЕНИЙ
  Future<List<dynamic>> getMessages(String chatId) async {
    return await _makeRequest(
        method: 'GET', endpoint: '/chats/$chatId/messages');
  }

  /// СОЗДАТЬ ЛИНК (Личный чат)
  Future<Map<String, dynamic>> findOrCreateChat(String friendId) async {
    return await _makeRequest(
        method: 'POST', endpoint: '/chats/direct', body: {'userId': friendId});
  }

  /// СОЗДАТЬ ОТРЯД (Группа)
  Future<Map<String, dynamic>> createGroupChat(
      String name, List<String> userIds) async {
    return await _makeRequest(
        method: 'POST',
        endpoint: '/chats/group',
        body: {'name': name, 'userIds': userIds});
  }

  /// ПОИСК СИГНАЛОВ (Пользователей)
  Future<List<dynamic>> searchUsers(String query) async {
    // Поиск работает только в онлайне или через Bridge
    return await _makeRequest(
        method: 'GET', endpoint: '/friends/search?query=$query');
  }

  /// ЗАПРОС НА УСТАНОВКУ СВЯЗИ (Дружба)
  Future<void> sendFriendRequest(String friendId) async {
    await _makeRequest(
        method: 'POST', endpoint: '/friends/add', body: {'friendId': friendId});
  }

  /// Принять заявку в друзья (requestId = id отправителя заявки, userA_id)
  Future<void> acceptFriendRequest(String requestId) async {
    await _makeRequest(
        method: 'PUT',
        endpoint: '/friends/requests/$requestId/accept');
  }

  /// Отклонить заявку в друзья (requestId = id отправителя заявки, userA_id)
  Future<void> rejectFriendRequest(String requestId) async {
    await _makeRequest(
        method: 'DELETE',
        endpoint: '/friends/requests/$requestId/reject');
  }

  /// Удалить из друзей (после принятой заявки).
  /// Бэкенд: DELETE /friends/:friendId или аналог.
  Future<void> removeFriend(String friendId) async {
    await _makeRequest(
        method: 'DELETE', endpoint: '/friends/$friendId');
  }

  /// АКТИВНЫЕ ЧАСТОТЫ (Тренды)
  Future<List<dynamic>> getTrendingBranches() async {
    return await _makeRequest(method: 'GET', endpoint: '/chats/trending');
  }

  // --- КАНАЛЫ (онлайн-only, обновления только через сервер; mesh не используется) ---

  /// Список каналов с опциональными фильтрами (категория, сортировка, поиск).
  /// Бэкенд может поддерживать query: category, sort, q. Если не поддерживает — фильтрация на клиенте.
  Future<List<Map<String, dynamic>>> getChannels({
    String? category,
    String? sort,
    String? q,
  }) async {
    if (isGhostMode) return [];
    try {
      final query = <String, String>{};
      if (category != null && category.isNotEmpty) query['category'] = category;
      if (sort != null && sort.isNotEmpty) query['sort'] = sort;
      if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
      final queryStr = query.isEmpty ? '' : '?${query.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
      final res = await _makeRequest(method: 'GET', endpoint: '/channels$queryStr');
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e is Map ? e : {})).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Каналы, созданные текущим пользователем (для лимита 2 канала на аккаунт).
  Future<List<Map<String, dynamic>>> getMyChannels() async {
    if (isGhostMode) return [];
    try {
      final res = await _makeRequest(method: 'GET', endpoint: '/channels/mine');
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e is Map ? e : {})).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Создать канал. type — один из id из ChannelType. isPrivate: закрытый (только по приглашению).
  Future<Map<String, dynamic>> createChannel({
    required String name,
    String? description,
    required String type,
    bool isPrivate = false,
  }) async {
    final body = <String, dynamic>{'name': name, 'type': type, 'isPrivate': isPrivate};
    if (description != null && description.trim().isNotEmpty) body['description'] = description.trim();
    return await _makeRequest(method: 'POST', endpoint: '/channels', body: body);
  }

  /// Получить ссылку-приглашение в канал (для владельца/админа). Закрытые каналы — только по ссылке.
  Future<Map<String, dynamic>> getChannelInviteLink(String channelId) async {
    return await _makeRequest(method: 'GET', endpoint: '/channels/$channelId/invite-link');
  }

  /// Вступить в канал по инвайт-токену или ссылке (токен из query или путь).
  Future<Map<String, dynamic>> joinChannelByInvite(String inviteToken) async {
    return await _makeRequest(method: 'POST', endpoint: '/channels/join', body: {'inviteToken': inviteToken});
  }

  /// Рекомендованные каналы (если бэкенд отдаёт). Иначе клиент может использовать getChannels(sort: 'popular').
  Future<List<Map<String, dynamic>>> getRecommendedChannels() async {
    if (isGhostMode) return [];
    try {
      final res = await _makeRequest(method: 'GET', endpoint: '/channels/recommended');
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e is Map ? e : {})).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Подписанные каналы пользователя. Только при онлайне.
  Future<List<Map<String, dynamic>>> getSubscribedChannels() async {
    if (isGhostMode) return [];
    try {
      final res = await _makeRequest(method: 'GET', endpoint: '/channels/subscribed');
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e is Map ? e : {})).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Посты канала. Только при онлайне.
  Future<List<Map<String, dynamic>>> getChannelPosts(String channelId, {int limit = 50}) async {
    if (isGhostMode) return [];
    try {
      final res = await _makeRequest(
        method: 'GET',
        endpoint: '/channels/$channelId/posts?limit=$limit',
      );
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e is Map ? e : {})).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Подписаться на канал. Только при онлайне.
  Future<void> subscribeToChannel(String channelId) async {
    if (isGhostMode) return;
    try {
      await _makeRequest(method: 'POST', endpoint: '/channels/$channelId/subscribe');
    } catch (_) {}
  }

  /// Отписаться от канала. Только при онлайне.
  Future<void> unsubscribeFromChannel(String channelId) async {
    if (isGhostMode) return;
    try {
      await _makeRequest(method: 'POST', endpoint: '/channels/$channelId/unsubscribe');
    } catch (_) {}
  }

  /// СЛОВАРЬ GUARDIAN (Цензурные фильтры)
  Future<Map<String, dynamic>> getGuardianDictionary() async {
    return await _makeRequest(method: 'GET', endpoint: '/guardian/dictionary');
  }

  /// ЖАЛОБА (Report)
  Future<void> sendReport(
      {required String reason,
      required String reportedUserId,
      String? description,
      String? messageId}) async {
    await _makeRequest(method: 'POST', endpoint: '/reports', body: {
      'reason': reason,
      'reportedUserId': reportedUserId,
      'description': description,
      'messageId': messageId
    });
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
        await client
            .get(Uri.parse(
                'https://www.google.com/search?q=weather+today+in+Amsterdam'))
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
    return await _makeRequest(
        method: 'POST', endpoint: '/auth/generate-recovery');
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
  }
}
