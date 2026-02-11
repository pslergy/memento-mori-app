// lib/core/decoy/app_bootstrap.dart
//
// SECURITY INVARIANT: AppMode MUST be resolved BEFORE runApp().
// Cold start: last used mode from gate_storage (REAL or DECOY).
// In-app switch: CalculatorGate calls teardown + setupCore/Session(resolved).

import 'app_mode.dart';
import 'gate_storage.dart';

/// Resolves application mode for cold start (before runApp).
/// Uses last saved mode from gate_storage so that after DECOY unlock we don't reset to REAL.
Future<AppMode> resolveAppMode() async {
  return getGateMode();
}
