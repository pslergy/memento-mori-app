import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Системные импорты
import 'core/api_service.dart';
import 'core/locator.dart';
import 'core/mesh_prep_service.dart';
import 'core/mesh_service.dart';
import 'core/native_mesh_service.dart';
import 'core/storage_service.dart';
import 'core/websocket_service.dart';

// Экраны
import 'package:memento_mori_app/features/camouflage/calculator_gate.dart';
import 'package:memento_mori_app/features/auth/briefing_screen.dart';
import 'package:memento_mori_app/features/auth/auth_gate_screen.dart'; // 🔥 Твой новый экран

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      print("🧪 [DEBUG] Manual Hardware Probe Start...");
      final caps = await NativeMeshService.getHardwareCapabilities();
      print("🛠️ HARDWARE REPORT: $caps");
    });

    _initApp();
  }

  Future<void> _initApp() async {
    // 1. Психологическая пауза (дает время ОС и железу подгрузить нативные модули сонара и сети)
    await Future.delayed(const Duration(milliseconds: 1500));

    final api = locator<ApiService>();
    final prefs = await SharedPreferences.getInstance();

    bool ready = await MeshPrepService.requestTacticalPermissions();

    if (ready) {
      // Включаем "Groosa" (прием и передачу сразу)
      await locator<MeshService>().activateGroosaProtocol();
    }


    String? userId;
    String? token;

    try {
      // 2. Инициализация тактической личности
      // Загружаем токен и ID в кэш ApiService
      await api.loadSavedIdentity();

      // Читаем данные напрямую из бронированного хранилища
      userId = await Vault.read('user_id');
      token = await Vault.read('auth_token');

      print("🕵️ [Splash] Grid Check -> ID: $userId | Status: ${token != null ? 'SECURED' : 'UNAUTHORIZED'}");

      // 3. ФОНОВАЯ СИНХРОНИЗАЦИЯ (Только для онлайн-аккаунтов)
      // Если у нас есть реальный облачный токен — подключаем связи в фоне
      if (token != null && token != 'GHOST_MODE_ACTIVE') {
        print("🌐 [Splash] Cloud Node detected. Establishing secure links...");

        // Мы используем unawaited, чтобы не блокировать вход пользователя в приложение
        unawaited(api.getMe());
        unawaited(WebSocketService().connect());
      }

      // Если мы в режиме "Призрака", проверяем возможность легализации
      if (token == 'GHOST_MODE_ACTIVE') {
        print("👻 [Splash] Ghost Identity active. Waiting for internet bridge to legalize.");
      }

    } catch (e) {
      print("☢️ [Splash] Critical Initialization Error: $e");
    }

    // Проверка, что экран еще "жив" во Flutter-дереве
    if (!mounted) return;

    // 4. ДЕТЕРМИНИРОВАННАЯ МАРШРУТИЗАЦИЯ (State Machine)
    // Флаг первого запуска (может восстановиться из облака Xiaomi/Google)
    final bool isFirstRun = prefs.getBool('isFirstRun') ?? true;

    if (isFirstRun) {
      // СОСТОЯНИЕ: НОВОБРАНЕЦ
      // Пользователь видит приложение впервые. Показываем секретный код 3301.
      print("🎯 [Route] State: First Run. Redirecting to Briefing.");
      _navigate(const BriefingScreen());

    } else if (userId != null || token != null) {
      // СОСТОЯНИЕ: АКТИВНЫЙ АГЕНТ
      // Личность (облачная или локальный Ghost) уже создана.
      // Принудительно прячемся за Калькулятором (Decoy Mode).
      print("🎯 [Route] State: Identity Secured. Activating Camouflage Gate.");
      _navigate(const CalculatorGate());

    } else {
      // СОСТОЯНИЕ: НЕКОНСИСТЕНТНОЕ (Случай с Xiaomi)
      // Бэкап сказал "isFirstRun = false", но данных личности (userId) нет.
      // Чтобы не пугать юзера принудительной регистрацией — даем выбор.
      print("🎯 [Route] State: Inconsistent (No ID found). Redirecting to Auth Gate.");
      _navigate(const AuthGateScreen());
    }
  }

  // Вспомогательный метод для чистой смены экранов
  void _navigate(Widget screen) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => screen),
    );
  }



  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: Colors.redAccent,
              strokeWidth: 2,
            ),
            SizedBox(height: 20),
            Text(
              "SYNCHRONIZING WITH GRID...",
              style: TextStyle(
                  color: Colors.white24,
                  fontSize: 10,
                  letterSpacing: 2,
                  fontFamily: 'monospace'
              ),
            )
          ],
        ),
      ),
    );
  }
}