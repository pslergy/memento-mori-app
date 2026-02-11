// lib/core/decoy/session_teardown.dart
//
// FORENSIC (Iteration 3): Explicit teardown. For user-initiated "Logout" use
// [ModeExitService.performExit] instead (Iteration 4) — single exit authority,
// process exit, no in-process return to login.
// This function remains for non-exit teardown scenarios (e.g. tests) only.
//
// Lifecycle: close DB (checkpoint WAL) → stop runners → stop foreground task → reset DI.

import '../background_service.dart';
import '../local_db_service.dart';
import '../locator.dart';
import 'routine_runner.dart';

/// Performs full session teardown: closes SQLite (with WAL checkpoint), stops
/// RoutineRunner and BackgroundService, resets GetIt. Call on logout before
/// navigating away. After this, in-memory caches and DB references are dropped;
/// app should exit or next launch will re-bootstrap with no stale handles.
///
/// Order guarantees: DB is checkpointed and closed first so no orphaned WAL;
/// then runners stop; then locator reset so no service holds refs.
Future<void> teardownSession() async {
  if (locator.isRegistered<LocalDatabaseService>()) {
    try {
      await locator<LocalDatabaseService>().closeAndCheckpoint();
    } catch (_) {}
  }
  if (locator.isRegistered<RoutineRunner>()) {
    try {
      locator<RoutineRunner>().stop();
    } catch (_) {}
  }
  try {
    await BackgroundService.stop();
  } catch (_) {}
  locator.reset();
}
