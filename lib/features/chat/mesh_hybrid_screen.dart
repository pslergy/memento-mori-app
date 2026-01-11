import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

// Импорты твоих системных сервисов
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';
import 'package:memento_mori_app/core/network_monitor.dart';

class MeshHybridScreen extends StatefulWidget {
  const MeshHybridScreen({super.key});

  @override
  State<MeshHybridScreen> createState() => _MeshHybridScreenState();
}

class _MeshHybridScreenState extends State<MeshHybridScreen> {
  final MeshService _meshService = locator<MeshService>();
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();

  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    // Привязываем UI к обновлениям MeshService
    _meshService.addListener(_onMeshUpdate);

    // Автоматическая прокрутка логов при поступлении новых записей
    _meshService.statusStream.listen((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _meshService.removeListener(_onMeshUpdate);
    _msgController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _onMeshUpdate() {
    if (mounted) setState(() {});
  }

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

  void _handleScan() async {
    setState(() => _isScanning = true);
    HapticFeedback.mediumImpact();

    // Запускаем оба протокола через единый сервис
    await _meshService.startDiscovery(SignalType.mesh);
    await _meshService.startDiscovery(SignalType.bluetooth);

    // Имитируем активную фазу сканирования
    await Future.delayed(const Duration(seconds: 15));
    if (mounted) setState(() => _isScanning = false);
  }

  void _handleBroadcast() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    HapticFeedback.lightImpact();

    // Используем "Умную отправку" (Cloud -> WiFi Burst -> BLE)
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
          _buildRadarSection(nodes),
          Expanded(child: _buildTerminalView()),
          _buildInputSection(),
        ],
      ),
    );
  }

  // --- UI КОМПОНЕНТЫ ---

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF121212),
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("MEMENTO MESH",
              style: GoogleFonts.orbitron(color: Colors.cyanAccent, fontSize: 18, letterSpacing: 2)),
          const Text("HYBRID LINK PROTOCOL V2.4",
              style: TextStyle(color: Colors.white24, fontSize: 9, fontFamily: 'monospace')),
        ],
      ),
      actions: [
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

  Widget _buildRadarSection(List<SignalNode> nodes) {
    return Container(
      height: 120,
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
    return StreamBuilder<String>(
      stream: _meshService.statusStream,
      builder: (context, snapshot) {
        // Мы используем данные из внутреннего списка MeshService для полной истории
        final allLogs = _meshService.nearbyNodes; // Здесь лучше иметь доступ к списку логов

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
            itemCount: 100, // Пример. В реальности: _meshService.logs.length
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  "> [SYSLOG] Node update at delta-t", // Пример лога
                  style: GoogleFonts.robotoMono(color: Colors.cyanAccent.withOpacity(0.7), fontSize: 11),
                ),
              );
            },
          ),
        );
      },
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
                hintText: "ENTER COMMAND...",
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
    final color = isBT ? Colors.blueAccent : Colors.cyanAccent;

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
          border: Border.all(color: color.withOpacity(0.3), width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isBT ? Icons.bluetooth_searching : Icons.wifi_tethering, color: color, size: 24),
            const SizedBox(height: 8),
            Text(node.name,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
            Text(node.id.length > 8 ? node.id.substring(0, 8) : node.id,
                style: TextStyle(color: color.withOpacity(0.5), fontSize: 8, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }
}