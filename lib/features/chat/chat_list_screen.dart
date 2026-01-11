import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/google_service.dart'; // Проверка Google Services
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import 'package:memento_mori_app/features/chat/select_friends_screen.dart';
import 'package:memento_mori_app/features/chat/find_friends_screen.dart';
import 'package:memento_mori_app/features/profile/profile_screen.dart';
import 'package:memento_mori_app/features/chat/mesh_hybrid_screen.dart'; // Наш Радар
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
  bool _hasGoogleServices = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // Перерисовываем UI при смене вкладки (чтобы менять FAB)
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() {}); });

    _loadChats();
    _listenToSocket();
    _checkGoogleServices();
    NetworkMonitor().onRoleChanged.listen((role) {
      if (role == MeshRole.BRIDGE) {
        print("🌐 [UI] Internet restored. Forcing chat sync...");
        _loadChats(); // Перезагружаем список с сервера
      }
    });
  }


  @override
  void dispose() {
    _tabController.dispose();
    _socketSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkGoogleServices() async {
    final status = await GooglePlayServices.isAvailable();
    if (mounted) setState(() => _hasGoogleServices = status);
  }

  Future<void> _loadChats() async {
    try {
      final chats = await _apiService.getChats();
      if (mounted) {
        setState(() {
          _allChats = chats;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Chat Load Error: $e");
      // Если мы в оффлайне, API вернет ошибку, только если совсем всё плохо.
      // Но наш новый _handleOfflineFlow в ApiService теперь возвращает Маяк!
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleRefresh() async {
    await _loadChats();
  }

  void _listenToSocket() {
    _socketSubscription = WebSocketService().stream.listen((data) {
      if (data['type'] == 'updateChatList' || data['type'] == 'newMessage') {
        _loadChats();
      }
    });
  }

  // --- ФИЛЬТРАЦИЯ ЧАТОВ ---
  List<dynamic> get _directChats => _allChats.where((c) => c['type'] == 'DIRECT').toList();
  List<dynamic> get _groupChats => _allChats.where((c) => c['type'] == 'GROUP').toList();
  dynamic get _globalChat => _allChats.firstWhere((c) => c['type'] == 'GLOBAL', orElse: () => null);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('COMMUNICATIONS'),
        backgroundColor: Colors.black,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.redAccent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(icon: Icon(Icons.public), text: "GLOBAL"),
            Tab(icon: Icon(Icons.groups), text: "SQUADS"),
            Tab(icon: Icon(Icons.person), text: "DIRECT"),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          // 🔥 СТРИМ-МОНИТОР СЕТИ: Авто-обновление при появлении BRIDGE
          StreamBuilder<MeshRole>(
            stream: NetworkMonitor().onRoleChanged,
            initialData: NetworkMonitor().currentRole,
            builder: (context, snapshot) {
              if (snapshot.data == MeshRole.BRIDGE) {
                // Если мы вышли в онлайн — инициируем загрузку данных с сервера
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_allChats.isEmpty && !_isLoading) _loadChats();
                });
              }
              return _buildNetworkStatusBanner();
            },
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(),
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

  // --- ВКЛАДКА 1: ГЛОБАЛЬНЫЙ ЧАТ / РАДАР ---
  Widget _buildGlobalTab() {
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: FutureBuilder<List<dynamic>>(
        future: _apiService.getTrendingBranches(), // Получаем активные ветки
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.redAccent));
          }

          final branches = snapshot.data ?? [];

          if (branches.isEmpty) {
            return const Center(child: Text("NO ACTIVE FREQUENCIES", style: TextStyle(color: Colors.grey)));
          }

          return ListView.builder(
            itemCount: branches.length,
            itemBuilder: (context, index) {
              final branch = branches[index];
              // Считаем полоски активности (от 1 до 5)
              final int msgCount = branch['_count']?['messages'] ?? 0;

              return ListTile(
                leading: _buildActivityBars(msgCount),
                title: Text(branch['name'] ?? 'Frequency Alpha',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text("Traffic: $msgCount packets | Active",
                    style: const TextStyle(color: Colors.grey, fontSize: 10)),
                trailing: const Icon(Icons.settings_input_antenna, color: Colors.greenAccent, size: 18),
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
            },
          );
        },
      ),
    );
  }

  Widget _buildActivityBars(int count) {
    int bars = (count / 5).clamp(1, 5).toInt();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Container(
        width: 2,
        height: (i + 1) * 4.0,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        color: i < bars ? Colors.greenAccent : Colors.white10,
      )),
    );
  }


// Виджет тактических полосок активности
  Widget _buildSignalIndicator(int activity) {
    int bars = (activity / 10).clamp(1, 5).toInt();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Container(
        width: 2,
        height: (i + 1) * 4.0,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        color: i < bars ? Colors.greenAccent : Colors.white10,
      )),
    );
  }

  // --- ВИДЖЕТ СПИСКА ЧАТОВ ---
  Widget _buildChatList(List<dynamic> chats, String emptyMsg) {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (chats.isEmpty) return Center(child: Text(emptyMsg, style: const TextStyle(color: Colors.white38)));

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: Colors.white,
      backgroundColor: Colors.grey[900],
      child: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          // Если это DIRECT - берем имя друга, если GROUP - название группы
          final String title = chat['type'] == 'DIRECT'
              ? (chat['otherUser']?['username'] ?? 'Unknown')
              : (chat['name'] ?? 'Unnamed Squad');

          final String lastMsg = chat['lastMessage'] != null
              ? chat['lastMessage']['content']
              : 'No messages';

          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.grey[800],
              child: Icon(chat['type'] == 'GROUP' ? Icons.group : Icons.person, color: Colors.white),
            ),
            title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: Text(lastMsg, style: TextStyle(color: Colors.grey[400]), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ConversationScreen(
                  friendId: chat['type'] == 'DIRECT' ? chat['otherUser']['id'] : '',
                  friendName: title,
                  // Для групп передаем ID чата
                  chatRoomId: chat['type'] == 'GROUP' ? chat['id'] : null,
                ),
              )).then((_) => _handleRefresh());
            },
          );
        },
      ),
    );
  }

  // --- СТАТУС БАР ---
  Widget _buildNetworkStatusBanner() {
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final role = snapshot.data ?? MeshRole.GHOST;
        final isBridge = role == MeshRole.BRIDGE;

        return InkWell(
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: const Text("Pinging Server..."), duration: const Duration(seconds: 1), backgroundColor: Colors.grey[800]),
            );
            NetworkMonitor().checkNow();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            color: isBridge ? Colors.green[900] : Colors.red[900],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(isBridge ? Icons.public : Icons.public_off, color: Colors.white, size: 14),
                const SizedBox(width: 8),
                Text(
                  isBridge ? "BRIDGE (ONLINE)" : "GHOST (MESH ONLY)",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- FAB (КНОПКА) ---
  Widget? _buildFab() {
    // Вкладка 0 (Global): Нет кнопки
    if (_tabController.index == 0) return null;

    // Вкладка 1 (Groups): Создать группу
    if (_tabController.index == 1) {
      return FloatingActionButton(
        backgroundColor: Colors.redAccent,
        child: const Icon(Icons.group_add, color: Colors.white),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelectFriendsScreen())),
      );
    }

    // Вкладка 2 (Direct): Найти друга
    return FloatingActionButton(
      backgroundColor: Colors.white,
      child: const Icon(Icons.person_add, color: Colors.black),
      onPressed: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FindFriendsScreen()));
      },
    );
  }
}