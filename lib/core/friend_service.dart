import 'package:sqflite/sqflite.dart';

import 'local_db_service.dart';

class FriendService {
  LocalDatabaseService get db => LocalDatabaseService();

  // Установка тактической связи (Handshake)
  Future<void> establishTrust({
    required String userId,
    required String username,
    String? publicKey,
  }) async {
    final database = await db.database;

    await database.insert('friends', {
      'id': userId,
      'username': username,
      'publicKey': publicKey,
      'isVerified': publicKey != null ? 1 : 0,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    print("🛡️ Trust established with $username (#${userId.substring(0,4)})");
  }

  Future<List<Map<String, dynamic>>> getTrustedFriends() async {
    final database = await db.database;
    return await database.query('friends', orderBy: 'lastSeen DESC');
  }
}