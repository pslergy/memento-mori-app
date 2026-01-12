import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:async';

import '../features/chat/conversation_screen.dart'; // Модель ChatMessage
import 'models/ad_packet.dart'; // Модель рекламного пакета

class LocalDatabaseService {
  static final LocalDatabaseService _instance = LocalDatabaseService._internal();
  factory LocalDatabaseService() => _instance;
  LocalDatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'memento_mori_v2.db');

    return await openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.rawQuery('PRAGMA synchronous = NORMAL');
          print("⚡ [DB] Kernel: WAL Mode & Performance Protocols active.");
        } catch (e) {
          print("⚠️ [DB] Kernel configuration failed: $e");
        }
      },
      onOpen: (db) async {
        print("🚀 [DB] Global Handshake: Sanitizing offline IDs and Stats...");
        try {
          // 1. САМОЛЕЧЕНИЕ: Таблица статистики
          await db.execute('''
            CREATE TABLE IF NOT EXISTS system_stats(
              key TEXT PRIMARY KEY,
              value INTEGER
            )
          ''');
          await db.rawInsert('INSERT OR IGNORE INTO system_stats(key, value) VALUES("karma", 0)');

          // 2. ВЕЧНЫЙ МАЯК: Гарантируем наличие глобальной частоты
          await db.insert('chat_rooms', {
            'id': 'THE_BEACON_GLOBAL',
            'name': 'THE BEACON (Global SOS)',
            'type': 'GLOBAL',
            'lastMessage': 'Protocol Active. Listening for pulses...',
            'lastActivity': DateTime.now().toIso8601String()
          }, conflictAlgorithm: ConflictAlgorithm.ignore);

          // 3. ТАКТИЧЕСКИЙ РЕМАППИНГ: GLOBAL -> THE_BEACON_GLOBAL
          await db.execute("UPDATE messages SET chatRoomId = 'THE_BEACON_GLOBAL' WHERE chatRoomId = 'GLOBAL'");
          await db.execute("UPDATE outbox SET chatRoomId = 'THE_BEACON_GLOBAL' WHERE chatRoomId = 'GLOBAL'");

          print("✅ [DB] THE_BEACON_GLOBAL synchronized. Legacy tags migrated.");
        } catch (e) {
          print("⚠️ [DB] Post-open sanity check failed: $e");
        }
      },
      onCreate: (db, version) async {
        print("🛠️ [DB] Construction: Building protocol v$version schema...");

        await db.transaction((txn) async {
          // Таблица сообщений
          await txn.execute('''
            CREATE TABLE messages(
              id TEXT PRIMARY KEY,
              clientTempId TEXT,
              content TEXT,
              chatRoomId TEXT,
              senderId TEXT,
              senderUsername TEXT,
              createdAt TEXT,
              status TEXT,
              isEncrypted INTEGER DEFAULT 0
            )
          ''');

          await txn.execute('CREATE INDEX idx_messages_chatroom ON messages(chatRoomId)');
          await txn.execute('CREATE INDEX idx_messages_temp_id ON messages(clientTempId)');

          // Очередь Outbox (Viral Relay)
          await txn.execute('''
            CREATE TABLE outbox(
              id TEXT PRIMARY KEY,
              chatRoomId TEXT,
              content TEXT,
              isEncrypted INTEGER,
              createdAt TEXT
            )
          ''');

          // Реклама (Gossip Ad-Pool)
          await txn.execute('''
            CREATE TABLE ads(
              id TEXT PRIMARY KEY,
              title TEXT,
              content TEXT,
              imageUrl TEXT,
              priority INTEGER,
              isInterstitial INTEGER,
              expiresAt TEXT
            )
          ''');

          // Лицензии и Чат-комнаты
          await txn.execute('CREATE TABLE licenses(id TEXT PRIMARY KEY, signedToken TEXT, status TEXT, expiresAt TEXT)');
          await txn.execute('CREATE TABLE chat_rooms(id TEXT PRIMARY KEY, name TEXT, type TEXT, lastMessage TEXT, lastActivity TEXT)');

          // Статистика
          await txn.execute('CREATE TABLE system_stats(key TEXT PRIMARY KEY, value INTEGER)');
          await txn.rawInsert('INSERT OR IGNORE INTO system_stats(key, value) VALUES("karma", 0)');
        });

        print("✅ [DB] Tactical Infrastructure ready.");
      },
    );
  }

  // ===========================================================================
  // 📡 МЕТОДЫ ДЛЯ СООБЩЕНИЙ
  // ===========================================================================

  Future<void> saveMessage(ChatMessage msg, String chatId) async {
    final db = await database;

    if (msg.clientTempId != null) {
      await db.delete('messages', where: 'id = ?', whereArgs: [msg.clientTempId]);
    }

    await db.insert(
      'messages',
      {
        'id': msg.id,
        'clientTempId': msg.clientTempId,
        'content': msg.content,
        'chatRoomId': chatId,
        'senderId': msg.senderId,
        'senderUsername': msg.senderUsername,
        'createdAt': msg.createdAt.toIso8601String(),
        'status': msg.status,
        'isEncrypted': 1
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessage>> getMessages(String chatId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatRoomId = ?',
      whereArgs: [chatId],
      orderBy: 'createdAt ASC',
    );

    return List.generate(maps.length, (i) {
      return ChatMessage(
        id: maps[i]['id'],
        clientTempId: maps[i]['clientTempId'],
        content: maps[i]['content'],
        senderId: maps[i]['senderId'],
        senderUsername: maps[i]['senderUsername'],
        createdAt: DateTime.parse(maps[i]['createdAt']),
        status: maps[i]['status'] ?? 'SENT',
      );
    });
  }

  // ===========================================================================
  // 📦 МЕТОДЫ ОЧЕРЕДИ (Store-and-Forward)
  // ===========================================================================

  Future<void> addToOutbox(ChatMessage msg, String chatId) async {
    final db = await database;
    await db.insert('outbox', {
      'id': msg.id,
      'chatRoomId': chatId,
      'content': msg.content,
      'isEncrypted': 1,
      'createdAt': msg.createdAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getPendingFromOutbox() async {
    final db = await database;
    return await db.query('outbox', orderBy: 'createdAt ASC');
  }

  Future<void> removeFromOutbox(String id) async {
    final db = await database;
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  // ===========================================================================
  // 💰 МЕТОДЫ РЕКЛАМЫ (Gossip Ad-Mesh)
  // ===========================================================================

  Future<void> saveAd(AdPacket ad) async {
    final db = await database;
    await db.insert('ads', ad.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AdPacket>> getActiveAds() async {
    final db = await database;
    try {
      final List<Map<String, dynamic>> maps = await db.query(
          'ads',
          where: 'expiresAt > ?',
          whereArgs: [DateTime.now().toIso8601String()],
          orderBy: 'priority DESC'
      );
      return maps.map((e) => AdPacket.fromJson(e)).toList();
    } catch (e) {
      print("❌ [DB] Error fetching ads: $e");
      return [];
    }
  }

  // ===========================================================================
  // ☢️ СИСТЕМНЫЕ МЕТОДЫ
  // ===========================================================================

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('outbox');
    await db.delete('ads');
    await db.delete('licenses');
    await db.delete('chat_rooms');
    await db.delete('system_stats');
    print("☢️ [DB] MEMORY PURGED SUCCESSFULLY.");
  }
}