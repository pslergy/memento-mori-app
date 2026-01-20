import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/local_db_service.dart';
import 'core/http_override.dart';
import 'core/api_service.dart';
import 'core/locator.dart';

import 'core/mesh_service.dart';
import 'core/mesh_permission_screen.dart';

import 'core/native_mesh_service.dart';
import 'core/background_service.dart';
import 'core/websocket_service.dart';
import 'core/MeshOrchestrator.dart';

import 'splash_screen.dart';

/// ===============================
/// ENTRY POINT
/// ===============================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /// ❗❗❗
  /// ЗДЕСЬ СВЯТОЕ МЕСТО
  /// ❌ НИКАКИХ radio / bluetooth / wifi
  /// ❌ НИКАКИХ native init
  /// ✅ ТОЛЬКО DI + storage
  /// ❗❗❗

  setupLocator();

  final localDb = LocalDatabaseService();
  final bool isFirstLaunch = await localDb.isFirstLaunch();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(
          value: locator<MeshService>(),
        ),
      ],
      child: MyApp(isFirstLaunch: isFirstLaunch),
    ),
  );
}

/// ===============================
/// ROOT APP
/// ===============================
class MyApp extends StatelessWidget {
  final bool isFirstLaunch;

  const MyApp({
    super.key,
    required this.isFirstLaunch,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Memento Mori',
      debugShowCheckedModeBanner: false,

      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),

      /// 🔒 Строгая маршрутизация
      /// Первый запуск → ТОЛЬКО экран прав
      /// Иначе → Splash → Orchestrator
      home: isFirstLaunch
          ? const MeshPermissionScreen()
          : const SplashScreen(),
    );
  }
}

/// ===============================
/// CRITICAL ERROR VIEW
/// (оставляем, это твоя фишка)
/// ===============================
class ErrorView extends StatelessWidget {
  final String error;
  final String stack;

  const ErrorView({
    super.key,
    required this.error,
    required this.stack,
  });

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
              children: const [
                Text(
                  "🚨 CRITICAL CORE FAULT",
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
