import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/local_db_service.dart';
import '../../core/mesh_service.dart';
import '../../core/locator.dart';
import '../../core/api_service.dart';
import '../../core/native_mesh_service.dart';
import '../../core/models/signal_node.dart';
import '../../core/room_service.dart';
import '../chat/conversation_screen.dart';
import '../chat/create_room_screen.dart';
import 'add_friend_screen.dart';

class FriendsListScreen extends StatefulWidget {
  const FriendsListScreen({super.key});

  @override
  State<FriendsListScreen> createState() => _FriendsListScreenState();
}

class _FriendsListScreenState extends State<FriendsListScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _pendingRequests = [];
  bool _isLoading = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadFriends();
    // Обновляем каждые 5 секунд для актуального статуса
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadFriends());
    
    // Слушаем входящие friend requests
    locator<MeshService>().messageStream.listen((data) {
      if (data['type'] == 'FRIEND_REQUEST' || data['type'] == 'FRIEND_RESPONSE') {
        _loadFriends();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    if (!mounted) return;
    
    try {
      final allFriends = await _db.getFriends();
      setState(() {
        _friends = allFriends.where((f) => f['status'] == 'accepted').toList();
        _pendingRequests = allFriends.where((f) => f['status'] == 'pending').toList();
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text(
          'FRIENDS',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, color: Colors.redAccent),
            tooltip: 'Новый чат',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreateRoomScreen()),
              ).then((_) => _loadFriends());
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_add, color: Colors.cyanAccent),
            tooltip: 'Добавить друга',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddFriendScreen()),
              ).then((_) => _loadFriends());
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : Column(
              children: [
                // Запросы в друзья
                if (_pendingRequests.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.orange.withOpacity(0.1),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PENDING REQUESTS',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._pendingRequests.map((friend) => _buildPendingRequestCard(friend)),
                      ],
                    ),
                  ),
                
                // Список друзей
                Expanded(
                  child: _friends.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.people_outline, size: 64, color: Colors.white24),
                              const SizedBox(height: 16),
                              Text(
                                'NO FRIENDS YET',
                                style: TextStyle(color: Colors.white24, fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const AddFriendScreen()),
                                  );
                                },
                                child: const Text('ADD FRIEND', style: TextStyle(color: Colors.cyanAccent)),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _friends.length,
                          itemBuilder: (context, index) => _buildFriendCard(_friends[index]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildPendingRequestCard(Map<String, dynamic> friend) {
    final friendId = friend['id']?.toString() ?? '';
    final username = friend['username']?.toString() ?? 'Unknown';
    final requestedAt = friend['requested_at'] as int?;
    final timeAgo = requestedAt != null
        ? DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(requestedAt)).inMinutes
        : 0;

    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.orange.withOpacity(0.3),
          child: const Icon(Icons.person_add, color: Colors.orange, size: 20),
        ),
        title: Text(
          username,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Requested ${timeAgo}m ago',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.check, color: Colors.green, size: 20),
              onPressed: () => _handleFriendResponse(friendId, 'accepted'),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.red, size: 20),
              onPressed: () => _handleFriendResponse(friendId, 'rejected'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFriendCard(Map<String, dynamic> friend) {
    final friendId = friend['id']?.toString() ?? '';
    final username = friend['username']?.toString() ?? 'Unknown';
    final tacticalName = friend['tactical_name']?.toString();
    final lastSeen = friend['lastSeen'] as int?;
    final isOnline = lastSeen != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastSeen)).inMinutes < 5;

    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isOnline ? Colors.green.withOpacity(0.3) : Colors.grey.withOpacity(0.3),
          child: Icon(
            isOnline ? Icons.circle : Icons.circle_outlined,
            color: isOnline ? Colors.green : Colors.grey,
            size: 12,
          ),
        ),
        title: Text(
          username,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          tacticalName ?? friendId.substring(0, 8),
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.message, color: Colors.cyanAccent, size: 20),
          onPressed: () async {
            // Используем RoomService для создания детерминированного room_id
            final roomService = RoomService();
            try {
              final room = await roomService.createDirectRoom(friendId);
              if (mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ConversationScreen(
                      friendId: friendId,
                      friendName: username,
                      chatRoomId: room['id'],
                    ),
                  ),
                );
              }
            } catch (e) {
              // Fallback на старый способ если ошибка
              if (mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ConversationScreen(
                      friendId: friendId,
                      friendName: username,
                      chatRoomId: 'dm_${locator<ApiService>().currentUserId}_$friendId',
                    ),
                  ),
                );
              }
            }
          },
        ),
        onTap: () async {
          // Используем RoomService для создания детерминированного room_id
          final roomService = RoomService();
          try {
            final room = await roomService.createDirectRoom(friendId);
            if (mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConversationScreen(
                    friendId: friendId,
                    friendName: username,
                    chatRoomId: room['id'],
                  ),
                ),
              );
            }
          } catch (e) {
            // Fallback на старый способ если ошибка
            if (mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConversationScreen(
                    friendId: friendId,
                    friendName: username,
                    chatRoomId: 'dm_${locator<ApiService>().currentUserId}_$friendId',
                  ),
                ),
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _handleFriendResponse(String friendId, String status) async {
    try {
      // Облако: принять/отклонить на бэкенде (requestId = id отправителя заявки)
      final api = locator<ApiService>();
      try {
        if (status == 'accepted') {
          await api.acceptFriendRequest(friendId);
        } else {
          await api.rejectFriendRequest(friendId);
        }
      } catch (_) {
        // Нет сети или не авторизован — продолжаем только локально и по mesh
      }

      await _db.updateFriendStatus(
        friendId,
        status,
        acceptedAt: status == 'accepted' ? DateTime.now().millisecondsSinceEpoch : null,
      );

      // Отправляем ответ через mesh
      final mesh = locator<MeshService>();
      final response = {
        'type': 'FRIEND_RESPONSE',
        'senderId': api.currentUserId,
        'receiverId': friendId,
        'status': status,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Ищем друга в nearby nodes для отправки ответа
      final friendNode = mesh.nearbyNodes.firstWhere(
        (node) => node.id == friendId,
        orElse: () => mesh.nearbyNodes.first,
      );

      if (friendNode.type == SignalType.mesh && mesh.isP2pConnected) {
        await NativeMeshService.sendTcp(jsonEncode(response), host: friendNode.metadata);
      }

      _loadFriends();
      HapticFeedback.lightImpact();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
