import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/local_db_service.dart';
import '../../core/mesh_service.dart';
import '../../core/locator.dart';
import '../../core/api_service.dart';
import '../../core/native_mesh_service.dart';
import '../../core/models/signal_node.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import 'dart:convert';

class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  final GhostController _searchGhost = GhostController();
  final MeshService _mesh = locator<MeshService>();
  final ApiService _api = locator<ApiService>();
  List<SignalNode> _foundNodes = [];
  bool _isSearching = false;
  bool _showQR = false;
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _startScanning();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  void _startScanning() {
    // Обновляем список найденных узлов каждые 3 секунды
    _scanTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        setState(() {
          _foundNodes = _mesh.nearbyNodes.where((node) => 
            node.type == SignalType.bluetooth || node.type == SignalType.mesh
          ).toList();
        });
      }
    });
  }

  Future<void> _sendFriendRequest(String friendId, String? username) async {
    try {
      HapticFeedback.mediumImpact();
      
      await _mesh.sendFriendRequest(friendId, message: 'Привет! Добавь меня в друзья');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Friend request sent!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _getMyQRData() {
    final myId = _api.currentUserId;
    final myUsername = 'Nomad'; // Можно получить из Vault
    return jsonEncode({
      'type': 'FRIEND_QR',
      'id': myId,
      'username': myUsername,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text(
          'ADD FRIEND',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_showQR ? Icons.list : Icons.qr_code, color: Colors.cyanAccent),
            onPressed: () => setState(() => _showQR = !_showQR),
          ),
        ],
      ),
      body: _showQR
          ? _buildQRView()
          : Column(
              children: [
                // Поиск (Ghost-клавиатура для Tecno и др.)
                Container(
                  padding: const EdgeInsets.all(16),
                  child: GestureDetector(
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => GhostKeyboard(
                          controller: _searchGhost,
                          onSend: () {
                            setState(() {
                              _isSearching = _searchGhost.value.isNotEmpty;
                            });
                            Navigator.pop(context);
                          },
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.search, color: Colors.cyanAccent, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedBuilder(
                              animation: _searchGhost,
                              builder: (_, __) => Text(
                                _searchGhost.value.isEmpty
                                    ? 'Search by tactical name or ID...'
                                    : _searchGhost.value,
                                style: TextStyle(
                                  color: _searchGhost.value.isEmpty ? Colors.white38 : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Список найденных узлов
                Expanded(
                  child: _foundNodes.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.bluetooth_searching, size: 64, color: Colors.white24),
                              const SizedBox(height: 16),
                              const Text(
                                'SCANNING FOR NODES...',
                                style: TextStyle(color: Colors.white24, fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Found: ${_foundNodes.length}',
                                style: TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _foundNodes.length,
                          itemBuilder: (context, index) {
                            final node = _foundNodes[index];
                            final searchVal = _searchGhost.value;
                            final matchesSearch = searchVal.isEmpty ||
                                node.name.toLowerCase().contains(searchVal.toLowerCase()) ||
                                node.id.toLowerCase().contains(searchVal.toLowerCase());

                            if (!matchesSearch && _isSearching) return const SizedBox.shrink();

                            return Card(
                              color: const Color(0xFF1A1A1A),
                              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: node.type == SignalType.mesh
                                      ? Colors.green.withOpacity(0.3)
                                      : Colors.blue.withOpacity(0.3),
                                  child: Icon(
                                    node.type == SignalType.mesh ? Icons.wifi : Icons.bluetooth,
                                    color: node.type == SignalType.mesh ? Colors.green : Colors.blue,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  node.name,
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                ),
                                subtitle: Text(
                                  '${node.type.name} • ${node.id.substring(0, 8)}...',
                                  style: TextStyle(color: Colors.white38, fontSize: 10),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.person_add, color: Colors.cyanAccent),
                                  onPressed: () => _sendFriendRequest(node.id, node.name),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildQRView() {
    final qrData = _getMyQRData();
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'SHARE YOUR QR CODE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 250,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _api.currentUserId.substring(0, 16),
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            'Let others scan this QR code to add you',
            style: TextStyle(color: Colors.white38, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
