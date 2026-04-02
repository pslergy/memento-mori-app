import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../features/chat/conversation_screen.dart';
import 'api_service.dart';
import 'decoy/app_mode.dart';
import 'decoy/storage_paths.dart';
import 'decoy/vault_interface.dart';
import 'locator.dart';
import 'panic/panic_neutral_phrases.dart';
import 'models/ad_packet.dart';
import 'room_events.dart' show RoomEvent, EventOrigin;
import 'dm_chat_id.dart';
import 'encryption_service.dart';
import 'mesh/mesh_constants.dart';
import 'mesh/utils/mesh_utils.dart';
import 'message_crypto_facade.dart';
import 'event_bus_service.dart';
import 'double_ratchet/double_ratchet_user_prefs.dart';
import 'double_ratchet/dr_dh_peer_pins.dart';
import 'double_ratchet/dr_peer_bundle_cache.dart';
import 'safe_string_prefix.dart';
import 'storage_service.dart';

Future<void> _ensureDrHandshakeDeliveryColumnsV31(Database db) async {
  Future<void> tryAlter(String sql) async {
    try {
      await db.execute(sql);
    } catch (_) {}
  }

  final info = await db.rawQuery('PRAGMA table_info(dr_handshake_outbox)');
  if (info.isEmpty) return;
  final names = info.map((c) => c['name'] as String).toSet();
  if (!names.contains('delivery_state')) {
    await tryAlter(
      "ALTER TABLE dr_handshake_outbox ADD COLUMN delivery_state TEXT DEFAULT 'pending'",
    );
  }
  if (!names.contains('next_retry_at')) {
    await tryAlter('ALTER TABLE dr_handshake_outbox ADD COLUMN next_retry_at INTEGER');
  }
}

Future<void> _backfillDrHandshakeDeliveryStateV31(Database db) async {
  try {
    await db.execute(
      "UPDATE dr_handshake_outbox SET delivery_state = 'acknowledged' "
      "WHERE IFNULL(delivered_confirmed, 0) = 1 "
      "AND (delivery_state IS NULL OR delivery_state = '')",
    );
    await db.execute(
      "UPDATE dr_handshake_outbox SET delivery_state = 'sent', "
      "next_retry_at = NULL "
      "WHERE IFNULL(delivered_to_peer, 0) = 1 "
      "AND IFNULL(delivered_confirmed, 0) = 0 "
      "AND (delivery_state IS NULL OR delivery_state = '')",
    );
    await db.execute(
      "UPDATE dr_handshake_outbox SET delivery_state = 'pending' "
      "WHERE (delivery_state IS NULL OR delivery_state = '')",
    );
  } catch (_) {}
}

Future<void> _ensureDrHandshakeOutboxColumnsV25(Database db) async {
  Future<void> tryAlter(String sql) async {
    try {
      await db.execute(sql);
    } catch (_) {}
  }

  final info = await db.rawQuery('PRAGMA table_info(dr_handshake_outbox)');
  if (info.isEmpty) return;
  final names = info.map((c) => c['name'] as String).toSet();
  if (!names.contains('packet_id')) {
    await tryAlter('ALTER TABLE dr_handshake_outbox ADD COLUMN packet_id TEXT');
  }
  if (!names.contains('row_version')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN row_version INTEGER DEFAULT 1');
  }
  if (!names.contains('status')) {
    await tryAlter(
        "ALTER TABLE dr_handshake_outbox ADD COLUMN status TEXT DEFAULT 'PENDING'");
  }
  if (!names.contains('attempt_count')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN attempt_count INTEGER DEFAULT 0');
  }
  if (!names.contains('last_attempt_at')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN last_attempt_at INTEGER');
  }
  if (!names.contains('chat_id')) {
    await tryAlter('ALTER TABLE dr_handshake_outbox ADD COLUMN chat_id TEXT');
  }
  if (!names.contains('delivered_to_peer')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN delivered_to_peer INTEGER DEFAULT 0');
  }
  if (!names.contains('last_delivery_attempt')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN last_delivery_attempt INTEGER');
  }
  if (!names.contains('delivery_attempts')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN delivery_attempts INTEGER DEFAULT 0');
  }
  if (!names.contains('delivered_confirmed')) {
    await tryAlter(
        'ALTER TABLE dr_handshake_outbox ADD COLUMN delivered_confirmed INTEGER DEFAULT 0');
  }
}

Future<void> _backfillDrHandshakeOutboxPacketIds(Database db) async {
  try {
    final rows = await db.query(
      'dr_handshake_outbox',
      where: 'packet_id IS NULL OR packet_id = ?',
      whereArgs: [''],
    );
    for (final r in rows) {
      try {
        final raw = r['payload_json'] as String? ?? '';
        if (raw.isEmpty) continue;
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final h = m['h']?.toString();
        if (h == null || h.isEmpty) continue;
        await db.update(
          'dr_handshake_outbox',
          {'packet_id': h},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      } catch (_) {}
    }
  } catch (_) {}
}

Future<void> _ensureDrHandshakeSessionTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS dr_handshake_session(
      chat_id TEXT NOT NULL,
      peer_user_id TEXT NOT NULL,
      state TEXT NOT NULL,
      handshake_version INTEGER NOT NULL DEFAULT 1,
      ack_received INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (chat_id, peer_user_id)
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dr_hs_sess_updated ON dr_handshake_session(updated_at)');
}

/// Сводка локальной истории чата: поколение мутаций, heads fingerprint (CRDT), время последнего изменения.
/// Не гарантирует совпадение с другим устройством — только состояние этой БД.
class ChatHistorySnapshot {
  const ChatHistorySnapshot({
    required this.chatId,
    required this.historyGeneration,
    required this.lastMutationAtMs,
    required this.authorCount,
    required this.maxSequenceAcrossAuthors,
    required this.headsFingerprint,
    required this.messageRowCount,
  });

  final String chatId;
  /// Монотонно растёт при каждой зафиксированной мутации истории (см. [LocalDatabaseService]).
  final int historyGeneration;
  final int lastMutationAtMs;
  /// Число авторов с сообщениями на основной цепи (fork_of пустой).
  final int authorCount;
  /// Максимум `sequence_number` среди авторских голов в этом чате.
  final int maxSequenceAcrossAuthors;
  /// Укороченный SHA-256 от канонической строки heads (authorId:maxSeq|...).
  final String headsFingerprint;
  /// Все строки сообщений в чате (включая без seq).
  final int messageRowCount;
}

/// SECURITY INVARIANT: REAL and DECOY use separate directories and DB files (no shared WAL/journals).
/// When [dbDirectorySuffix] is set, DB lives in `databases/<suffix>/<fileName>`; no path reuse across modes.
/// On logout, call [closeAndCheckpoint] before teardown so no orphaned WAL/handles remain.
///
/// ⚠️ НЕ УДАЛЯТЬ таблицы и поля: messages (ownerId, chatRoomId), outbox (senderId), getMessages/saveMessage/addToOutbox,
/// chat_history_state (historyGeneration, lastHistoryMutationAt) — поколение локальной истории для UI/сводок,
/// getPendingFromOutbox, dr_handshake_outbox (DR_DH pull queue), THE_BEACON_GLOBAL seed — Beacon/Ghost и mesh.
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

  /// `true` для профиля каталога `real/` (отдельно от DECOY).
  bool get isRealDatabaseProfile => _dbDirectorySuffix == 'real';

  /// Суффикс каталога БД (`real` / `decoy`) или null для legacy-пути без изоляции режимов.
  String? get databaseDirectorySuffix => _dbDirectorySuffix;

  /// Соответствует ли открытая БД ожидаемому режиму REAL/DECOY (отдельные файлы на диске).
  bool isOpenedForAppMode(AppMode mode) {
    final expected = dbDirectorySuffixForMode(mode);
    return _dbDirectorySuffix == expected;
  }

  static const String _firstLaunchKey = 'first_launch_done';

  /// Максимум сообщений на одну личку (`dm_*`); при превышении удаляются самые старые.
  static const int dmLocalMessageRetentionCap = 500;

  Database? _database;
  Completer<Database>? _dbCompleter;

  /// Set when [ensureDrHandshakeOutboxRow] completes (OUTBOX_REQUEST vs SQLite race).
  int _lastDrHandshakeEnqueueMs = 0;

  /// Per-peer enqueue barrier (target_user_id + 16-char BLE keys) — soft coordination with OUTBOX_REQUEST.
  final Map<String, int> _lastEnqueueTimestampByPeer = {};

  /// Bumped on every enqueue/update to [dr_handshake_outbox] so BLE can detect insert-vs-pull races.
  int _drHandshakeOutboxWriteGeneration = 0;

  /// Monotonic ms since epoch; use in peripheral OUTBOX handler to delay if enqueue was under 50ms ago.
  int get lastDrHandshakeEnqueueEpochMs => _lastDrHandshakeEnqueueMs;

  int get drHandshakeOutboxWriteGeneration => _drHandshakeOutboxWriteGeneration;

  /// Last [ensureDrHandshakeOutboxRow] time for [peerKey] (`target_user_id` or 16-char device UUID).
  int? lastEnqueueTimestampForPeerKey(String? peerKey) {
    if (peerKey == null || peerKey.isEmpty) return null;
    return _lastEnqueueTimestampByPeer[peerKey.trim().toLowerCase()];
  }

  void _recordDrHandshakeEnqueueBarrier(String targetUserId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final k = targetUserId.trim().toLowerCase();
    _lastEnqueueTimestampByPeer[k] = now;
    for (final key in meshBleDeviceUuidKeysForFriend(targetUserId)) {
      final kk = key.trim().toLowerCase();
      if (kk.length == 16) {
        _lastEnqueueTimestampByPeer[kk] = now;
      }
    }
  }

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
      version: 31, // v31: delivery_state + next_retry_at (GATT re-notify until ACK)
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
        if (oldVersion < 18) {
          try {
            var messagesInfo = await db.rawQuery('PRAGMA table_info(messages)');
            var cols = messagesInfo.map((c) => c['name'] as String).toList();
            if (!cols.contains('reply_to_id')) {
              await db.execute('ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
            }
            if (!cols.contains('reply_preview')) {
              await db.execute('ALTER TABLE messages ADD COLUMN reply_preview TEXT');
            }
            print("✅ [DB] Migration v18 completed: reply_to_id, reply_preview");
          } catch (e) {
            print("⚠️ [DB] Migration v18 error: $e");
          }
        }
        if (oldVersion < 19) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS attempt_logs(
                id TEXT PRIMARY KEY,
                donor_sni TEXT NOT NULL,
                mode TEXT NOT NULL,
                padding_config TEXT,
                timestamp INTEGER NOT NULL,
                operator_code TEXT,
                region TEXT,
                result TEXT NOT NULL,
                failure_reason TEXT,
                bytes_transferred INTEGER
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_attempt_logs_timestamp ON attempt_logs(timestamp)');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_attempt_logs_donor ON attempt_logs(donor_sni)');
            print("✅ [DB] Migration v19 completed: attempt_logs (Immune Chunk)");
          } catch (e) {
            print("⚠️ [DB] Migration v19 error: $e");
          }
        }
        if (oldVersion < 20) {
          try {
            var outboxInfo = await db.rawQuery('PRAGMA table_info(outbox)');
            var outboxColumns =
                outboxInfo.map((c) => c['name'] as String).toList();
            if (!outboxColumns.contains('sprayCount')) {
              await db.execute(
                  'ALTER TABLE outbox ADD COLUMN sprayCount INTEGER');
            }
            if (!outboxColumns.contains('copiesRemaining')) {
              await db.execute(
                  'ALTER TABLE outbox ADD COLUMN copiesRemaining INTEGER');
            }
            print(
                "✅ [DB] Migration v20 completed: sprayCount, copiesRemaining (Spray-and-Wait)");
          } catch (e) {
            print("⚠️ [DB] Migration v20 error: $e");
          }
        }
        if (oldVersion < 21) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS chat_history_state(
                chatRoomId TEXT NOT NULL,
                ownerId TEXT NOT NULL,
                historyGeneration INTEGER NOT NULL DEFAULT 0,
                lastHistoryMutationAt INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (ownerId, chatRoomId)
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_chat_history_state_room ON chat_history_state(chatRoomId)');
            print(
                "✅ [DB] Migration v21 completed: chat_history_state (local history generation)");
          } catch (e) {
            print("⚠️ [DB] Migration v21 error: $e");
          }
        }
        if (oldVersion < 22) {
          try {
            var attemptInfo =
                await db.rawQuery('PRAGMA table_info(attempt_logs)');
            var attemptCols =
                attemptInfo.map((c) => c['name'] as String).toList();
            if (!attemptCols.contains('bytes_transferred')) {
              await db.execute(
                  'ALTER TABLE attempt_logs ADD COLUMN bytes_transferred INTEGER');
            }
            print(
                "✅ [DB] Migration v22 completed: attempt_logs.bytes_transferred (DPI metrics)");
          } catch (e) {
            print("⚠️ [DB] Migration v22 error: $e");
          }
        }
        if (oldVersion < 23) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS double_ratchet_sessions(
                chat_id TEXT PRIMARY KEY,
                state_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_double_ratchet_updated ON double_ratchet_sessions(updated_at)');
            print(
                "✅ [DB] Migration v23 completed: double_ratchet_sessions (DR state)");
          } catch (e) {
            print("⚠️ [DB] Migration v23 error: $e");
          }
        }
        if (oldVersion < 24) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS dr_handshake_outbox(
                id TEXT PRIMARY KEY,
                packet_type TEXT NOT NULL,
                target_user_id TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                peer_mac_hint TEXT,
                created_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_target ON dr_handshake_outbox(target_user_id)');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_created ON dr_handshake_outbox(created_at)');
            print(
                "✅ [DB] Migration v24 completed: dr_handshake_outbox (DR_DH GATT pull)");
          } catch (e) {
            print("⚠️ [DB] Migration v24 error: $e");
          }
        }
        if (oldVersion < 25) {
          try {
            await _ensureDrHandshakeOutboxColumnsV25(db);
            await _backfillDrHandshakeOutboxPacketIds(db);
            await _ensureDrHandshakeSessionTable(db);
            print(
                "✅ [DB] Migration v25 completed: dr_handshake_outbox state + dr_handshake_session");
          } catch (e) {
            print("⚠️ [DB] Migration v25 error: $e");
          }
        }
        if (oldVersion < 26) {
          try {
            final fi = await db.rawQuery('PRAGMA table_info(friends)');
            final fc = fi.map((c) => c['name'] as String).toList();
            if (!fc.contains('ble_route_device_uuid')) {
              await db.execute(
                'ALTER TABLE friends ADD COLUMN ble_route_device_uuid TEXT',
              );
            }
            print(
                "✅ [DB] Migration v26 completed: friends.ble_route_device_uuid");
          } catch (e) {
            print("⚠️ [DB] Migration v26 error: $e");
          }
        }
        if (oldVersion < 27) {
          try {
            await _ensureDrHandshakeOutboxColumnsV25(db);
            try {
              await db.execute(
                "UPDATE dr_handshake_outbox SET delivered_to_peer = 1 "
                "WHERE IFNULL(NULLIF(TRIM(status), ''), 'PENDING') = 'NOTIFY_OK'",
              );
            } catch (_) {}
            print(
                "✅ [DB] Migration v27 completed: dr_handshake_outbox.delivered_to_peer");
          } catch (e) {
            print("⚠️ [DB] Migration v27 error: $e");
          }
        }
        if (oldVersion < 28) {
          try {
            await _ensureDrHandshakeOutboxColumnsV25(db);
            print(
                "✅ [DB] Migration v28 completed: dr_handshake_outbox delivery telemetry",
            );
          } catch (e) {
            print("⚠️ [DB] Migration v28 error: $e");
          }
        }
        if (oldVersion < 29) {
          try {
            await _ensureDrHandshakeOutboxColumnsV25(db);
            await db.execute('''
              CREATE TABLE IF NOT EXISTS ble_peer_sync_hint(
                mac TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL
              )
            ''');
            try {
              await db.execute(
                "UPDATE dr_handshake_outbox SET delivered_confirmed = 1 "
                "WHERE IFNULL(delivered_to_peer,0) = 1 "
                "AND IFNULL(NULLIF(TRIM(status), ''), 'PENDING') IN ('NOTIFY_OK', 'PENDING')",
              );
            } catch (_) {}
            print(
                "✅ [DB] Migration v29 completed: delivered_confirmed + ble_peer_sync_hint",
            );
          } catch (e) {
            print("⚠️ [DB] Migration v29 error: $e");
          }
        }
        if (oldVersion < 30) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS mesh_transit_store(
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                target_user_id TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                ttl INTEGER,
                created_at INTEGER NOT NULL,
                last_relay_at INTEGER
              )
            ''');
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_mesh_transit_target ON mesh_transit_store(target_user_id)',
            );
            print("✅ [DB] Migration v30 completed: mesh_transit_store");
          } catch (e) {
            print("⚠️ [DB] Migration v30 error: $e");
          }
        }
        if (oldVersion < 31) {
          try {
            await _ensureDrHandshakeOutboxColumnsV25(db);
            await _ensureDrHandshakeDeliveryColumnsV31(db);
            await _backfillDrHandshakeDeliveryStateV31(db);
            print(
              "✅ [DB] Migration v31 completed: delivery_state + next_retry_at (outbox truth)",
            );
          } catch (e) {
            print("⚠️ [DB] Migration v31 error: $e");
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

          // Defensive: ensure outbox spray-and-wait columns exist (e.g. DB created at v20 via onCreate before schema update)
          final outboxInfo = await db.rawQuery('PRAGMA table_info(outbox)');
          final outboxCols = outboxInfo.map((c) => c['name'] as String).toList();
          if (!outboxCols.contains('sprayCount')) {
            await db.execute('ALTER TABLE outbox ADD COLUMN sprayCount INTEGER');
            print("✅ [DB] onOpen: added missing sprayCount to outbox");
          }
          if (!outboxCols.contains('copiesRemaining')) {
            await db.execute('ALTER TABLE outbox ADD COLUMN copiesRemaining INTEGER');
            print("✅ [DB] onOpen: added missing copiesRemaining to outbox");
          }
          if (!outboxCols.contains('sentFragmentIndex')) {
            await db.execute('ALTER TABLE outbox ADD COLUMN sentFragmentIndex INTEGER DEFAULT -1');
            print("✅ [DB] onOpen: added missing sentFragmentIndex to outbox");
          }

          final drTables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='double_ratchet_sessions'");
          if (drTables.isEmpty) {
            await db.execute('''
              CREATE TABLE double_ratchet_sessions(
                chat_id TEXT PRIMARY KEY,
                state_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_double_ratchet_updated ON double_ratchet_sessions(updated_at)');
            print("✅ [DB] onOpen: created double_ratchet_sessions");
          }

          final drHoTables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='dr_handshake_outbox'");
          if (drHoTables.isEmpty) {
            await db.execute('''
              CREATE TABLE dr_handshake_outbox(
                id TEXT PRIMARY KEY,
                packet_type TEXT NOT NULL,
                target_user_id TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                peer_mac_hint TEXT,
                created_at INTEGER NOT NULL,
                packet_id TEXT,
                row_version INTEGER DEFAULT 1,
                status TEXT DEFAULT 'PENDING',
                attempt_count INTEGER DEFAULT 0,
                last_attempt_at INTEGER,
                chat_id TEXT,
                delivered_to_peer INTEGER DEFAULT 0,
                delivery_state TEXT DEFAULT 'pending',
                next_retry_at INTEGER
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_target ON dr_handshake_outbox(target_user_id)');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_created ON dr_handshake_outbox(created_at)');
            print("✅ [DB] onOpen: created dr_handshake_outbox");
          }
          await _ensureDrHandshakeOutboxColumnsV25(db);
          await _ensureDrHandshakeDeliveryColumnsV31(db);
          await _backfillDrHandshakeDeliveryStateV31(db);
          await _backfillDrHandshakeOutboxPacketIds(db);
          await _ensureDrHandshakeSessionTable(db);

          final syncHintTables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='ble_peer_sync_hint'");
          if (syncHintTables.isEmpty) {
            await db.execute('''
              CREATE TABLE ble_peer_sync_hint(
                mac TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL
              )
            ''');
            print("✅ [DB] onOpen: created ble_peer_sync_hint");
          }

          final friendsOpen =
              await db.rawQuery('PRAGMA table_info(friends)');
          final friendsOpenCols =
              friendsOpen.map((c) => c['name'] as String).toList();
          if (!friendsOpenCols.contains('ble_route_device_uuid')) {
            await db.execute(
                'ALTER TABLE friends ADD COLUMN ble_route_device_uuid TEXT');
            print("✅ [DB] onOpen: added ble_route_device_uuid to friends");
          }

          final histTables = await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='chat_history_state'");
          if (histTables.isEmpty) {
            await db.execute('''
              CREATE TABLE chat_history_state(
                chatRoomId TEXT NOT NULL,
                ownerId TEXT NOT NULL,
                historyGeneration INTEGER NOT NULL DEFAULT 0,
                lastHistoryMutationAt INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (ownerId, chatRoomId)
              )
            ''');
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_chat_history_state_room ON chat_history_state(chatRoomId)');
            print("✅ [DB] onOpen: created chat_history_state");
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
  /// 6. ads, 7. licenses, 8. chat_rooms, 8.1. room_events, 8.2. chat_history_state
  /// 9. system_stats, 10. known_routers, 11. sos_signals
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
          karma INTEGER DEFAULT 0,
          ble_route_device_uuid TEXT
        )
      ''');

      // 4. Gossip Deduplicator (Seen Pulses)
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS seen_pulses(id TEXT PRIMARY KEY, seenAt INTEGER)');

      // 5. Outbox (Viral Relay Queue + Smart Routing)
      // v15: senderId for relay attribution and ephemeral token
      // v16: sentFragmentIndex (BLE fragment resume)
      // v20: sprayCount, copiesRemaining (Spray-and-Wait DTN)
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
          senderId TEXT,
          sprayCount INTEGER,
          copiesRemaining INTEGER,
          sentFragmentIndex INTEGER DEFAULT -1
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

      // 8.2. Локальное поколение истории чата (UI / отладка; не замена CRDT heads на wire)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS chat_history_state(
          chatRoomId TEXT NOT NULL,
          ownerId TEXT NOT NULL,
          historyGeneration INTEGER NOT NULL DEFAULT 0,
          lastHistoryMutationAt INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (ownerId, chatRoomId)
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_chat_history_state_room ON chat_history_state(chatRoomId)');

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

      // 12. Attempt Logs (Immune Chunk — дневник попыток подключения)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS attempt_logs(
          id TEXT PRIMARY KEY,
          donor_sni TEXT NOT NULL,
          mode TEXT NOT NULL,
          padding_config TEXT,
          timestamp INTEGER NOT NULL,
          operator_code TEXT,
          region TEXT,
          result TEXT NOT NULL,
          failure_reason TEXT,
          bytes_transferred INTEGER
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_attempt_logs_ts ON attempt_logs(timestamp)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_attempt_logs_donor ON attempt_logs(donor_sni)');

      // 13. Double Ratchet session state (per dm_* chat, local E2EE phase 2)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS double_ratchet_sessions(
          chat_id TEXT PRIMARY KEY,
          state_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_double_ratchet_updated ON double_ratchet_sessions(updated_at)');

      // 14. DR handshake deferred delivery (Peripheral pulls via OUTBOX_REQUEST → notify)
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS dr_handshake_outbox(
          id TEXT PRIMARY KEY,
          packet_type TEXT NOT NULL,
          target_user_id TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          peer_mac_hint TEXT,
          created_at INTEGER NOT NULL,
          packet_id TEXT,
          row_version INTEGER DEFAULT 1,
          status TEXT DEFAULT 'PENDING',
          attempt_count INTEGER DEFAULT 0,
          last_attempt_at INTEGER,
          chat_id TEXT,
          delivered_to_peer INTEGER DEFAULT 0,
          last_delivery_attempt INTEGER,
          delivery_attempts INTEGER DEFAULT 0,
          delivered_confirmed INTEGER DEFAULT 0,
          delivery_state TEXT DEFAULT 'pending',
          next_retry_at INTEGER
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_target ON dr_handshake_outbox(target_user_id)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_dr_hs_outbox_created ON dr_handshake_outbox(created_at)');

      await txn.execute('''
        CREATE TABLE IF NOT EXISTS dr_handshake_session(
          chat_id TEXT NOT NULL,
          peer_user_id TEXT NOT NULL,
          state TEXT NOT NULL,
          handshake_version INTEGER NOT NULL DEFAULT 1,
          ack_received INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (chat_id, peer_user_id)
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_dr_hs_sess_updated ON dr_handshake_session(updated_at)');

      await txn.execute('''
        CREATE TABLE IF NOT EXISTS mesh_transit_store(
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          target_user_id TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          ttl INTEGER,
          created_at INTEGER NOT NULL,
          last_relay_at INTEGER
        )
      ''');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_mesh_transit_target ON mesh_transit_store(target_user_id)');

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

  /// DIRECT-комната, в [participants] которой есть [peerSenderId] (или тот же mesh-stable id).
  Future<String?> findDirectRoomIdContainingPeer(
      String ownerId, String peerSenderId) async {
    if (ownerId.isEmpty || peerSenderId.isEmpty) return null;
    final db = await database;
    final rooms = await db.query(
      'chat_rooms',
      columns: ['id', 'participants'],
      where: "ownerId = ? AND (type = 'DIRECT' OR room_type = 'DIRECT')",
      whereArgs: [ownerId],
    );
    final peerStable = meshStableIdForDm(peerSenderId);
    for (final r in rooms) {
      final rid = r['id']?.toString() ?? '';
      if (!rid.toLowerCase().startsWith('dm_')) continue;
      List<dynamic> parts;
      try {
        final pRaw = r['participants'];
        final pStr = pRaw is String ? pRaw : (pRaw?.toString() ?? '[]');
        parts = jsonDecode(pStr) as List<dynamic>? ?? [];
      } catch (_) {
        continue;
      }
      for (final p in parts) {
        if (meshStableIdForDm(p.toString()) == peerStable) {
          return rid;
        }
      }
    }
    return null;
  }

  /// Строка участника из `chat_rooms`, совпадающая с [peerSenderId] по [meshStableIdForDm]
  /// (например в БД короткий hex, на wire полный `GHOST_*`). Для расшифровки mesh с тем же ключом, что при открытии чата.
  Future<String?> getDirectDmPeerStoredAlias(
      String ownerId, String peerSenderId) async {
    if (ownerId.isEmpty || peerSenderId.isEmpty) return null;
    final db = await database;
    final rooms = await db.query(
      'chat_rooms',
      columns: ['participants'],
      where: "ownerId = ? AND (type = 'DIRECT' OR room_type = 'DIRECT')",
      whereArgs: [ownerId],
    );
    final peerStable = meshStableIdForDm(peerSenderId);
    for (final r in rooms) {
      List<dynamic> parts;
      try {
        final pRaw = r['participants'];
        final pStr = pRaw is String ? pRaw : (pRaw?.toString() ?? '[]');
        parts = jsonDecode(pStr) as List<dynamic>? ?? [];
      } catch (_) {
        continue;
      }
      for (final p in parts) {
        final ps = p.toString();
        if (meshStableIdForDm(ps) == peerStable) {
          return ps;
        }
      }
    }
    return null;
  }

  /// Единый `dm_*` для записи в SQLite: совпадает с строкой [chat_rooms], если личка уже есть.
  Future<String> resolveDmStorageChatIdForMeshPacket({
    required String wireOrResolvedChatId,
    required String senderId,
  }) async {
    final c = wireOrResolvedChatId.trim();
    if (!c.toLowerCase().startsWith('dm_')) return c;
    final myId = await _getCurrentUserId();
    if (myId.isEmpty) return normalizeDmChatId(c);
    final sid = senderId.trim();
    if (sid.isEmpty || sid == myId) return normalizeDmChatId(c);
    final db = await database;
    final wireNorm = normalizeDmChatId(c);
    final byId = await db.query(
      'chat_rooms',
      columns: ['id'],
      where: 'id = ? AND ownerId = ?',
      whereArgs: [wireNorm, myId],
      limit: 1,
    );
    if (byId.isNotEmpty) return wireNorm;
    final fromParticipants = await findDirectRoomIdContainingPeer(myId, sid);
    if (fromParticipants != null) return normalizeDmChatId(fromParticipants);
    return dmStorageChatIdFromWireAndSender(
      wireChatId: c,
      senderId: sid,
      myUserId: myId,
    );
  }

  /// Удаляет самые старые сообщения лички сверх [dmLocalMessageRetentionCap].
  Future<void> pruneDmChatBeyondCap(String chatId) async {
    if (!chatId.toLowerCase().startsWith('dm_')) return;
    final db = await database;
    final owner = await _getCurrentUserId();
    if (owner.isEmpty) return;
    final cap = dmLocalMessageRetentionCap;
    final total = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM messages WHERE chatRoomId = ? AND ownerId = ?',
          [chatId, owner],
        )) ??
        0;
    if (total <= cap) return;
    final extra = total - cap;
    final oldRows = await db.rawQuery(
      'SELECT id FROM messages WHERE chatRoomId = ? AND ownerId = ? '
      'ORDER BY createdAt ASC, id ASC LIMIT ?',
      [chatId, owner, extra],
    );
    if (oldRows.isEmpty) return;
    final ids = oldRows.map((e) => e['id'] as String).toList();
    final ph = List.filled(ids.length, '?').join(',');
    await db.delete(
      'message_fragments',
      where: 'messageId IN ($ph)',
      whereArgs: ids,
    );
    await db.delete(
      'messages',
      where: 'id IN ($ph)',
      whereArgs: ids,
    );
  }

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

    final String encryptedContent;
    if (contentAlreadyEncrypted) {
      encryptedContent = msg.content;
    } else if (locator.isRegistered<MessageCryptoFacade>()) {
      final env = await locator<MessageCryptoFacade>()
          .encryptForChat(chatId: chatId, plaintext: msg.content);
      encryptedContent = env.ciphertext;
    } else {
      final chatKey = await encryptionService.getChatKey(chatId);
      encryptedContent = await encryptionService.encrypt(msg.content, chatKey);
    }

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
    if (msg.replyToId != null) row['reply_to_id'] = msg.replyToId;
    if (msg.replyPreview != null) row['reply_preview'] = msg.replyPreview;

    final insertedRowId = await db.insert(
      'messages',
      row,
      conflictAlgorithm:
          idempotentMerge ? ConflictAlgorithm.ignore : ConflictAlgorithm.replace,
    );
    if (idempotentMerge && insertedRowId == 0) {
      return;
    }
    await _bumpChatHistoryMutation(chatId);
    if (chatId.toLowerCase().startsWith('dm_')) {
      unawaited(pruneDmChatBeyondCap(chatId));
    }
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

  /// U+0000–U+001F / U+007F в id ломают строгий JSON на BLE CRDT (см. [CrdtReconciliation] sanitize ключей).
  static String _sanitizeCrdtWireId(String k) {
    if (k.isEmpty) return '_';
    final b = StringBuffer();
    for (final r in k.runes) {
      if (r < 0x20 || r == 0x7f) {
        b.write('_');
      } else {
        b.writeCharCode(r);
      }
    }
    return b.toString();
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
      final rawChat = (r['chatRoomId'] as String?) ?? '';
      final rawAuthor = (r['senderId'] as String?) ?? '';
      if (rawChat.isEmpty || rawAuthor.isEmpty) continue;
      final chatId = _sanitizeCrdtWireId(rawChat);
      final authorId = _sanitizeCrdtWireId(rawAuthor);
      final maxSeq = r['maxSeq'] is int ? r['maxSeq'] as int : int.tryParse(r['maxSeq'].toString()) ?? 0;
      if (chatId.isEmpty || authorId.isEmpty) continue;
      out.putIfAbsent(chatId, () => {})[authorId] = maxSeq;
    }
    return out;
  }

  /// HEADS только для одного чата (основная цепь; без веток fork_of_id).
  Future<Map<String, int>> getHeadsForChat(String chatId) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty || chatId.isEmpty) return {};
    final rows = await db.rawQuery(
      'SELECT senderId, MAX(COALESCE(sequence_number, 0)) AS maxSeq '
      'FROM messages WHERE ownerId = ? AND chatRoomId = ? '
      'AND (fork_of_id IS NULL OR fork_of_id = ?) '
      'GROUP BY senderId',
      [currentUserId, chatId, ''],
    );
    final Map<String, int> out = {};
    for (final r in rows) {
      final authorId = (r['senderId'] as String?) ?? '';
      final maxSeq = r['maxSeq'] is int
          ? r['maxSeq'] as int
          : int.tryParse(r['maxSeq'].toString()) ?? 0;
      if (authorId.isEmpty) continue;
      out[authorId] = maxSeq;
    }
    return out;
  }

  /// Канонический отпечаток heads для UI/сравнения (не криптографический контракт).
  static String fingerprintFromHeads(Map<String, int> heads) {
    if (heads.isEmpty) {
      return '0000000000000000';
    }
    final keys = heads.keys.toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf.write(k);
      buf.write(':');
      buf.write(heads[k] ?? 0);
      buf.write('|');
    }
    final digest = sha256.convert(utf8.encode(buf.toString()));
    return digest.toString().substring(0, 16);
  }

  /// Инкремент «поколения» локальной истории чата (отправка, приём mesh, CRDT merge и т.д.).
  Future<void> _bumpChatHistoryMutation(String chatId) async {
    if (chatId.isEmpty) return;
    final ownerId = await _getCurrentUserId();
    if (ownerId.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert(
      '''
      INSERT INTO chat_history_state(chatRoomId, ownerId, historyGeneration, lastHistoryMutationAt)
      VALUES (?, ?, 1, ?)
      ON CONFLICT(ownerId, chatRoomId) DO UPDATE SET
        historyGeneration = historyGeneration + 1,
        lastHistoryMutationAt = excluded.lastHistoryMutationAt
      ''',
      [chatId, ownerId, now],
    );
  }

  /// Быстрая сводка для UI: поколение, heads fingerprint, время последнего изменения (на этом устройстве).
  Future<ChatHistorySnapshot> getChatHistorySnapshot(String chatId) async {
    final db = await database;
    final ownerId = await _getCurrentUserId();
    if (ownerId.isEmpty || chatId.isEmpty) {
      return ChatHistorySnapshot(
        chatId: chatId,
        historyGeneration: 0,
        lastMutationAtMs: 0,
        authorCount: 0,
        maxSequenceAcrossAuthors: 0,
        headsFingerprint: fingerprintFromHeads({}),
        messageRowCount: 0,
      );
    }
    final heads = await getHeadsForChat(chatId);
    var maxSeq = 0;
    for (final v in heads.values) {
      if (v > maxSeq) maxSeq = v;
    }
    final countRow = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM messages WHERE ownerId = ? AND chatRoomId = ?',
      [ownerId, chatId],
    );
    final messageRowCount = Sqflite.firstIntValue(countRow) ?? 0;

    final st = await db.query(
      'chat_history_state',
      columns: ['historyGeneration', 'lastHistoryMutationAt'],
      where: 'ownerId = ? AND chatRoomId = ?',
      whereArgs: [ownerId, chatId],
      limit: 1,
    );
    var gen = 0;
    var lastAt = 0;
    if (st.isNotEmpty) {
      gen = st.first['historyGeneration'] is int
          ? st.first['historyGeneration'] as int
          : int.tryParse(st.first['historyGeneration'].toString()) ?? 0;
      lastAt = st.first['lastHistoryMutationAt'] is int
          ? st.first['lastHistoryMutationAt'] as int
          : int.tryParse(st.first['lastHistoryMutationAt'].toString()) ?? 0;
    }
    if (lastAt == 0 && messageRowCount > 0) {
      final mx = await db.rawQuery(
        'SELECT MAX(createdAt) AS mx FROM messages WHERE ownerId = ? AND chatRoomId = ?',
        [ownerId, chatId],
      );
      if (mx.isNotEmpty && mx.first['mx'] != null) {
        lastAt = mx.first['mx'] is int
            ? mx.first['mx'] as int
            : int.tryParse(mx.first['mx'].toString()) ?? 0;
      }
    }
    return ChatHistorySnapshot(
      chatId: chatId,
      historyGeneration: gen,
      lastMutationAtMs: lastAt,
      authorCount: heads.length,
      maxSequenceAcrossAuthors: maxSeq,
      headsFingerprint: fingerprintFromHeads(heads),
      messageRowCount: messageRowCount,
    );
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
      final forkId = '${ex['id']}_fork_${safePrefix(incomingHash, 8)}';
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

  static const String _kDecryptPlaceholder = '[Secure message unavailable]';

  /// Собеседник в личке по `chat_rooms` (нужен для расшифровки своих сообщений при разных `dm_*`).
  Future<String?> _dmPeerUserIdForStoredRoom(String roomId, String ownerId) async {
    final db = await database;
    final ids = <String>{normalizeDmChatId(roomId), roomId.trim()};
    for (final id in ids) {
      if (id.isEmpty || !id.toLowerCase().startsWith('dm_')) continue;
      final found = await db.query(
        'chat_rooms',
        columns: ['participants'],
        where: 'id = ? AND ownerId = ?',
        whereArgs: [id, ownerId],
        limit: 1,
      );
      if (found.isEmpty) continue;
      try {
        final pRaw = found.first['participants'];
        final pStr = pRaw is String ? pRaw : (pRaw?.toString() ?? '[]');
        final parts = jsonDecode(pStr) as List<dynamic>? ?? [];
        for (final p in parts) {
          final s = p.toString();
          if (meshStableIdForDm(s) != meshStableIdForDm(ownerId)) {
            return s;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Собеседник в личке `dm_*` (для DR / ротации ключа). Публичная обёртка над [_dmPeerUserIdForStoredRoom].
  Future<String?> getDmPeerUserIdForRoom(String chatId) async {
    final ownerId = await getCurrentUserIdSafe();
    if (ownerId.isEmpty) return null;
    return _dmPeerUserIdForStoredRoom(chatId, ownerId);
  }

  Future<List<String>> _decryptKeyIdsForMessageRow(
    String chatId,
    String currentUserId,
    Map<String, dynamic> m,
  ) async {
    final senderId = m['senderId']?.toString() ?? '';
    if (!chatId.toLowerCase().startsWith('dm_')) return [chatId];
    String? peerWhenFromMe;
    if (senderId == currentUserId) {
      peerWhenFromMe = await _dmPeerUserIdForStoredRoom(chatId, currentUserId);
    }
    return dmDecryptChatIdsForMessage(
      roomChatId: chatId,
      myUserId: currentUserId,
      messageSenderId: senderId,
      dmPeerWhenFromMe: peerWhenFromMe,
    );
  }

  Future<String> _decryptMessageContentWithDmKeyCandidates({
    required String chatId,
    required String currentUserId,
    required Map<String, dynamic> m,
    required EncryptionService encryptionService,
    required bool useFacade,
  }) async {
    final encryptedContent = m['content'] as String? ?? '';
    if (encryptedContent.contains(' ') || encryptedContent.length < 20) {
      return encryptedContent;
    }
    final tryIds = await _decryptKeyIdsForMessageRow(chatId, currentUserId, m);
    var best = _kDecryptPlaceholder;
    for (final cid in tryIds) {
      try {
        final plain = useFacade
            ? await locator<MessageCryptoFacade>().decryptForChat(
                  chatId: cid,
                  ciphertext: encryptedContent,
                )
            : await encryptionService.decrypt(
                  encryptedContent,
                  await encryptionService.getChatKey(cid),
                );
        if (plain != _kDecryptPlaceholder) {
          return plain;
        }
      } catch (_) {
        continue;
      }
    }
    return best;
  }

  /// [limit] if set (>0), loads only last N messages (DESC + reverse) for **any** chat — снижает лаг DM/массовых комнат.
  /// [substituteContent] when true — не расшифровываем content, подменяем нейтральными фразами (режим паники).
  Future<List<ChatMessage>> getMessages(String chatId, {int? limit, bool substituteContent = false}) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    // THE_BEACON_GLOBAL: include legacy GLOBAL rows so one chat shows all (sync fix).
    // BEACON_NEARBY / THE_BEACON_XX: single room, limit last N for performance.
    final bool isGlobalOrBeacon = chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL';
    final String whereClause = isGlobalOrBeacon
        ? "(chatRoomId = 'THE_BEACON_GLOBAL' OR chatRoomId = 'GLOBAL') AND ownerId = ?"
        : 'chatRoomId = ? AND ownerId = ?';
    /// Последние N сообщений для любого чата (раньше limit работал только для beacon — DM тянули всю историю и висели на расшифровке).
    final bool useLimit = limit != null && limit > 0;
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

    final decryptedMessages = <ChatMessage>[];

    if (substituteContent) {
      // Режим паники: не расшифровываем — подменяем нейтральными фразами (Level 2: plaintext не в памяти).
      for (final m in maps) {
        final msgId = m['id'] as String? ?? '';
        final json = {
          ...m,
          'content': neutralPhraseForId(msgId),
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

    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());
    final useFacade = locator.isRegistered<MessageCryptoFacade>();

    Future<ChatMessage> decryptRow(Map<String, dynamic> m) async {
      final decryptedContent = await _decryptMessageContentWithDmKeyCandidates(
        chatId: chatId,
        currentUserId: currentUserId,
        m: m,
        encryptionService: encryptionService,
        useFacade: useFacade,
      );

      final json = {
        ...m,
        'content': decryptedContent,
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
        'receivedAt': m['receivedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['receivedAt'] as int)
                .toIso8601String()
            : null,
        'vectorClock': m['vectorClock'] as String?,
      };
      return ChatMessage.fromJson(json);
    }

    const decryptConcurrency = 24;
    for (var i = 0; i < maps.length; i += decryptConcurrency) {
      final end = math.min(i + decryptConcurrency, maps.length);
      final slice = maps.sublist(i, end);
      final chunk = await Future.wait(slice.map(decryptRow));
      decryptedMessages.addAll(chunk);
    }
    return decryptedMessages;
  }

  /// Те же строки, что [getMessages], без расшифровки: UI показывает плейсхолдер, затем [decryptMessageMaps].
  /// Сейчас используется для `BEACON_NEARBY` (быстрый первый кадр).
  Future<({List<ChatMessage> shells, List<Map<String, dynamic>> rows})>
      getMessagesShellsForDeferredDecrypt(
    String chatId, {
    required int limit,
  }) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) {
      return (shells: <ChatMessage>[], rows: <Map<String, dynamic>>[]);
    }
    final bool isGlobalOrBeacon =
        chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL';
    final String whereClause = isGlobalOrBeacon
        ? "(chatRoomId = 'THE_BEACON_GLOBAL' OR chatRoomId = 'GLOBAL') AND ownerId = ?"
        : 'chatRoomId = ? AND ownerId = ?';
    final List<dynamic> whereArgs = isGlobalOrBeacon
        ? [currentUserId]
        : [chatId, currentUserId];
    final List<Map<String, dynamic>> rows = await db.rawQuery(
      'SELECT * FROM messages WHERE $whereClause '
      'ORDER BY createdAt DESC, senderId DESC, COALESCE(sequence_number, 0) DESC, id DESC LIMIT ?',
      [...whereArgs, limit],
    );
    final maps = rows.reversed.toList();

    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      return (shells: <ChatMessage>[], rows: <Map<String, dynamic>>[]);
    }

    final shells = <ChatMessage>[];
    for (final m in maps) {
      final json = {
        ...m,
        'content': '',
        'contentPendingDecrypt': true,
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
        'receivedAt': m['receivedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['receivedAt'] as int)
                .toIso8601String()
            : null,
        'vectorClock': m['vectorClock'] as String?,
      };
      shells.add(ChatMessage.fromJson(json));
    }
    return (shells: shells, rows: List<Map<String, dynamic>>.from(maps));
  }

  /// Расшифровка сырых строк из [getMessagesShellsForDeferredDecrypt]; тот же путь, что в [getMessages].
  Future<List<ChatMessage>> decryptMessageMaps(
    String chatId,
    List<Map<String, dynamic>> maps,
  ) async {
    if (maps.isEmpty) return [];
    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      return [];
    }
    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());
    final useFacade = locator.isRegistered<MessageCryptoFacade>();
    final uid = await _getCurrentUserId();
    if (uid.isEmpty) return [];

    const decryptConcurrency = 24;
    final out = <ChatMessage>[];
    Future<ChatMessage> decryptRowWithUid(Map<String, dynamic> m) async {
      final decryptedContent = await _decryptMessageContentWithDmKeyCandidates(
        chatId: chatId,
        currentUserId: uid,
        m: m,
        encryptionService: encryptionService,
        useFacade: useFacade,
      );

      final json = {
        ...m,
        'content': decryptedContent,
        'contentPendingDecrypt': false,
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
        'receivedAt': m['receivedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['receivedAt'] as int)
                .toIso8601String()
            : null,
        'vectorClock': m['vectorClock'] as String?,
      };
      return ChatMessage.fromJson(json);
    }

    for (var i = 0; i < maps.length; i += decryptConcurrency) {
      final end = math.min(i + decryptConcurrency, maps.length);
      final slice = maps.sublist(i, end);
      final chunk = await Future.wait(slice.map(decryptRowWithUid));
      out.addAll(chunk);
    }
    return out;
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

  /// Старшие сообщения для пагинации в UI. Тот же порядок сортировки, что и [getMessages].
  ///
  /// [offset] — сколько строк пропустить в порядке `ORDER BY ... DESC` (0 = самые новые).
  /// Возвращает чанк в **хронологическом** порядке (старые → новые внутри чанка), как [getMessages].
  Future<List<ChatMessage>> getMessagesPaged(
    String chatId,
    int limit,
    int offset, {
    bool substituteContent = false,
  }) async {
    final db = await database;
    final currentUserId = await _getCurrentUserId();
    if (currentUserId.isEmpty) return [];
    final bool isGlobalOrBeacon =
        chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL';
    final String whereClause = isGlobalOrBeacon
        ? "(chatRoomId = 'THE_BEACON_GLOBAL' OR chatRoomId = 'GLOBAL') AND ownerId = ?"
        : 'chatRoomId = ? AND ownerId = ?';
    final List<dynamic> whereArgs = isGlobalOrBeacon
        ? [currentUserId]
        : [chatId, currentUserId];
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT * FROM messages WHERE $whereClause '
      'ORDER BY createdAt DESC, senderId DESC, COALESCE(sequence_number, 0) DESC, id DESC '
      'LIMIT ? OFFSET ?',
      [...whereArgs, limit, offset],
    );

    if (!locator.isRegistered<EncryptionService>() &&
        !locator.isRegistered<VaultInterface>()) {
      return [];
    }

    final decryptedMessages = <ChatMessage>[];

    if (substituteContent) {
      for (final m in maps) {
        final msgId = m['id'] as String? ?? '';
        final json = {
          ...m,
          'content': neutralPhraseForId(msgId),
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
      return decryptedMessages.reversed.toList();
    }

    final encryptionService = locator.isRegistered<EncryptionService>()
        ? locator<EncryptionService>()
        : EncryptionService(locator<VaultInterface>());
    final useFacade = locator.isRegistered<MessageCryptoFacade>();

    Future<ChatMessage> decryptRow(Map<String, dynamic> m) async {
      final decryptedContent = await _decryptMessageContentWithDmKeyCandidates(
        chatId: chatId,
        currentUserId: currentUserId,
        m: m,
        encryptionService: encryptionService,
        useFacade: useFacade,
      );

      final json = {
        ...m,
        'content': decryptedContent,
        'createdAt': DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int)
            .toIso8601String(),
        'receivedAt': m['receivedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['receivedAt'] as int)
                .toIso8601String()
            : null,
        'vectorClock': m['vectorClock'] as String?,
      };
      return ChatMessage.fromJson(json);
    }

    const decryptConcurrency = 24;
    for (var i = 0; i < maps.length; i += decryptConcurrency) {
      final end = math.min(i + decryptConcurrency, maps.length);
      final slice = maps.sublist(i, end);
      final chunk = await Future.wait(slice.map(decryptRow));
      decryptedMessages.addAll(chunk);
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

  /// Только чтение: не регистрирует пакет. Нужен ingress до [GossipManager.processEnvelope],
  /// иначе [isPacketSeen] в процессоре «занимает» id и gossip пропускает incubate/relay.
  Future<bool> peekPacketSeen(String packetId) async {
    final db = await database;
    final maps =
        await db.query('seen_pulses', where: 'id=?', whereArgs: [packetId]);
    return maps.isNotEmpty;
  }

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

  /// Перенос лички `dm_*` на канонический id (после [meshStableIdForDm] / выравнивания с mesh).
  Future<void> migrateDmChatRoomId({
    required String fromId,
    required String toId,
  }) async {
    if (fromId.isEmpty || toId.isEmpty || fromId == toId) return;
    final db = await database;
    final ownerId = await _getCurrentUserId();
    await db.transaction((txn) async {
      await txn.update(
        'room_events',
        {'roomId': toId},
        where: 'roomId = ?',
        whereArgs: [fromId],
      );
      await txn.update(
        'messages',
        {'chatRoomId': toId},
        where: 'chatRoomId = ? AND ownerId = ?',
        whereArgs: [fromId, ownerId],
      );
      await txn.update(
        'chat_history_state',
        {'chatRoomId': toId},
        where: 'chatRoomId = ? AND ownerId = ?',
        whereArgs: [fromId, ownerId],
      );
      await txn.update(
        'outbox',
        {'chatRoomId': toId},
        where: 'chatRoomId = ?',
        whereArgs: [fromId],
      );
      await txn.update(
        'chat_rooms',
        {'id': toId},
        where: 'id = ?',
        whereArgs: [fromId],
      );
    });
  }

  /// Канонический `dm_*` для outbox/mesh: по строке комнаты в outbox и участникам из [chat_rooms].
  Future<String> resolveCanonicalDmChatIdForOutboxRow(
      Map<String, dynamic> row) async {
    final raw = (row['chatRoomId'] as String?)?.trim() ?? '';
    if (raw.isEmpty) return '';
    if (!raw.toLowerCase().startsWith('dm_')) return raw;
    final me = await _getCurrentUserId();
    if (me.isEmpty) return normalizeDmChatId(raw);
    final db = await database;
    final found = await db.query(
      'chat_rooms',
      where: 'id = ? AND ownerId = ?',
      whereArgs: [raw, me],
      limit: 1,
    );
    if (found.isEmpty) return normalizeDmChatId(raw);
    List<dynamic> parts;
    try {
      final pRaw = found.first['participants'];
      final pStr = pRaw is String ? pRaw : (pRaw?.toString() ?? '[]');
      parts = jsonDecode(pStr) as List<dynamic>? ?? [];
    } catch (_) {
      return normalizeDmChatId(raw);
    }
    final ps = parts.map((e) => e.toString()).toList();
    String? peer;
    for (final p in ps) {
      if (meshStableIdForDm(p) != meshStableIdForDm(me)) {
        peer = p;
        break;
      }
    }
    if (peer == null || peer.isEmpty) return normalizeDmChatId(raw);
    return canonicalDmForMeshPair(me, peer);
  }

  /// То же для произвольного сохранённого id комнаты (например [sendAuto] до insert в outbox).
  Future<String> resolveCanonicalDmChatIdForStoredRoom(String storedChatRoomId) {
    return resolveCanonicalDmChatIdForOutboxRow(
        {'chatRoomId': storedChatRoomId});
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

  /// [messages.chatRoomId] for the placeholder row created for fragment reassembly (if any).
  Future<String?> getChatRoomIdForMessage(String messageId) async {
    final db = await database;
    final ownerId = await _getCurrentUserId();
    final rows = await db.query(
      'messages',
      columns: ['chatRoomId'],
      where: 'id = ? AND ownerId = ?',
      whereArgs: [messageId, ownerId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['chatRoomId'] as String?;
  }

  /// When a later fragment carries a real [chatId], move placeholder off global/pending bucket.
  Future<void> upgradeFragmentPlaceholderRoom(
      String messageId, String newChatRoomId) async {
    if (newChatRoomId.isEmpty) return;
    final db = await database;
    final ownerId = await _getCurrentUserId();
    await db.update(
      'messages',
      {'chatRoomId': newChatRoomId},
      where:
          'id = ? AND ownerId = ? AND chatRoomId IN (?, ?)',
      whereArgs: [
        messageId,
        ownerId,
        kMeshFragmentPendingChatRoom,
        'THE_BEACON_GLOBAL',
      ],
    );
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
        if (locator.isRegistered<MessageCryptoFacade>()) {
          final env = await locator<MessageCryptoFacade>()
              .encryptForChat(chatId: chatId, plaintext: msg.content);
          contentToStore = env.ciphertext;
        } else {
          final encryptionService = locator.isRegistered<EncryptionService>()
              ? locator<EncryptionService>()
              : EncryptionService(locator.isRegistered<VaultInterface>() ? locator<VaultInterface>() : null);
          final chatKey = await encryptionService.getChatKey(chatId);
          contentToStore = await encryptionService.encrypt(msg.content, chatKey);
        }
      }
    } catch (e) {
      print("[OUTBOX] addToOutbox FAILED (encrypt): $e");
      rethrow;
    }
    final defaultExpiresAt = expiresAt ??
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    final senderIdVal = msg.senderId;
    try {
      const defaultSpray = 6; // [DTN] Spray-and-Wait L (4-8 by density; default 6)
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
            'sprayCount': defaultSpray,
            'copiesRemaining': defaultSpray,
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

  /// [DTN+] Smart outbox scheduling: prioritize by TTL urgency, then smallest payload.
  /// Returns pending sorted: 1) soonest expiresAt first, 2) smallest content first.
  /// Note: db.query returns read-only QueryResultSet — must copy before sort.
  Future<List<Map<String, dynamic>>> getPendingFromOutboxSmart() async {
    final pending = await getPendingFromOutbox();
    final mutable = List<Map<String, dynamic>>.from(pending);
    mutable.sort((a, b) {
      final expA = a['expiresAt'] as int?;
      final expB = b['expiresAt'] as int?;
      // Sooner expiry = more urgent (null = no expiry = least urgent)
      final urgencyA = expA ?? 0x7FFFFFFFFFFFFFFF;
      final urgencyB = expB ?? 0x7FFFFFFFFFFFFFFF;
      if (urgencyA != urgencyB) return urgencyA.compareTo(urgencyB);
      // Same urgency: smallest payload first
      final lenA = (a['content'] as String?)?.length ?? 0;
      final lenB = (b['content'] as String?)?.length ?? 0;
      return lenA.compareTo(lenB);
    });
    return mutable;
  }

  /// Fires [OutboxEmptyEvent] only when relay outbox и очередь DR пусты (intent bit has_outbox).
  Future<void> _tryFireOutboxEmptyEvent(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final afterRows = await db.query(
      'outbox',
      where: 'expiresAt IS NULL OR expiresAt > ?',
      whereArgs: [now],
      limit: 1,
    );
    final drLeft = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM dr_handshake_outbox WHERE "
          "COALESCE(NULLIF(TRIM(delivery_state), ''), "
          "CASE WHEN IFNULL(delivered_confirmed,0)=1 THEN 'acknowledged' "
          "WHEN IFNULL(delivered_to_peer,0)=1 THEN 'sent' ELSE 'pending' END) "
          "!= 'acknowledged'",
        )) ??
        0;
    if (afterRows.isEmpty &&
        drLeft == 0 &&
        locator.isRegistered<EventBusService>()) {
      locator<EventBusService>().fire(OutboxEmptyEvent());
    }
  }

  Future<void> removeFromOutbox(String id) async {
    final db = await database;
    await db.delete('outbox', where: 'id=?', whereArgs: [id]);
    await _tryFireOutboxEmptyEvent(db);
  }

  /// Идемпотентная запись по [packetId] (поле `h` JSON): обновляет попытки и тело, если строка уже есть.
  Future<String> ensureDrHandshakeOutboxRow({
    required String targetUserId,
    required String packetType,
    required String payloadJson,
    String? packetId,
    String? chatId,
    String? peerMacHint,
  }) async {
    final db = await database;
    final pid = (packetId != null && packetId.isNotEmpty)
        ? packetId
        : 'drnopid_${DateTime.now().microsecondsSinceEpoch}';
    var extractedChat = chatId;
    if (extractedChat == null || extractedChat.isEmpty) {
      try {
        final m = jsonDecode(payloadJson) as Map<String, dynamic>;
        extractedChat = m['chatId']?.toString();
      } catch (_) {}
    }
    final existing = await db.query(
      'dr_handshake_outbox',
      where: 'packet_id = ?',
      whereArgs: [pid],
      limit: 1,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing.isNotEmpty) {
      final rowId = existing.first['id'] as String;
      final ac = existing.first['attempt_count'];
      final prevAttempts = ac is int
          ? ac
          : (ac is num
              ? ac.toInt()
              : int.tryParse('$ac') ?? 0);
      // Sqflite: await update completes after the write is visible on this isolate's DB handle.
      await db.update(
        'dr_handshake_outbox',
        {
          'payload_json': payloadJson,
          'target_user_id': targetUserId,
          'packet_type': packetType,
          'peer_mac_hint': peerMacHint,
          'chat_id': extractedChat,
          'attempt_count': prevAttempts + 1,
          'last_attempt_at': now,
          'status': 'PENDING',
          'delivered_to_peer': 0,
          'delivered_confirmed': 0,
          'delivery_state': 'pending',
          'next_retry_at': null,
        },
        where: 'id = ?',
        whereArgs: [rowId],
      );
      _drHandshakeOutboxWriteGeneration++;
      _lastDrHandshakeEnqueueMs = DateTime.now().millisecondsSinceEpoch;
      _recordDrHandshakeEnqueueBarrier(targetUserId);
      if (locator.isRegistered<EventBusService>()) {
        locator<EventBusService>().fire(DrHandshakeOutboxEnqueuedEvent(targetUserId));
      }
      return rowId;
    }
    final before = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM dr_handshake_outbox WHERE "
          "IFNULL(delivered_to_peer, 0) = 0",
        )) ??
        0;
    final id = 'drq_${DateTime.now().microsecondsSinceEpoch}';
    // Sqflite: await insert completes after commit for this connection.
    await db.insert('dr_handshake_outbox', {
      'id': id,
      'packet_type': packetType,
      'target_user_id': targetUserId,
      'payload_json': payloadJson,
      'peer_mac_hint': peerMacHint,
      'created_at': now,
      'packet_id': pid,
      'row_version': 1,
      'status': 'PENDING',
      'attempt_count': 1,
      'last_attempt_at': now,
      'chat_id': extractedChat,
      'delivered_to_peer': 0,
      'delivery_attempts': 0,
      'delivered_confirmed': 0,
      'delivery_state': 'pending',
      'next_retry_at': null,
    });
    _drHandshakeOutboxWriteGeneration++;
    if (before == 0 && locator.isRegistered<EventBusService>()) {
      locator<EventBusService>().fire(OutboxFirstMessageEvent());
    }
    _lastDrHandshakeEnqueueMs = DateTime.now().millisecondsSinceEpoch;
    _recordDrHandshakeEnqueueBarrier(targetUserId);
    if (locator.isRegistered<EventBusService>()) {
      locator<EventBusService>().fire(DrHandshakeOutboxEnqueuedEvent(targetUserId));
    }
    return id;
  }

  /// Очередь DR_DH_* / DR_HS_DONE для GATT notify после OUTBOX_REQUEST.
  Future<void> enqueueDrHandshakeOutbox({
    required String targetUserId,
    required String packetType,
    required String payloadJson,
    String? peerMacHint,
  }) async {
    String? pid;
    String? cid;
    try {
      final m = jsonDecode(payloadJson) as Map<String, dynamic>;
      pid = m['h']?.toString();
      cid = m['chatId']?.toString();
    } catch (_) {}
    await ensureDrHandshakeOutboxRow(
      targetUserId: targetUserId,
      packetType: packetType,
      payloadJson: payloadJson,
      packetId: pid,
      chatId: cid,
      peerMacHint: peerMacHint,
    );
  }

  /// Охрана от повторной записи при TCP+fallback OUTBOX на одном и том же пакетном типе.
  Future<bool> hasDrHandshakeOutboxForTargetAndType({
    required String targetUserId,
    required String packetType,
  }) async {
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      where: 'target_user_id = ? AND packet_type = ?',
      whereArgs: [targetUserId, packetType],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> getPendingDrHandshakeOutboxRows({
    String? forTargetUserId,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final tid = forTargetUserId?.trim();
    final tidClause = (tid != null && tid.isNotEmpty)
        ? ' AND target_user_id = ?'
        : '';
    final args = (tid != null && tid.isNotEmpty) ? <Object>[now, tid] : <Object>[now];
    // pending | sent (not yet delivery-ACKed): include GATT re-notify after next_retry_at.
    return db.rawQuery(
      '''
      SELECT * FROM dr_handshake_outbox
      WHERE COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') IN ('pending', 'sent')
        AND (
          COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') = 'pending'
          OR (
            COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') = 'sent'
            AND (next_retry_at IS NULL OR next_retry_at <= ?)
          )
        )
        $tidClause
      ORDER BY created_at ASC
      ''',
      args,
    );
  }

  /// Soft retry: OUTBOX handler vs SQLite commit / WAL visibility.
  Future<List<Map<String, dynamic>>> getPendingDrHandshakeOutboxRowsWithRetry({
    String? forTargetUserId,
  }) async {
    List<Map<String, dynamic>> rows = [];
    for (var i = 0; i < 3; i++) {
      rows = await getPendingDrHandshakeOutboxRows(forTargetUserId: forTargetUserId);
      if (rows.isNotEmpty) {
        break;
      }
      if (i < 2) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    return rows;
  }

  /// Gates central [pullOutboxFromPeer] reconnect when the session returned 0 useful notifies.
  Future<bool> shouldRetryCentralOutboxPullAfterEmptyResult() async {
    if (await hasPendingDrHandshakeOutbox()) return true;
    if (await hasPendingPeerBleSyncHint()) return true;
    final db = await database;
    final fr = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM friends WHERE "
          "IFNULL(NULLIF(TRIM(status), ''), '') IN ('pending', 'pending_outgoing')",
        )) ??
        0;
    if (fr > 0) return true;
    final dr = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM dr_handshake_session WHERE state IN ("
          "'INIT_SENT', 'ACK_SENT', 'OUTSTANDING', 'HS_DONE_QUEUED')",
        )) ??
        0;
    return dr > 0;
  }

  Future<void> markDrHandshakeOutboxNotifyOk(String id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRetry = now + 3500;
    final rows = await db.query(
      'dr_handshake_outbox',
      columns: ['packet_id', 'packet_type', 'delivered_to_peer'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.update(
      'dr_handshake_outbox',
      {
        'status': 'NOTIFY_OK',
        'delivered_to_peer': 1,
        'last_attempt_at': now,
        'last_delivery_attempt': now,
        'delivery_state': 'sent',
        'next_retry_at': nextRetry,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isNotEmpty) {
      final pid = rows.first['packet_id']?.toString() ?? '';
      final pt = rows.first['packet_type']?.toString() ?? '';
      final dtp = int.tryParse('${rows.first['delivered_to_peer']}') ?? 0;
      print(
        "[DELIVERY] packetId=$pid type=$pt delivered_to_peer=1 (was $dtp) delivered_confirmed=unchanged",
      );
    }
  }

  /// GATT notify succeeded — does not imply peer processed (see [delivered_confirmed]).
  /// Call [markDrHandshakeOutboxDeliveredConfirmed] when peer-side confirmation exists.
  Future<void> markDrHandshakeOutboxDeliveredConfirmed(String id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'dr_handshake_outbox',
      {
        'delivered_confirmed': 1,
        'last_attempt_at': now,
        'delivery_state': 'acknowledged',
        'next_retry_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// TCP/gossip handoff succeeded — **not** GATT notify to peer.
  ///
  /// Must **not** use the same [delivery_state]/[next_retry_at] pair as [markDrHandshakeOutboxNotifyOk]:
  /// `sent` + `next_retry_at` in the future **excludes** the row from [getPendingDrHandshakeOutboxRows],
  /// so OUTBOX_REQUEST would see **0 rows** until the retry window elapses — even though Samsung never
  /// received a BLE notify. Gossip does not delete rows; this marker was the desync.
  Future<void> markDrHandshakeOutboxWireSentByPacketId(String packetId) async {
    final p = packetId.trim();
    if (p.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'dr_handshake_outbox',
      {
        'delivered_to_peer': 0,
        'status': 'GOSSIP_WIRE',
        'last_attempt_at': now,
        'last_delivery_attempt': now,
        'delivered_confirmed': 0,
        'delivery_state': 'pending',
        'next_retry_at': null,
      },
      where: 'packet_id = ?',
      whereArgs: [p],
    );
    print(
      "[DELIVERY] packetId=$p gossip_wire_ok delivery_state=pending (GATT path still eligible) "
      "delivered_to_peer=0",
    );
  }

  /// Diagnostics: distinguish empty table vs rows excluded by pending WHERE (Case A vs B).
  Future<String> drHandshakeOutboxDebugSummaryLine() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final total = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM dr_handshake_outbox'),
        ) ??
        0;
    final pendingRows = Sqflite.firstIntValue(
          await db.rawQuery(
            '''
      SELECT COUNT(*) FROM dr_handshake_outbox
      WHERE COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') IN ('pending', 'sent')
        AND (
          COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') = 'pending'
          OR (
            COALESCE(NULLIF(TRIM(delivery_state), ''), 'pending') = 'sent'
            AND (next_retry_at IS NULL OR next_retry_at <= ?)
          )
        )
      ''',
            [now],
          ),
        ) ??
        0;
    final confirmedRows = Sqflite.firstIntValue(
          await db.rawQuery(
            '''
      SELECT COUNT(*) FROM dr_handshake_outbox
      WHERE COALESCE(NULLIF(TRIM(delivery_state), ''), '') = 'acknowledged'
         OR IFNULL(delivered_confirmed, 0) = 1
      ''',
          ),
        ) ??
        0;
    final sentRows = Sqflite.firstIntValue(
          await db.rawQuery(
            '''
      SELECT COUNT(*) FROM dr_handshake_outbox
      WHERE COALESCE(NULLIF(TRIM(delivery_state), ''), '') = 'sent'
        AND (next_retry_at IS NOT NULL AND next_retry_at > ?)
      ''',
            [now],
          ),
        ) ??
        0;
    return '[OUTBOX][DEBUG] totalRows=$total pendingRows=$pendingRows '
        'sentRows=$sentRows confirmedRows=$confirmedRows';
  }

  Future<void> markDrHandshakeOutboxDeliveredConfirmedByPacketId(
      String packetId) async {
    final p = packetId.trim();
    if (p.isEmpty) return;
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      columns: ['id'],
      where: 'packet_id = ?',
      whereArgs: [p],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final id = rows.first['id'] as String?;
    if (id == null || id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'dr_handshake_outbox',
      {
        'delivered_confirmed': 1,
        'delivered_to_peer': 1,
        'status': 'NOTIFY_OK',
        'last_attempt_at': now,
        'last_delivery_attempt': now,
        'delivery_state': 'acknowledged',
        'next_retry_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    print(
      "[DELIVERY] packetId=$p delivered_confirmed=1 delivered_to_peer=1 (direct/TCP confirm)",
    );
  }

  /// Same as [markDrHandshakeOutboxNotifyOk] but keyed by [packet_id] (`h` in JSON).
  Future<void> markDrHandshakeOutboxNotifyOkByPacketId(String packetId) async {
    final p = packetId.trim();
    if (p.isEmpty) return;
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      columns: ['id'],
      where: 'packet_id = ?',
      whereArgs: [p],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final id = rows.first['id'] as String?;
    if (id == null || id.isEmpty) return;
    await markDrHandshakeOutboxNotifyOk(id);
  }

  /// Best-effort store on third nodes for gossip re-emission toward [target_user_id].
  Future<void> insertMeshTransitIfAbsent({
    required String id,
    required String kind,
    required String targetUserId,
    required String payloadJson,
    int ttl = 16,
  }) async {
    final tid = targetUserId.trim();
    if (tid.isEmpty || id.trim().isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await db.insert(
        'mesh_transit_store',
        {
          'id': id.trim(),
          'kind': kind,
          'target_user_id': tid,
          'payload_json': payloadJson,
          'ttl': ttl,
          'created_at': now,
          'last_relay_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> getMeshTransitRowsForRelay({
    int limit = 8,
    int minIntervalMs = 22000,
  }) async {
    final db = await database;
    final threshold = DateTime.now().millisecondsSinceEpoch - minIntervalMs;
    return db.rawQuery(
      'SELECT * FROM mesh_transit_store WHERE '
      '(last_relay_at IS NULL OR last_relay_at < ?) '
      'ORDER BY created_at ASC LIMIT ?',
      [threshold, limit],
    );
  }

  Future<void> touchMeshTransitRelay(String id) async {
    final rid = id.trim();
    if (rid.isEmpty) return;
    final db = await database;
    await db.update(
      'mesh_transit_store',
      {'last_relay_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [rid],
    );
  }

  /// Increment before each GATT notify attempt for a row (reliability telemetry).
  Future<void> incrementDrHandshakeDeliveryAttempts(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE dr_handshake_outbox SET delivery_attempts = IFNULL(delivery_attempts, 0) + 1 WHERE id = ?',
      [id],
    );
  }

  /// Whether [packet_id] has been successfully delivered to the peer (GATT or TCP marked).
  /// Lookup for CONTROL_PLANE_ACK matching outgoing [FRIEND_RESPONSE] (`fr_<peerId>`).
  Future<List<Map<String, dynamic>>> getDrHandshakeOutboxRowsByPacketIdAndType({
    required String packetId,
    required String packetType,
  }) async {
    final p = packetId.trim();
    final t = packetType.trim();
    if (p.isEmpty || t.isEmpty) return [];
    final db = await database;
    return db.query(
      'dr_handshake_outbox',
      where: 'packet_id = ? AND packet_type = ?',
      whereArgs: [p, t],
      limit: 1,
    );
  }

  /// `true` when control-plane delivery is settled (ACK or row removed), for gossip backoff.
  Future<bool> isDrHandshakePacketDeliveredByPacketId(String packetId) async {
    final p = packetId.trim();
    if (p.isEmpty) return false;
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      columns: ['delivery_state', 'delivered_confirmed'],
      where: 'packet_id = ?',
      whereArgs: [p],
      limit: 1,
    );
    if (rows.isEmpty) return true;
    final ds = rows.first['delivery_state']?.toString().trim() ?? '';
    if (ds == 'acknowledged') return true;
    return int.tryParse('${rows.first['delivered_confirmed']}') == 1;
  }

  /// Longer BLE listen when friend pending or undelivered DR/FRIEND control rows exist.
  Future<bool> shouldUseExtendedCentralPullListenWindow() async {
    if (await hasPendingDrHandshakeOutbox()) return true;
    if (await hasPendingPeerBleSyncHint()) return true;
    final db = await database;
    final fr = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM friends WHERE "
          "IFNULL(NULLIF(TRIM(status), ''), '') IN ('pending', 'pending_outgoing')",
        )) ??
        0;
    return fr > 0;
  }

  Future<void> removeDrHandshakeOutboxInitRowsForChat({
    required String chatId,
    required String targetPeerUserId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      where: 'packet_type = ? AND target_user_id = ?',
      whereArgs: ['DR_DH_INIT', targetPeerUserId],
    );
    for (final r in rows) {
      try {
        final raw = r['payload_json'] as String? ?? '';
        final m = jsonDecode(raw) as Map<String, dynamic>;
        if (m['chatId']?.toString() == chatId) {
          final rid = r['id'] as String? ?? '';
          if (rid.isEmpty) continue;
          await db.delete('dr_handshake_outbox',
              where: 'id = ?', whereArgs: [rid]);
        }
      } catch (_) {}
    }
    await _tryFireOutboxEmptyEvent(db);
  }

  Future<void> removeDrHandshakeOutboxAckRowsForChat({
    required String chatId,
    required String targetInitiatorUserId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      where: 'packet_type = ? AND target_user_id = ?',
      whereArgs: ['DR_DH_ACK', targetInitiatorUserId],
    );
    for (final r in rows) {
      try {
        final raw = r['payload_json'] as String? ?? '';
        final m = jsonDecode(raw) as Map<String, dynamic>;
        if (m['chatId']?.toString() == chatId) {
          final rid = r['id'] as String? ?? '';
          if (rid.isEmpty) continue;
          await db.delete('dr_handshake_outbox',
              where: 'id = ?', whereArgs: [rid]);
        }
      } catch (_) {}
    }
    await _tryFireOutboxEmptyEvent(db);
  }

  Future<void> upsertDrHandshakeSession({
    required String chatId,
    required String peerUserId,
    required String state,
    int handshakeVersion = 1,
    int ackReceived = 0,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'dr_handshake_session',
      {
        'chat_id': chatId,
        'peer_user_id': peerUserId,
        'state': state,
        'handshake_version': handshakeVersion,
        'ack_received': ackReceived,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Только UI: состояние вспомогательной таблицы [dr_handshake_session] по парам (не замена крипто-проверки).
  /// При нескольких [chat_id] на пару предпочитает [state] == `COMPLETE`.
  Future<Map<String, String?>> getDrHandshakeSessionStatesForPeers(
    String ownerUserId,
    List<String> peerIds,
  ) async {
    final owner = ownerUserId.trim();
    final peers = peerIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final result = <String, String?>{for (final p in peers) p: null};
    if (owner.isEmpty || peers.isEmpty) return result;

    final allChatIds = <String>[];
    final seen = <String>{};
    for (final peer in peers) {
      for (final cid in dmAllPairKeyChatIds(owner, peer)) {
        final n = normalizeDmChatId(cid);
        if (seen.add(n)) allChatIds.add(n);
      }
    }
    if (allChatIds.isEmpty) return result;

    final db = await database;
    final ph = List.filled(allChatIds.length, '?').join(',');
    final rows = await db.query(
      'dr_handshake_session',
      columns: ['chat_id', 'state'],
      where: 'chat_id IN ($ph)',
      whereArgs: allChatIds,
    );
    final byChat = <String, String>{};
    for (final r in rows) {
      final raw = r['chat_id']?.toString() ?? '';
      if (raw.isEmpty) continue;
      final key = normalizeDmChatId(raw);
      final st = r['state']?.toString() ?? '';
      if (st.isEmpty) continue;
      final prev = byChat[key];
      if (prev == 'COMPLETE') continue;
      if (st == 'COMPLETE') {
        byChat[key] = st;
      } else if (prev == null) {
        byChat[key] = st;
      }
    }

    for (final peer in peers) {
      String? best;
      for (final cid in dmAllPairKeyChatIds(owner, peer)) {
        final st = byChat[normalizeDmChatId(cid)];
        if (st == null) continue;
        if (st == 'COMPLETE') {
          best = 'COMPLETE';
          break;
        }
        best ??= st;
      }
      result[peer] = best;
    }
    return result;
  }

  /// Remove by logical [packet_id] (e.g. `fr_<userId>` or DR `h`) after [markDrHandshakeOutboxNotifyOk].
  Future<void> removeDrHandshakeOutboxRowByPacketId(String packetId) async {
    final p = packetId.trim();
    if (p.isEmpty) return;
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      columns: ['id'],
      where: 'packet_id = ?',
      whereArgs: [p],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final id = rows.first['id'] as String?;
    if (id == null || id.isEmpty) return;
    await removeDrHandshakeOutboxRow(id);
  }

  Future<void> removeDrHandshakeOutboxRow(String id) async {
    final db = await database;
    final rows = await db.query(
      'dr_handshake_outbox',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final r = rows.first;
    final pt = r['packet_type']?.toString() ?? '';
    if (pt != 'DR_HS_DONE' &&
        pt != 'FRIEND_RESPONSE' &&
        pt != 'DR_DH_ACK') {
      print(
        "⚠️ [DB] removeDrHandshakeOutboxRow skipped: non-terminal packet_type=$pt id=$id",
      );
      return;
    }
    final ds = r['delivery_state']?.toString().trim() ?? '';
    final acked = ds == 'acknowledged' ||
        int.tryParse('${r['delivered_confirmed']}') == 1;
    if (!acked) {
      print(
        "⚠️ [DB] removeDrHandshakeOutboxRow skipped: not acknowledged id=$id type=$pt",
      );
      return;
    }
    await db.delete('dr_handshake_outbox', where: 'id = ?', whereArgs: [id]);
    await _tryFireOutboxEmptyEvent(db);
  }

  /// Central marked peer after empty useful notify — retry pull on next opportunity.
  Future<bool> hasPendingPeerBleSyncHint() async {
    final db = await database;
    final n = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM ble_peer_sync_hint'),
    );
    return (n ?? 0) > 0;
  }

  Future<void> markPeerBleNeedsDrSync(String mac) async {
    final m = mac.trim().toUpperCase();
    if (m.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'ble_peer_sync_hint',
      {'mac': m, 'created_at': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearPeerBleNeedsDrSync(String mac) async {
    final m = mac.trim().toUpperCase();
    if (m.isEmpty) return;
    final db = await database;
    await db.delete('ble_peer_sync_hint', where: 'mac = ?', whereArgs: [m]);
  }

  Future<List<String>> getPeerBleSyncHintMacs() async {
    final db = await database;
    final rows = await db.query('ble_peer_sync_hint', columns: ['mac']);
    return rows
        .map((r) => r['mac']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// BLE route UUIDs stored for friends (survives MAC rotation vs strict mesh key derivation).
  Future<Map<String, Set<String>>> bleRouteUuidKeysForTargetUserIds(
      Set<String> userIds) async {
    final ids = userIds.where((e) => e.trim().isNotEmpty).toList();
    if (ids.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, ble_route_device_uuid FROM friends WHERE id IN ($placeholders)',
      ids,
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      final id = r['id']?.toString() ?? '';
      final raw =
          r['ble_route_device_uuid']?.toString().trim().toLowerCase() ?? '';
      if (id.isEmpty) continue;
      out.putIfAbsent(id, () => <String>{});
      if (raw.length == 16 && RegExp(r'^[0-9a-f]{16}$').hasMatch(raw)) {
        out[id]!.add(raw);
      }
    }
    return out;
  }

  Future<bool> hasPendingDrHandshakeOutbox() async {
    final db = await database;
    final n = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM dr_handshake_outbox WHERE '
        "COALESCE(NULLIF(TRIM(delivery_state), ''), "
        "CASE WHEN IFNULL(delivered_confirmed,0)=1 THEN 'acknowledged' "
        "WHEN IFNULL(delivered_to_peer,0)=1 THEN 'sent' ELSE 'pending' END) "
        "!= 'acknowledged'"));
    return (n ?? 0) > 0;
  }

  /// [DTN Spray-and-Wait] Обновляет sprayCount/copiesRemaining после отправки.
  Future<void> updateOutboxSprayState(
      String messageId, int? sprayCount, int? copiesRemaining) async {
    final db = await database;
    final updates = <String, dynamic>{};
    if (sprayCount != null) updates['sprayCount'] = sprayCount;
    if (copiesRemaining != null) updates['copiesRemaining'] = copiesRemaining;
    if (updates.isEmpty) return;
    await db.update('outbox', updates, where: 'id = ?', whereArgs: [messageId]);
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
      for (var t in tables) {
        await txn.delete(t);
      }
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
    /// 16 hex из BLE GH (manufacturerData); надёжнее wire senderId при GATT self-echo.
    String? bleRouteDeviceUuid,
  }) async {
    final db = await database;
    final existing = await getFriend(friendId);
    final prevBle =
        existing?['ble_route_device_uuid']?.toString().trim() ?? '';
    final incomingBle = bleRouteDeviceUuid?.trim() ?? '';
    final resolvedBle = incomingBle.isNotEmpty
        ? incomingBle.toLowerCase()
        : (prevBle.isNotEmpty ? prevBle.toLowerCase() : '');
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
        if (resolvedBle.isNotEmpty) 'ble_route_device_uuid': resolvedBle,
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

  /// Имя из [FRIEND_RESPONSE] / профиля — не затирает статус и метки времени.
  Future<void> updateFriendUsername(String friendId, String username) async {
    final u = username.trim();
    if (u.isEmpty) return;
    final db = await database;
    await db.update(
      'friends',
      {'username': u},
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

  /// Удаляет друга и **все** локальные следы лички с ним: сообщения, outbox, комнаты, DR session,
  /// очередь DR handshake, TOFU/bundle в SharedPreferences — чтобы повторное добавление
  /// начиналось с чистого состояния (актуально после смены crypto/wire).
  ///
  /// [ownerUserId] — текущий пользователь ([ApiService.currentUserId] / vault id).
  Future<void> removeFriendCompletely(
    String friendId, {
    required String ownerUserId,
  }) async {
    final peer = friendId.trim();
    if (peer.isEmpty) return;
    final owner = ownerUserId.trim();
    final db = await database;

    if (owner.isEmpty) {
      await removeFriend(peer);
      await _clearFriendCryptoPrefsOnly(peer);
      return;
    }

    final dmIds = dmAllPairKeyChatIds(owner, peer).toList();
    if (dmIds.isEmpty) {
      await db.delete('friends', where: 'id = ?', whereArgs: [peer]);
      await _clearFriendCryptoPrefsOnly(peer);
      return;
    }

    final inList = List.filled(dmIds.length, '?').join(',');
    final peerVariants = <String>{peer, meshStableIdForDm(peer)}..removeWhere((e) => e.isEmpty);
    final pIn = List.filled(peerVariants.length, '?').join(',');

    await db.transaction((txn) async {
      await txn.delete(
        'messages',
        where: 'ownerId = ? AND chatRoomId IN ($inList)',
        whereArgs: [owner, ...dmIds],
      );
      await txn.delete(
        'chat_history_state',
        where: 'ownerId = ? AND chatRoomId IN ($inList)',
        whereArgs: [owner, ...dmIds],
      );
      await txn.delete(
        'outbox',
        where: 'chatRoomId IN ($inList)',
        whereArgs: dmIds,
      );
      for (final id in dmIds) {
        await txn.delete('double_ratchet_sessions', where: 'chat_id = ?', whereArgs: [id]);
      }
      await txn.delete(
        'dr_handshake_session',
        where: 'chat_id IN ($inList) OR peer_user_id IN ($pIn)',
        whereArgs: [...dmIds, ...peerVariants],
      );
      await txn.delete(
        'dr_handshake_outbox',
        where:
            'target_user_id IN ($pIn) OR IFNULL(chat_id, \'\') IN ($inList)',
        whereArgs: [...peerVariants, ...dmIds],
      );
      for (final id in dmIds) {
        await txn.delete('chat_rooms', where: 'id = ?', whereArgs: [id]);
      }
      await txn.delete('friends', where: 'id = ?', whereArgs: [peer]);
    });

    for (final id in dmIds) {
      await DoubleRatchetUserPrefs.clearWirePrefForChat(id);
    }
    await _clearFriendCryptoPrefsOnly(peer);
    await _tryFireOutboxEmptyEvent(db);
  }

  Future<void> _clearFriendCryptoPrefsOnly(String peer) async {
    final p = peer.trim();
    if (p.isEmpty) return;
    await DrDhPeerPins.clearPin(p);
    await DrDhPeerPins.clearPin(meshStableIdForDm(p));
    await DrPeerBundlePreKeyCache.clearForPeer(p);
    await DrPeerBundlePreKeyCache.clearForPeer(meshStableIdForDm(p));
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
