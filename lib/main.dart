import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/l10n/app_localizations.dart';
import 'package:memento_mori_app/core/http_override.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/splash_screen.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/MeshOrchestrator.dart';
import 'core/background_service.dart';
import 'core/gossip_manager.dart';
import 'core/locator.dart';
import 'core/mesh_permission_screen.dart';
import 'core/mesh_service.dart';
import 'core/native_mesh_service.dart';
import 'core/websocket_service.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupLocator();
  locator<TacticalMeshOrchestrator>().start();

  NativeMeshService.init();
  BackgroundService.init();
  await WebSocketService().initNotifications();
  await WakelockPlus.enable();

  bool isFirstLaunch = await LocalDatabaseService().isFirstLaunch();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: locator<MeshService>()),
      ],
      child: MyApp(isFirstLaunch: isFirstLaunch),
    ),
  );
}

class MyApp extends StatelessWidget {
  final bool isFirstLaunch;
  const MyApp({super.key, required this.isFirstLaunch});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Memento Mori',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF121212)),
      home: isFirstLaunch ? const MeshPermissionScreen() : const SplashScreen(),
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
                    style: TextStyle(color: Colors.red, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Text(error, style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                const Divider(color: Colors.white24),
                Text(stack,
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}