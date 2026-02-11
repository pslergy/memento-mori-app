// lib/core/decoy/storage_paths.dart
//
// FORENSIC INVARIANT (Iteration 3): REAL and DECOY use separate directories
// and separate SQLite files. No shared WAL, journals, temp dirs, or paths.
// File layout: <app-databases>/<dir>/<file>.db (and .db-wal, .db-shm only there).

import 'app_mode.dart';

/// Database file name for the given mode.
String dbFileNameForMode(AppMode mode) {
  switch (mode) {
    case AppMode.REAL:
      return 'real.db';
    case AppMode.DECOY:
      return 'decoy.db';
    case AppMode.INVALID:
      return 'real.db';
  }
}

/// Subdirectory name for the given mode. Ensures no file path reuse across modes.
String dbDirectorySuffixForMode(AppMode mode) {
  switch (mode) {
    case AppMode.REAL:
      return 'real';
    case AppMode.DECOY:
      return 'decoy';
    case AppMode.INVALID:
      return 'real';
  }
}
