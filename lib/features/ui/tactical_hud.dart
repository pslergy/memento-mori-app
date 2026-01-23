import 'dart:async';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/locator.dart';
import '../../core/mesh_service.dart';
import '../../core/network_monitor.dart';
import '../../core/ultrasonic_service.dart';
import '../theme/app_colors.dart';

class TacticalHUD extends StatefulWidget {
  @override
  State<TacticalHUD> createState() => _TacticalHUDState();
}

class _TacticalHUDState extends State<TacticalHUD> {
  String? _lastAcousticSignal;
  Timer? _displayTimer;

  @override
  void initState() {
    super.initState();
    // Подписываемся на Сонар прямо в HUD
    locator<UltrasonicService>().sonarMessages.listen((msg) {
      if (mounted) {
        setState(() {
          _lastAcousticSignal = msg.startsWith("LNK:") ? "HANDSHAKE DETECTED" : "DATA PACKET INCOMING";
        });

        // Скрываем надпись через 3 секунды
        _displayTimer?.cancel();
        _displayTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _lastAcousticSignal = null);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final isOnline = NetworkMonitor().currentRole == MeshRole.BRIDGE;

    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: _lastAcousticSignal != null ? AppColors.sonarPurple.withOpacity(0.2) : AppColors.surface,
        border: Border(bottom: BorderSide(color: _lastAcousticSignal != null ? AppColors.sonarPurple : AppColors.white10)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Основной статус
          if (_lastAcousticSignal == null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPulseDot(isOnline ? AppColors.cloudGreen : AppColors.gridCyan),
                const SizedBox(width: 10),
                Text(
                  isOnline ? "UPLINK SECURED" : "MESH ACTIVE",
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),

          // 🔥 ВИЗУАЛИЗАЦИЯ СОНАРА
          if (_lastAcousticSignal != null)
            FadeInDown(
              duration: const Duration(milliseconds: 300),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Pulse(infinite: true, child: Icon(Icons.waves, color: AppColors.sonarPurple, size: 16)),
                  const SizedBox(width: 10),
                  Text(
                    _lastAcousticSignal!,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.sonarPurple,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPulseDot(Color color) {
    return Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color));
  }
}