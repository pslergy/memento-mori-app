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
        // Используем rawQuery вместо execute для PRAGMA - это фиксит баг "Sqlite code 0"
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.rawQuery('PRAGMA synchronous = NORMAL');
        } catch (e) {
          print("⚠️ [DB] WAL Mode not supported on this device. Falling back.");
        }
      },
      onCreate: (db, version) async {
        print("🛠️ [DB] Initialization: Protocol v$version started...");

        // Мы используем транзакцию, чтобы гарантировать: либо создадутся все таблицы, либо ни одной.
        await db.transaction((txn) async {
          // 1. Таблица сообщений
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

          // Создаем ИНДЕКС на chatRoomId.
          // Это "золотой стандарт" для интервью: ускоряет выборку истории в разы.
          await txn.execute('CREATE INDEX idx_messages_chatroom ON messages(chatRoomId)');

          // 2. Таблица очереди (Store-and-Forward Outbox)
          await txn.execute('''
            CREATE TABLE outbox(
              id TEXT PRIMARY KEY,
              chatRoomId TEXT,
              content TEXT,
              isEncrypted INTEGER,
              createdAt TEXT
            )
          ''');

          // 3. Таблица рекламы (Gossip Ad-Pool)
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

          // 4. Таблица лицензий (Offline Premium Verification)
          await txn.execute('''
            CREATE TABLE licenses(
              id TEXT PRIMARY KEY,
              signedToken TEXT, 
              status TEXT,
              expiresAt TEXT
            )
          ''');

          // 5. Таблица чат-комнат (Для быстрого вывода списка чатов оффлайн)
          await txn.execute('''
            CREATE TABLE chat_rooms(
              id TEXT PRIMARY KEY,
              name TEXT,
              type TEXT,
              lastMessage TEXT,
              lastActivity TEXT
            )
          ''');
        });

        print("✅ [DB] All tactical tables and indices established.");
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Логика миграции: позволяет обновлять приложение без потери данных пользователя
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS ads(id TEXT PRIMARY KEY, title TEXT, content TEXT, imageUrl TEXT, priority INTEGER, isInterstitial INTEGER, expiresAt TEXT)');
          print("🛠️ [DB] Migration: Added Ads table.");
        }
      },
    );
  }

  // ===========================================================================
  // 📡 МЕТОДЫ ДЛЯ СООБЩЕНИЙ (Messaging)
  // ===========================================================================

  Future<void> saveMessage(ChatMessage msg, String chatId) async {
    final db = await database;

    // 🔥 АНТИ-ДУБЛЬ: Если сохраняем серверную версию, удаляем её "временный" клон
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
        'isEncrypted': 1 // В БД всегда храним расшифрованным для юзера
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
  // 📦 МЕТОДЫ ОЧЕРЕДИ (Store-and-Forward Outbox)
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
    // Полная зачистка всех таблиц при активации протокола PANIC
    await db.delete('messages');
    await db.delete('outbox');
    await db.delete('ads');
    await db.delete('licenses');
    await db.delete('chat_rooms');
    print("☢️ [DB] MEMORY PURGED SUCCESSFULLY.");
  }
}