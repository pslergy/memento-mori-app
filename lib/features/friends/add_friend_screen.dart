import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/mesh_core_engine.dart';
import '../../core/mesh_pairing_proximity_hint.dart';
import '../../core/bluetooth_service.dart';
import '../../core/decoy/app_mode.dart';
import '../../core/di_restart_scope.dart';
import '../../core/storage_service.dart';
import '../../core/locator.dart';
import '../../core/api_service.dart';
import '../../core/models/signal_node.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import 'dart:convert';

import 'friend_qr_payload.dart';
import 'friend_qr_scan_screen.dart';
import 'nearby_nodes_display.dart';

class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  final GhostController _searchGhost = GhostController();
  bool _sessionHooksInstalled = false;

  MeshCoreEngine get _mesh => locator<MeshCoreEngine>();
  ApiService get _api => locator<ApiService>();

  List<SignalNode> _foundNodes = [];
  bool _isSearching = false;
  bool _showQR = false;
  Timer? _scanTimer;
  /// ~1 мин усиленных попыток: реклама + радар (см. комментарий в UI).
  Timer? _pairingBoostTimer;
  int _pairingBoostTicks = 0;
  static const int _kPairingBoostMaxTicks = 4;
  static const Duration _kPairingBoostInterval = Duration(seconds: 15);
  String _myQrUsername = 'User';
  /// Один исходящий запрос за раз — без двойных срабатываний автоматов.
  bool _friendRequestInFlight = false;
  String? _friendRequestTargetId;

  void _kickPairingTransportBoost() {
    if (!locator.isRegistered<MeshCoreEngine>()) return;
    try {
      locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
    } catch (_) {}
    unawaited(_mesh.startNearbyPeersRadar());
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSessionAndStart());
  }

  /// Field init used to call [locator] before SESSION was registered (e.g. first frame races).
  void _ensureSessionAndStart() {
    if (!mounted) return;
    if (!locator.isRegistered<MeshCoreEngine>()) {
      final mode = RestartedAppModeScope.of(context);
      if (mode != AppMode.INVALID) {
        try {
          setupSessionLocator(mode);
        } catch (e, st) {
          debugPrint('AddFriendScreen: setupSessionLocator failed: $e\n$st');
        }
      }
    }
    if (!locator.isRegistered<MeshCoreEngine>() ||
        !locator.isRegistered<ApiService>()) {
      if (mounted) setState(() {});
      return;
    }
    if (_sessionHooksInstalled) return;
    _sessionHooksInstalled = true;
    MeshPairingProximityHint.enter();
    try {
      locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
    } catch (_) {}
    _startPairingTransportBoost();
    _refreshQrUsername();
    _startScanning();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        unawaited(_mesh.startNearbyPeersRadar());
        unawaited(locator<BluetoothMeshService>().ensureGattServerForPairing());
      } catch (_) {}
    });
  }

  Future<void> _refreshQrUsername() async {
    final n = await Vault.read('user_name');
    if (!mounted) return;
    final t = n?.trim() ?? '';
    setState(() => _myQrUsername = t.isNotEmpty ? t : 'User');
  }

  @override
  void dispose() {
    _pairingBoostTimer?.cancel();
    if (_sessionHooksInstalled) {
      MeshPairingProximityHint.leave();
      try {
        if (locator.isRegistered<BluetoothMeshService>()) {
          locator<BluetoothMeshService>().requestAdvertisingIntentRefresh();
        }
      } catch (_) {}
    }
    _scanTimer?.cancel();
    super.dispose();
  }

  void _startScanning() {
    // Обновляем список найденных узлов каждые 3 секунды
    _scanTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        setState(() {
          final raw = _mesh.nearbyNodes.where((node) =>
              node.type == SignalType.bluetooth || node.type == SignalType.mesh);
          _foundNodes = dedupeNearbyNodesForDisplay(raw.toList());
        });
      }
    });
  }

  Future<void> _pulseNearbyRadar() async {
    await _mesh.startNearbyPeersRadar();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scanning for mesh peers (BLE + Wi‑Fi)…'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _openQrScanner() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const FriendQrScanScreen()),
    );
    if (!mounted || raw == null) return;
    final payload = parseFriendQrPayload(raw);
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not a valid friend QR (expected Memento Mori FRIEND_QR).'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (!isFriendQrFresh(payload)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This QR looks expired. Ask your friend to show a fresh one.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (payload.userId == _api.currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That\'s your own QR — scan someone else\'s.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final name = payload.username ?? payload.userId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Send friend request?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Add $name?\n\nID: ${payload.userId.length > 12 ? '${payload.userId.substring(0, 12)}…' : payload.userId}',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send', style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _sendFriendRequest(payload.userId, payload.username);
    }
  }

  Future<void> _sendFriendRequest(String friendId, String? username) async {
    if (_friendRequestInFlight) return;
    setState(() {
      _friendRequestInFlight = true;
      _friendRequestTargetId = friendId;
    });
    try {
      HapticFeedback.mediumImpact();

      await _mesh.sendFriendRequest(friendId,
          message: 'Привет! Добавь меня в друзья', peerUsername: username);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Заявка отправлена. Если пир рядом, подтверждение и ключи могут дойти до ~1 минуты — '
              'зависит от BLE/Wi‑Fi Direct.',
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 5),
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
    } finally {
      if (mounted) {
        setState(() {
          _friendRequestInFlight = false;
          _friendRequestTargetId = null;
        });
      } else {
        _friendRequestInFlight = false;
        _friendRequestTargetId = null;
      }
    }
  }

  String _getMyQRData() {
    final myId = _api.currentUserId;
    return jsonEncode({
      'type': 'FRIEND_QR',
      'id': myId,
      'username': _myQrUsername,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionReady = locator.isRegistered<MeshCoreEngine>() &&
        locator.isRegistered<ApiService>();
    if (!sessionReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSessionAndStart();
      });
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
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Colors.redAccent),
        ),
      );
    }

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
            tooltip: 'Scan mesh peers nearby (BLE + Wi‑Fi)',
            icon: const Icon(Icons.radar, color: Colors.cyanAccent),
            onPressed: _pulseNearbyRadar,
          ),
          IconButton(
            tooltip: 'Scan friend QR',
            icon: const Icon(Icons.qr_code_scanner, color: Colors.cyanAccent),
            onPressed: _openQrScanner,
          ),
          IconButton(
            tooltip: _showQR ? 'Show nearby list' : 'Show my QR',
            icon: Icon(_showQR ? Icons.list : Icons.qr_code, color: Colors.cyanAccent),
            onPressed: () => setState(() => _showQR = !_showQR),
          ),
        ],
      ),
      body: _showQR
          ? _buildQRView()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Material(
                    color: Colors.amber.shade900.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.amber.shade200, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Bluetooth не мгновенный: до ~1 минуты на согласование рекламы и GATT. '
                              'Держите телефоны рядом, Bluetooth включён. Заявка в друзья может отобразиться '
                              'раньше, чем готов канал для обмена ключами (DR_DH) — это нормально.',
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

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _friendRequestInFlight ? null : _openQrScanner,
                      icon: _friendRequestInFlight
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.cyanAccent,
                              ),
                            )
                          : const Icon(Icons.qr_code_scanner, color: Colors.cyanAccent),
                      label: const Text(
                        'SCAN QR TO ADD (RECOMMENDED)',
                        style: TextStyle(
                          color: Colors.cyanAccent,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: Colors.cyanAccent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Nearby list uses mesh/BLE discovery — nick search only filters that list. QR works offline in person.',
                    style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),

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
                                'SCANNING FOR NEARBY NODES…',
                                style: TextStyle(color: Colors.white24, fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Found: ${_foundNodes.length} — or use QR above',
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
                            final plat = node.blePlatformName?.toLowerCase() ?? '';
                            final matchesSearch = searchVal.isEmpty ||
                                node.name.toLowerCase().contains(searchVal.toLowerCase()) ||
                                node.id.toLowerCase().contains(searchVal.toLowerCase()) ||
                                (plat.isNotEmpty && plat.contains(searchVal.toLowerCase()));

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
                                  nearbyNodePrimaryLabel(node),
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                ),
                                subtitle: Text(
                                  nearbyNodeSubtitleLine(node),
                                  style: TextStyle(color: Colors.white38, fontSize: 10),
                                ),
                                trailing: IconButton(
                                  icon: (_friendRequestInFlight &&
                                          _friendRequestTargetId == node.id)
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.cyanAccent,
                                          ),
                                        )
                                      : const Icon(Icons.person_add, color: Colors.cyanAccent),
                                  onPressed: _friendRequestInFlight
                                      ? null
                                      : () => _sendFriendRequest(
                                            node.id, nearbyNodePrimaryLabel(node)),
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
