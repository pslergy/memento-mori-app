import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../features/chat/conversation_screen.dart';
import 'api_service.dart';
import 'decoy/vault_interface.dart';
import 'locator.dart';
import 'models/ad_packet.dart';
import 'room_events.dart' show RoomEvent, EventOrigin;
import 'encryption_service.dart';
import 'event_bus_service.dart';
import 'storage_service.dart';

/// SECURITY INVARIANT: REAL and DECOY use separate directories and DB files (no shared WAL/journals).
/// When [dbDirectorySuffix] is set, DB lives in <databases>/<suffix>/<fileName>; no path reuse across modes.
/// On logout, call [closeAndCheckpoint] before teardown so no orphaned WAL/handles remain.
///
/// ⚠️ НЕ УДАЛЯТЬ таблицы и поля: messages (ownerId, chatRoomId), outbox (senderId), getMessages/saveMessage/addToOutbox,
/// getPendingFromOutbox, THE_BEACON_GLOBAL seed — всё используется Beacon/Ghost и mesh.
class LocalDatabaseService {
  factory LocalDatabaseService() {
    if (GetIt.instance.isRegistered<LocalDatabaseService>()) {
      return GetIt.instance<LocalDatabaseService>();
    }
    return LocalDatabaseService.raw(dbFileName: 'memento_mori_v5.db');
  }

  LocalDatabaseService.raw({
    String? dbFileName,
    VaultInterface? vault,
    String? dbDirectorySuffix,
  })  : _dbFileName = dbFileName ?? 'memento_mori_v5.db',
        _vault = vault,
        _dbDirectorySuffix = dbDirectorySuffix;

  final String _dbFileName;
  final VaultInterface? _vault;
  final String? _dbDirectorySuffix;

  static const String _firstLaunchKey = 'first_launch_done';

  Database? _database;
  Completer<Database>? _dbCompleter;

  /// Проверяет, первый ли запуск (для текущего режима / хранилища).
  Future<bool> isFirstLaunch() async {
    if (_vault != null) {
      final v = await _vault!.read(_firstLaunchKey);
      return v != '1';
    }
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_firstLaunchKey) ?? false);
  }

  /// Помечает, что первый запуск завершён.
  Future<void> setFirstLaunchDone() async {
    if (_vault != null) {
      await _vault!.write(_firstLaunchKey, '1');
      return;
    }
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

  /// FORENSIC: Close DB and checkpoint WAL so no orphaned files. Call before session teardown.
  Future<void> closeAndCheckpoint() async {
    final db = _database;
    _database = null;
    _dbCompleter = null;
    if (db == null) return;
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    try {
      await db.close();
    } catch (_) {}
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final String path;
    if (_dbDirectorySuffix != null && _dbDirectorySuffix!.isNotEmpty) {
      final dir = Directory(join(dbPath, _dbDirectorySuffix!));
      if (!await dir.exists()) await dir.create(recursive: true);
      path = join(dir.path, _dbFileName);
    } else {
      path = join(dbPath, _dbFileName);
    }

    return await openDatabase(
      path,
      version: 17, // v17: CRDT log — sequence_number, previous_hash, fork_of_id (additive)
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
            bool hasOwner =
                tableInfo.any((column) => column['name'] == 'ownerId');
            if (!hasOwner) {
              await db.execute('ALTER TABLE messages ADD COLUMN ownerId TEXT');
              await db
                  .execute('ALTER TABLE chat_rooms ADD COLUMN ownerId TEXT');
            }
          } catch (_) {}
        }
        if (oldVersion < 8) {
          try {
            // Миграция v8: Расширение friends, добавление полей для глобального чата и личных сообщений
            var friendsInfo = await db.rawQuery('PRAGMA table_info(friends)');
            var friendsColumns =
                friendsInfo.map((c) => c['name'] as String).toList();

            if (!friendsColumns.contains('status')) {
              await db.execute(
                  'ALTER TABLE friends ADD COLUMN status TEXT DEFAULT \'pending\'');
            }
            if (!friendsColumns.contains('tactical_name')) {
              await db
                  .execute('ALTER TABLE friends ADD COLUMN tactical_name TEXT');
            }
            if (!friendsColumns.contains('requested_at')) {
              await db.execute(
                  'ALTER TABLE friends ADD COLUMN requested_at INTEGER');
            }
            if (!friendsColumns.contains('accepted_at')) {
              await db.execute(
                  'ALTER TABLE friends ADD COLUMN accepted_at INTEGER');
            }
            if (!friendsColumns.contains('karma')) {
              await db.execute(
                  'ALTER TABLE friends ADD COLUMN karma INTEGER DEFAULT 0');
            }

            var messagesInfo = await db.rawQuery('PRAGMA table_info(messages)');
            var messagesColumns =
                messagesInfo.map((c) => c['name'] as String).toList();

            if (!messagesColumns.contains('gossip_hash')) {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN gossip_hash TEXT');
              await db.execute(
                  'CREATE INDEX IF NOT EXISTS idx_messages_gossip_hash ON messages(gossip_hash)');
            }
            if (!messagesColumns.contains('ttl')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN ttl INTEGER DEFAULT 7');
            }
            if (!messagesColumns.contains('delivered')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN delivered INTEGER DEFAULT 0');
              await db.execute(
                  'CREATE INDEX IF NOT EXISTS idx_messages_delivered ON messages(delivered)');
            }
            if (!messagesColumns.contains('delivered_at')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN delivered_at INTEGER');
            }

            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_friends_status ON friends(status)');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_friends_tactical ON friends(tactical_name)');

            print(
                "✅ [DB] Migration v8 completed: Friends and messaging enhancements");
          } catch (e) {
            print("⚠️ [DB] Migration v8 error: $e");
          }
        }
        if (oldVersion < 9) {
          try {
            // Миграция v9: Добавление таблицы SOS сигналов
            var tables = await db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='sos_signals'");
            if (tables.isEmpty) {
              await db.execute('''
                CREATE TABLE sos_signals(
                  id TEXT PRIMARY KEY,
                  sectorId TEXT NOT NULL,
                  locationName TEXT,
                  lat REAL,
                  lon REAL,
                  timestamp INTEGER NOT NULL,
                  synced INTEGER DEFAULT 0,
                  count INTEGER DEFAULT 1
                )
              ''');
              await db.execute(
                  'CREATE INDEX idx_sos_sector ON sos_signals(sectorId)');
              await db.execute(
                  'CREATE INDEX idx_sos_timestamp ON sos_signals(timestamp)');
              await db.execute(
                  'CREATE INDEX idx_sos_synced ON sos_signals(synced)');
            }
            print("✅ [DB] Migration v9 completed: SOS signals table added");
          } catch (e) {
            print("⚠️ [DB] Migration v9 error: $e");
          }
        }
        if (oldVersion < 11) {
          try {
            // Миграция v11: Добавление полей для комнат и сообщений
            var chatRoomsInfo =
                await db.rawQuery('PRAGMA table_info(chat_rooms)');
            var chatRoomsColumns =
                chatRoomsInfo.map((c) => c['name'] as String).toList();

            if (!chatRoomsColumns.contains('room_type')) {
              await db
                  .execute('ALTER TABLE chat_rooms ADD COLUMN room_type TEXT');
            }
            if (!chatRoomsColumns.contains('creator')) {
              await db
                  .execute('ALTER TABLE chat_rooms ADD COLUMN creator TEXT');
            }
            if (!chatRoomsColumns.contains('participants')) {
              await db.execute(
                  'ALTER TABLE chat_rooms ADD COLUMN participants TEXT');
            }

            var messagesInfo = await db.rawQuery('PRAGMA table_info(messages)');
            var messagesColumns =
                messagesInfo.map((c) => c['name'] as String).toList();

            if (!messagesColumns.contains('receivedAt')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN receivedAt INTEGER');
            }
            if (!messagesColumns.contains('vectorClock')) {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN vectorClock TEXT');
            }

            print(
                "✅ [DB] Migration v11 completed: Rooms and messages enhancements");
          } catch (e) {
            print("⚠️ [DB] Migration v11 error: $e");
          }
        }
        if (oldVersion < 12) {
          try {
            // Миграция v12: Добавление таблицы room_events
            var tables = await db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='room_events'");
            if (tables.isEmpty) {
              await db.execute('''
                CREATE TABLE room_events(
                  id TEXT NOT NULL,
                  roomId TEXT NOT NULL,
                  type TEXT NOT NULL,
                  userId TEXT NOT NULL,
                  timestamp INTEGER NOT NULL,
                  payload TEXT,
                  PRIMARY KEY (roomId, id)
                )
              ''');
              await db.execute(
                  'CREATE INDEX idx_room_events_roomId ON room_events(roomId)');
              await db.execute(
                  'CREATE INDEX idx_room_events_timestamp ON room_events(timestamp)');
            } else {
              // Миграция: если таблица существует с PRIMARY KEY только на id, пересоздаем
              try {
                var tableInfo =
                    await db.rawQuery("PRAGMA table_info(room_events)");
                var hasCompositeKey = tableInfo
                    .any((col) => col['name'] == 'roomId' && col['pk'] == 1);
                var hasOrigin =
                    tableInfo.any((col) => col['name'] == 'event_origin');

                if (!hasCompositeKey || !hasOrigin) {
                  // Пересоздаем таблицу с составным ключом и event_origin
                  await db.execute('DROP TABLE IF EXISTS room_events');
                  await db.execute('''
                    CREATE TABLE room_events(
                      id TEXT NOT NULL,
                      roomId TEXT NOT NULL,
                      type TEXT NOT NULL,
                      userId TEXT NOT NULL,
                      timestamp INTEGER NOT NULL,
                      payload TEXT,
                      event_origin TEXT DEFAULT 'LOCAL',
                      PRIMARY KEY (roomId, id)
                    )
                  ''');
                  await db.execute(
                      'CREATE INDEX idx_room_events_roomId ON room_events(roomId)');
                  await db.execute(
                      'CREATE INDEX idx_room_events_timestamp ON room_events(timestamp)');
                  await db.execute(
                      'CREATE INDEX idx_room_events_origin ON room_events(event_origin)');
                } else if (!hasOrigin) {
                  // Добавляем только event_origin если его нет
                  await db.execute(
                      'ALTER TABLE room_events ADD COLUMN event_origin TEXT DEFAULT \'LOCAL\'');
                  await db.execute(
                      'CREATE INDEX IF NOT EXISTS idx_room_events_origin ON room_events(event_origin)');
                }
              } catch (e) {
                print(
                    "⚠️ [DB] Migration v12: Error checking room_events structure: $e");
              }
            }
            print("✅ [DB] Migration v12 completed: Room events table added");
          } catch (e) {
            print("⚠️ [DB] Migration v12 error: $e");
          }
        }
        if (oldVersion < 13) {
          try {
            // Миграция v13: Добавление поля event_origin для диагностики
            var tableInfo = await db.rawQuery("PRAGMA table_info(room_events)");
            var hasOrigin =
                tableInfo.any((col) => col['name'] == 'event_origin');

            if (!hasOrigin) {
              await db.execute(
                  'ALTER TABLE room_events ADD COLUMN event_origin TEXT DEFAULT \'LOCAL\'');
              await db.execute(
                  'CREATE INDEX IF NOT EXISTS idx_room_events_origin ON room_events(event_origin)');
            }
            print("✅ [DB] Migration v13 completed: event_origin field added");
          } catch (e) {
            print("⚠️ [DB] Migration v13 error: $e");
          }
        }
        if (oldVersion < 14) {
          try {
            var outboxInfo = await db.rawQuery('PRAGMA table_info(outbox)');
            var outboxColumns =
                outboxInfo.map((c) => c['name'] as String).toList();
            if (!outboxColumns.contains('expiresAt')) {
              await db
                  .execute('ALTER TABLE outbox ADD COLUMN expiresAt INTEGER');
              print("✅ [DB] Migration v14 completed");
            }
          } catch (e) {
            print("⚠️ [DB] Migration v14 error: $e");
          }
        }
        if (oldVersion < 15) {
          try {
            var outboxInfo = await db.rawQuery('PRAGMA table_info(outbox)');
            var outboxColumns =
                outboxInfo.map((c) => c['name'] as String).toList();
            if (!outboxColumns.contains('senderId')) {
              await db.execute('ALTER TABLE outbox ADD COLUMN senderId TEXT');
              print(
                  "✅ [DB] Migration v15 completed: Added senderId to outbox (relay/ephemeral)");
            }
          } catch (e) {
            print("⚠️ [DB] Migration v15 error: $e");
          }
        }
        if (oldVersion < 16) {
          try {
            var outboxInfo = await db.rawQuery('PRAGMA table_info(outbox)');
            var outboxColumns =
                outboxInfo.map((c) => c['name'] as String).toList();
            if (!outboxColumns.contains('sentFragmentIndex')) {
              await db.execute(
                  'ALTER TABLE outbox ADD COLUMN sentFragmentIndex INTEGER DEFAULT -1');
              print(
                  "✅ [DB] Migration v16 completed: Added sentFragmentIndex to outbox (BLE fragment resume)");
            }
          } catch (e) {
            print("⚠️ [DB] Migration v16 error: $e");
          }
        }
        if (oldVersion < 17) {
          try {
            var messagesInfo = await db.rawQuery('PRAGMA table_info(messages)');
            var cols = messagesInfo.map((c) => c['name'] as String).toList();
            if (!cols.contains('sequence_number')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN sequence_number INTEGER');
            }
            if (!cols.contains('previous_hash')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN previous_hash TEXT');
            }
            if (!cols.contains('fork_of_id')) {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN fork_of_id TEXT');
            }
            print(
                "✅ [DB] Migration v17 completed: CRDT log columns (sequence_number, previous_hash, fork_of_id)");
          } catch (e) {
            print("⚠️ [DB] Migration v17 error: $e");
          }
        }
      },
      onOpen: (db) async {
        print("🚀 [DB] Global Handshake: Validating Grid Integrity...");
        try {
          // Defensive: ensure CRDT columns exist (e.g. DB created at v17 via onCreate without them)
          final messagesInfo = await db.rawQuery('PRAGMA table_info(messages)');
          final cols = messagesInfo.map((c) => c['name'] as String).toList();
          if (!cols.contains('sequence_number')) {
            await db.execute('ALTER TABLE messages ADD COLUMN sequence_number INTEGER');
            print("✅ [DB] onOpen: added missing sequence_number to messages");
          }
          if (!cols.contains('previous_hash')) {
            await db.execute('ALTER TABLE messages ADD COLUMN previous_hash TEXT');
            print("✅ [DB] onOpen: added missing previous_hash to messages");
          }
          if (!cols.contains('fork_of_id')) {
            await db.execute('ALTER TABLE messages ADD COLUMN fork_of_id TEXT');
            print("✅ [DB] onOpen: added missing fork_of_id to messages");
          }

          // Вызов внутреннего обслуживания без рекурсии геттера
          await _performInternalMaintenance(db);

          await db.rawInsert(
              "INSERT OR IGNORE INTO system_stats(key, value) VALUES('karma', 0)");

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

  /// Лимит записей в outbox на устройство (контроль памяти). При переполнении вытесняются самые старые по createdAt.
  static const int maxOutboxSize = 300;

  Future<int> getOutboxCount() async {
    try {
      final db = await database;
      // Считаем количество записей в таблице outbox
      final List<Map<String, dynamic>> res =
          await db.rawQuery("SELECT COUNT(*) as count FROM outbox");
      return Sqflite.firstIntValue(res) ?? 0;
    } catch (e) {
      print("⚠️ [DB] Error counting outbox: $e");
      return 0;
    }
  }

  /// Текущая карма из system_stats (для REQ payload). Возвращает 0 если нет записи.
  Future<int> getKarma() async {
    try {
      final db = await database;
      final res = await db.query('system_stats', where: 'key = ?', whereArgs: ['karma'], limit: 1);
      if (res.isEmpty) return 0;
      final value = res.first['value'];
      if (value is int) return value;
      if (value != null) return int.tryParse(value.toString()) ?? 0;
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /// 🔒 Anti-Sybil: karma по identityKey для входящих REQ (не доверять payload).
  /// Пока нет хранимой per-identity karma — возвращаем 0 (throttle применяется).
  Future<int> getKarmaForIdentity(String identityKey) async {
    if (identityKey.isEmpty) return 0;
    // Опционально: позже можно читать из friends/другой таблицы по identityKey
    return 0;
  }

  /// Вытесняет самые старые записи из outbox, пока количество не станет <= [maxCount]. Вызывается перед addToOutbox при переполнении.
  Future<void> _evictOutboxIfOverLimit(Database db, int maxCount) async {
    final count = Sqflite.firstIntValue(
            await db.rawQuery("SELECT COUNT(*) as c FROM outbox")) ??
        0;
    if (count < maxCount) return;
    final toRemove = count - maxCount + 1;
    if (toRemove <= 0) return;
    final rows = await db.query('outbox',
        columns: ['id'],
        orderBy: 'createdAt ASC',
        limit: toRemove);
    final ids = rows.map((r) => r['id'] as String?).whereType<String>().toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
    }
    print("🧹 [OUTBOX] Evicted ${ids.length} oldest (limit: $maxCount)");
  }

  /// Полная структура таблиц. Порядок создания (приоритет зависимостей):
  /// 1. messages — история чатов, ownerId, chatRoomId (THE_BEACON_GLOBAL и др.)
  /// 2. message_fragments — фрагменты для Gossip/Sonar (FK → messages)
  /// 3. friends — доверенные контакты
  /// 4. seen_pulses — дедупликация gossip
  /// 5. outbox — очередь relay для GHOST (senderId v15)
  /// 6. ads, 7. licenses, 8. chat_rooms, 8.1. room_events, 9. system_stats
  /// 10. known_routers, 11. sos_signals
  Future<void> _createTacticalSchema(Database db) async {
    await db.transaction((txn) async {
      // 1. Мессенджер (History)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS messages(
          id TEXT PRIMARY KEY,
          ownerId TEXT,
          clientTempId TEXT,
          content TEXT,
          chatRoomId TEXT,
          senderId TEXT,
          senderUsername TEXT,
          createdAt INTEGER,
          receivedAt INTEGER,
          vectorClock TEXT,
          status TEXT,
          isEncrypted INTEGER DEFAULT 0,
          sequence_number INTEGER,
          previous_hash TEXT,
          fork_of_id TEXT
        )
      ''');

      // 2. Meaning Units (Фрагменты для Gossip/Sonar)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS message_fragments(
          fragmentId TEXT PRIMARY KEY,
          messageId TEXT,
          index_num INTEGER NOT NULL,
          total INTEGER,
          data TEXT,
          receivedAt INTEGER,
          FOREIGN KEY(messageId) REFERENCES messages(id) ON DELETE CASCADE
        )
      ''');

      // 3. Trust Identity (Друзья) - Расширенная версия
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS friends(
          id TEXT PRIMARY KEY,
          username TEXT,
          tactical_name TEXT,
          publicKey TEXT,
          isVerified INTEGER DEFAULT 0,
          status TEXT DEFAULT 'pending',
          requested_at INTEGER,
          accepted_at INTEGER,
          lastSeen INTEGER,
          avatarUrl TEXT,
          karma INTEGER DEFAULT 0
        )
      ''');

      // 4. Gossip Deduplicator (Seen Pulses)
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS seen_pulses(id TEXT PRIMARY KEY, seenAt INTEGER)');

      // 5. Outbox (Viral Relay Queue + Smart Routing)
      // v15: senderId for relay attribution and ephemeral token
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS outbox(
          id TEXT PRIMARY KEY,
          chatRoomId TEXT,
          content TEXT,
          isEncrypted INTEGER,
          createdAt INTEGER,
          expiresAt INTEGER,
          preferred_uplink TEXT,
          hop_path TEXT,
          routing_state TEXT DEFAULT 'PENDING',
          senderId TEXT
        )
      ''');

      // 6. Ad-Pool (Gossip Ads)
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS ads(id TEXT PRIMARY KEY, title TEXT, content TEXT, imageUrl TEXT, priority INTEGER, isInterstitial INTEGER, expiresAt INTEGER)');

      // 7. Identity & Licenses (Landing Pass)
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS licenses(id TEXT PRIMARY KEY, signedToken TEXT, status TEXT, expiresAt INTEGER)');

      // 8. Grid Rooms (Metadata)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS chat_rooms(
          id TEXT PRIMARY KEY,
          ownerId TEXT,
          name TEXT,
          type TEXT,
          room_type TEXT,
          creator TEXT,
          participants TEXT,
          lastMessage TEXT,
          lastActivity INTEGER
        )
      ''');

      // 8.1. Room Events (Истина о состоянии комнаты)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS room_events(
          id TEXT NOT NULL,
          roomId TEXT NOT NULL,
          type TEXT NOT NULL,
          userId TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          payload TEXT,
          event_origin TEXT DEFAULT 'LOCAL',
          PRIMARY KEY (roomId, id),
          FOREIGN KEY(roomId) REFERENCES chat_rooms(id) ON DELETE CASCADE
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_room_events_roomId ON room_events(roomId)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_room_events_timestamp ON room_events(timestamp)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_room_events_origin ON room_events(event_origin)');

      // 9. System Stats
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS system_stats(key TEXT PRIMARY KEY, value INTEGER)');

      // 10. Known Routers (Протокол захвата роутера)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS known_routers(
          id TEXT PRIMARY KEY,
          ssid TEXT NOT NULL UNIQUE,
          mac_address TEXT,
          ip_address TEXT,
          priority INTEGER DEFAULT 50,
          is_trusted INTEGER DEFAULT 0,
          last_seen INTEGER,
          rssi REAL,
          has_internet INTEGER DEFAULT 0,
          is_open INTEGER DEFAULT 0,
          use_as_relay INTEGER DEFAULT 0,
          created_at INTEGER
        )
      ''');
      await txn.execute('CREATE INDEX idx_routers_ssid ON known_routers(ssid)');
      await txn.execute(
          'CREATE INDEX idx_routers_priority ON known_routers(priority)');
      await txn.execute(
          'CREATE INDEX idx_routers_trusted ON known_routers(is_trusted)');

      // 11. SOS Signals (Emergency signals для оффлайн работы)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS sos_signals(
          id TEXT PRIMARY KEY,
          sectorId TEXT NOT NULL,
          locationName TEXT,
          lat REAL,
          lon REAL,
          timestamp INTEGER NOT NULL,
          synced INTEGER DEFAULT 0,
          count INTEGER DEFAULT 1
        )
      ''');
      // Создаем индексы только если их еще нет (SQLite не поддерживает IF NOT EXISTS для индексов, но можно игнорировать ошибку)
      try {
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_sos_sector ON sos_signals(sectorId)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_sos_timestamp ON sos_signals(timestamp)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_sos_synced ON sos_signals(synced)');
      } catch (e) {
        // Игнорируем ошибки создания индексов (они могут уже существовать)
        print("⚠️ [DB] Index creation warning (may already exist): $e");
      }

      // Индексы для O(1) и плавной прокрутки (с защитой от дубликатов)
      try {
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_chatroom ON messages(chatRoomId)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_seen_pulses_time ON seen_pulses(seenAt)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_fragments_msg ON message_fragments(messageId)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_owner ON messages(ownerId)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(createdAt)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_friends_status ON friends(status)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_friends_tactical ON friends(tactical_name)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_routers_ssid ON known_routers(ssid)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_routers_priority ON known_routers(priority)');
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_routers_trusted ON known_routers(is_trusted)');
      } catch (e) {
        // Игнорируем ошибки создания индексов (они могут уже существовать)
        print("⚠️ [DB] Index creation warning (may already exist): $e");
      }

      // Глобальный чат: TTL и gossip hash для дедупликации (ALTER TABLE с защитой)
      try {
        await txn.execute('ALTER TABLE messages ADD COLUMN gossip_hash TEXT');
      } catch (e) {
        // Колонка может уже существовать
      }
      try {
        await txn
            .execute('ALTER TABLE messages ADD COLUMN ttl INTEGER DEFAULT 7');
      } catch (e) {
        // Колонка может уже существовать
      }
      try {
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_gossip_hash ON messages(gossip_hash)');
      } catch (e) {
        // Индекс может уже существовать
      }

      // Личные сообщения: индикатор доставки (ALTER TABLE с защитой)
      try {
        await txn.execute(
            'ALTER TABLE messages ADD COLUMN delivered INTEGER DEFAULT 0');
      } catch (e) {
        // Колонка может уже существовать
      }
      try {
        await txn
            .execute('ALTER TABLE messages ADD COLUMN delivered_at INTEGER');
      } catch (e) {
        // Колонка может уже существовать
      }
      try {
        await txn.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_delivered ON messages(delivered)');
      } catch (e) {
        // Индекс может уже существовать
      }

      print("📦 [DB] All tables and indexes established.");
    });
  }

  // ==========================================
  // 💬 MESSAGE OPERATIONS
  // ==========================================

  /// Ghost/Offline: current user id from ApiService when registered, else from Vault.
  /// 🔒 BEACON/GHOST FIX: Fallback to global Vault if scoped returns empty (persistence after app restart).
  Future<String> _getCurrentUserId() async {
    if (locator.isRegistered<ApiService>()) {
      return locator<ApiService>().currentUserId;
    }
    if (_vault != null) {
      final id = await _vault!.read('user_id');
      if (id != null && id.isNotEmpty) return id;
      // Fallback: global Vault (same key) in case scoped vault missed on cold start
      final fallback = await Vault.read('user_id');
      return fallback ?? '';
    }
    final id = await Vault.read('user_id');
    return id ?? '';
  }

  /// [contentAlreadyEncrypted] — true when saving mesh/received message that
  /// is already encrypted (do not double-encrypt). Default false = encrypt before store.
  /// [idempotentMerge] — when true use INSERT OR IGNORE (CRDT merge: no overwrite, no duplicate).
  Future<void> saveMessage(ChatMessage msg, String chatId,
      {bool contentAlreadyEncrypted = false, bool idempotentMerge = false}) async {
    // 🔒 SECURITY: Use same key source as getMessages — never EncryptionService(null), or decrypt on load fails.
    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      print(
          "⚠️ [DB] saveMessage skipped: CORE not ready (no EncryptionService/Vault) — message not persisted");
      return;
    }
    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());

    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (msg.clientTempId != null) {
      await db
          .delete('messages', where: 'id = ?', whereArgs: [msg.clientTempId]);
    }

    final chatKey = await encryptionService.getChatKey(chatId);
    final String encryptedContent = contentAlreadyEncrypted
        ? msg.content
        : await encryptionService.encrypt(msg.content, chatKey);

    // Импортируем jsonEncode для vectorClock
    final vectorClockJson =
        msg.vectorClock != null ? jsonEncode(msg.vectorClock) : null;

    int? seqNum = msg.sequenceNumber;
    String? prevHash = msg.previousHash;
    Map<String, int>? vc = msg.vectorClock;
    if (!idempotentMerge && (seqNum == null || prevHash == null || vc == null)) {
      final next = await getNextSequenceAndVectorClock(chatId, msg.senderId);
      seqNum ??= next.sequenceNumber;
      prevHash ??= next.previousHash;
      vc ??= next.vectorClock;
    }
    final row = <String, dynamic>{
      'id': msg.id,
      'ownerId': currentUserId,
      'clientTempId': msg.clientTempId,
      'content': encryptedContent,
      'chatRoomId': chatId,
      'senderId': msg.senderId,
      'senderUsername': msg.senderUsername,
      'createdAt': msg.createdAt.millisecondsSinceEpoch,
      'receivedAt': msg.receivedAt?.millisecondsSinceEpoch,
      'vectorClock': vc != null ? jsonEncode(vc) : vectorClockJson,
      'status': msg.status,
      'isEncrypted': 1,
    };
    if (seqNum != null) row['sequence_number'] = seqNum;
    if (prevHash != null) row['previous_hash'] = prevHash;
    if (msg.forkOfId != null) row['fork_of_id'] = msg.forkOfId;

    await db.insert(
      'messages',
      row,
      conflictAlgorithm:
          idempotentMerge ? ConflictAlgorithm.ignore : ConflictAlgorithm.replace,
    );
  }

  /// CRDT: Next sequence number, previous_hash, and HEADS snapshot for (chatId, authorId).
  Future<({int sequenceNumber, String previousHash, Map<String, int> vectorClock})>
      getNextSequenceAndVectorClock(String chatId, String authorId) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) {
      return (sequenceNumber: 1, previousHash: '', vectorClock: {authorId: 1});
    }
    final maxRow = await db.rawQuery(
      'SELECT MAX(COALESCE(sequence_number, 0)) AS mx FROM messages '
      'WHERE ownerId = ? AND chatRoomId = ? AND senderId = ?',
      [currentUserId, chatId, authorId],
    );
    final maxSeq = (maxRow.isNotEmpty && maxRow.first['mx'] != null)
        ? (maxRow.first['mx'] is int
            ? maxRow.first['mx'] as int
            : int.tryParse(maxRow.first['mx'].toString()) ?? 0)
        : 0;
    final nextSeq = maxSeq + 1;
    String previousHash = '';
    if (maxSeq > 0) {
      final prevRow = await db.rawQuery(
        'SELECT id, content, previous_hash FROM messages '
        'WHERE ownerId = ? AND chatRoomId = ? AND senderId = ? AND COALESCE(sequence_number, 0) = ?',
        [currentUserId, chatId, authorId, maxSeq],
      );
      if (prevRow.isNotEmpty) {
        final p = prevRow.first;
        previousHash = _hashLogEntry(
          p['id'], p['content'], p['previous_hash'], maxSeq,
        );
      }
    }
    final heads = await getHeads();
    final chatHeads = heads[chatId] ?? {};
    final vectorClock = Map<String, int>.from(chatHeads);
    vectorClock[authorId] = nextSeq;
    return (sequenceNumber: nextSeq, previousHash: previousHash, vectorClock: vectorClock);
  }

  static String _hashLogEntry(Object? id, Object? content, Object? prevHash, int seq) {
    final bytes = utf8.encode('${id ?? ""}|${content ?? ""}|${prevHash ?? ""}|$seq');
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// CRDT HEADS: per chat, author_id → highest_valid_sequence (main chain only; excludes fork branches).
  Future<Map<String, Map<String, int>>> getHeads() async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return {};
    final rows = await db.rawQuery(
      'SELECT chatRoomId, senderId, MAX(COALESCE(sequence_number, 0)) AS maxSeq '
      'FROM messages WHERE ownerId = ? AND (fork_of_id IS NULL OR fork_of_id = \'\') '
      'GROUP BY chatRoomId, senderId',
      [currentUserId],
    );
    final Map<String, Map<String, int>> out = {};
    for (final r in rows) {
      final chatId = (r['chatRoomId'] as String?) ?? '';
      final authorId = (r['senderId'] as String?) ?? '';
      final maxSeq = r['maxSeq'] is int ? r['maxSeq'] as int : int.tryParse(r['maxSeq'].toString()) ?? 0;
      if (chatId.isEmpty || authorId.isEmpty) continue;
      out.putIfAbsent(chatId, () => {})[authorId] = maxSeq;
    }
    return out;
  }

  /// CRDT: Log entries for (chatId, authorId) in range [fromSeq, toSeq] in sequence order.
  Future<List<Map<String, dynamic>>> getLogEntriesByAuthorRange(
      String chatId, String authorId, int fromSeq, int toSeq) async {
    if (fromSeq > toSeq) return [];
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    final rows = await db.rawQuery(
      'SELECT id, content, chatRoomId, senderId, senderUsername, createdAt, isEncrypted, '
      'sequence_number, previous_hash, vectorClock FROM messages '
      'WHERE ownerId = ? AND chatRoomId = ? AND senderId = ? '
      'AND COALESCE(sequence_number, 0) BETWEEN ? AND ? AND (fork_of_id IS NULL OR fork_of_id = \'\') '
      'ORDER BY sequence_number ASC',
      [currentUserId, chatId, authorId, fromSeq, toSeq],
    );
    return rows;
  }

  /// Returns hash of our local entry at (chatId, authorId, seq) for chain validation.
  Future<String?> getLocalEntryHashAt(String chatId, String authorId, int seq) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return null;
    final rows = await db.rawQuery(
      'SELECT id, content, previous_hash, sequence_number FROM messages '
      'WHERE ownerId = ? AND chatRoomId = ? AND senderId = ? AND COALESCE(sequence_number, 0) = ? '
      'AND (fork_of_id IS NULL OR fork_of_id = \'\') LIMIT 1',
      [currentUserId, chatId, authorId, seq],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return _hashLogEntry(r['id'], r['content'], r['previous_hash'], seq);
  }

  /// CRDT sync: insert log entry with chain validation and fork detection.
  /// Returns ({ inserted: true if stored, wasFork: true if stored as divergent branch }).
  Future<({bool inserted, bool wasFork})> saveLogEntryFromSync({
    required String chatId,
    required String authorId,
    required int sequenceNumber,
    required String previousHash,
    required Map<String, int> vectorClock,
    required int timestamp,
    required String encryptedPayload,
    required String id,
    String? senderUsername,
  }) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return (inserted: false, wasFork: false);

    final existing = await db.rawQuery(
      'SELECT id, previous_hash, content FROM messages '
      'WHERE ownerId = ? AND chatRoomId = ? AND senderId = ? AND COALESCE(sequence_number, 0) = ? '
      'AND (fork_of_id IS NULL OR fork_of_id = \'\') LIMIT 1',
      [currentUserId, chatId, authorId, sequenceNumber],
    );
    if (existing.isNotEmpty) {
      final ex = existing.first;
      final exHash = _hashLogEntry(ex['id'], ex['content'], ex['previous_hash'], sequenceNumber);
      final incomingHash = _hashLogEntry(id, encryptedPayload, previousHash, sequenceNumber);
      if (ex['previous_hash'] == previousHash && exHash == incomingHash) {
        return (inserted: true, wasFork: false); // idempotent
      }
      // Fork: same (author_id, seq) different hash — store as divergent branch
      final forkId = '${ex['id']}_fork_${incomingHash.substring(0, 8)}';
      final msg = ChatMessage(
        id: forkId,
        content: encryptedPayload,
        senderId: authorId,
        senderUsername: senderUsername ?? 'Unknown',
        createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
        status: 'MESH_LINK',
        sequenceNumber: sequenceNumber,
        previousHash: previousHash,
        vectorClock: vectorClock,
        forkOfId: ex['id'] as String?,
      );
      await saveMessage(msg, chatId, contentAlreadyEncrypted: true, idempotentMerge: true);
      return (inserted: true, wasFork: true);
    }

    if (sequenceNumber > 1) {
      final localPrevHash = await getLocalEntryHashAt(chatId, authorId, sequenceNumber - 1);
      if (localPrevHash != previousHash) {
        return (inserted: false, wasFork: false); // chain broken, reject
      }
    }

    final msg = ChatMessage(
      id: id,
      content: encryptedPayload,
      senderId: authorId,
      senderUsername: senderUsername ?? 'Unknown',
      createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
      status: 'MESH_LINK',
      sequenceNumber: sequenceNumber,
      previousHash: previousHash,
      vectorClock: vectorClock,
    );
    await saveMessage(msg, chatId, contentAlreadyEncrypted: true, idempotentMerge: true);
    return (inserted: true, wasFork: false);
  }

  /// CRDT reconciliation: per-chat list of message ids (for digest / divergence).
  /// Returns map chatRoomId -> sorted list of message ids.
  Future<Map<String, List<String>>> getMessageIdsByChat() async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return {};
    final List<Map<String, dynamic>> rows = await db.query(
      'messages',
      columns: ['id', 'chatRoomId', 'createdAt'],
      where: 'ownerId = ?',
      whereArgs: [currentUserId],
      orderBy: 'chatRoomId ASC, createdAt ASC, id ASC',
    );
    final Map<String, List<String>> byChat = {};
    for (final r in rows) {
      final chatId = (r['chatRoomId'] as String?) ?? '';
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      byChat.putIfAbsent(chatId, () => []).add(id);
    }
    return byChat;
  }

  /// CRDT reconciliation: full message rows by ids (for sending missing as OFFLINE_MSG).
  /// Returns list of maps with id, content, chatRoomId, senderId, senderUsername, createdAt, isEncrypted.
  Future<List<Map<String, dynamic>>> getMessagesByIds(
      List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, content, chatRoomId, senderId, senderUsername, createdAt, isEncrypted '
      'FROM messages WHERE ownerId = ? AND id IN ($placeholders)',
      [currentUserId, ...ids],
    );
    return rows;
  }

  /// Обновляет статус сообщения
  Future<void> updateMessageStatus(String messageId, String newStatus) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    await db.update(
      'messages',
      {'status': newStatus},
      where: 'id = ? AND ownerId = ?',
      whereArgs: [messageId, currentUserId],
    );
  }

  /// [limit] if set (e.g. 500 for THE_BEACON_GLOBAL), loads only last N messages to reduce lag.
  Future<List<ChatMessage>> getMessages(String chatId, {int? limit}) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    // THE_BEACON_GLOBAL: include legacy GLOBAL rows so one chat shows all (sync fix).
    // BEACON_NEARBY / THE_BEACON_XX: single room, limit last N for performance.
    final bool isGlobalOrBeacon = chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL';
    final bool isNearby = chatId == 'BEACON_NEARBY';
    final bool isBeaconCountry = chatId.startsWith('THE_BEACON_') && chatId.length == 13;
    final String whereClause = isGlobalOrBeacon
        ? "(chatRoomId = 'THE_BEACON_GLOBAL' OR chatRoomId = 'GLOBAL') AND ownerId = ?"
        : 'chatRoomId = ? AND ownerId = ?';
    final bool useLimit = limit != null && limit > 0 && (isGlobalOrBeacon || isNearby || isBeaconCountry);
    final List<dynamic> whereArgs = isGlobalOrBeacon
        ? [currentUserId]
        : [chatId, currentUserId];
    final List<Map<String, dynamic>> maps;
    if (useLimit) {
      // Last N in DESC order, then reverse so result is ASC (oldest first) for display.
      final rows = await db.rawQuery(
        'SELECT * FROM messages WHERE $whereClause '
        'ORDER BY createdAt DESC, senderId DESC, COALESCE(sequence_number, 0) DESC, id DESC LIMIT ?',
        [...whereArgs, limit],
      );
      maps = rows.reversed.toList();
    } else {
      maps = await db.rawQuery(
        'SELECT * FROM messages WHERE $whereClause '
        'ORDER BY createdAt ASC, senderId ASC, COALESCE(sequence_number, 0) ASC, id ASC',
        whereArgs,
      );
    }
    // 🔒 SECURITY: Use only Vault-bound crypto so cold start (camouflage → code → chat) decrypts with same salt.
    // Never create EncryptionService(null) — that uses a different salt and breaks decrypt after app kill.
    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      return []; // CORE not ready; UI should wait and retry or show empty until CORE is up
    }
    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());
    final chatKey = await encryptionService.getChatKey(chatId);

    // 🔒 Fix Database N+1: Convert dates efficiently (could be optimized further by storing DateTime directly)
    // Note: Current approach converts int → DateTime → ISO String for each message
    // Future optimization: Store DateTime in ChatMessage model directly, convert only in UI layer
    final decryptedMessages = <ChatMessage>[];
    for (final m in maps) {
      // Decrypt content
      final encryptedContent = m['content'] as String? ?? '';
      final decryptedContent =
          await encryptionService.decrypt(encryptedContent, chatKey);

      final json = {
        ...m,
        'content': decryptedContent, // 🔒 Decrypted content
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
        'receivedAt': m['receivedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['receivedAt'] as int)
                .toIso8601String()
            : null,
        'vectorClock': m['vectorClock'] as String?,
      };
      decryptedMessages.add(ChatMessage.fromJson(json));
    }
    return decryptedMessages;
  }

  /// Получить все чаты пользователя
  Future<List<Map<String, dynamic>>> getAllChatRooms() async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    final List<Map<String, dynamic>> maps = await db.query(
      'chat_rooms',
      where: 'ownerId = ?',
      whereArgs: [currentUserId],
      orderBy: 'lastActivity DESC',
    );
    return maps;
  }

  Future<List<ChatMessage>> getMessagesPaged(
      String chatId, int limit, int offset) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    final bool isGlobalOrBeacon = chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL';
    final String whereClause = isGlobalOrBeacon
        ? "(chatRoomId = 'THE_BEACON_GLOBAL' OR chatRoomId = 'GLOBAL') AND ownerId = ?"
        : 'chatRoomId = ? AND ownerId = ?';
    final List<dynamic> whereArgs = isGlobalOrBeacon
        ? [currentUserId]
        : [chatId, currentUserId];
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT * FROM messages WHERE $whereClause ORDER BY createdAt DESC LIMIT ? OFFSET ?',
      [...whereArgs, limit, offset],
    );

    // 🔒 SECURITY: Use only Vault-bound crypto (same as getMessages) — never EncryptionService(null).
    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      return [];
    }
    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());
    final chatKey = await encryptionService.getChatKey(chatId);

    final decryptedMessages = <ChatMessage>[];
    for (final m in maps) {
      // Decrypt content
      final encryptedContent = m['content'] as String? ?? '';
      final decryptedContent =
          await encryptionService.decrypt(encryptedContent, chatKey);

      final json = {
        ...m,
        'content': decryptedContent, // 🔒 Decrypted content
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
      };
      decryptedMessages.add(ChatMessage.fromJson(json));
    }
    return decryptedMessages.reversed.toList();
  }

  /// Удаляет сообщения за последние 24 часа (паник-протокол)
  Future<int> deleteMessagesLast24Hours() async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return 0;
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(hours: 24));
    final yesterdayTimestamp = yesterday.millisecondsSinceEpoch;

    print(
        "🧹 [PANIC] Deleting messages from last 24 hours (after ${yesterday.toIso8601String()})...");

    // Сначала получаем ID сообщений для удаления фрагментов
    final messagesToDelete = await db.query(
      'messages',
      columns: ['id'],
      where: 'ownerId = ? AND createdAt >= ?',
      whereArgs: [currentUserId, yesterdayTimestamp],
    );

    final messageIds = messagesToDelete.map((m) => m['id'] as String).toList();

    // Удаляем фрагменты сообщений
    if (messageIds.isNotEmpty) {
      final placeholders = List.filled(messageIds.length, '?').join(',');
      await db.delete(
        'message_fragments',
        where: 'messageId IN ($placeholders)',
        whereArgs: messageIds,
      );
    }

    // Удаляем сами сообщения
    final deletedCount = await db.delete(
      'messages',
      where: 'ownerId = ? AND createdAt >= ?',
      whereArgs: [currentUserId, yesterdayTimestamp],
    );

    print("✅ [PANIC] Deleted $deletedCount message(s) from last 24 hours");
    return deletedCount;
  }

  // ==========================================
  // 🤝 IDENTITY & TRUST
  // ==========================================

  Future<void> establishTrust(String id, String name, String? pubKey) async {
    final db = await database;
    await db.insert(
        'friends',
        {
          'id': id,
          'username': name,
          'publicKey': pubKey,
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
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
    final maps =
        await db.query('seen_pulses', where: 'id=?', whereArgs: [packetId]);
    if (maps.isNotEmpty) return true;

    await db.insert(
        'seen_pulses',
        {
          'id': packetId,
          'seenAt': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return false;
  }

  /// 🔥 MESH FRAGMENT PROTECTION: Лимиты на фрагментацию
  static const int maxFragmentsPerMessage =
      100; // Максимум 100 фрагментов на сообщение
  static const int maxFragmentDataSize = 500; // Максимум 500 байт на фрагмент
  static const int fragmentTtlMs =
      1000 * 60 * 30; // 30 минут TTL для фрагментов

  // 🔒 SECURITY FIX: Global limit on pending fragments to prevent OOM
  static const int maxGlobalPendingFragments =
      1000; // Max 1000 fragments globally
  static const int maxPendingMessages =
      50; // Max 50 incomplete messages at a time

  /// [chatId] and [senderId] required for first fragment: creates placeholder in
  /// messages so message_fragments FK is satisfied (incoming fragments have no
  /// message row until assembly).
  Future<bool> saveFragment(
      {required String messageId,
      required int index,
      required int total,
      required String data,
      String? chatId,
      String? senderId}) async {
    // 🛡️ FRAGMENT FLOODING PROTECTION
    if (total > maxFragmentsPerMessage) {
      print(
          "⚠️ [FRAGMENT] Rejected: too many fragments ($total > $maxFragmentsPerMessage) for $messageId");
      return false;
    }
    if (index < 0 || index >= total) {
      print(
          "⚠️ [FRAGMENT] Rejected: invalid index ($index/$total) for $messageId");
      return false;
    }
    if (data.length > maxFragmentDataSize) {
      print(
          "⚠️ [FRAGMENT] Rejected: fragment too large (${data.length} > $maxFragmentDataSize) for $messageId");
      return false;
    }

    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 🔒 SECURITY FIX: Check global fragment limit
    final globalCount = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM message_fragments')) ??
        0;

    if (globalCount >= maxGlobalPendingFragments) {
      print(
          "🛡️ [FRAGMENT] Global limit reached ($globalCount >= $maxGlobalPendingFragments). Cleaning up oldest fragments...");
      // Clean up oldest fragments to make room
      await _cleanupOldestFragments(
          db, maxGlobalPendingFragments ~/ 4); // Remove 25%
    }

    // 🔒 SECURITY FIX: Check pending message count (unique messageIds)
    final pendingMessages = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(DISTINCT messageId) FROM message_fragments')) ??
        0;

    // Check if this is a new message
    final existingForMessage = await db.query(
      'message_fragments',
      where: 'messageId = ?',
      whereArgs: [messageId],
      limit: 1,
    );

    if (existingForMessage.isEmpty && pendingMessages >= maxPendingMessages) {
      print(
          "🛡️ [FRAGMENT] Max pending messages reached ($pendingMessages >= $maxPendingMessages). Rejecting new message: $messageId");
      // Clean up oldest incomplete messages
      await _cleanupOldestIncompleteMessages(db, maxPendingMessages ~/ 4);
      return false;
    }

    // 🔥 FK FIX: message_fragments.messageId REFERENCES messages(id). For incoming
    // fragments the message row is created only after assembly; insert a
    // placeholder so the first fragment insert does not fail with FOREIGN KEY.
    if (existingForMessage.isEmpty && chatId != null && chatId.isNotEmpty && senderId != null && senderId.isNotEmpty) {
      final ownerId = await _getCurrentUserId();
      await db.insert(
          'messages',
          {
            'id': messageId,
            'ownerId': ownerId,
            'content': '',
            'chatRoomId': chatId,
            'senderId': senderId,
            'createdAt': now,
            'receivedAt': now,
            'status': 'pending_fragments',
            'isEncrypted': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    // 🔥 ДЕДУПЛИКАЦИЯ: Проверяем, не получали ли мы уже этот фрагмент
    final existing = await db.query(
      'message_fragments',
      where: 'fragmentId = ?',
      whereArgs: ["${messageId}_$index"],
    );
    if (existing.isNotEmpty) {
      print("ℹ️ [FRAGMENT] Duplicate fragment ignored: ${messageId}_$index");
      return false; // Дубликат
    }

    await db.insert(
        'message_fragments',
        {
          'fragmentId': "${messageId}_$index",
          'messageId': messageId,
          'index_num': index,
          'total': total,
          'data': data,
          'receivedAt': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);

    print(
        "📦 [FRAGMENT] Stored: ${messageId}_$index ($index/$total), ${data.length} bytes");
    return true;
  }

  /// 🔒 SECURITY FIX: Clean up oldest fragments when limit exceeded
  Future<void> _cleanupOldestFragments(Database db, int count) async {
    await db.rawDelete('''
      DELETE FROM message_fragments 
      WHERE fragmentId IN (
        SELECT fragmentId FROM message_fragments 
        ORDER BY receivedAt ASC 
        LIMIT ?
      )
    ''', [count]);
    print("🧹 [FRAGMENT] Cleaned up $count oldest fragments");
  }

  /// 🔒 SECURITY FIX: Clean up oldest incomplete messages
  Future<void> _cleanupOldestIncompleteMessages(Database db, int count) async {
    // Find oldest incomplete messages
    final oldestMessages = await db.rawQuery('''
      SELECT messageId, MIN(receivedAt) as oldest 
      FROM message_fragments 
      GROUP BY messageId 
      ORDER BY oldest ASC 
      LIMIT ?
    ''', [count]);

    for (var msg in oldestMessages) {
      final messageId = msg['messageId'] as String;
      await db.delete('message_fragments',
          where: 'messageId = ?', whereArgs: [messageId]);
      // Remove placeholder message row created for FK (pending_fragments)
      await db.delete('messages',
          where: 'id = ? AND status = ?',
          whereArgs: [messageId, 'pending_fragments']);
      print("🧹 [FRAGMENT] Cleaned up incomplete message: $messageId");
    }
  }

  /// 🔥 Проверяет, собрано ли сообщение полностью
  Future<bool> isMessageComplete(String messageId) async {
    final db = await database;
    final frags = await db.query(
      'message_fragments',
      columns: ['total'],
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
    if (frags.isEmpty) return false;
    final total = frags.first['total'] as int;
    return frags.length == total;
  }

  Future<List<Map<String, dynamic>>> getFragments(String messageId) async {
    final db = await database;
    return await db.query('message_fragments',
        where: 'messageId = ?', whereArgs: [messageId]);
  }

  Future<void> clearFragments(String messageId) async {
    final db = await database;
    await db.delete('message_fragments',
        where: 'messageId = ?', whereArgs: [messageId]);
  }

  // ==========================================
  // 📦 OUTBOX & RELAY
  // ==========================================

  /// 🛡️ ANTICENSORSHIP: contentAlreadyEncrypted=true when content is already encrypted (relay);
  /// false when plain — we encrypt before store (device seizure won't reveal plaintext).
  Future<void> addToOutbox(ChatMessage msg, String chatId,
      {int? expiresAt, bool contentAlreadyEncrypted = false}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final beforeRows = await db.query('outbox',
        where: 'expiresAt IS NULL OR expiresAt > ?', whereArgs: [now]);
    final countBefore = beforeRows.length;

    await _evictOutboxIfOverLimit(db, maxOutboxSize);
    String contentToStore = msg.content;
    try {
      if (!contentAlreadyEncrypted) {
        final encryptionService = locator.isRegistered<EncryptionService>()
            ? locator<EncryptionService>()
            : EncryptionService(locator.isRegistered<VaultInterface>() ? locator<VaultInterface>() : null);
        final chatKey = await encryptionService.getChatKey(chatId);
        contentToStore = await encryptionService.encrypt(msg.content, chatKey);
      }
    } catch (e) {
      print("[OUTBOX] addToOutbox FAILED (encrypt): $e");
      rethrow;
    }
    final defaultExpiresAt = expiresAt ??
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    final senderIdVal = msg.senderId;
    try {
      await db.insert(
          'outbox',
          {
            'id': msg.id,
            'chatRoomId': chatId,
            'content': contentToStore,
            'isEncrypted': 1,
            'createdAt': msg.createdAt.millisecondsSinceEpoch,
            'expiresAt': defaultExpiresAt,
            'routing_state': 'PENDING',
            'senderId': senderIdVal,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      print("[OUTBOX] addToOutbox FAILED (db.insert): $e");
      rethrow;
    }
    print("[OUTBOX] addToOutbox OK: id=${msg.id} chatId=$chatId");

    if (countBefore == 0) {
      final afterRows = await db.query('outbox',
          where: 'expiresAt IS NULL OR expiresAt > ?', whereArgs: [now]);
      if (afterRows.isNotEmpty && locator.isRegistered<EventBusService>()) {
        locator<EventBusService>().fire(OutboxFirstMessageEvent());
      }
    }
  }

  Future<List<Map<String, dynamic>>> getPendingFromOutbox() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 🔥 УЛУЧШЕНИЕ: Фильтруем просроченные payload (TTL > 1 час)
    final results = await db.query('outbox',
        where: 'expiresAt IS NULL OR expiresAt > ?',
        whereArgs: [now],
        orderBy: 'createdAt ASC');

    // Удаляем просроченные записи из базы
    await db.delete('outbox',
        where: 'expiresAt IS NOT NULL AND expiresAt <= ?', whereArgs: [now]);

    return results;
  }

  Future<void> removeFromOutbox(String id) async {
    final db = await database;
    await db.delete('outbox', where: 'id=?', whereArgs: [id]);
    final now = DateTime.now().millisecondsSinceEpoch;
    final afterRows = await db.query('outbox',
        where: 'expiresAt IS NULL OR expiresAt > ?', whereArgs: [now]);
    if (afterRows.isEmpty && locator.isRegistered<EventBusService>()) {
      locator<EventBusService>().fire(OutboxEmptyEvent());
    }
  }

  /// Обновляет прогресс отправки фрагментов по BLE (resume). Вызывать после каждой успешно отправленного фрагмента.
  Future<void> updateOutboxSentFragmentIndex(String messageId, int index) async {
    final db = await database;
    await db.update(
      'outbox',
      {'sentFragmentIndex': index},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Получает недавние сообщения из чата за указанный период
  Future<List<ChatMessage>> getRecentMessages({
    required String chatId,
    required DateTime since,
  }) async {
    final db = await database;
    final sinceMs = since.millisecondsSinceEpoch;

    final results = await db.query(
      'messages',
      where: 'chatRoomId = ? AND createdAt >= ?',
      whereArgs: [chatId, sinceMs],
      orderBy: 'createdAt DESC',
      limit: 50, // Ограничиваем последними 50 сообщениями
    );

    return results.map((row) => ChatMessage.fromJson(row)).toList();
  }

  // ==========================================
  // 🧹 MAINTENANCE & CLEANUP
  // ==========================================

  Future<void> _performInternalMaintenance(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pulseTtl = now - (1000 * 60 * 60 * 48); // 48 часов
    final fragmentTtl = now - fragmentTtlMs; // 30 минут для фрагментов

    await db.transaction((txn) async {
      // 🔥 FRAGMENT GC: Удаляем старые несобранные фрагменты
      final deletedFragments = await txn.delete('message_fragments',
          where: 'receivedAt < ?', whereArgs: [fragmentTtl]);
      if (deletedFragments > 0) {
        print(
            "🧹 [GC] Cleaned $deletedFragments stale message fragments (TTL: 30min)");
      }

      await txn
          .delete('seen_pulses', where: 'seenAt < ?', whereArgs: [pulseTtl]);
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

      // Автоочистка стагнационных SOS сигналов (12 часов после последнего сигнала в секторе)
      // Если сигнал идет на спад (нет новых сигналов 12+ часов) - удаляем весь сектор
      final sosTtl = now - (1000 * 60 * 60 * 12); // 12 часов
      await txn.execute('''
        DELETE FROM sos_signals
        WHERE sectorId IN (
          SELECT sectorId FROM sos_signals
          GROUP BY sectorId
          HAVING MAX(timestamp) < ?
        )
      ''', [sosTtl]);
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
    await db.insert('ads', ad.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AdPacket>> getActiveAds() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final List<Map<String, dynamic>> maps = await db.query('ads',
        where: 'expiresAt > ?', whereArgs: [now], orderBy: 'priority DESC');
    return maps.map((e) => AdPacket.fromJson(e)).toList();
  }

  // ==========================================
  // 🚨 SOS SIGNALS (Emergency signals)
  // ==========================================

  /// Сохраняет SOS сигнал в локальную БД (для оффлайн работы)
  Future<void> saveSosSignal({
    required String sectorId,
    String? locationName,
    double? lat,
    double? lon,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final signalId = 'sos_${sectorId}_$now';

    // Проверяем, есть ли уже сигнал для этого сектора
    final existing = await db.query(
      'sos_signals',
      where: 'sectorId = ? AND synced = 0',
      whereArgs: [sectorId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (existing.isNotEmpty) {
      // Обновляем существующий сигнал (увеличиваем счетчик)
      await db.update(
        'sos_signals',
        {
          'count': (existing.first['count'] as int? ?? 1) + 1,
          'timestamp': now,
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    } else {
      // Создаем новый сигнал
      await db.insert(
        'sos_signals',
        {
          'id': signalId,
          'sectorId': sectorId,
          'locationName': locationName,
          'lat': lat,
          'lon': lon,
          'timestamp': now,
          'synced': 0,
          'count': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Получает все несинхронизированные SOS сигналы
  Future<List<Map<String, dynamic>>> getUnsyncedSosSignals() async {
    final db = await database;
    return await db.query(
      'sos_signals',
      where: 'synced = 0',
      orderBy: 'timestamp DESC',
    );
  }

  /// Получает агрегированные SOS сигналы по секторам (для отображения в Hot Zones)
  /// Показывает только зоны, где было 3+ SOS сигнала (массовое ЧП)
  Future<List<Map<String, dynamic>>> getAggregatedSosSignals() async {
    final db = await database;
    // Группируем по sectorId и считаем количество сигналов
    // Показываем только зоны с 3+ сигналами (массовое ЧП)
    final result = await db.rawQuery('''
      SELECT 
        sectorId,
        MAX(locationName) as locationName,
        MAX(lat) as lat,
        MAX(lon) as lon,
        MAX(timestamp) as timestamp,
        SUM(count) as count
      FROM sos_signals
      WHERE timestamp > ?
      GROUP BY sectorId
      HAVING SUM(count) >= 3
      ORDER BY SUM(count) DESC, MAX(timestamp) DESC
    ''', [
      DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch
    ]);

    return result;
  }

  /// Анонимный счётчик SOS за последние 24 ч (для Sector map — без секторов и локаций).
  Future<int> getSosSignalsCountLast24h() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(count), 0) as total FROM sos_signals WHERE timestamp > ?
    ''', [DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch]);
    final v = result.isNotEmpty ? result.first['total'] : 0;
    return (v is int) ? v : (v is num ? v.toInt() : 0);
  }

  /// Помечает SOS сигналы как синхронизированные
  Future<void> markSosSignalsAsSynced(List<String> signalIds) async {
    final db = await database;
    if (signalIds.isEmpty) return;

    final placeholders = signalIds.map((_) => '?').join(',');
    await db.update(
      'sos_signals',
      {'synced': 1},
      where: 'id IN ($placeholders)',
      whereArgs: signalIds,
    );
  }

  // ==========================================
  // ☢️ EMERGENCY ERASURE (KILL SWITCH)
  // ==========================================

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      final tables = [
        'messages',
        'message_fragments',
        'friends',
        'seen_pulses',
        'outbox',
        'ads',
        'licenses',
        'chat_rooms',
        'system_stats'
      ];
      for (var t in tables) await txn.delete(t);
    });
    print("☢️ [DB] MEMORY PURGED SUCCESSFULLY.");
  }

  // ==========================================
  // 👥 FRIENDS OPERATIONS (Масштабируемая система друзей)
  // ==========================================

  /// Добавляет или обновляет друга
  Future<void> saveFriend({
    required String friendId,
    String? username,
    String? tacticalName,
    String? publicKey,
    String status = 'pending',
    int? requestedAt,
    int? acceptedAt,
    int? lastSeen,
    int karma = 0,
  }) async {
    final db = await database;
    await db.insert(
      'friends',
      {
        'id': friendId,
        'username': username,
        'tactical_name': tacticalName,
        'publicKey': publicKey,
        'status': status,
        'requested_at': requestedAt,
        'accepted_at': acceptedAt,
        'lastSeen': lastSeen,
        'karma': karma,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Получает список друзей по статусу
  Future<List<Map<String, dynamic>>> getFriends({String? status}) async {
    final db = await database;
    if (status != null) {
      return await db
          .query('friends', where: 'status = ?', whereArgs: [status]);
    }
    return await db.query('friends', orderBy: 'lastSeen DESC');
  }

  /// Получает друга по ID
  Future<Map<String, dynamic>?> getFriend(String friendId) async {
    final db = await database;
    final results = await db.query('friends',
        where: 'id = ?', whereArgs: [friendId], limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  /// Обновляет статус друга
  Future<void> updateFriendStatus(String friendId, String status,
      {int? acceptedAt}) async {
    final db = await database;
    await db.update(
      'friends',
      {
        'status': status,
        if (acceptedAt != null) 'accepted_at': acceptedAt,
      },
      where: 'id = ?',
      whereArgs: [friendId],
    );
  }

  /// Обновляет lastSeen для друга
  Future<void> updateFriendLastSeen(String friendId) async {
    final db = await database;
    await db.update(
      'friends',
      {'lastSeen': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [friendId],
    );
  }

  /// Удаляет друга
  Future<void> removeFriend(String friendId) async {
    final db = await database;
    await db.delete('friends', where: 'id = ?', whereArgs: [friendId]);
  }

  // ==========================================
  // 💬 GLOBAL CHAT OPERATIONS (Масштабируемый общий чат)
  // ==========================================

  /// Сохраняет сообщение в глобальный чат с TTL и gossip hash
  Future<void> saveGlobalChatMessage({
    required String id,
    required String senderId,
    String? senderUsername,
    required String content,
    String? gossipHash,
    int ttl = 7, // дней
    bool isEncrypted = false,
  }) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'id': id,
        'chatRoomId': 'THE_BEACON_GLOBAL',
        'senderId': senderId,
        'senderUsername': senderUsername,
        'content': content,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'status': 'SENT',
        'isEncrypted': isEncrypted ? 1 : 0,
        'gossip_hash': gossipHash,
        'ttl': ttl,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Получает сообщения из глобального чата (с лимитом и TTL фильтрацией)
  Future<List<Map<String, dynamic>>> getGlobalChatMessages(
      {int limit = 100}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Очищаем старые сообщения (TTL истек)
    await db.delete(
      'messages',
      where: 'chatRoomId = ? AND (createdAt + (ttl * 86400000)) < ?',
      whereArgs: ['THE_BEACON_GLOBAL', now],
    );
    // Возвращаем последние сообщения
    return await db.query(
      'messages',
      where: 'chatRoomId = ?',
      whereArgs: ['THE_BEACON_GLOBAL'],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
  }

  /// Проверяет, видели ли мы уже это сообщение (по gossip hash)
  Future<bool> isGossipMessageSeen(String gossipHash) async {
    if (gossipHash.isEmpty) return false;
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'gossip_hash = ?',
      whereArgs: [gossipHash],
      limit: 1,
    );
    return results.isNotEmpty;
  }

  // ==========================================
  // 🎯 ROOM EVENTS (Event-протокол для комнат)
  // ==========================================

  /// Сохраняет событие комнаты
  /// 🔥 Защита от дубликатов: (roomId, id) - уникальный ключ
  /// Если событие уже существует - игнорируем (idempotent)
  Future<bool> saveRoomEvent(RoomEvent event) async {
    final db = await database;
    try {
      await db.insert(
        'room_events',
        {
          'id': event.id,
          'roomId': event.roomId,
          'type': event.type,
          'userId': event.userId,
          'timestamp': event.timestamp.millisecondsSinceEpoch,
          'payload': event.payload != null ? jsonEncode(event.payload) : null,
          'event_origin': event.origin.name, // 📊 Для диагностики
        },
        conflictAlgorithm: ConflictAlgorithm.ignore, // Игнорируем дубликаты
      );
      return true; // Событие сохранено
    } catch (e) {
      // Если событие уже существует (уникальное ограничение) - это нормально
      if (e.toString().contains('UNIQUE constraint') ||
          e.toString().contains('PRIMARY KEY')) {
        print(
            "ℹ️ [DB] Room event already exists: ${event.roomId}/${event.id} (origin: ${event.origin.name}) - skipping");
        return false; // Событие уже было
      }
      rethrow;
    }
  }

  /// Получает все события комнаты
  Future<List<RoomEvent>> getRoomEvents(String roomId) async {
    final db = await database;
    final maps = await db.query(
      'room_events',
      where: 'roomId = ?',
      whereArgs: [roomId],
      orderBy: 'timestamp ASC',
    );

    return maps.map((m) {
      // Парсим event_origin
      EventOrigin origin = EventOrigin.LOCAL;
      if (m['event_origin'] != null) {
        final originStr = m['event_origin'] as String;
        origin = EventOrigin.values.firstWhere(
          (e) => e.name == originStr,
          orElse: () => EventOrigin.LOCAL,
        );
      }

      return RoomEvent(
        id: m['id'] as String,
        roomId: m['roomId'] as String,
        type: m['type'] as String,
        userId: m['userId'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        payload: m['payload'] != null
            ? jsonDecode(m['payload'] as String) as Map<String, dynamic>
            : null,
        origin: origin,
      );
    }).toList();
  }

  // ==========================================
  // 📨 DIRECT MESSAGE OPERATIONS (Личные сообщения)
  // ==========================================

  /// Сохраняет личное сообщение
  Future<void> saveDirectMessage({
    required String id,
    required String chatId, // dm_senderId_receiverId
    required String senderId,
    required String receiverId,
    required String content,
    bool isEncrypted = true,
  }) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'id': id,
        'chatRoomId': chatId,
        'senderId': senderId,
        'receiverId': receiverId,
        'content': content,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'status': 'PENDING_DELIVERY',
        'isEncrypted': isEncrypted ? 1 : 0,
        'delivered': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Отмечает сообщение как доставленное
  Future<void> markMessageDelivered(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {
        'delivered': 1,
        'delivered_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'DELIVERED',
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Получает личные сообщения для чата
  Future<List<Map<String, dynamic>>> getDirectMessages(String chatId,
      {int limit = 100}) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'chatRoomId = ?',
      whereArgs: [chatId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
  }
}
