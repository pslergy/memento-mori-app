import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'core/app_navigator_key.dart';
import 'core/app_routes.dart';
import 'core/beacon_country_helper.dart';
import 'core/decoy/gate_storage.dart';
import 'core/di_restart_scope.dart';
import 'l10n/app_localizations.dart';
import 'core/decoy/app_mode.dart';
import 'core/decoy/timed_panic_lifecycle_bridge.dart';
import 'core/locator.dart';
import 'core/permission_gate.dart';
import 'features/camouflage/calculator_gate.dart';

/// Маскирует чувствительные данные в crash-логе (токены, пути, user_id).
String _sanitizeForCrashLog(String raw) {
  var s = raw;
  s = s.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9\-_.]+'), 'Bearer ***');
  s = s.replaceAll(RegExp(r'eph_[A-Za-z0-9]+'), 'eph_***');
  s = s.replaceAll(RegExp(r'[A-Za-z0-9+/]{40,}={0,2}'), '[BASE64_REDACTED]');
  s = s.replaceAll(RegExp(r'user_id["\s:=]+[^\s,}\]]+'), 'user_id***');
  s = s.replaceAll(RegExp(r'auth_token["\s:=]+[^\s,}\]]+'), 'auth_token***');
  if (s.length > 6000) s = '${s.substring(0, 6000)}...[truncated]';
  return s;
}

Future<String> _writeCrash(Object error, StackTrace stack) async {
  try {
    final raw = 'ERROR: $error\n\n$stack';
    final sanitized = _sanitizeForCrashLog(raw);
    final dir = await getApplicationSupportDirectory();
    final file =
        File('${dir.path}/crash_${DateTime.now().millisecondsSinceEpoch}.log');
    await file.writeAsString(sanitized);
    return file.path;
  } catch (_) {
    return 'crash log write failed';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) async {
    await _writeCrash(details.exception, details.stack ?? StackTrace.current);
    FlutterError.dumpErrorToConsole(details);
  };

  // Staged DI: CORE + SESSION registered before runApp so Provider<MeshCoreEngine> and all screens can resolve without crash.
  // Последний режим калькулятора (REAL/DECOY) — отдельные Vault и БД.
  final AppMode mode = await getGateMode();
  setupLocatorSafe();
  setupCoreLocator(mode);
  setupSessionLocator(mode);
  await BeaconCountryHelper.loadOverride();

  runApp(
    DiRestartScope(
      initialMode: mode,
      child: TimedPanicLifecycleBridge(
        child: const MyApp(),
      ),
    ),
  );
}

/// Placeholder when authentication fails. No mode-specific wording.
class _GatePlaceholder extends StatelessWidget {
  const _GatePlaceholder();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
            child: Text('Access required',
                style: TextStyle(color: Colors.grey[400]))),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = RestartedAppModeScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.top],
      );
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      );
    });

    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Memento Mori',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData.dark()
          .copyWith(scaffoldBackgroundColor: const Color(0xFF121212)),
      routes: {
        kCalculatorGateRoute: (_) => const CalculatorGate(),
      },
      home: PermissionGate(mode: mode),
    );
  }
}

class ErrorView extends StatelessWidget {
  final String error;
  final String stack;
  const ErrorView({super.key, required this.error, required this.stack});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF1A0000),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("🚨 CRITICAL CORE FAULT",
                    style: TextStyle(
                        color: Colors.red,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Text(error,
                    style: const TextStyle(
                        color: Colors.orange, fontWeight: FontWeight.bold)),
                const Divider(color: Colors.white24),
                Text(stack,
                    style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 10,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
