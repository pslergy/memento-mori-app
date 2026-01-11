import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 🔥 Для вибрации
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart'; // 🔥 Импорт для перехода
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';

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
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchGhost.addListener(_onSearchChanged);
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
    if (mounted) setState(() => _isLoading = true);
    try {
      final results = await _apiService.searchUsers(query);
      if (mounted) setState(() => _searchResults = results);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Search failed. Server unreachable.'))
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🔥 МЕТОД ДЛЯ УСТАНОВКИ СВЯЗИ (Добавление + Переход)
  Future<void> _establishLink(String userId, String username) async {
    HapticFeedback.heavyImpact(); // Сильная вибрация для подтверждения
    setState(() => _isLoading = true);

    try {
      // 1. Сначала вызываем API создания прямого чата
      // Это гарантирует, что комната будет в базе ДО того, как мы туда зайдем
      final chatData = await _apiService.findOrCreateChat(userId);

      if (!mounted) return;

      // 2. Сразу переходим в чат, передавая полученный chatId
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            friendId: userId,
            friendName: username,
            chatRoomId: chatData['id'], // Используем ID из базы сервера!
          ),
        ),
      );

      // 3. В фоне шлем запрос в друзья (необязательно для работы чата, но полезно)
      unawaited(_apiService.sendFriendRequest(userId));

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('LINK FAILED: Check node integrity.'))
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showKeyboard() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GhostKeyboard(
        controller: _searchGhost,
        onSend: () => Navigator.pop(context),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchGhost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('SIGNAL SEARCH', style: TextStyle(letterSpacing: 2, fontSize: 16)),
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: GestureDetector(
              onTap: _showKeyboard,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 12),
                    AnimatedBuilder(
                      animation: _searchGhost,
                      builder: (context, _) => Text(
                        _searchGhost.value.isEmpty ? "Scan for username..." : _searchGhost.value,
                        style: TextStyle(
                            color: _searchGhost.value.isEmpty ? Colors.grey : Colors.white,
                            fontFamily: 'monospace'
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
                : _buildResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searchResults.isEmpty) {
      return const Center(
          child: Text("NO SIGNALS DETECTED",
              style: TextStyle(color: Colors.white10, letterSpacing: 2, fontSize: 12))
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemBuilder: (context, index) {
        final user = _searchResults[index];
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0D),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            leading: CircleAvatar(
                backgroundColor: Colors.grey[900],
                child: const Icon(Icons.person, color: Colors.white24, size: 20)
            ),
            title: Text(user['username'],
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: const Text("ACTIVE NODE",
                style: TextStyle(color: Colors.greenAccent, fontSize: 9, letterSpacing: 1)),
            trailing: IconButton(
              icon: const Icon(Icons.sensors, color: Colors.redAccent),
              onPressed: () => _establishLink(user['id'], user['username']),
            ),
          ),
        );
      },
    );
  }
}