// lib/core/decoy/mode_exit_service.dart
//
// Iteration 4: Single point of control for Mode Exit. No other component may
// perform exit logic. Guarantees full teardown and process exit.
//
// MANDATORY TEARDOWN ORDER (documented and enforced here only):
//  1. Block new operations
//  2. Stop background runners (RoutineRunner) and foreground task (BackgroundService)
//  3. Flush and close SQLite; checkpoint WAL
//  4. Dispose repositories and caches (MeshService, GossipManager, etc.)
//  5. Wipe in-memory crypto material (EncryptionService)
//  6. Caller must have already wiped Vault (logout) — we do not touch vault here
//  7. Dispose DI container (locator.reset())
//  8. Process exit (exit(0))
//
// Restart strategy: Option A — controlled process exit. OS relaunches on next
// open; cleanest forensic boundary; no state carry-over.

import 'dart:io';

import '../background_service.dart';
import '../discovery_context_service.dart';
import '../encryption_service.dart';
import '../gossip_manager.dart';
import '../local_db_service.dart';
import '../locator.dart';
import '../mesh_service.dart';
import '../peer_cache_service.dart';
import 'routine_runner.dart';

class ModeExitService {
  ModeExitService._();

  static bool _exiting = false;

  /// True while exit is in progress. Other components may check to block new work.
  static bool get isExiting => _exiting;

  /// Performs full mode exit: teardown in mandatory order, then process exit.
  /// Call only after caller has wiped current-mode vault (e.g. ApiService.logout()).
  /// Idempotent: safe to call multiple times; exits once.
  static Future<void> performExit() async {
    if (_exiting) return;
    _exiting = true;

    try {
      // 1. Block new operations (flag set above; callers may check isExiting)

      // 2. Stop background runners and foreground task
      if (locator.isRegistered<RoutineRunner>()) {
        try {
          locator<RoutineRunner>().stop();
        } catch (_) {}
      }
      try {
        await BackgroundService.stop();
      } catch (_) {}

      // 3. Flush and close SQLite; checkpoint WAL
      if (locator.isRegistered<LocalDatabaseService>()) {
        try {
          await locator<LocalDatabaseService>().closeAndCheckpoint();
        } catch (_) {}
      }

      // 4. Dispose repositories and caches
      if (locator.isRegistered<MeshService>()) {
        try {
          locator<MeshService>().dispose();
        } catch (_) {}
      }
      if (locator.isRegistered<GossipManager>()) {
        try {
          locator<GossipManager>().dispose();
        } catch (_) {}
      }
      if (locator.isRegistered<DiscoveryContextService>()) {
        try {
          locator<DiscoveryContextService>().dispose();
        } catch (_) {}
      }
      if (locator.isRegistered<PeerCacheService>()) {
        try {
          locator<PeerCacheService>().dispose();
        } catch (_) {}
      }

      // 5. Wipe in-memory crypto material
      if (locator.isRegistered<EncryptionService>()) {
        try {
          locator<EncryptionService>().clearCachedSecrets();
        } catch (_) {}
      }

      // 6. Vault: caller must have called Vault.deleteAll() (e.g. via logout) before performExit

      // 7. Dispose DI container
      locator.reset();
    } catch (_) {}

    // 8. Process exit — no return
    exit(0);
  }
}
