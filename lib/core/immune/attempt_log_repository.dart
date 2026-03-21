// lib/core/immune/attempt_log_repository.dart
//
// Репозиторий для дневника попыток подключения.
// Использует LocalDatabaseService. Ограничивает размер таблицы.

import 'package:sqflite/sqflite.dart';

import '../locator.dart';
import '../local_db_service.dart';
import 'attempt_log.dart';
import 'immune_constants.dart';

class AttemptLogRepository {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  /// Сохранить запись. При переполнении вытесняются старые.
  Future<void> insert(AttemptLog log) async {
    final database = await _db.database;
    await database.insert(
      'attempt_logs',
      {
        'id': log.id,
        'donor_sni': log.donorSni,
        'mode': log.modeString,
        'padding_config': log.paddingConfig,
        'timestamp': log.timestamp.millisecondsSinceEpoch,
        'operator_code': log.operatorCode,
        'region': log.region,
        'result': log.resultString,
        'failure_reason': log.failureReason,
        'bytes_transferred': log.bytesTransferred,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _evictIfOverLimit(database);
  }

  /// Получить последние [limit] записей, отсортированных по timestamp DESC.
  Future<List<AttemptLog>> getRecent({int limit = 100}) async {
    final database = await _db.database;
    final rows = await database.query(
      'attempt_logs',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map((r) => _rowToLog(r)).toList();
  }

  /// Получить записи по donor и режиму (для анализа).
  Future<List<AttemptLog>> getByDonorAndMode(
    String donorSni,
    String mode, {
    int limit = 50,
  }) async {
    final database = await _db.database;
    final rows = await database.query(
      'attempt_logs',
      where: 'donor_sni = ? AND mode = ?',
      whereArgs: [donorSni, mode],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map((r) => _rowToLog(r)).toList();
  }

  /// Количество записей.
  Future<int> getCount() async {
    final database = await _db.database;
    final r = await database.rawQuery('SELECT COUNT(*) as c FROM attempt_logs');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  static AttemptLog _rowToLog(Map<String, dynamic> r) {
    return AttemptLog(
      id: r['id'] as String? ?? '',
      donorSni: r['donor_sni'] as String? ?? '',
      mode: AttemptLog.modeFromString(r['mode'] as String?),
      paddingConfig: r['padding_config'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          (r['timestamp'] as int?) ?? 0),
      operatorCode: r['operator_code'] as String?,
      region: r['region'] as String?,
      result: AttemptLog.resultFromString(r['result'] as String?),
      failureReason: r['failure_reason'] as String?,
      bytesTransferred: (r['bytes_transferred'] as num?)?.toInt(),
    );
  }

  Future<void> _evictIfOverLimit(Database db) async {
    final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM attempt_logs')) ??
        0;
    if (count <= kAttemptLogMaxEntries) return;

    final toRemove = count - kAttemptLogMaxEntries;
    final rows = await db.query(
      'attempt_logs',
      columns: ['id'],
      orderBy: 'timestamp ASC',
      limit: toRemove,
    );
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id != null) await db.delete('attempt_logs', where: 'id = ?', whereArgs: [id]);
    }
  }
}
