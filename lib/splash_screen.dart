import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Системные импорты
import 'core/api_service.dart';
import 'core/locator.dart';
import 'core/mesh_service.dart';
import 'core/native_mesh_service.dart';
import 'core/storage_service.dart';
import 'core/websocket_service.dart';
import 'core/MeshOrchestrator.dart';
import 'core/network_monitor.dart';
import 'core/panic_service.dart';
import 'core/bluetooth_service.dart';

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
    _initApp();
  }

  Future<void> _initApp() async {
    SharedPreferences? prefs;
    String? userId;
    String? token;

    try {
      // 1. Психологическая пауза (дает время ОС и железу подгрузить нативные модули сонара и сети)
      print("⏳ [Splash] Step 1: Waiting 1500ms...");
      await Future.delayed(const Duration(milliseconds: 1500));

      print("⏳ [Splash] Step 2: Getting services...");
      final api = locator<ApiService>();
      prefs = await SharedPreferences.getInstance();

      // ⚙️ Ре-инициализация Mesh-инфраструктуры после hot restart / убийства процесса
      try {
        print("⏳ [Splash] Step 3: Rebooting Mesh infrastructure (Native + Orchestrator)...");

        // Лёгкий старт нативного слоя (Wi‑Fi Direct / BLE glue)
        NativeMeshService.init();

        // Мониторинг ролей (BRIDGE / NODE / GHOST)
        NetworkMonitor().start();
        
        // 🔥 АВТОМАТИЧЕСКИЙ ЗАПУСК GATT SERVER ДЛЯ BRIDGE (оптимизирован для слабых устройств)
        // Запускаем в фоне, не блокируя splash screen
        unawaited(_autoStartGattServerIfNeeded());

        // Оркестратор Mesh (Gossip + Wi‑Fi Direct + BLE + Sonar)
        // Не блокируем Splash — запускаем в фоне.
        unawaited(locator<TacticalMeshOrchestrator>().startMeshNetwork(context: context));

        print("✅ [Splash] Mesh infrastructure online.");
      } catch (e, stack) {
        print("⚠️ [Splash] Mesh reboot failed (non-fatal): $e");
        print("Stack: $stack");
      }

      print("⏳ [Splash] Step 4: Loading identity...");
      try {
        // 2. Инициализация тактической личности
        // Загружаем токен и ID в кэш ApiService
        await api.loadSavedIdentity();
        print("✅ [Splash] Identity loaded");

        // Читаем данные напрямую из бронированного хранилища
        print("⏳ [Splash] Step 5: Reading from Vault...");
        userId = await Vault.read('user_id');
        token = await Vault.read('auth_token');
        print("✅ [Splash] Vault read complete");

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

      } catch (e, stack) {
        print("☢️ [Splash] Critical Initialization Error: $e");
        print("Stack: $stack");
      }
    } catch (e, stack) {
      print("💥 [Splash] FATAL ERROR in _initApp: $e");
      print("Stack: $stack");
      // Продолжаем навигацию, даже если что-то упало
    }

    // Проверка, что экран еще "жив" во Flutter-дереве
    if (!mounted) return;

    // 4. ДЕТЕРМИНИРОВАННАЯ МАРШРУТИЗАЦИЯ (State Machine)
    // Флаг первого запуска (может восстановиться из облака Xiaomi/Google)
    final bool isFirstRun = prefs?.getBool('isFirstRun') ?? true;

    // 🔥 ПРИОРИТЕТ: Проверяем паник-протокол ПЕРВЫМ
    final bool isPanicActivated = await PanicService.isPanicProtocolActivated();
    if (isPanicActivated) {
      // СОСТОЯНИЕ: ПАНИК-ПРОТОКОЛ АКТИВИРОВАН
      // Требуем калькулятор + биометрию при следующем входе
      print("🚩 [Route] State: Panic Protocol Active. Requiring Calculator + Biometric.");
      _navigate(const CalculatorGate());
      return;
    }

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
  
  /// 🔥 АВТОМАТИЧЕСКИЙ ЗАПУСК GATT SERVER ПРИ СТАРТЕ ПРИЛОЖЕНИЯ
  /// Оптимизирован для слабых устройств - запускается асинхронно, не блокирует UI
  Future<void> _autoStartGattServerIfNeeded() async {
    try {
      // Даем время на инициализацию NetworkMonitor
      await Future.delayed(const Duration(milliseconds: 1000));
      
      // Проверяем роль устройства
      final currentRole = NetworkMonitor().currentRole;
      if (currentRole != MeshRole.BRIDGE) {
        print("ℹ️ [Splash] Not a BRIDGE device, skipping GATT server auto-start");
        return;
      }
      
      print("🚀 [Splash] BRIDGE detected, auto-starting GATT server...");
      
      // Получаем BluetoothMeshService и запускаем GATT server
      final btService = locator<BluetoothMeshService>();
      final success = await btService.autoStartGattServerIfBridge();
      
      if (success) {
        print("✅ [Splash] GATT server auto-started successfully");
      } else {
        print("⚠️ [Splash] GATT server auto-start failed (will retry later via advertising)");
      }
    } catch (e) {
      print("❌ [Splash] Error in GATT server auto-start: $e");
      // Не критично - GATT server запустится позже через startAdvertising
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