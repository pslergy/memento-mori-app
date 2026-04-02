import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Системные импорты
import 'core/api_service.dart';
import 'core/decoy/app_mode.dart';
import 'core/decoy/decoy_beacon_feed.dart';
import 'core/decoy/decoy_seed_service.dart';
import 'core/decoy/gate_storage.dart';
import 'core/decoy/session_teardown.dart';
import 'core/decoy/vault_interface.dart';
import 'core/local_db_service.dart';
import 'core/locator.dart';
import 'core/mesh_core_engine.dart';
import 'core/native_mesh_service.dart';
import 'core/storage_service.dart';
import 'core/websocket_service.dart';
import 'core/MeshOrchestrator.dart';
import 'core/network_monitor.dart';
import 'core/panic_service.dart';
import 'core/bluetooth_service.dart';
import 'core/decoy/routine_runner.dart';

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
      // 5️⃣ Preserve timing: wait 1500ms BEFORE CORE/SESSION steps (no change to animation/timers).
      print("⏳ [Splash] Waiting 1500ms...");
      await Future.delayed(const Duration(milliseconds: 1500));

      // Режим REAL/DECOY — как на калькуляторе (отдельные Vault и БД).
      final AppMode gateMode = await getGateMode();

      // 1️⃣ CORE: Vault + БД должны совпадать с [getGateMode] (REAL/DECOY — разные файлы).
      // Если DI остался от другого режима (пропущен rebind), пересобираем CORE+SESSION.
      await ensureCoreLocatorAlignedWithMode(gateMode);
      print("[Splash] CORE aligned with gate mode ($gateMode)");

      // 2️⃣ SESSION: after CORE ready, register Mesh/Gossip/BLE etc. Do not resolve Mesh/Bluetooth yet.
      if (!locator.isRegistered<MeshCoreEngine>()) {
        setupSessionLocator(gateMode);
        print("[Splash] SESSION setup complete ($gateMode)");
      }

      prefs = await SharedPreferences.getInstance();

      // OFFLINE SAFE: ApiService is NOT required for startup or ghost flow.
      if (locator.isRegistered<ApiService>()) {
        print("⏳ [Splash] Step 2: Getting services...");
        try {
          final api = locator<ApiService>();
          await api.loadSavedIdentity();
          print("✅ [Splash] Identity loaded");
        } catch (e, _) {
          print("⚠️ [Splash] ApiService init (non-fatal): $e");
        }
      } else {
        print("⏳ [Splash] Step 2: Offline mode — skipping ApiService.");
      }

      print("⏳ [Splash] Step 3: Reading from Vault...");
      userId = await Vault.read('user_id');
      token = await Vault.read('auth_token');
      print("✅ [Splash] Vault read complete");
      print(
          "🕵️ [Splash] Grid Check -> ID: $userId | Status: ${token != null ? 'SECURED' : 'UNAUTHORIZED'}");

      // DECOY: один раз наполняем фейк-аккаунт друзьями и перепиской (реалистичный вид при входе)
      if (gateMode == AppMode.DECOY && userId != null && userId.isNotEmpty) {
        await DecoySeedService.ensureDecoySeeded();
        startDecoyBeaconFeed();
      }

      // 3️⃣ Ghost / Offline: skip real network calls, log and continue.
      if (token == 'GHOST_MODE_ACTIVE') {
        print("[Splash] Ghost active: SESSION registered, offline mode");
        print("[Splash] Ghost/Offline ready");
        if (!locator.isRegistered<MeshCoreEngine>()) {
          setupSessionLocator(gateMode);
          print("[Splash] SESSION setup complete (Ghost, $gateMode)");
        }
      } else {
        // ONLINE ONLY: Cloud sync when ApiService registered and token is cloud.
        if (locator.isRegistered<ApiService>() && token != null) {
          print(
              "🌐 [Splash] Cloud Node detected. Establishing secure links...");
          try {
            final api = locator<ApiService>();
            unawaited(api.getMe());
            unawaited(WebSocketService().connect());
          } catch (_) {}
        }
      }

      // 4️⃣ Guard heavy Mesh operations: require CORE + MeshCoreEngine before startMeshNetwork.
      bool meshReady = locator.isRegistered<LocalDatabaseService>() &&
          locator.isRegistered<VaultInterface>() &&
          locator.isRegistered<MeshCoreEngine>();
      if (!meshReady && isCoreReady && !locator.isRegistered<MeshCoreEngine>()) {
        setupSessionLocator(gateMode);
        print("[Splash] SESSION setup complete (deferred, $gateMode)");
        meshReady = locator.isRegistered<MeshCoreEngine>();
      }
      if (!meshReady) {
        print(
            "[Splash] Mesh not ready (CORE or SESSION missing), skipping mesh start.");
      } else if (locator.isRegistered<TacticalMeshOrchestrator>()) {
        try {
          print("⏳ [Splash] Step 4: Starting Mesh infrastructure...");
          NativeMeshService.init();
          NetworkMonitor().start();
          unawaited(_autoStartGattServerIfNeeded());
          unawaited(locator<TacticalMeshOrchestrator>()
              .startMeshNetwork(context: context));
          print("✅ [Splash] Mesh infrastructure online.");
          if (locator.isRegistered<RoutineRunner>()) {
            locator<RoutineRunner>().start();
          }
        } catch (e, _) {
          print("⚠️ [Splash] Mesh start failed (non-fatal): $e");
        }
      } else {
        print(
            "⏳ [Splash] Step 4: TacticalMeshOrchestrator not registered — skipping mesh start.");
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
      print(
          "🚩 [Route] State: Panic Protocol Active. Requiring Calculator + Biometric.");
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
      print(
          "🎯 [Route] State: Inconsistent (No ID found). Redirecting to Auth Gate.");
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
        print(
            "ℹ️ [Splash] Not a BRIDGE device, skipping GATT server auto-start");
        return;
      }

      print("🚀 [Splash] BRIDGE detected, auto-starting GATT server...");

      // Получаем BluetoothMeshService и запускаем GATT server
      final btService = locator<BluetoothMeshService>();
      final success = await btService.autoStartGattServerIfBridge();

      if (success) {
        print("✅ [Splash] GATT server auto-started successfully");
      } else {
        print(
            "⚠️ [Splash] GATT server auto-start failed (will retry later via advertising)");
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
                  fontFamily: 'monospace'),
            )
          ],
        ),
      ),
    );
  }
}
