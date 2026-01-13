import 'package:sqflite/sqflite.dart';

import '../../core/local_db_service.dart';

class FriendService {
  final db = LocalDatabaseService();

  Future<void> establishTrust({
    required String userId,
    required String username,
    String? publicKey
  }) async {
    final database = await db.database;

    // Сохраняем в тактическую таблицу друзей
    await database.insert('friends', {
      'id': userId,
      'username': username,
      'publicKey': publicKey,
      'isVerified': publicKey != null ? 1 : 0,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    _log("🛡️ Link established with Nomad $username");
  }

  void _log(String msg) {
    print("[FriendService] $msg");
  }
}