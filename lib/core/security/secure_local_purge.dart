import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../decoy/app_mode.dart';
import '../decoy/mode_scoped_vault.dart';
import '../decoy/storage_paths.dart';
import '../encryption_service.dart';
import '../local_db_service.dart';
import '../locator.dart';
import '../mesh_core_engine.dart';
import '../message_signing_service.dart';
import '../panic/panic_storage_keys.dart';
import '../storage_service.dart';

/// Полное стирание **только профиля REAL**: Vault REAL, файлы БД в каталоге `real/`,
/// флаги паники и прочие глобальные секреты приложения. **DECOY не затрагивается.**
///
/// Вызывать перед [GetIt.reset]; после — зарегистрировать CORE заново при следующем входе.
class SecureLocalPurge {
  SecureLocalPurge._();

  static const FlutterSecureStorage _panicStorage = FlutterSecureStorage();

  static const FlutterSecureStorage _encryptedPrefsStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Ключи в «глобальном» secure storage (не namespace ModeScopedVault).
  static const List<String> _globalSecureKeysToRemove = [
    kPanicProtocolActivatedStorageKey,
    'user_encryption_salt', // fallback EncryptionService без vault
  ];

  static const List<String> _messageSigningKeys = [
    'ed25519_private_key',
    'ed25519_public_key',
  ];

  /// Закрыть сессию mesh (по возможности), стереть REAL-данные на диске и в Vault REAL.
  static Future<void> execute() async {
    if (locator.isRegistered<MeshCoreEngine>()) {
      try {
        locator<MeshCoreEngine>().dispose();
      } catch (_) {}
    }

    if (locator.isRegistered<LocalDatabaseService>()) {
      final ldb = locator<LocalDatabaseService>();
      if (ldb.isRealDatabaseProfile) {
        await ldb.closeAndCheckpoint();
      }
    }

    await _deleteRealDatabaseFiles();

    final realVault = ModeScopedVault(AppMode.REAL);
    await realVault.deleteAll();

    for (final key in _globalSecureKeysToRemove) {
      try {
        await _panicStorage.delete(key: key);
      } catch (_) {}
      try {
        await _encryptedPrefsStorage.delete(key: key);
      } catch (_) {}
    }

    for (final key in _messageSigningKeys) {
      try {
        await StorageService.storage.delete(key: key);
      } catch (_) {}
    }
    try {
      MessageSigningService().wipeMemoryAfterPurge();
    } catch (_) {}

    await GhostBackup.clearAll();

    if (locator.isRegistered<EncryptionService>()) {
      try {
        locator<EncryptionService>().clearCachedSecrets();
      } catch (_) {}
    }
    // `locator.reset` и повторная регистрация — в `DiRestartScopeState.rebindAfterPurge`.
  }

  static Future<void> _deleteRealDatabaseFiles() async {
    final dbRoot = await getDatabasesPath();
    final suffix = dbDirectorySuffixForMode(AppMode.REAL);
    final dir = Directory(p.join(dbRoot, suffix));
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.db') ||
          name.endsWith('.db-wal') ||
          name.endsWith('.db-shm')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
