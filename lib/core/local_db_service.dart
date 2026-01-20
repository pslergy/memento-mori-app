import 'dart:async';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../features/chat/conversation_screen.dart'; // Модель ChatMessage
import 'api_service.dart';
import 'locator.dart';
import 'models/ad_packet.dart'; // Модель AdPacket

class LocalDatabaseService {
  // ==========================================
  // 🛡️ Singleton & Concurrency Guard
  // ==========================================
  static final LocalDatabaseService _instance = LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();
  static const String _firstLaunchKey = 'first_launch_done';

  Database? _database;
  Completer<Database>? _dbCompleter;

  /// Проверяет, первый ли запуск
  Future<bool> isFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_firstLaunchKey) ?? false);
  }

  /// Помечает, что первый запуск завершён
  Future<void> setFirstLaunchDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_firstLaunchKey, true);
  }


  /// Главная точка входа: гарантирует атомарную инициализацию базы
  Future<Database> get database async {
    if (_database != null) return _database!;
    if (_dbCompleter != null) return _dbCompleter!.future;

    _dbCompleter = Completer<Database>();
    try {
      final db = await _initDB();
      _database = db;
      _dbCompleter!.complete(db);
      return db;
    } catch (e) {
      _dbCompleter!.completeError(e);
      _dbCompleter = null; // Позволяем повторную попытку при сбое
      rethrow;
    }
  }

  // ==========================================
  // ⚙️ Initialization & Lifecycle
  // ==========================================
  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    // Мы используем v5 для гарантированного применения новой схемы с ownerId
    final path = join(dbPath, 'memento_mori_v5.db');

    return await openDatabase(
      path,
      version: 7, // Финальная версия со всеми тактическими полями
      onConfigure: (db) async {
        try {
          // WAL через rawQuery
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
          await db.execute('PRAGMA foreign_keys = ON');
          print('⚡ [DB] Kernel: WAL Mode & Foreign Keys secured.');
        } catch (e) {
          print('⚠️ [DB] Kernel configuration failed: $e');
        }
      },
      onCreate: (db, version) async {
        print("🛠️ [DB] Construction: Building resilient schema v$version...");
        await _createTacticalSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        print("🔼 [DB] Upgrade detected: $oldVersion to $newVersion");
        if (oldVersion < 7) {
          try {
            // Защитная миграция: добавляем ownerId если его не было
            var tableInfo = await db.rawQuery('PRAGMA table_info(messages)');
            bool hasOwner = tableInfo.any((column) => column['name'] == 'ownerId');
            if (!hasOwner) {
              await db.execute('ALTER TABLE messages ADD COLUMN ownerId TEXT');
              await db.execute('ALTER TABLE chat_rooms ADD COLUMN ownerId TEXT');
            }
          } catch (_) {}
        }
      },
      onOpen: (db) async {
        print("🚀 [DB] Global Handshake: Validating Grid Integrity...");
        try {
          // Вызов внутреннего обслуживания без рекурсии геттера
          await _performInternalMaintenance(db);

          await db.rawInsert("INSERT OR IGNORE INTO system_stats(key, value) VALUES('karma', 0)");

          await db.insert(
            'chat_rooms',
            {
              'id': 'THE_BEACON_GLOBAL',
              'ownerId': 'SYSTEM',
              'name': 'THE BEACON',
              'type': 'GLOBAL',
              'lastMessage': 'Protocol Active',
              'lastActivity': DateTime.now().millisecondsSinceEpoch
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );

          print("✅ [DB] Handshake complete. Grid is stable.");
        } catch (e) {
          print("⚠️ [DB] Post-open logic failed: $e");
        }
      },
    );
  }

  Future<int> getOutboxCount() async {
    try {
      final db = await database;
      // Считаем количество записей в таблице outbox
      final List<Map<String, dynamic>> res = await db.rawQuery("SELECT COUNT(*) as count FROM outbox");
      return Sqflite.firstIntValue(res) ?? 0;
    } catch (e) {
      print("⚠️ [DB] Error counting outbox: $e");
      return 0;
    }
  }

  /// Полная структура таблиц (9 тактических модулей)
  Future<void> _createTacticalSchema(Database db) async {
    await db.transaction((txn) async {
      // 1. Мессенджер (History)
      await txn.execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          ownerId TEXT,
          clientTempId TEXT,
          content TEXT,
          chatRoomId TEXT,
          senderId TEXT,
          senderUsername TEXT,
          createdAt INTEGER,
          status TEXT,
          isEncrypted INTEGER DEFAULT 0
        )
      ''');

      // 2. Meaning Units (Фрагменты для Gossip/Sonar)
      await txn.execute('''
        CREATE TABLE message_fragments(
          fragmentId TEXT PRIMARY KEY,
          messageId TEXT,
          index_num INTEGER NOT NULL,
          total INTEGER,
          data TEXT,
          receivedAt INTEGER,
          FOREIGN KEY(messageId) REFERENCES messages(id) ON DELETE CASCADE
        )
      ''');

      // 3. Trust Identity (Друзья)
      await txn.execute('''
        CREATE TABLE friends(
          id TEXT PRIMARY KEY,
          username TEXT,
          publicKey TEXT,
          isVerified INTEGER DEFAULT 0,
          lastSeen INTEGER,
          avatarUrl TEXT
        )
      ''');

      // 4. Gossip Deduplicator (Seen Pulses)
      await txn.execute('CREATE TABLE seen_pulses(id TEXT PRIMARY KEY, seenAt INTEGER)');

      // 5. Outbox (Viral Relay Queue + Smart Routing)
      await txn.execute('''
        CREATE TABLE outbox(
          id TEXT PRIMARY KEY,
          chatRoomId TEXT,
          content TEXT,
          isEncrypted INTEGER,
          createdAt INTEGER,
          preferred_uplink TEXT,
          hop_path TEXT,
          routing_state TEXT DEFAULT 'PENDING'
        )
      ''');

      // 6. Ad-Pool (Gossip Ads)
      await txn.execute('CREATE TABLE ads(id TEXT PRIMARY KEY, title TEXT, content TEXT, imageUrl TEXT, priority INTEGER, isInterstitial INTEGER, expiresAt INTEGER)');

      // 7. Identity & Licenses (Landing Pass)
      await txn.execute('CREATE TABLE licenses(id TEXT PRIMARY KEY, signedToken TEXT, status TEXT, expiresAt INTEGER)');

      // 8. Grid Rooms (Metadata)
      await txn.execute('CREATE TABLE chat_rooms(id TEXT PRIMARY KEY, ownerId TEXT, name TEXT, type TEXT, lastMessage TEXT, lastActivity INTEGER)');

      // 9. System Stats
      await txn.execute('CREATE TABLE system_stats(key TEXT PRIMARY KEY, value INTEGER)');

      // Индексы для O(1) и плавной прокрутки
      await txn.execute('CREATE INDEX idx_messages_chatroom ON messages(chatRoomId)');
      await txn.execute('CREATE INDEX idx_seen_pulses_time ON seen_pulses(seenAt)');
      await txn.execute('CREATE INDEX idx_fragments_msg ON message_fragments(messageId)');
      await txn.execute('CREATE INDEX idx_messages_owner ON messages(ownerId)');
      await txn.execute('CREATE INDEX idx_messages_created ON messages(createdAt)');

      print("📦 [DB] All tables and indexes established.");
    });
  }

  // ==========================================
  // 💬 MESSAGE OPERATIONS
  // ==========================================

  Future<void> saveMessage(ChatMessage msg, String chatId) async {
    final db = await database;
    final currentUserId = locator<ApiService>().currentUserId;
    if (msg.clientTempId != null) {
      await db.delete('messages', where: 'id = ?', whereArgs: [msg.clientTempId]);
    }
    await db.insert(
      'messages',
      {
        'id': msg.id,
        'ownerId': currentUserId,
        'clientTempId': msg.clientTempId,
        'content': msg.content,
        'chatRoomId': chatId,
        'senderId': msg.senderId,
        'senderUsername': msg.senderUsername,
        'createdAt': msg.createdAt.millisecondsSinceEpoch,
        'status': msg.status,
        'isEncrypted': 1
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessage>> getMessages(String chatId) async {
    final db = await database;
    final currentUserId = locator<ApiService>().currentUserId;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatRoomId = ? AND ownerId = ?',
      whereArgs: [chatId, currentUserId],
      orderBy: 'createdAt ASC',
    );
    // Конвертируем INTEGER дату обратно в ISO String для модели ChatMessage
    return maps.map((m) => ChatMessage.fromJson({
      ...m,
      'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int).toIso8601String(),
    })).toList();
  }

  Future<List<ChatMessage>> getMessagesPaged(String chatId, int limit, int offset) async {
    final db = await database;
    final currentUserId = locator<ApiService>().currentUserId;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatRoomId = ? AND ownerId = ?',
      whereArgs: [chatId, currentUserId],
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => ChatMessage.fromJson({
      ...m,
      'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int).toIso8601String(),
    })).toList().reversed.toList();
  }

  // ==========================================
  // 🤝 IDENTITY & TRUST
  // ==========================================

  Future<void> establishTrust(String id, String name, String? pubKey) async {
    final db = await database;
    await db.insert('friends', {
      'id': id,
      'username': name,
      'publicKey': pubKey,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getTrustedFriends() async {
    final db = await database;
    return await db.query('friends', orderBy: 'lastSeen DESC');
  }

  // ==========================================
  // 📦 GOSSIP & FRAGMENTS
  // ==========================================

  Future<bool> isPacketSeen(String packetId) async {
    final db = await database;
    final maps = await db.query('seen_pulses', where: 'id=?', whereArgs: [packetId]);
    if (maps.isNotEmpty) return true;

    await db.insert('seen_pulses', {
      'id': packetId,
      'seenAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return false;
  }

  Future<void> saveFragment({required String messageId, required int index, required int total, required String data}) async {
    final db = await database;
    await db.insert('message_fragments', {
      'fragmentId': "${messageId}_$index",
      'messageId': messageId,
      'index_num': index,
      'total': total,
      'data': data,
      'receivedAt': DateTime.now().millisecondsSinceEpoch
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getFragments(String messageId) async {
    final db = await database;
    return await db.query('message_fragments', where: 'messageId = ?', whereArgs: [messageId]);
  }

  Future<void> clearFragments(String messageId) async {
    final db = await database;
    await db.delete('message_fragments', where: 'messageId = ?', whereArgs: [messageId]);
  }

  // ==========================================
  // 📦 OUTBOX & RELAY
  // ==========================================

  Future<void> addToOutbox(ChatMessage msg, String chatId) async {
    final db = await database;
    await db.insert('outbox', {
      'id': msg.id,
      'chatRoomId': chatId,
      'content': msg.content,
      'isEncrypted': 1,
      'createdAt': msg.createdAt.millisecondsSinceEpoch,
      'routing_state': 'PENDING'
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // 🔻 ИЗМЕНЕНИЕ: Добавлен параметр limit
  Future<List<Map<String, dynamic>>> getPendingFromOutbox({int limit = 50}) async {
    final db = await database;
    // 🔻 ИЗМЕНЕНИЕ: Добавлен LIMIT в SQL запрос
    return await db.query('outbox', orderBy: 'createdAt ASC', limit: limit);
  }

  // 🔻 НОВЫЙ МЕТОД: Для обновления статуса после отправки через Mesh
  Future<void> updateMessageStatus(String id, String status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> removeFromOutbox(String id) async {
    final db = await database;
    await db.delete('outbox', where: 'id=?', whereArgs: [id]);
  }

  // ==========================================
  // 🧹 MAINTENANCE & CLEANUP
  // ==========================================

  Future<void> _performInternalMaintenance(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pulseTtl = now - (1000 * 60 * 60 * 48); // 48 часов

    await db.transaction((txn) async {
      await txn.delete('seen_pulses', where: 'seenAt < ?', whereArgs: [pulseTtl]);
      await txn.delete('ads', where: 'expiresAt < ?', whereArgs: [now]);

      // Ограничиваем историю (2000 последних), но сохраняем SOS
      await txn.execute('''
        DELETE FROM messages 
        WHERE id NOT IN (
          SELECT id FROM messages 
          WHERE status = 'SOS' 
          OR id IN (SELECT id FROM messages ORDER BY createdAt DESC LIMIT 2000)
        ) AND status != 'SOS'
      ''');
    });
    print("🧹 [DB] Maintenance: Cache pressure released.");
  }

  Future<void> runMaintenance() async {
    final db = await database;
    await _performInternalMaintenance(db);
  }

  // ==========================================
  // 💰 ADS & MISC
  // ==========================================

  Future<void> saveAd(AdPacket ad) async {
    final db = await database;
    await db.insert('ads', ad.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AdPacket>> getActiveAds() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final List<Map<String, dynamic>> maps = await db.query(
        'ads',
        where: 'expiresAt > ?',
        whereArgs: [now],
        orderBy: 'priority DESC'
    );
    return maps.map((e) => AdPacket.fromJson(e)).toList();
  }

  // ==========================================
  // ☢️ EMERGENCY ERASURE (KILL SWITCH)
  // ==========================================

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      final tables = [
        'messages', 'message_fragments', 'friends', 'seen_pulses',
        'outbox', 'ads', 'licenses', 'chat_rooms', 'system_stats'
      ];
      for (var t in tables) await txn.delete(t);
    });
    print("☢️ [DB] MEMORY PURGED SUCCESSFULLY.");
  }
}