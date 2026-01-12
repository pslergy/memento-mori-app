import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

// Системные сервисы
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';

class MeshHybridScreen extends StatefulWidget {
  const MeshHybridScreen({super.key});

  @override
  State<MeshHybridScreen> createState() => _MeshHybridScreenState();
}

class _MeshHybridScreenState extends State<MeshHybridScreen> {
  final MeshService _meshService = locator<MeshService>();
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();

  // Локальный список логов для отображения в терминале
  final List<String> _terminalLogs = [];
  StreamSubscription? _logSubscription;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();

    // 1. Привязываем UI к MeshService
    _meshService.addListener(_onMeshUpdate);

    // 2. Подписка на системные логи терминала
    _logSubscription = _meshService.statusStream.listen((log) {
      if (mounted) {
        setState(() => _terminalLogs.add(log));
        _scrollToBottom();
      }
    });

    // 3. 🔥 ИСПРАВЛЕННЫЙ СЛУШАТЕЛЬ СОНАРА
    locator<UltrasonicService>().sonarMessages.listen((msg) {
      _meshService.addLog("👂 [Sonar] Detected signal: $msg");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.waves, color: Colors.white),
                const SizedBox(width: 12),
                Text("Acoustic Pulse: $msg",
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              ],
            ),
            backgroundColor: const Color(0xFFFF00FF), // Та самая Маджента
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating, // Делаем его "парящим" для стиля
          ),
        );
      }
    });

    // 4. Запускаем прослушку акустического эфира
    locator<UltrasonicService>().startListening();

    // 5. Запускаем фоновый Mesh-сервер Kotlin
    NativeMeshService.startBackgroundMesh();
  }

  @override
  void dispose() {
    _meshService.removeListener(_onMeshUpdate);
    _logSubscription?.cancel();
    _msgController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _onMeshUpdate() => setState(() {});

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- ОБРАБОТЧИКИ СОБЫТИЙ ---

  void _handleScan() async {
    setState(() => _isScanning = true);
    HapticFeedback.mediumImpact();
    await _meshService.startDiscovery(SignalType.mesh);
    await Future.delayed(const Duration(seconds: 15));
    if (mounted) setState(() => _isScanning = false);
  }

  void _handleSonar() async {
    HapticFeedback.vibrate();
    _meshService.addLog("🔊 SONAR: Emitting acoustic identity pulse...");
    await locator<UltrasonicService>().transmit("BEACON_ACTIVE");
  }

  void _handleBroadcast() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    HapticFeedback.lightImpact();
    await _meshService.sendAuto(
      content: text,
      receiverName: "Broadcast Node",
      chatId: "THE_BEACON_GLOBAL",
    );
    _msgController.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final bool isLinked = _meshService.isP2pConnected;
    final nodes = _meshService.nearbyNodes;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildConnectivityBar(isLinked),
          _buildTacticalControlPanel(), // НОВАЯ ПАНЕЛЬ С ТУМБЛЕРОМ
          _buildRadarSection(nodes),
          Expanded(child: _buildTerminalView()),
          _buildInputSection(),
        ],
      ),
    );
  }

  // --- UI БЛОКИ ---

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF121212),
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("MEMENTO MESH",
              style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 18, letterSpacing: 2)),
          const Text("HYBRID LINK PROTOCOL V2.5",
              style: TextStyle(color: Colors.white24, fontSize: 9, fontFamily: 'monospace')),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.waves, color: Colors.pinkAccent),
          tooltip: "Sonar Pulse",
          onPressed: _handleSonar,
        ),
        _isScanning
            ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent)))
            : IconButton(
          icon: const Icon(Icons.radar, color: Colors.cyanAccent),
          onPressed: _handleScan,
        ),
      ],
    );
  }

  Widget _buildConnectivityBar(bool isLinked) {
    final role = NetworkMonitor().currentRole;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      color: isLinked ? Colors.cyanAccent.withOpacity(0.1) : Colors.redAccent.withOpacity(0.1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: isLinked ? Colors.cyanAccent : Colors.redAccent),
              const SizedBox(width: 8),
              Text(isLinked ? "LINK ESTABLISHED" : "LINK SEVERED",
                  style: GoogleFonts.robotoMono(color: isLinked ? Colors.cyanAccent : Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
          Text("ROLE: ${role.name.toUpperCase()}",
              style: GoogleFonts.robotoMono(color: Colors.white38, fontSize: 10)),
        ],
      ),
    );
  }

  // НОВАЯ ПАНЕЛЬ УПРАВЛЕНИЯ
  Widget _buildTacticalControlPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Тумблер Stealth Mode
          Row(
            children: [
              Icon(Icons.security,
                  color: _meshService.isPowerSaving ? Colors.greenAccent : Colors.white24, size: 18),
              const SizedBox(width: 8),
              Text("STEALTH MODE",
                  style: GoogleFonts.robotoMono(color: Colors.white70, fontSize: 11)),
              Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: _meshService.isPowerSaving,
                  onChanged: (v) {
                    HapticFeedback.lightImpact();
                    _meshService.togglePowerSaving(v);
                  },
                  activeColor: Colors.greenAccent,
                ),
              ),
            ],
          ),
          // Индикатор Кармы
          Row(
            children: [
              const Icon(Icons.star, color: Colors.orangeAccent, size: 14), // Star -> star
              const SizedBox(width: 4),
              Text("KARMA: 124", // В реальности брать из статистики БД
                  style: GoogleFonts.robotoMono(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRadarSection(List<SignalNode> nodes) {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: nodes.isEmpty
          ? Center(child: Text("NO NODES DETECTED", style: GoogleFonts.robotoMono(color: Colors.white10, fontSize: 12)))
          : ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: nodes.length,
        itemBuilder: (context, index) => _NodeCard(node: nodes[index]),
      ),
    );
  }

  Widget _buildTerminalView() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ListView.builder(
        controller: _logScrollController,
        itemCount: _terminalLogs.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              "> ${_terminalLogs[index]}",
              style: GoogleFonts.robotoMono(
                  color: _terminalLogs[index].contains("ERROR") ? Colors.redAccent : Colors.cyanAccent.withOpacity(0.7),
                  fontSize: 11
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInputSection() {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 12, left: 16, right: 16, top: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _msgController,
              style: GoogleFonts.robotoMono(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: "EMIT SIGNAL...",
                hintStyle: GoogleFonts.robotoMono(color: Colors.white10, fontSize: 14),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send_rounded, color: Colors.cyanAccent),
            onPressed: _handleBroadcast,
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  final SignalNode node;
  const _NodeCard({required this.node});

  @override
  Widget build(BuildContext context) {
    final isBT = node.type == SignalType.bluetooth;

    // 🔥 ЛОГИКА "МАГНИТА": Если нода видит интернет, подсвечиваем её золотым
    final bool isMagnet = node.bridgeDistance < 5;
    final color = isMagnet ? Colors.orangeAccent : (isBT ? Colors.blueAccent : Colors.cyanAccent);

    return GestureDetector(
      onTap: () {
        HapticFeedback.heavyImpact();
        NativeMeshService.connect(node.id);
      },
      child: Container(
        width: 100,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(isMagnet ? 0.8 : 0.3), width: isMagnet ? 2 : 1),
          boxShadow: isMagnet ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 8)] : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isMagnet ? Icons.hub : (isBT ? Icons.bluetooth_searching : Icons.wifi_tethering),
                color: color, size: 24),
            const SizedBox(height: 8),
            Text(node.name,
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: isMagnet ? FontWeight.bold : FontWeight.normal),
                overflow: TextOverflow.ellipsis),
            Text(isMagnet ? "BRIDGE LINK" : "ISOLATED",
                style: TextStyle(color: color.withOpacity(0.7), fontSize: 7, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }
}