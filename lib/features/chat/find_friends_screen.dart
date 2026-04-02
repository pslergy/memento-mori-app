import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:animate_do/animate_do.dart';

import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/mesh_core_engine.dart';
import 'package:memento_mori_app/core/mesh_pairing_proximity_hint.dart';
import 'package:memento_mori_app/core/bluetooth_service.dart';
import 'package:memento_mori_app/core/locator.dart';
 // Используем наш новый класс цветов
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import '../../core/models/signal_node.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../friends/nearby_nodes_display.dart';
import '../theme/app_colors.dart';

class FindFriendsScreen extends StatefulWidget {
  const FindFriendsScreen({super.key});
  @override
  State<FindFriendsScreen> createState() => _FindFriendsScreenState();
}

class _FindFriendsScreenState extends State<FindFriendsScreen> {
  final ApiService _apiService = ApiService();
  final GhostController _searchGhost = GhostController();
  List<dynamic> _searchResults = [];
  bool _isLoading = false;
  bool _radarBusy = false;
  Timer? _debounce;
  Timer? _pairingBoostTimer;
  int _pairingBoostTicks = 0;
  static const int _kPairingBoostMaxTicks = 4;
  static const Duration _kPairingBoostInterval = Duration(seconds: 15);

  void _kickPairingTransportBoost() {
    try {
      locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
    } catch (_) {}
    unawaited(locator<MeshCoreEngine>().startNearbyPeersRadar());
  }

  void _startPairingTransportBoost() {
    _pairingBoostTimer?.cancel();
    _pairingBoostTicks = 0;
    _kickPairingTransportBoost();
    _pairingBoostTimer = Timer.periodic(_kPairingBoostInterval, (_) {
      if (!mounted) return;
      _kickPairingTransportBoost();
      _pairingBoostTicks++;
      if (_pairingBoostTicks >= _kPairingBoostMaxTicks) {
        _pairingBoostTimer?.cancel();
        _pairingBoostTimer = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    MeshPairingProximityHint.enter();
    _startPairingTransportBoost();
    _searchGhost.addListener(_onSearchChanged);
    // BLE + Wi‑Fi: mesh-only discovery does not run [_scanBluetooth] — nearby list stayed empty.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      locator<MeshCoreEngine>().startNearbyPeersRadar();
      try {
        unawaited(locator<BluetoothMeshService>().ensureGattServerForPairing());
      } catch (_) {}
    });
  }

  Future<void> _pulseNearbyRadar() async {
    setState(() => _radarBusy = true);
    try {
      await locator<MeshCoreEngine>().startNearbyPeersRadar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('BLE + mesh radar scan triggered'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _radarBusy = false);
    }
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (_searchGhost.value.length >= 3) {
        _search(_searchGhost.value);
      } else {
        setState(() => _searchResults = []);
      }
    });
  }

  Future<void> _search(String query) async {
    setState(() => _isLoading = true);
    try {
      final results = await _apiService.searchUsers(query);
      setState(() => _searchResults = results);
    } catch (e) {
      _logError("Cloud search offline. Relying on local radar.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // МЕТОД УСТАНОВКИ СВЯЗИ (Универсальный: Cloud или Mesh)
  Future<void> _establishLink(String userId, String username, {bool isMesh = false}) async {
    HapticFeedback.heavyImpact();
    setState(() => _isLoading = true);

    try {
      // 1. Создаем комнату (через прокси-бридж или напрямую)
      final chatData = await _apiService.findOrCreateChat(userId);

      // 2. Если это новый контакт, добавляем его в тактический Friend-лист (Offline Trust)
      // await locator<FriendService>().establishTrust(userId: userId, username: username);

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            friendId: userId,
            friendName: username,
            chatRoomId: chatData['id'],
          ),
        ),
      );
    } catch (e) {
      _logError("LINK FAILED: Secure handshake timed out.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshCoreEngine>();
    final neighbors =
        dedupeNearbyNodesForDisplay(List<SignalNode>.from(mesh.nearbyNodes));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'ESTABLISH_TRUST',
          style: TextStyle(
            letterSpacing: 2,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        actions: [
          if (_radarBusy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gridCyan),
              ),
            )
          else
            IconButton(
              tooltip: 'Scan for mesh peers nearby (BLE + Wi‑Fi)',
              icon: const Icon(Icons.radar),
              onPressed: _pulseNearbyRadar,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Material(
              color: Colors.amber.shade900.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        color: Colors.amber.shade200, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Bluetooth и GATT не мгновенные: до ~1 минуты на согласование рекламы и канала. '
                        'Держите устройства рядом. Контакт в списке может появиться до готовности ключей.',
                        style: TextStyle(
                          color: Colors.amber.shade50,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _buildSearchField(),
          Expanded(
            child: ListView(
              children: [
                // --- СЕКЦИЯ 1: LOCAL RADAR (MESH) ---
                if (neighbors.isNotEmpty) ...[
                  _buildSectionHeader("SIGNALS NEARBY (MESH / BLE)"),
                  ...neighbors.map((node) => _buildNeighborTile(node)),
                  const Divider(color: Colors.white10, height: 40),
                ],

                // --- СЕКЦИЯ 2: GLOBAL SEARCH (CLOUD) ---
                if (_searchResults.isNotEmpty) ...[
                  _buildSectionHeader("GLOBAL GRID RESULTS"),
                  ..._searchResults.map((user) => _buildUserTile(user)),
                ] else if (!_isLoading && neighbors.isEmpty)
                  _buildEmptyState(),

                if (_isLoading)
                  const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: AppColors.gridCyan))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: GestureDetector(
        onTap: () => _showKeyboard(),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.white10),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, color: AppColors.gridCyan, size: 20),
              const SizedBox(width: 12),
              AnimatedBuilder(
                animation: _searchGhost,
                builder: (context, _) => Text(
                  _searchGhost.value.isEmpty ? "Enter alias or email..." : _searchGhost.value,
                  style: TextStyle(color: _searchGhost.value.isEmpty ? AppColors.textDim : Colors.white, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textDim,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  // Плитка соседа (найден по Mesh)
  Widget _buildNeighborTile(SignalNode node) {
    return FadeInLeft(
      child: ListTile(
        leading: Pulse(
          infinite: true,
          child: const Center(child: Icon(Icons.hub, color: AppColors.gridCyan, size: 20)),
        ),
        title: Text(nearbyNodePrimaryLabel(node),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(
          nearbyNodeSubtitleLine(node),
          style: const TextStyle(color: AppColors.gridCyan, fontSize: 9),
        ),
        trailing: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.gridCyan, foregroundColor: Colors.black),
          onPressed: () => _establishLink(
              node.id, nearbyNodePrimaryLabel(node), isMesh: true),
          child: const Text("LINK", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
        ),
      ),
    );
  }

  // Плитка пользователя (найден в Cloud)
  Widget _buildUserTile(dynamic user) {
    return ListTile(
      leading: CircleAvatar(backgroundColor: AppColors.white05, child: const Icon(Icons.person, color: Colors.white38)),
      title: Text(user['username'], style: const TextStyle(color: Colors.white)),
      subtitle: const Text("Verified Identity", style: TextStyle(color: AppColors.textDim, fontSize: 9)),
      trailing: IconButton(
        icon: const Icon(Icons.add_moderator, color: AppColors.warningRed),
        onPressed: () => _establishLink(user['id'], user['username']),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 50),
          Icon(Icons.radar, size: 40, color: AppColors.textMuted),
          const SizedBox(height: 10),
          Text(
            "SILENCE IN SECTOR",
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const Text(
            "No local or global signals detected.",
            style: TextStyle(color: AppColors.textDim, fontSize: 10),
          ),
          const SizedBox(height: 12),
          const Text(
            "Tap the radar icon to run BLE + Wi‑Fi mesh scan (Location must be on).",
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textDim, fontSize: 9),
          ),
        ],
      ),
    );
  }

  void _logError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.warningRed));
  }

  void _showKeyboard() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GhostKeyboard(controller: _searchGhost, onSend: () => Navigator.pop(context)),
    );
  }

  @override
  void dispose() {
    _pairingBoostTimer?.cancel();
    MeshPairingProximityHint.leave();
    locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
    _debounce?.cancel();
    _searchGhost.dispose();
    super.dispose();
  }
}