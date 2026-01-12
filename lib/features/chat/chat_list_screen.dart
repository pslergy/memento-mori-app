import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/google_service.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import 'package:memento_mori_app/features/chat/select_friends_screen.dart';
import 'package:memento_mori_app/features/chat/find_friends_screen.dart';
import 'package:memento_mori_app/features/profile/profile_screen.dart';
import 'package:memento_mori_app/features/chat/mesh_hybrid_screen.dart';
import 'package:memento_mori_app/features/auth/auth_gate_screen.dart';
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

    // Слушаем изменения сети для авто-обновления
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
      print("🚨 [UI] Failed to load chats: $e");
      if (mounted) {
        setState(() {
          _allChats = []; // Очищаем список при критической ошибке
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

  // --- ФИЛЬТРАЦИЯ ЧАТОВ (Исправленная версия) ---
  List<dynamic> get _directChats => _allChats.where((c) => c != null && c['type'] == 'DIRECT').toList();
  List<dynamic> get _groupChats => _allChats.where((c) => c != null && c['type'] == 'GROUP').toList();

  // Безопасный поиск Маяка без ошибок типов
  dynamic get _beaconChat {
    final matches = _allChats.where((c) => c != null && c['id'] == 'THE_BEACON_GLOBAL');
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('COMMUNICATIONS', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.redAccent,
          tabs: const [
            Tab(text: "GLOBAL"),
            Tab(text: "SQUADS"),
            Tab(text: "DIRECT"),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.radar, color: Colors.cyanAccent),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MeshHybridScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildNetworkStatusBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(), // ОБНОВЛЕННАЯ ВКЛАДКА
                _buildChatList(_groupChats, "No squads joined."),
                _buildChatList(_directChats, "No private chats."),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _buildFab(),
    );
  }

  // --- ВКЛАДКА GLOBAL (С ВЕЧНЫМ МАЯКОМ) ---
  Widget _buildGlobalTab() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.redAccent));

    return RefreshIndicator(
      onRefresh: _loadChats,
      child: ListView(
        children: [
          // 1. ПРИНУДИТЕЛЬНЫЙ МАЯК (Светится всегда)
          if (_beaconChat != null) _buildBeaconTile(_beaconChat),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text("TRENDING FREQUENCIES", style: TextStyle(color: Colors.white24, fontSize: 10, letterSpacing: 1)),
          ),

          // 2. ОСТАЛЬНЫЕ ПУБЛИЧНЫЕ ЧАТЫ (Если есть инет)
          FutureBuilder<List<dynamic>>(
            future: _apiService.getTrendingBranches(),
            builder: (context, snapshot) {
              final branches = snapshot.data ?? [];
              if (branches.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Center(child: Text("Scanning for nearby signals...", style: TextStyle(color: Colors.grey, fontSize: 12))),
                );
              }
              return Column(
                children: branches.where((b) => b['id'] != 'THE_BEACON_GLOBAL').map((b) => _buildBranchTile(b)).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  // Виджет самого МАЯКА (Красный, тактический)
  Widget _buildBeaconTile(dynamic chat) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
      ),
      child: ListTile(
        leading: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
        title: Text(chat['name'] ?? 'THE BEACON',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
        subtitle: const Text("EMERGENCY BROADCAST | MESH ACTIVE",
            style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const ConversationScreen(
              friendId: 'GLOBAL',
              friendName: 'THE BEACON',
              chatRoomId: 'THE_BEACON_GLOBAL',
            ),
          ));
        },
      ),
    );
  }

  Widget _buildBranchTile(dynamic branch) {
    final int msgCount = branch['_count']?['messages'] ?? 0;
    return ListTile(
      leading: _buildActivityBars(msgCount),
      title: Text(branch['name'] ?? 'Unknown Frequency', style: const TextStyle(color: Colors.white)),
      subtitle: Text("Relay strength: $msgCount packets", style: const TextStyle(color: Colors.grey, fontSize: 10)),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ConversationScreen(
            friendId: '',
            friendName: branch['name'],
            chatRoomId: branch['id'],
          ),
        ));
      },
    );
  }

  Widget _buildActivityBars(int count) {
    int bars = (count / 5).clamp(1, 5).toInt();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Container(
        width: 2, height: (i + 1) * 4.0,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        color: i < bars ? Colors.greenAccent : Colors.white10,
      )),
    );
  }

  // --- СТАНДАРТНЫЙ СПИСОК (SQUADS / DIRECT) ---
  Widget _buildChatList(List<dynamic> chats, String emptyMsg) {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (chats.isEmpty) return Center(child: Text(emptyMsg, style: const TextStyle(color: Colors.white38)));

    return ListView.builder(
      itemCount: chats.length,
      itemBuilder: (context, index) {
        final chat = chats[index];
        final String title = chat['type'] == 'DIRECT'
            ? (chat['otherUser']?['username'] ?? 'Unknown')
            : (chat['name'] ?? 'Unnamed Squad');

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.grey[900],
            child: Icon(chat['type'] == 'GROUP' ? Icons.groups : Icons.person, color: Colors.white),
          ),
          title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          subtitle: const Text("Link secured", style: TextStyle(color: Colors.grey, fontSize: 11)),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ConversationScreen(
                friendId: chat['type'] == 'DIRECT' ? chat['otherUser']['id'] : '',
                friendName: title,
                chatRoomId: chat['id'],
              ),
            ));
          },
        );
      },
    );
  }

  Widget _buildNetworkStatusBanner() {
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final isBridge = snapshot.data == MeshRole.BRIDGE;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4),
          color: isBridge ? Colors.green[900]!.withOpacity(0.3) : Colors.red[900]!.withOpacity(0.3),
          child: Text(
            isBridge ? "📡 UPLINK: STABLE" : "🚫 MODE: GHOST (AIR-GAP)",
            textAlign: TextAlign.center,
            style: TextStyle(color: isBridge ? Colors.greenAccent : Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
          ),
        );
      },
    );
  }

  Widget? _buildFab() {
    if (_tabController.index == 0) return null;
    return FloatingActionButton(
      backgroundColor: Colors.redAccent,
      child: Icon(_tabController.index == 1 ? Icons.group_add : Icons.person_add, color: Colors.white),
      onPressed: () {}, // Реализуй по необходимости
    );
  }
}