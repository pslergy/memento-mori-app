import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

enum PermissionStep {
  welcome,
  location,
  bluetooth,
  battery,
  ready,
}

class PermissionFlowScreen extends StatefulWidget {
  final VoidCallback onReady;

  const PermissionFlowScreen({Key? key, required this.onReady}) : super(key: key);

  @override
  State<PermissionFlowScreen> createState() => _PermissionFlowScreenState();
}

class _PermissionFlowScreenState extends State<PermissionFlowScreen> {
  PermissionStep _step = PermissionStep.welcome;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildStep(),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case PermissionStep.welcome:
        return _page(
          title: "Welcome",
          text: "This app connects you with nearby users.",
          button: "CONTINUE",
          onPressed: () => _go(PermissionStep.location),
        );

      case PermissionStep.location:
        return _page(
          title: "Allow location access",
          text: "Location is required to find nearby devices.",
          button: "CONTINUE",
          onPressed: _requestLocation,
        );

      case PermissionStep.bluetooth:
        return _page(
          title: "Turn on Bluetooth",
          text: "Bluetooth is required to connect to nearby users.",
          button: "ENABLE BLUETOOTH",
          onPressed: _requestBluetooth,
        );

      case PermissionStep.battery:
        return _page(
          title: "Allow background activity",
          text: "This allows messages to be delivered reliably.",
          button: "ALLOW",
          onPressed: _requestBattery,
        );

      case PermissionStep.ready:
        return _page(
          title: "All set",
          text: "You are ready to start.",
          button: "START",
          onPressed: widget.onReady,
        );
    }
  }

  Widget _page({
    required String title,
    required String text,
    required String button,
    required VoidCallback onPressed,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Text(title,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Text(text,
            style: const TextStyle(fontSize: 16, color: Colors.black54)),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _loading ? null : onPressed,
            child: _loading
                ? const CircularProgressIndicator(color: Colors.white)
                : Text(button),
          ),
        ),
      ],
    );
  }

  void _go(PermissionStep step) {
    setState(() => _step = step);
  }

  // ===== REQUESTS =====

  Future<void> _requestLocation() async {
    _loading = true;
    setState(() {});
    await Permission.location.request();
    _loading = false;
    _go(PermissionStep.bluetooth);
  }

  Future<void> _requestBluetooth() async {
    _loading = true;
    setState(() {});

    if (Platform.isAndroid) {
      await Permission.bluetoothScan.request();
      await Future.delayed(const Duration(milliseconds: 400));
      await Permission.bluetoothConnect.request();
    }

    _loading = false;
    _go(PermissionStep.battery);
  }

  Future<void> _requestBattery() async {
    _loading = true;
    setState(() {});
    await Permission.ignoreBatteryOptimizations.request();
    _loading = false;
    _go(PermissionStep.ready);
  }
}
