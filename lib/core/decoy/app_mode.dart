// lib/core/decoy/app_mode.dart
//
// SECURITY INVARIANT: Authentication resolves to a MODE, not just success/failure.
// REAL and DECOY are both valid successful logins. INVALID = authentication failure.
// UI and timing MUST be indistinguishable between REAL and DECOY.
// Never expose mode names in UI, logs, or user-visible strings.

/// Resolved application mode after authentication.
/// Switching mode REQUIRES full app restart or complete DI teardown and rebuild.
enum AppMode {
  /// Primary storage and crypto namespace.
  REAL,

  /// Alternative storage and crypto namespace. Isolated from REAL.
  DECOY,

  /// Authentication failed. Treat like normal login failure.
  INVALID,
}

extension AppModeExtension on AppMode {
  bool get isAuthenticated => this != AppMode.INVALID;
}
