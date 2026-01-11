import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:memento_mori_app/l10n/app_localizations.dart';
import 'package:memento_mori_app/core/http_override.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/splash_screen.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart'; // 🔥 Добавлено

import 'core/background_service.dart';
import 'core/locator.dart';
import 'core/mesh_service.dart';
import 'core/websocket_service.dart';

void main() async {
  // 1. Инициализация привязок Flutter
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Инициализация GetIt
  setupLocator();

  // 3. Инициализация фонового сервиса
  BackgroundService.init();
  await WebSocketService().initNotifications();

  // 🔥 ВКЛЮЧАЕМ WAKELOCK ДЛЯ TECNO (Не даем засыпать основному процессу)
  try {
    WakelockPlus.enable();
  } catch (e) {
    print("WakeLock Error: $e");
  }

  Object? initialError;
  StackTrace? initialStack;

  try {
    HttpOverrides.global = MyHttpOverrides();
    ApiService.init();
  } catch (e, stack) {
    initialError = e;
    initialStack = stack;
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: locator<MeshService>()),
      ],
      child: initialError != null
          ? ErrorView(error: initialError.toString(), stack: initialStack.toString())
          : const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Memento Mori',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', ''), Locale('ru', '')],
      home: const SplashScreen(),
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
                const Text("🚨 CRASH DETECTED", style: TextStyle(color: Colors.red, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Text(error, style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                const Divider(color: Colors.white24),
                Text(stack, style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}