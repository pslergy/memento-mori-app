import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 🔥 Для флага первого входа

// Импорты твоих экранов
import 'package:memento_mori_app/features/camouflage/calculator_gate.dart';
import 'package:memento_mori_app/features/auth/briefing_screen.dart'; // Создадим его ниже
import 'core/api_service.dart';
import 'core/locator.dart';
import 'core/mesh_service.dart';
import 'core/storage_service.dart';
import 'core/websocket_service.dart';
import 'features/auth/registration_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // 1. Даем время системе прогрузиться
    await Future.delayed(const Duration(milliseconds: 1200));

    final api = locator<ApiService>();
    final prefs = await SharedPreferences.getInstance();

    String? userId;
    String? token;

    try {
      // 2. Загружаем личность в ApiService через Vault
      await api.loadSavedIdentity();

      // 3. Читаем данные через наш единый "бронированный" Vault
      userId = await Vault.read('user_id');
      token = await Vault.read('auth_token');

      print("🕵️ [Splash] ID: $userId | Token: ${token?.substring(0, 5)}...");

      // 4. Логика фоновой синхронизации
      if (token == 'GHOST_MODE_ACTIVE') {
        print("👻 [Splash] Ghost Identity verified. Bypassing cloud check.");
      } else if (token != null) {
        print("🌐 [Splash] Cloud Node. Establishing links...");
        // В онлайне обновляем профиль и подключаем сокеты
        unawaited(api.getMe());
        unawaited(WebSocketService().connect());
      }
    } catch (e) {
      print("☢️ [Splash] Critical Init Error: $e");
    }

    if (!mounted) return;

    // 5. МАРШРУТИЗАЦИЯ
    final bool isFirstRun = prefs.getBool('isFirstRun') ?? true;

    if (isFirstRun) {
      print("🕵️ [Splash] First run detected. To Briefing.");
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const BriefingScreen()),
      );
    } else if (userId != null || token != null) {
      print("🧮 [Splash] Access Granted. To Calculator.");
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const CalculatorGate()),
      );
    } else {
      print("🛑 [Splash] No Identity. To Registration.");
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const RegistrationScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: CircularProgressIndicator(
          color: Colors.redAccent,
          strokeWidth: 2,
        ),
      ),
    );
  }
}