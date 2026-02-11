// lib/core/decoy/routine_runner.dart
//
// ANTI-CORRELATION (Iteration 2): Main-isolate routine behavior that runs
// identically in both modes. Uses injected DB and vault (mode-scoped).
// No fake content; only harmless reads and cache-style access so CPU/IO
// and timing patterns do not differ between modes.
//
// SECURITY INVARIANT: Must not contact REAL-only servers, use REAL keys,
// or leak intent via traffic. All work is local (DB, vault).

import 'dart:async';

import '../locator.dart';
import '../local_db_service.dart';
import 'vault_interface.dart';

/// Runs periodic lightweight tasks in the main isolate using mode-scoped
/// dependencies. Same code path and volume in both modes.
class RoutineRunner {
  RoutineRunner() {
    _db = locator<LocalDatabaseService>();
    _vault = locator<VaultInterface>();
  }

  late final LocalDatabaseService _db;
  late final VaultInterface _vault;

  Timer? _timer;
  static const Duration _interval = Duration(seconds: 90);

  /// Starts periodic routine work. Call once after app bootstrap (e.g. from splash).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _tick());
    // Run one tick soon so behavior is not delayed.
    Future.microtask(() => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      await _db.database;
      await _vault.containsKey('_r');
    } catch (_) {
      // Identical handling in both modes; no logging of content or mode.
    }
  }
}
