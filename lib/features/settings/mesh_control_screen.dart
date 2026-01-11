import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/api_service.dart';
import '../../core/locator.dart';
import '../../core/models/signal_node.dart';
import '../../core/native_mesh_service.dart';
import '../../core/ultrasonic_service.dart';
import '../chat/conversation_screen.dart';
import '../chat/frequency_scanner_sheet.dart';

class MeshControlScreen extends StatefulWidget {
  const MeshControlScreen({super.key});

  @override
  State<MeshControlScreen> createState() => _MeshControlScreenState();
}

class _MeshControlScreenState extends State<MeshControlScreen> {
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Подписка на стрим логов из сервиса
    context.read<MeshService>().statusStream.listen((log) {
      if (mounted) {
        setState(() {
          _logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second} > $log");
        });
      }
    });
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    await [
      Permission.location,
      Permission.nearbyWifiDevices,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.ignoreBatteryOptimizations, // Важно для Tecno
    ].request();
  }

  void _openScanner(SignalType type) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FrequencyScannerSheet(type: type),
    );
  }

  void _connectToNode(SignalNode node) async {
    // 1. Достаем сервисы через локатор
    final meshService = locator<MeshService>();
    final api = locator<ApiService>();

    // 2. Получаем наш ID (Личность)
    final myId = api.currentUserId;

    // 🛡️ ПРОВЕРКА 1: Личность не установлена
    if (myId.isEmpty) {
      meshService.addLog("❌ ERROR: Identity unknown. Unlock via 3301 first.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Identification required. Please unlock via 3301."),
              backgroundColor: Colors.redAccent,
            )
        );
      }
      return;
    }

    // 📡 ПРОВЕРКА 2: Валидация целевого адреса (Защита от краша "Empty Address")
    // Мы берем metadata (MAC-адрес), если он пуст — берем id.
    final String targetAddress = (node.metadata != null && node.metadata!.isNotEmpty)
        ? node.metadata!
        : node.id;

    if (targetAddress.isEmpty) {
      meshService.addLog("❌ ERROR: Target node has no physical address.");
      return;
    }

    // 🧠 ГЕНЕРАЦИЯ ЕДИНОГО ТАКТИЧЕСКОГО ID
    // Сортируем ID, чтобы у обоих устройств чат назывался одинаково
    List<String> ids = [myId, node.id];
    ids.sort();
    final String sharedOfflineId = "GHOST_${ids.join('_')}";

    // --- ЛОГИКА ПОДКЛЮЧЕНИЯ ---

    if (node.type == SignalType.bluetooth) {
      // КЕЙС: BLUETOOTH
      meshService.addLog("🦷 Linking via Bluetooth Pulse: ${node.name}");
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ConversationScreen(
          friendId: node.id,
          friendName: node.name,
          chatRoomId: sharedOfflineId,
        ),
      ));
    }
    else if (node.type == SignalType.mesh) {
      // КЕЙС: WI-FI DIRECT MESH
      meshService.addLog("📡 Establishing Wi-Fi Link: $targetAddress");

      try {
        // Вызываем нативный метод с ПРОВЕРЕННЫМ адресом
        await NativeMeshService.connect(targetAddress);

        // Если команда прошла успешно, открываем терминал чата
        if (mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConversationScreen(
              friendId: node.id,
              friendName: node.name,
              chatRoomId: sharedOfflineId,
            ),
          ));
        }
      } catch (e) {
        meshService.addLog("❌ Hardware Connection Error: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Link Refused: $e"))
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meshService = context.watch<MeshService>();
    final nodes = meshService.nearbyNodes;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text("TACTICAL LINK", style: TextStyle(fontFamily: 'Orbitron',letterSpacing: 2, fontSize: 16)),
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildRadarHeader(nodes.length),

          // 🔥 ТАКТИЧЕСКАЯ ПЛАШКА: ПРЕДУПРЕЖДЕНИЕ О GPS
          if (!meshService.isGpsEnabled) _buildGpsWarningBanner(),

          Expanded(
            child: nodes.isEmpty
                ? _buildEmptyScanner()
                : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: nodes.length,
              itemBuilder: (context, index) => _buildNearbyNodeTile(nodes[index]),
            ),
          ),

          const Divider(color: Colors.white10, height: 1),

          // ПАНЕЛЬ УПРАВЛЕНИЯ
          _buildControlPanel(meshService),
        ],
      ),
    );
  }

  // Виджет баннера при выключенном GPS
  Widget _buildGpsWarningBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.location_off, color: Colors.redAccent, size: 24),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("GPS SENSOR OFFLINE",
                    style: GoogleFonts.russoOne(color: Colors.redAccent, fontSize: 12)),
                const SizedBox(height: 2),
                const Text(
                  "Nearby discovery is blocked by Android OS. Enable Location Services to scan.",
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarHeader(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      color: const Color(0xFF0A0A0A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.radar, color: Colors.greenAccent, size: 18),
              const SizedBox(width: 10),
              Text("PASSIVE RADAR", style: GoogleFonts.russoOne(fontSize: 14, color: Colors.white70)),
            ],
          ),
          Text(
            count > 0 ? "NODES: $count" : "SCANNING...",
            style: TextStyle(
                color: count > 0 ? Colors.greenAccent : Colors.white24,
                fontSize: 10,
                fontWeight: FontWeight.bold
            ),
          )
        ],
      ),
    );
  }

  Widget _buildNearbyNodeTile(SignalNode node) {
    return Card(
      color: const Color(0xFF111111),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.white10)),
      child: ListTile(
        leading: Icon(
          node.type == SignalType.bluetooth ? Icons.bluetooth : Icons.wifi_tethering,
          color: Colors.greenAccent.withOpacity(0.5),
        ),
        title: Text(node.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        subtitle: Text(node.type.name.toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 10)),
        trailing: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black, visualDensity: VisualDensity.compact),
          onPressed: () => _connectToNode(node),
          child: const Text("LINK", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildEmptyScanner() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 1, color: Colors.white10)),
          const SizedBox(height: 20),
          Text("MONITORING AIRWAVES...", style: GoogleFonts.robotoMono(color: Colors.white24, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildControlPanel(MeshService meshService) {
    return Container(
      padding: const EdgeInsets.all(20),
      color: const Color(0xFF0D0D0D),
      child: Column(
        children: [
          _buildToggleRow(
            label: "THE CHAIN (MESH NETWORK)",
            value: meshService.isMeshEnabled,
            onChanged: (v) => meshService.toggleMesh(v),
            color: Colors.greenAccent,
          ),
          const SizedBox(height: 10),
          _buildToggleRow(
            label: "ADAPTIVE POWER (BATTERY SAVER)",
            value: meshService.isPowerSaving,
            onChanged: (v) => meshService.togglePowerSaving(v),
            color: Colors.orangeAccent,
          ),
          const SizedBox(height: 20),

          Opacity(
            opacity: meshService.isMeshEnabled ? 1.0 : 0.3,
            child: AbsorbPointer(
              absorbing: !meshService.isMeshEnabled,
              child: _buildManualButtons(meshService),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManualButtons(MeshService meshService) {
    return Column(
      children: [
        Row(
          children: [
            _buildProtocolButton(
                icon: Icons.cloud_outlined,
                label: "CLOUD",
                color: Colors.greenAccent,
                onTap: () => _openScanner(SignalType.cloud)
            ),
            const SizedBox(width: 12),
            _buildProtocolButton(
                icon: Icons.wifi_tethering,
                label: "MESH",
                color: Colors.cyanAccent,
                onTap: () => _openScanner(SignalType.mesh)
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _buildProtocolButton(
                icon: Icons.bluetooth_searching,
                label: "BT",
                color: Colors.blueAccent,
                onTap: () => _openScanner(SignalType.bluetooth)
            ),
            const SizedBox(width: 12),
            // КНОПКА SONAR
            Expanded(
              child: InkWell(
                onTap: () async {
                  try {
                    await UltrasonicService().transmit("PING_NODE");
                    meshService.addLog("🔊 SONAR: Acoustic pulse emitted.");
                  } catch (e) {
                    meshService.addLog("❌ SONAR ERROR: $e");
                  }
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.purpleAccent.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.purpleAccent.withOpacity(0.2)),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.record_voice_over, color: Colors.purpleAccent, size: 20),
                      const SizedBox(height: 4),
                      Text("SONAR",
                          style: TextStyle(fontFamily: 'Orbitron',color: Colors.purpleAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildHaltButton(meshService),
      ],
    );
  }

  Widget _buildProtocolButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(fontFamily: 'Orbitron',color: color, fontSize: 9, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleRow({required String label, required bool value, required ValueChanged<bool> onChanged, required Color color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: GoogleFonts.russoOne(color: Colors.white70, fontSize: 10)),
        Switch(value: value, onChanged: onChanged, activeColor: color, activeTrackColor: color.withOpacity(0.3)),
      ],
    );
  }

  Widget _buildHaltButton(MeshService meshService) {
    return InkWell(
      onTap: () => meshService.stopAll(),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.stop_circle, color: Colors.redAccent, size: 20),
            const SizedBox(width: 10),
            Text("EMERGENCY HALT: KILL ALL SIGNALS",
                style: TextStyle(fontFamily: 'Orbitron',color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}