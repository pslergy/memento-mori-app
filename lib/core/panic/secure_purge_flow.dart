import 'package:flutter/material.dart';

import '../app_navigator_key.dart';
import '../app_routes.dart';
import '../di_restart_scope.dart';
import '../security/secure_local_purge.dart';

/// Полное стирание REAL, пересборка GetIt/Provider, переход на калькулятор по [appNavigatorKey].
Future<void> hardPurgeRealAndNavigateToCalculator() async {
  await SecureLocalPurge.execute();
  await DiRestartScopeState.rebindAfterPurgeFromStatic();

  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  Navigator.of(ctx, rootNavigator: true).pushNamedAndRemoveUntil(
    kCalculatorGateRoute,
    (_) => false,
  );
}
