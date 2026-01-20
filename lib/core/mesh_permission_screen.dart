import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/websocket_service.dart';

import '../splash_screen.dart';
import 'MeshOrchestrator.dart';
import 'background_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'mesh_activation_gate.dart';
import 'native_mesh_service.dart';

class MeshPermissionScreen extends StatefulWidget {
  const MeshPermissionScreen({super.key});

  @override
  State<MeshPermissionScreen> createState() => _MeshPermissionScreenState();
}

class _MeshPermissionScreenState extends State<MeshPermissionScreen> {

  bool _isGranting = false;

  Future<void> _grantPermissions() async {
    if (_isGranting) return;
    setState(() => _isGranting = true);

    final granted = await MeshActivationGate.requestAll();

    if (!granted) {
      setState(() => _isGranting = false);
      return;
    }

    /// ⚠️ ТОЛЬКО ТЕПЕРЬ
    await _activateMeshStack();

    await LocalDatabaseService().isFirstLaunch();

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
    );
  }

  Future<void> _activateMeshStack() async {
    /// 🔒 Полный серилизационный замок
    await MeshActivationGate.lock();

    /// 1️⃣ Нативные сервисы
    await NativeMeshService.activate();

    /// 2️⃣ Фоновые сервисы
    BackgroundService.init();

    /// 3️⃣ WebSocket (если есть интернет)
    await WebSocketService().initNotifications();

    /// 4️⃣ Оркестратор — ПОСЛЕДНИМ
    locator<TacticalMeshOrchestrator>().start();

    await MeshActivationGate.unlock();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: _isGranting ? null : _grantPermissions,
          child: const Text('Grant Permissions'),
        ),
      ),
    );
  }
}
