import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/app_navigator_key.dart';
import 'core/beacon_country_helper.dart';
import 'core/decoy/app_bootstrap.dart';
import 'l10n/app_localizations.dart';
import 'core/decoy/app_mode.dart';
import 'core/decoy/timed_panic_lifecycle_bridge.dart';
import 'core/locator.dart';
import 'core/mesh_service.dart';
import 'core/permission_gate.dart';

Future<String> _writeCrash(Object error, StackTrace stack) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file =
        File('${dir.path}/crash_${DateTime.now().millisecondsSinceEpoch}.log');
    await file.writeAsString('ERROR: $error\n\n$stack');
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

  // Staged DI: CORE + SESSION registered before runApp so Provider<MeshService> and all screens can resolve without crash.
  final AppMode mode = await resolveAppMode();
  if (mode == AppMode.INVALID) {
    runApp(const _GatePlaceholder());
    return;
  }
  setupLocatorSafe();
  setupCoreLocator(mode);
  setupSessionLocator(mode);
  await BeaconCountryHelper.loadOverride();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MeshService>(
          create: (_) => locator<MeshService>(),
        ),
      ],
      child: TimedPanicLifecycleBridge(
        child: MyApp(mode: mode),
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
  final AppMode mode;
  const MyApp({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
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
