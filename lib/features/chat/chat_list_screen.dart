import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/module_status_panel.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import 'package:memento_mori_app/features/chat/donate_screen.dart';
import 'package:memento_mori_app/features/profile/profile_screen.dart';
import 'package:memento_mori_app/features/chat/mesh_hybrid_screen.dart';
import 'package:memento_mori_app/features/friends/friends_list_screen.dart';
import '../../core/storage_service.dart';
import '../../core/websocket_service.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<dynamic> _allChats = [];
  bool _isLoading = true;
  StreamSubscription? _socketSubscription;

  @override
  void initState() {
    super.initState();
    _tabController =
        TabController(length: 4, vsync: this); // Добавили вкладку Friends
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });

    _loadChats();
    _listenToSocket();

    NetworkMonitor().onRoleChanged.listen((role) {
      if (mounted) _loadChats();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _socketSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadChats() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    // Ghost/Offline: log when ApiService not registered; UI still shows Beacon fallback
    if (!locator.isRegistered<ApiService>()) {
      logMissingFor('ChatListScreen._loadChats', requireApi: true);
    }

    try {
      // Retry логика для Tecno/Xiaomi (более агрессивные оптимизации батареи)
      List<dynamic> chats = [];
      int retries = 0;
      const maxRetries = 2;

      final api =
          locator.isRegistered<ApiService>() ? locator<ApiService>() : null;
      while (retries < maxRetries && chats.isEmpty && api != null) {
        try {
          chats = await api.getChats();
          if (chats.isNotEmpty) break; // Успешно загрузили
        } catch (e) {
          retries++;
          if (retries < maxRetries) {
            // Ждем перед повторной попыткой
            await Future.delayed(Duration(seconds: retries * 2));
          }
        }
      }

      // 🔥 ГАРАНТИЯ: Если список пустой - добавляем Beacon вручную
      if (chats.isEmpty) {
        chats = [
          {
            'id': 'THE_BEACON_GLOBAL',
            'name': 'THE BEACON (Global SOS)',
            'type': 'GLOBAL',
            'lastMessage': {
              'content': 'Mesh Active. Frequency secured.',
              'createdAt': DateTime.now().toIso8601String()
            },
          }
        ];
      }

      if (mounted) {
        setState(() {
          _allChats = chats;
          _isLoading = false;
        });
      }
    } catch (e) {
      // 🔥 FALLBACK: Если все попытки провалились - показываем хотя бы Beacon
      if (mounted) {
        setState(() {
          _allChats = [
            {
              'id': 'THE_BEACON_GLOBAL',
              'name': 'THE BEACON (Global SOS)',
              'type': 'GLOBAL',
              'lastMessage': {
                'content': 'Mesh Active. Frequency secured.',
                'createdAt': DateTime.now().toIso8601String()
              },
            }
          ];
          _isLoading = false;
        });
      }
    }
  }

  void _listenToSocket() {
    _socketSubscription = WebSocketService().stream.listen((data) {
      if (data['type'] == 'updateChatList' || data['type'] == 'newMessage') {
        _loadChats();
      }
    });
  }

  List<dynamic> get _directChats =>
      _allChats.where((c) => c != null && c['type'] == 'DIRECT').toList();
  List<dynamic> get _groupChats =>
      _allChats.where((c) => c != null && c['type'] == 'GROUP').toList();

  dynamic get _beaconChat {
    final matches = _allChats.where((c) =>
        c != null && (c['id'] == 'THE_BEACON_GLOBAL' || c['type'] == 'GLOBAL'));
    return matches.isEmpty ? null : matches.first;
  }

  // --- 🔥 ЛОГИКА СОНАРА (AUTO-LINK) ---
  void _emitHandshakeSignal() async {
    HapticFeedback.heavyImpact();
    final String myId = locator.isRegistered<ApiService>()
        ? locator<ApiService>().currentUserId
        : (await Vault.read('user_id') ?? 'GHOST');
    if (myId.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "🔊 EMITTING HANDSHAKE PULSE",
          style: TextStyle(
              fontSize: 10,
              color: Colors.purpleAccent,
              fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black,
        duration: Duration(seconds: 3),
      ),
    );

    // Сонар шлет команду на автоподключение
    await locator<UltrasonicService>().transmitFrame("LNK:$myId");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'GRID_COMMS',
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          // Кнопка Сонара (Handshake)
          IconButton(
            icon: Pulse(
                child: const Icon(Icons.spatial_audio_off,
                    color: Colors.purpleAccent),
                infinite: true),
            onPressed: _emitHandshakeSignal,
            tooltip: "Emit Handshake Pulse",
          ),
          IconButton(
            icon: const Icon(Icons.radar, color: Colors.cyanAccent),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MeshHybridScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.redAccent,
          labelStyle: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
          tabs: [
            Tab(text: "SIGNAL"),
            Tab(text: "SQUADS"),
            Tab(text: "NODES"),
            Tab(text: "FRIENDS"),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildTacticalHUD(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: ModuleStatusPanel(compact: true),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(),
                _buildChatList(
                    _groupChats, "No squads detected in this sector."),
                _buildChatList(_directChats, "No private links established."),
                const FriendsListScreen(), // Вкладка Friends
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- 🔥 ТАКТИЧЕСКИЙ HUD (HEADS-UP DISPLAY) ---
  Widget _buildTacticalHUD() {
    if (!locator.isRegistered<MeshService>()) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withOpacity(0.05),
          border: Border(
              bottom: BorderSide(
                  color: Colors.orangeAccent.withOpacity(0.3), width: 0.5)),
        ),
        child: const Center(
            child: Text("MODE: STEALTH (AIR-GAP)",
                style: TextStyle(color: Colors.orangeAccent, fontSize: 11))),
      );
    }
    final mesh = locator<MeshService>();
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final bool isOnline = snapshot.data == MeshRole.BRIDGE;
        final bool isMesh = mesh.isP2pConnected;

        Color themeColor = isOnline
            ? Colors.greenAccent
            : (isMesh ? Colors.cyanAccent : Colors.orangeAccent);
        String statusText = isOnline
            ? "UPLINK: SECURED"
            : (isMesh ? "GRID: ACTIVE (P2P)" : "MODE: STEALTH (AIR-GAP)");

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: themeColor.withOpacity(0.05),
            border: Border(
                bottom:
                    BorderSide(color: themeColor.withOpacity(0.3), width: 0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PulseDot(color: themeColor),
              const SizedBox(width: 10),
              Text(
                statusText,
                style: TextStyle(
                  color: themeColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  fontFamily: 'monospace',
                ),
              ),
              if (isMesh) ...[
                const SizedBox(width: 15),
                Text(
                  "|  RELAYS: ${mesh.nearbyNodes.length}",
                  style: TextStyle(
                      color: themeColor.withOpacity(0.5), fontSize: 9),
                ),
              ]
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalTab() {
    if (_isLoading)
      return const Center(
          child: CircularProgressIndicator(color: Colors.redAccent));

    return RefreshIndicator(
      onRefresh: _loadChats,
      backgroundColor: Colors.grey[900],
      color: Colors.redAccent,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_beaconChat != null) _buildBeaconTile(_beaconChat),
          _buildDonateTile(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.waves, color: Colors.white24, size: 12),
                const SizedBox(width: 8),
                const Text(
                  "NEIGHBORHOOD FREQUENCIES",
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          FutureBuilder<List<dynamic>>(
            future: locator.isRegistered<ApiService>()
                ? locator<ApiService>().getTrendingBranches()
                : Future.value(<dynamic>[]),
            builder: (context, snapshot) {
              final branches = snapshot.data ?? [];
              if (branches.isEmpty) return const SizedBox.shrink();
              return Column(
                  children: branches
                      .where((b) => b['id'] != 'THE_BEACON_GLOBAL')
                      .map((b) => _buildBranchTile(b))
                      .toList());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBeaconTile(dynamic chat) {
    return FadeInLeft(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Colors.redAccent.withOpacity(0.15), Colors.transparent]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: Pulse(
              child: const Icon(Icons.warning_amber_rounded,
                  color: Colors.redAccent, size: 28),
              infinite: true),
          title: const Text(
            "THE BEACON",
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          subtitle: const Text("GLOBAL EMERGENCY CHANNEL // BROADCASTING",
              style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 8,
                  fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => _openChat('GLOBAL', 'THE BEACON', 'THE_BEACON_GLOBAL'),
        ),
      ),
    );
  }

  Widget _buildDonateTile() {
    return FadeInLeft(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Colors.greenAccent.withOpacity(0.12), Colors.transparent],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: const Icon(Icons.volunteer_activism,
              color: Colors.greenAccent, size: 28),
          title: const Text(
            "SUPPORT / DONATE",
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          subtitle: const Text(
            "CRYPTO • DONATION LINK",
            style: TextStyle(
              color: Colors.greenAccent,
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DonateScreen()),
          ),
        ),
      ),
    );
  }

  Widget _buildChatList(List<dynamic> chats, String emptyMsg) {
    if (_isLoading)
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    if (chats.isEmpty) {
      return Center(
        child: Text(
          emptyMsg,
          style: const TextStyle(
            color: Colors.white10,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: chats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final chat = chats[index];
        final String title = chat['type'] == 'DIRECT'
            ? (chat['otherUser']?['username'] ?? 'Anonymous')
            : (chat['name'] ?? 'Squad Alpha');

        final String sub = chat['type'] == 'DIRECT'
            ? "Direct Link established"
            : "Mesh Squad Active";

        return ListTile(
          tileColor: const Color(0xFF0A0A0A),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: CircleAvatar(
            // 🔥 ИСПРАВЛЕНО ЗДЕСЬ:
            backgroundColor: Colors.white.withOpacity(0.05),
            child: Icon(
                chat['type'] == 'GROUP'
                    ? Icons.groups_3_outlined
                    : Icons.person_outline,
                color: Colors.white38),
          ),
          title: Text(
            title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            sub,
            style: const TextStyle(
              color: Colors.white24,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
          onTap: () => _openChat(
              chat['type'] == 'DIRECT' ? chat['otherUser']['id'] : '',
              title,
              chat['id']),
        );
      },
    );
  }

  Widget _buildBranchTile(dynamic branch) {
    return ListTile(
      leading: const Icon(Icons.radar, color: Colors.white10, size: 20),
      title: Text(branch['name'] ?? 'Public Freq',
          style: const TextStyle(color: Colors.white70, fontSize: 14)),
      subtitle: const Text("Relaying nearby signals",
          style: TextStyle(color: Colors.white10, fontSize: 10)),
      onTap: () => _openChat('', branch['name'], branch['id']),
    );
  }

  void _openChat(String friendId, String name, String? roomId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConversationScreen(
          friendId: friendId, friendName: name, chatRoomId: roomId),
    ));
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                  color: widget.color,
                  blurRadius: 4 + _controller.value * 6,
                  spreadRadius: _controller.value * 2)
            ]),
      ),
    );
  }
}
