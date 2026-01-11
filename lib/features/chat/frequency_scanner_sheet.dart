import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;
import '../../core/models/signal_node.dart';
import '../../core/mesh_service.dart';
import '../../core/native_mesh_service.dart';
import 'conversation_screen.dart';

class FrequencyScannerSheet extends StatefulWidget {
  final SignalType type;
  const FrequencyScannerSheet({super.key, required this.type});

  @override
  State<FrequencyScannerSheet> createState() => _FrequencyScannerSheetState();
}

class _FrequencyScannerSheetState extends State<FrequencyScannerSheet> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    MeshService().startDiscovery(widget.type);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // Вспомогательный метод для показа ошибок
  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.red[900],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF050505),
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
        border: Border(top: BorderSide(color: Colors.redAccent, width: 0.5)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildSignalList()),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Transform.rotate(
                angle: _pulseController.value * 2 * math.pi,
                child: const Icon(Icons.radar, color: Colors.redAccent, size: 30),
              );
            },
          ),
          const SizedBox(width: 15),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("SCANNING FREQUENCIES", style: TextStyle(color: Colors.white.withOpacity(0.9), fontWeight: FontWeight.bold, letterSpacing: 1)),
              Text("PROTOCOL: ${widget.type.toString().split('.').last.toUpperCase()}", style: const TextStyle(color: Colors.redAccent, fontSize: 10, fontFamily: 'monospace')),
            ],
          ),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, color: Colors.white24), onPressed: () => Navigator.pop(context))
        ],
      ),
    );
  }

  Widget _buildSignalList() {
    return StreamBuilder<List<SignalNode>>(
      stream: MeshService().discoveryStream,
      builder: (context, snapshot) {
        final nodes = snapshot.data?.where((n) => n.type == widget.type).toList() ?? [];

        return ListView.builder(
          itemCount: nodes.length,
          itemBuilder: (context, index) {
            final node = nodes[index];
            // Имитируем тактический индикатор мощности
            int activityLevel = _calculateActivity(node);

            return ListTile(
              leading: _buildActivityIcon(activityLevel),
              title: Text(node.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Text(
                activityLevel > 3 ? "🔥 HIGH TRAFFIC" : "LOW SIGNAL",
                style: TextStyle(color: activityLevel > 3 ? Colors.orange : Colors.grey, fontSize: 10),
              ),
              trailing: Text("${node.metadata} ms", style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontFamily: 'monospace')),
              onTap: () => _handleConnection(node),
            );
          },
        );
      },
    );
  }
  Widget _buildActivityIcon(int level) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        width: 3,
        height: (i + 1) * 3.0,
        color: i < level ? Colors.greenAccent : Colors.grey[900],
      )),
    );
  }

  int _calculateActivity(SignalNode node) {
    // Здесь логика: если это группа и много участников - уровень выше
    if (node.isGroup) return 4;
    return 2;
  }

  void _handleConnection(SignalNode node) async {
    final confirm = await _showJoinDialog(node);
    if (confirm != true) return;

    try {
      if (node.type == SignalType.cloud) {
        // ✅ Теперь это сработает, так как метод больше не void
        final chatData = await MeshService().joinGroupRequest(node.id);

        if (mounted) {
          Navigator.pop(context); // Закрываем сканер

          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConversationScreen(
              friendId: node.isGroup ? '' : node.id,
              friendName: node.name,
              chatRoomId: chatData['id'], // Используем полученный ID
            ),
          ));
        }
      }
      // 3. Если это MESH (P2P)
      else if (node.type == SignalType.mesh) {
        await NativeMeshService.connect(node.metadata!);
        if (mounted) {
          Navigator.pop(context);
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConversationScreen(
              friendId: '',
              friendName: node.name,
              // В меше работаем без chatRoomId сервера
            ),
          ));
        }
      }
    } catch (e) {
      _showError("LINK SEVERED: CONNECTION REFUSED");
    }
  }

  Future<bool?> _showJoinDialog(SignalNode node) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D0D),
        title: Text("JOIN SQUAD?", style: TextStyle(fontFamily: 'Orbitron',color: Colors.white, fontSize: 14)),
        content: Text("Send request to link with ${node.name}?", style: const TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("ABORT", style: TextStyle(color: Colors.redAccent))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("LINK", style: TextStyle(color: Colors.greenAccent))),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: Colors.black,
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.security, color: Colors.green, size: 12),
          SizedBox(width: 8),
          Text("ENCRYPTED P2P CHANNEL", style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}