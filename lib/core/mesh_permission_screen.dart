import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'locator.dart';
import 'gossip_manager.dart';
import 'native_mesh_service.dart';
import 'MeshOrchestrator.dart';
import 'local_db_service.dart';
import 'network_monitor.dart';
import '../splash_screen.dart';

class MeshPermissionScreen extends StatefulWidget {
  const MeshPermissionScreen({Key? key}) : super(key: key);

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
      const SnackBar(
        content: Text('Permissions denied! Memento Mori needs them to run the mesh network.'),
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
        title: const Text("Action Required", style: TextStyle(color: Colors.white)),
        content: const Text(
          "You have permanently denied some permissions. Please enable them manually in System Settings to start the mesh network.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("CANCEL", style: TextStyle(color: Colors.redAccent)),
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
    setState(() => _loading = true);

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

    // 1️⃣ Запрашиваем всё разом
    Map<Permission, PermissionStatus> statuses = await permissions.request();

    // 2️⃣ Проверяем на "Вечный отказ"
    bool isPermanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
    if (isPermanentlyDenied) {
      _showSettingsDialog();
      setState(() => _loading = false);
      return;
    }

    // 3️⃣ Проверяем, всё ли разрешено
    bool allGranted = statuses.values.every((s) => s.isGranted);

    if (allGranted) {
      _log("Mandate granted. Activating Infrastructure...");

      // Инициализация систем (только один раз при первом запуске)
      await locator<LocalDatabaseService>().setFirstLaunchDone();

      // Запуск базовых нативных сервисов и мониторинга сети
      NativeMeshService.init();
      NetworkMonitor().start();

      // Полный старт Mesh-оркестратора (Wi-Fi Direct + BLE + Sonar + Gossip)
      await locator<TacticalMeshOrchestrator>().startMeshNetwork(context: context);

      if (!mounted) return;
      // Летим в Сплеш, он направит дальше
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
      );
    } else {
      setState(() => _loading = false);
      _showErrorSnackBar();
    }
  }

  @override
  void initState() {
    super.initState();
    _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    final isFirstLaunch = await locator<LocalDatabaseService>().isFirstLaunch();
    if (!isFirstLaunch) {
      // Если не первый запуск — просто пролетаем дальше
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
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: Colors.redAccent)
            : Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield_outlined, size: 80, color: Colors.redAccent),
              const SizedBox(height: 32),
              const Text(
                "TACTICAL MANDATE",
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                "Memento Mori requires access to Bluetooth, Microphone, and Location to establish an off-grid mesh network.",
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _requestPermissionsAndStart,
                child: const Text("GRANT PERMISSIONS", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}