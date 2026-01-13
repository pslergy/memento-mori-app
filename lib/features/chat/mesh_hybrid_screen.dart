import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart'; // Для анимаций

import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:memento_mori_app/core/api_service.dart';

import 'package:memento_mori_app/ghost_input/ghost_controller.dart';
import 'package:memento_mori_app/ghost_input/ghost_keyboard.dart';

class MeshHybridScreen extends StatefulWidget {
  const MeshHybridScreen({super.key});

  @override
  State<MeshHybridScreen> createState() => _MeshHybridScreenState();
}

class _MeshHybridScreenState extends State<MeshHybridScreen> with SingleTickerProviderStateMixin {
  final MeshService _meshService = locator<MeshService>();
  final UltrasonicService _sonarService = locator<UltrasonicService>();
  final ScrollController _logScrollController = ScrollController();
  final GhostController _ghostController = GhostController();

  late AnimationController _radarController;

  bool _isKeyboardVisible = false;
  final List<String> _terminalLogs = [];
  StreamSubscription? _logSubscription;
  StreamSubscription? _sonarSubscription;

  bool _isScanning = false;
  bool _isAcousticTransmitting = false;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

    _logSubscription = _meshService.statusStream.listen((log) {
      if (mounted) {
        setState(() => _terminalLogs.add(log));
        _scrollToBottom();
      }
    });

    _sonarSubscription = _sonarService.sonarMessages.listen((msg) {
      _meshService.addLog("🎯 [SONAR]盟友信号 Captured: $msg");
      HapticFeedback.vibrate();
    });

    _sonarService.startListening();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _logSubscription?.cancel();
    _sonarSubscription?.cancel();
    _ghostController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(_logScrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  // 🔥 ОДНА КНОПКА ДЛЯ ВСЕГО (UX Mastery)
  void _startGlobalDiscovery() async {
    setState(() => _isScanning = true);
    HapticFeedback.mediumImpact();

    _meshService.addLog("📡 Re-initializing all sensors...");

    // 1. Сброс и старт Wi-Fi Mesh
    await NativeMeshService.forceReset();
    await Future.delayed(const Duration(seconds: 1));
    await _meshService.startDiscovery(SignalType.mesh);

    // 2. Старт Bluetooth
    await _meshService.startDiscovery(SignalType.bluetooth);

    // Таймер авто-выключения сканера через 30 сек
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) setState(() => _isScanning = false);
    });
  }

  void _handleFlare() async {
    if (_isAcousticTransmitting) return;
    setState(() => _isAcousticTransmitting = true);

    final myId = locator<ApiService>().currentUserId;
    _meshService.addLog("🔊 Emitting acoustic flare for auto-link...");

    await _sonarService.transmitFrame("LNK:$myId");

    if (mounted) setState(() => _isAcousticTransmitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final isLinked = mesh.isP2pConnected;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHUD(isLinked),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_isScanning) _buildRadarAnimation(),
                  _buildMainContent(mesh),
                ],
              ),
            ),
            _buildBottomControls(),
            if (_isKeyboardVisible)
              GhostKeyboard(controller: _ghostController, onSend: () {
                _meshService.sendAuto(content: _ghostController.value, receiverName: "Broadcast", chatId: "THE_BEACON_GLOBAL");
                _ghostController.clear();
                setState(() => _isKeyboardVisible = false);
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHUD(bool isLinked) {
    final role = NetworkMonitor().currentRole;
    bool isOnline = role == MeshRole.BRIDGE;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      decoration: BoxDecoration(
          color: const Color(0xFF0D0D0D),
          border: Border(bottom: BorderSide(color: isOnline ? Colors.greenAccent : (isLinked ? Colors.cyanAccent : Colors.redAccent), width: 0.5))
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isOnline ? "SECURED UPLINK" : (isLinked ? "MESH ACTIVE" : "SILENT MODE"),
                  style: GoogleFonts.orbitron(color: isOnline ? Colors.greenAccent : (isLinked ? Colors.cyanAccent : Colors.redAccent), fontSize: 14, fontWeight: FontWeight.bold)),
              Text(isOnline ? "Encrypted cloud bridge established" : "Local grid synchronization active",
                  style: TextStyle(color: Colors.white24, fontSize: 8)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white24),
            onPressed: () => _showSystemSettings(),
          )
        ],
      ),
    );
  }

  Widget _buildRadarAnimation() {
    return AnimatedBuilder(
      animation: _radarController,
      builder: (context, child) {
        return Container(
          width: 300 * _radarController.value,
          height: 300 * _radarController.value,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.cyanAccent.withOpacity(1 - _radarController.value), width: 2),
          ),
        );
      },
    );
  }

  Widget _buildMainContent(MeshService mesh) {
    return Column(
      children: [
        const SizedBox(height: 20),
        // Горизонтальный список союзников
        SizedBox(
          height: 120,
          child: mesh.nearbyNodes.isEmpty
              ? Center(child: Text("NO ALLIES IN RANGE", style: GoogleFonts.russoOne(color: Colors.white10, fontSize: 12)))
              : ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: mesh.nearbyNodes.length,
            itemBuilder: (context, i) => _AllyCard(node: mesh.nearbyNodes[i]),
          ),
        ),
        const Spacer(),
        // Центральная тактическая кнопка
        _buildActionCenter(),
        const Spacer(),
        _buildMiniTerminal(),
      ],
    );
  }

  Widget _buildActionCenter() {
    return Column(
      children: [
        GestureDetector(
          onTap: _isScanning ? null : _startGlobalDiscovery,
          child: Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isScanning ? Colors.white10 : Colors.cyanAccent.withOpacity(0.1),
                border: Border.all(color: _isScanning ? Colors.white24 : Colors.cyanAccent, width: 2),
                boxShadow: [if (!_isScanning) BoxShadow(color: Colors.cyanAccent.withOpacity(0.2), blurRadius: 20)]
            ),
            child: Icon(_isScanning ? Icons.sync : Icons.radar, color: Colors.cyanAccent, size: 30),
          ),
        ),
        const SizedBox(height: 15),
        Text(_isScanning ? "SCANNING SECTOR..." : "TAP TO SCAN",
            style: GoogleFonts.russoOne(color: Colors.cyanAccent, fontSize: 10, letterSpacing: 2)),
      ],
    );
  }

  Widget _buildMiniTerminal() {
    return Container(
      height: 100,
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white.withOpacity(0.05))),
      child: ListView.builder(
        controller: _logScrollController,
        itemCount: _terminalLogs.length,
        itemBuilder: (context, i) => Text("> ${_terminalLogs[i]}", style: GoogleFonts.robotoMono(color: Colors.greenAccent.withOpacity(0.5), fontSize: 9)),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(color: Color(0xFF0A0A0A)),
      child: Row(
        children: [
          // Кнопка Сонара
          _ProtocolButton(
            icon: Icons.record_voice_over,
            label: "FLARE",
            color: Colors.purpleAccent,
            onTap: _handleFlare,
            isActive: _isAcousticTransmitting,
          ),
          const SizedBox(width: 15),
          // Поле ввода сигнала
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _isKeyboardVisible = !_isKeyboardVisible),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(30)),
                child: AnimatedBuilder(
                  animation: _ghostController,
                  builder: (context, _) => Text(
                    _ghostController.value.isEmpty ? "Emit signal..." : _ghostController.value,
                    style: TextStyle(color: _ghostController.value.isEmpty ? Colors.white10 : Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSystemSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0D0D),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.power_settings_new, color: Colors.redAccent),
            title: const Text("HALT ALL TRANSMISSIONS"),
            onTap: () { _meshService.stopAll(); Navigator.pop(context); },
          ),
          ListTile(
            leading: const Icon(Icons.wifi_off, color: Colors.orangeAccent),
            title: const Text("RESET P2P STACK"),
            onTap: () { NativeMeshService.forceReset(); Navigator.pop(context); },
          ),
        ],
      ),
    );
  }
}

class _AllyCard extends StatelessWidget {
  final SignalNode node;
  const _AllyCard({required this.node});

  @override
  Widget build(BuildContext context) {
    bool isBT = node.type == SignalType.bluetooth;
    return FadeInRight(
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 15),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white.withOpacity(0.05))
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isBT ? Icons.bluetooth : Icons.wifi_tethering, color: isBT ? Colors.blueAccent : Colors.cyanAccent, size: 24),
            const SizedBox(height: 8),
            Text(node.name, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, minimumSize: const Size(60, 20), padding: EdgeInsets.zero),
              onPressed: () => NativeMeshService.connect(node.id),
              child: const Text("LINK", style: TextStyle(fontSize: 8, color: Colors.white)),
            )
          ],
        ),
      ),
    );
  }
}

class _ProtocolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool isActive;

  const _ProtocolButton({required this.icon, required this.label, required this.color, required this.onTap, this.isActive = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: isActive ? color : color.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: color.withOpacity(0.5))
            ),
            child: Icon(icon, color: isActive ? Colors.black : color, size: 20),
          ),
          const SizedBox(height: 4),
          Text(label, style: GoogleFonts.russoOne(color: color, fontSize: 8)),
        ],
      ),
    );
  }
}