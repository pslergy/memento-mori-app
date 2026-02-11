import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'locator.dart';
import 'native_mesh_service.dart';
import 'MeshOrchestrator.dart';
import 'local_db_service.dart';
import 'network_monitor.dart';
import '../splash_screen.dart';
import '../features/ui/terminal_style.dart';

/// When non-null, this screen runs in "gate mode": no GetIt (CORE/SESSION) until after grant.
/// On success it calls [onPermissionsGranted] and does NOT touch LocalDatabaseService or mesh.
class MeshPermissionScreen extends StatefulWidget {
  const MeshPermissionScreen({
    Key? key,
    this.onPermissionsGranted,
  }) : super(key: key);

  /// If set, permission UI must not use locator. Parent (PermissionGate) will setup DI and navigate.
  final VoidCallback? onPermissionsGranted;

  @override
  State<MeshPermissionScreen> createState() => _MeshPermissionScreenState();
}

class _MeshPermissionScreenState extends State<MeshPermissionScreen> {
  bool _loading = false;

  // Вспомогательный метод для логов
  void _log(String msg) {
    print("🛡️ [Permissions] $msg");
  }

  // Метод для показа ошибки
  void _showErrorSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const TerminalText(
          'Permissions denied! Memento Mori needs them to run the mesh network.',
          color: Colors.white,
        ),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  // Определение версии Android для специфичных разрешений
  Future<int> _getAndroidVersion() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      // В info.version.release может быть "13" или "13.0.1"
      return int.tryParse(info.version.release.split('.').first) ?? 0;
    }
    return 0;
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const TerminalTitle("Action Required", color: Colors.white),
        content: const TerminalText(
          "You have permanently denied some permissions. Please enable them manually in System Settings to start the mesh network.",
          color: Colors.white70,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text("CANCEL", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () => openAppSettings(),
            child: const Text("OPEN SETTINGS"),
          ),
        ],
      ),
    );
  }

  Future<void> _requestPermissionsAndStart() async {
    // 🔥 FIX: Проверяем, не идет ли уже запрос
    if (_loading) {
      _log("Permission request already in progress, ignoring");
      return;
    }

    _log("Starting permission request...");
    setState(() => _loading = true);

    // 🔥 FIX: Небольшая задержка для предотвращения двойного нажатия
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) {
      setState(() => _loading = false);
      return;
    }

    try {
      // Базовый список разрешений (без notification — на некоторых Tecno/HiOS это может крашить системный диалог)
      List<Permission> permissions = [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.microphone,
        Permission.location,
      ];

      // Android 13+ (API 33) требует отдельное разрешение для поиска устройств рядом
      if (Platform.isAndroid && (await _getAndroidVersion() >= 13)) {
        permissions.add(Permission.nearbyWifiDevices);
      }

      _log("Requesting ${permissions.length} permission(s)...");

      // 1️⃣ Запрашиваем всё разом
      Map<Permission, PermissionStatus> statuses = await permissions.request();

      _log("Permission request completed. Statuses: $statuses");

      if (!mounted) {
        setState(() => _loading = false);
        return;
      }

      // 2️⃣ Проверяем на "Вечный отказ"
      bool isPermanentlyDenied =
          statuses.values.any((s) => s.isPermanentlyDenied);
      if (isPermanentlyDenied) {
        _log("Some permissions permanently denied");
        if (!mounted) return;
        _showSettingsDialog();
        setState(() => _loading = false);
        return;
      }

      // 3️⃣ Проверяем, всё ли разрешено
      bool allGranted = statuses.values.every((s) => s.isGranted);

      if (allGranted) {
        _log("Mandate granted.");
        if (widget.onPermissionsGranted != null) {
          // Staged DI: parent (PermissionGate) will setup CORE + SESSION and navigate. No GetIt here.
          widget.onPermissionsGranted!();
          setState(() => _loading = false);
          return;
        }
        _log("Activating Infrastructure...");
        if (!locator.isRegistered<LocalDatabaseService>()) {
          setupLocator();
        }
        await locator<LocalDatabaseService>().setFirstLaunchDone();
        NativeMeshService.init();
        NetworkMonitor().start();
        await locator<TacticalMeshOrchestrator>()
            .startMeshNetwork(context: context);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const SplashScreen()),
        );
      } else {
        _log("Not all permissions granted");
        if (!mounted) return;
        setState(() => _loading = false);
        _showErrorSnackBar();
      }
    } catch (e) {
      _log("Error requesting permissions: $e");
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: TerminalText(
            'Error requesting permissions: $e',
            color: Colors.white,
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // 🔥 FIX: Скрываем системную навигацию (работает на Tecno/Xiaomi)
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top], // Показываем только статус-бар
    );
    // Устанавливаем цвет системной навигации в черный
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    // Only use GetIt when not in gate mode (onPermissionsGranted == null).
    if (widget.onPermissionsGranted == null) _checkFirstLaunch();
  }

  @override
  void dispose() {
    // Восстанавливаем системную навигацию при выходе
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    super.dispose();
  }

  Future<void> _checkFirstLaunch() async {
    if (widget.onPermissionsGranted != null) return;
    if (!locator.isRegistered<LocalDatabaseService>()) return;
    final isFirstLaunch = await locator<LocalDatabaseService>().isFirstLaunch();
    if (!isFirstLaunch) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      // 🔥 FIX: Убираем системную навигацию через extendBody
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Container(
        // 🔥 FIX: Добавляем отступ снизу для системной навигации (если она все еще видна)
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom > 0
              ? MediaQuery.of(context).padding.bottom
              : 0,
        ),
        child: SafeArea(
          child: Center(
            child: _loading
                ? const CircularProgressIndicator(color: Colors.redAccent)
                : SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.shield_outlined,
                              size: 80, color: Colors.redAccent),
                          const SizedBox(height: 32),
                          const TerminalTitle(
                            "PERMISSIONS REQUIRED",
                            color: Colors.redAccent,
                          ),
                          const SizedBox(height: 16),
                          const TerminalSubtitle(
                            "Memento Mori needs Bluetooth, Location, and Microphone to work offline.",
                          ),
                          const SizedBox(height: 32),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                              minimumSize: const Size(double.infinity, 56),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 4,
                            ),
                            onPressed: _loading
                                ? null
                                : () {
                                    // 🔥 FIX: Добавляем небольшую задержку для предотвращения двойного нажатия
                                    if (!_loading) {
                                      _requestPermissionsAndStart();
                                    }
                                  },
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.black),
                                    ),
                                  )
                                : const TerminalText(
                                    "GRANT PERMISSIONS",
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
