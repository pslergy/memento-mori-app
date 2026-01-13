import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animate_do/animate_do.dart';

import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import 'package:memento_mori_app/features/profile/profile_screen.dart';
import 'package:memento_mori_app/features/chat/mesh_hybrid_screen.dart';
import '../../core/websocket_service.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;

  List<dynamic> _allChats = [];
  bool _isLoading = true;
  StreamSubscription? _socketSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() {}); });

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

    try {
      final chats = await _apiService.getChats();
      if (mounted) {
        setState(() {
          _allChats = chats;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _listenToSocket() {
    _socketSubscription = WebSocketService().stream.listen((data) {
      if (data['type'] == 'updateChatList' || data['type'] == 'newMessage') {
        _loadChats();
      }
    });
  }

  List<dynamic> get _directChats => _allChats.where((c) => c != null && c['type'] == 'DIRECT').toList();
  List<dynamic> get _groupChats => _allChats.where((c) => c != null && c['type'] == 'GROUP').toList();

  dynamic get _beaconChat {
    final matches = _allChats.where((c) => c != null && (c['id'] == 'THE_BEACON_GLOBAL' || c['type'] == 'GLOBAL'));
    return matches.isEmpty ? null : matches.first;
  }

  // --- 🔥 ЛОГИКА СОНАРА (AUTO-LINK) ---
  void _emitHandshakeSignal() async {
    HapticFeedback.heavyImpact();
    final String myId = _apiService.currentUserId;
    final String shortId = myId.length > 6 ? myId.substring(myId.length - 6) : myId;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("🔊 EMITTING HANDSHAKE PULSE: Nomad #$shortId",
            style: GoogleFonts.russoOne(fontSize: 10, color: Colors.purpleAccent)),
        backgroundColor: Colors.black,
        duration: const Duration(seconds: 3),
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
        title: Text('GRID_COMMS', style: GoogleFonts.orbitron(letterSpacing: 2, fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          // Кнопка Сонара (Handshake)
          IconButton(
            icon: Pulse(child: const Icon(Icons.spatial_audio_off, color: Colors.purpleAccent), infinite: true),
            onPressed: _emitHandshakeSignal,
            tooltip: "Emit Handshake Pulse",
          ),
          IconButton(
            icon: const Icon(Icons.radar, color: Colors.cyanAccent),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MeshHybridScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.redAccent,
          labelStyle: GoogleFonts.russoOne(fontSize: 10, letterSpacing: 1),
          tabs: const [
            Tab(text: "SIGNAL"),
            Tab(text: "SQUADS"),
            Tab(text: "NODES"),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildTacticalHUD(), // 🔥 Вместо старого баннера
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(),
                _buildChatList(_groupChats, "No squads detected in this sector."),
                _buildChatList(_directChats, "No private links established."),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- 🔥 ТАКТИЧЕСКИЙ HUD (HEADS-UP DISPLAY) ---
  Widget _buildTacticalHUD() {
    final mesh = locator<MeshService>();
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final bool isOnline = snapshot.data == MeshRole.BRIDGE;
        final bool isMesh = mesh.isP2pConnected;

        Color themeColor = isOnline ? Colors.greenAccent : (isMesh ? Colors.cyanAccent : Colors.orangeAccent);
        String statusText = isOnline ? "UPLINK: SECURED" : (isMesh ? "GRID: ACTIVE (P2P)" : "MODE: STEALTH (AIR-GAP)");

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: themeColor.withOpacity(0.05),
            border: Border(bottom: BorderSide(color: themeColor.withOpacity(0.3), width: 0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PulseDot(color: themeColor),
              const SizedBox(width: 10),
              Text(statusText, style: GoogleFonts.robotoMono(color: themeColor, fontSize: 10, fontWeight: FontWeight.bold)),
              if (isMesh) ...[
                const SizedBox(width: 15),
                Text("|  RELAYS: ${mesh.nearbyNodes.length}", style: TextStyle(color: themeColor.withOpacity(0.5), fontSize: 9)),
              ]
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalTab() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.redAccent));

    return RefreshIndicator(
      onRefresh: _loadChats,
      backgroundColor: Colors.grey[900],
      color: Colors.redAccent,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_beaconChat != null) _buildBeaconTile(_beaconChat),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.waves, color: Colors.white24, size: 12),
                const SizedBox(width: 8),
                Text("NEIGHBORHOOD FREQUENCIES", style: GoogleFonts.russoOne(color: Colors.white24, fontSize: 9, letterSpacing: 1)),
              ],
            ),
          ),

          FutureBuilder<List<dynamic>>(
            future: _apiService.getTrendingBranches(),
            builder: (context, snapshot) {
              final branches = snapshot.data ?? [];
              if (branches.isEmpty) return const SizedBox.shrink();
              return Column(children: branches.where((b) => b['id'] != 'THE_BEACON_GLOBAL').map((b) => _buildBranchTile(b)).toList());
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
          gradient: LinearGradient(colors: [Colors.redAccent.withOpacity(0.15), Colors.transparent]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: Pulse(child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28), infinite: true),
          title: Text("THE BEACON", style: GoogleFonts.russoOne(color: Colors.white, fontSize: 16, letterSpacing: 1)),
          subtitle: const Text("GLOBAL EMERGENCY CHANNEL // BROADCASTING", style: TextStyle(color: Colors.redAccent, fontSize: 8, fontWeight: FontWeight.bold)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => _openChat('GLOBAL', 'THE BEACON', 'THE_BEACON_GLOBAL'),
        ),
      ),
    );
  }

  Widget _buildChatList(List<dynamic> chats, String emptyMsg) {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (chats.isEmpty) return Center(child: Text(emptyMsg, style: GoogleFonts.robotoMono(color: Colors.white10, fontSize: 12)));

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: chats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final chat = chats[index];
        final String title = chat['type'] == 'DIRECT'
            ? (chat['otherUser']?['username'] ?? 'Anonymous')
            : (chat['name'] ?? 'Squad Alpha');

        final String sub = chat['type'] == 'DIRECT' ? "Direct Link established" : "Mesh Squad Active";

        return ListTile(
          tileColor: const Color(0xFF0A0A0A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: CircleAvatar(
            // 🔥 ИСПРАВЛЕНО ЗДЕСЬ:
            backgroundColor: Colors.white.withOpacity(0.05),
            child: Icon(chat['type'] == 'GROUP' ? Icons.groups_3_outlined : Icons.person_outline, color: Colors.white38),
          ),
          title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text(sub, style: GoogleFonts.robotoMono(color: Colors.white24, fontSize: 9)),
          onTap: () => _openChat(chat['type'] == 'DIRECT' ? chat['otherUser']['id'] : '', title, chat['id']),
        );
      },
    );
  }

  Widget _buildBranchTile(dynamic branch) {
    return ListTile(
      leading: const Icon(Icons.radar, color: Colors.white10, size: 20),
      title: Text(branch['name'] ?? 'Public Freq', style: const TextStyle(color: Colors.white70, fontSize: 14)),
      subtitle: const Text("Relaying nearby signals", style: TextStyle(color: Colors.white10, fontSize: 10)),
      onTap: () => _openChat('', branch['name'], branch['id']),
    );
  }

  void _openChat(String friendId, String name, String? roomId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConversationScreen(friendId: friendId, friendName: name, chatRoomId: roomId),
    ));
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [BoxShadow(color: widget.color, blurRadius: 4 + _controller.value * 6, spreadRadius: _controller.value * 2)]
        ),
      ),
    );
  }
}