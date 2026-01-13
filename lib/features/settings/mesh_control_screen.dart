import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:animate_do/animate_do.dart';

import '../../core/mesh_service.dart';
import '../../core/locator.dart';
import '../../core/models/signal_node.dart';
import '../../core/native_mesh_service.dart';
import '../../core/ultrasonic_service.dart';
import '../../core/network_monitor.dart';

import '../../core/api_service.dart';
import '../theme/app_colors.dart';

class MeshControlScreen extends StatefulWidget {
  const MeshControlScreen({super.key});

  @override
  State<MeshControlScreen> createState() => _MeshControlScreenState();
}

class _MeshControlScreenState extends State<MeshControlScreen> with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  bool _isAcousticTransmitting = false;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

    // 🔥 ФИКС ОШИБКИ: Ждем завершения кадра перед логированием
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logAction("Terminal session started. Ready for grid operations.");
    });
  }

  void _logAction(String msg) {
    // Используем микротаск, чтобы гарантированно не попасть в фазу build
    Future.microtask(() {
      final mesh = locator<MeshService>();
      mesh.addLog("[TERMINAL] $msg");
      print("🛠️ DEBUG: $msg");
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    super.dispose();
  }

  // 🔥 ГЛОБАЛЬНЫЙ SOS С ЖЕСТКИМ ЛОГИРОВАНИЕМ
  void _executeEmergencySOS() async {
    _logAction("🚨 !!! SOS EXECUTION STARTED !!!");
    HapticFeedback.vibrate();

    final mesh = locator<MeshService>();
    final api = locator<ApiService>();

    try {
      // 1. Пакет в Mesh
      await mesh.sendAuto(
        content: "CRITICAL SOS: Nomad ${api.currentUserId.substring(0,4)} position compromised.",
        chatId: "THE_BEACON_GLOBAL",
        receiverName: "GLOBAL",
      );
      _logAction("✅ Mesh/Cloud signal dispatched.");

      // 2. Сонар
      await locator<UltrasonicService>().transmitFrame("SOS:${api.currentUserId}");
      _logAction("✅ Acoustic beacon emitting...");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("EMERGENCY BROADCAST ACTIVE"), backgroundColor: AppColors.warningRed),
        );
      }
    } catch (e) {
      _logAction("❌ SOS FAILED: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final nodes = mesh.nearbyNodes;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopStatusHeader(mesh),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  const SizedBox(height: 20),
                  _buildRadarDisplay(nodes.length),
                  const SizedBox(height: 30),

                  // 🔥 КНОПКА SOS (Теперь отдельный блок)
                  _buildEmergencyButton(),

                  const SizedBox(height: 30),

                  _buildTacticalGrid(mesh),

                  const SizedBox(height: 20),
                  _buildAlliesList(nodes),
                ],
              ),
            ),

            _buildFooterActions(mesh),
          ],
        ),
      ),
    );
  }

  Widget _buildTopStatusHeader(MeshService mesh) {
    final role = NetworkMonitor().currentRole;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.white10))
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildStat("CONNECTION", role == MeshRole.BRIDGE ? "CLOUD" : "MESH", AppColors.cloudGreen),
          _buildStat("NODES", "${mesh.nearbyNodes.length} ACTIVE", AppColors.gridCyan),
          _buildStat("STEALTH", mesh.isPowerSaving ? "ON" : "OFF", AppColors.stealthOrange),
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.russoOne(fontSize: 8, color: AppColors.textDim)),
        Text(value, style: GoogleFonts.robotoMono(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildRadarDisplay(int count) {
    return Container(
      height: 180,
      decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.white05)
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildRadarAnimation(),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.radar, color: AppColors.gridCyan, size: 30),
              const SizedBox(height: 10),
              Text(count > 0 ? "SCANNING: $count NODES" : "SCANNING SECTOR",
                  style: GoogleFonts.russoOne(fontSize: 10, color: AppColors.gridCyan)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmergencyButton() {
    return FadeInUp(
      child: GestureDetector(
        onLongPress: _executeEmergencySOS,
        onTap: () {
          HapticFeedback.lightImpact();
          _logAction("Interaction: Brief tap on SOS. Holding required.");
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 25),
          decoration: BoxDecoration(
              color: AppColors.warningRed.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.warningRed.withOpacity(0.5), width: 1),
              boxShadow: [BoxShadow(color: AppColors.warningRed.withOpacity(0.1), blurRadius: 20)]
          ),
          child: Column(
            children: [
              Pulse(infinite: true, child: const Icon(Icons.warning_amber_rounded, color: AppColors.warningRed, size: 32)),
              const SizedBox(height: 10),
              Text("HOLD FOR EMERGENCY SOS", style: GoogleFonts.russoOne(color: AppColors.warningRed, fontSize: 14, letterSpacing: 1)),
              const SizedBox(height: 5),
              Text("DISPATCHES SIGNAL TO ALL NEARBY NODES", style: TextStyle(color: AppColors.textDim, fontSize: 8)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTacticalGrid(MeshService mesh) {
    return Row(
      children: [
        _buildActionTile(
            icon: Icons.record_voice_over,
            label: "FLARE",
            sub: "Sonar Pulse",
            color: AppColors.sonarPurple,
            onTap: () async {
              _logAction("Acoustic flare command sent.");
              await locator<UltrasonicService>().transmitFrame("LNK:${mesh.apiService.currentUserId}");
            }
        ),
        const SizedBox(width: 15),
        _buildActionTile(
            icon: Icons.security,
            label: "STEALTH",
            sub: mesh.isPowerSaving ? "Masked" : "Active",
            color: AppColors.stealthOrange,
            onTap: () {
              mesh.togglePowerSaving(!mesh.isPowerSaving);
              _logAction("Stealth state changed to: ${!mesh.isPowerSaving}");
            }
        ),
      ],
    );
  }

  Widget _buildActionTile({required IconData icon, required String label, required String sub, required Color color, required VoidCallback onTap}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppColors.white05)
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 10),
              Text(label, style: GoogleFonts.russoOne(color: Colors.white, fontSize: 12)),
              Text(sub, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlliesList(List<SignalNode> nodes) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("DETECTION LOG", style: GoogleFonts.russoOne(color: AppColors.textDim, fontSize: 8)),
        const SizedBox(height: 10),
        ...nodes.map((n) => ListTile(
          dense: true,
          leading: Icon(Icons.hub, color: AppColors.gridCyan, size: 16),
          title: Text(n.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
          trailing: Text("LINKED", style: TextStyle(color: AppColors.gridCyan, fontSize: 8)),
        )),
      ],
    );
  }

  Widget _buildFooterActions(MeshService mesh) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppColors.warningRed.withOpacity(0.5)),
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
        ),
        icon: const Icon(Icons.power_settings_new, color: AppColors.warningRed, size: 18),
        label: Text("HALT ALL SIGNALS", style: GoogleFonts.orbitron(color: AppColors.warningRed, fontSize: 10)),
        onPressed: () {
          _logAction("EMERGENCY SHUTDOWN INITIATED.");
          mesh.stopAll();
        },
      ),
    );
  }

  Widget _buildRadarAnimation() {
    return AnimatedBuilder(
      animation: _radarController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: List.generate(2, (index) {
            double value = (_radarController.value + index / 2) % 1;
            return Container(
              width: 200 * value,
              height: 200 * value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.gridCyan.withOpacity(1 - value), width: 1),
              ),
            );
          }),
        );
      },
    );
  }
}