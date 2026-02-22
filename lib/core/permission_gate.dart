// lib/core/permission_gate.dart
//
// Staged DI: Permission UI must not use CORE or SESSION.
// This gate checks permissions only (SAFE). After grant it runs setupCoreLocator + setupSessionLocator
// and navigates to PostPermissionsScreen, which then does setFirstLaunchDone + mesh start → Splash.

import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_service.dart';
import 'decoy/app_mode.dart';
import 'locator.dart';
import 'local_db_service.dart';
import 'mesh_permission_screen.dart';
import 'MeshOrchestrator.dart';
import 'native_mesh_service.dart';
import 'network_monitor.dart';
import '../splash_screen.dart';

/// First route when app starts. Does NOT resolve CORE or SESSION until permissions are granted.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.mode});

  final AppMode mode;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _checked = false;
  bool _allGranted = false;

  static Future<bool> _areRequiredPermissionsGranted() async {
    final list = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.microphone,
      Permission.location,
    ];
    if (Platform.isAndroid) {
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        if (info.version.sdkInt >= 33) list.add(Permission.nearbyWifiDevices);
      } catch (_) {}
    }
    final statuses = await Future.wait(list.map((p) => p.status));
    return statuses.every((s) => s.isGranted);
  }

  void _onPermissionsGranted() {
    setupCoreLocator(widget.mode);
    setupSessionLocator(widget.mode);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => PostPermissionsScreen(mode: widget.mode)),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOnce());
  }

  Future<void> _checkOnce() async {
    if (_checked) return;
    final granted = await _areRequiredPermissionsGranted();
    if (!mounted) return;
    setState(() {
      _checked = true;
      _allGranted = granted;
    });
    if (granted) {
      setupCoreLocator(widget.mode);
      setupSessionLocator(widget.mode);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
            builder: (_) => PostPermissionsScreen(mode: widget.mode)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(
        backgroundColor: Color(0xFF050505),
        body: Center(
          child: CircularProgressIndicator(color: Colors.redAccent),
        ),
      );
    }
    if (_allGranted) {
      return const Scaffold(
        backgroundColor: Color(0xFF050505),
        body: Center(
          child: CircularProgressIndicator(color: Colors.redAccent),
        ),
      );
    }
    return MeshPermissionScreen(onPermissionsGranted: _onPermissionsGranted);
  }
}

/// Shown after permissions are granted. Uses CORE + SESSION (already set up by PermissionGate).
/// Does setFirstLaunchDone, mesh start, then replaces with SplashScreen.
class PostPermissionsScreen extends StatefulWidget {
  const PostPermissionsScreen({super.key, required this.mode});
  final AppMode mode;

  @override
  State<PostPermissionsScreen> createState() => _PostPermissionsScreenState();
}

class _PostPermissionsScreenState extends State<PostPermissionsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
  }

  Future<void> _activate() async {
    // Always re-establish CORE+SESSION so Vault/EncryptionService are guaranteed before Splash → AuthGate → Registration.
    setupCoreLocator(widget.mode);
    setupSessionLocator(widget.mode);
    try {
      await locator<LocalDatabaseService>().setFirstLaunchDone();
    } catch (_) {}
    try {
      NativeMeshService.init();
      NetworkMonitor().start();
    } catch (_) {}
    try {
      await locator<TacticalMeshOrchestrator>()
          .startMeshNetwork(context: context);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF050505),
      body: Center(
        child: CircularProgressIndicator(color: Colors.redAccent),
      ),
    );
  }
}
