import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/safe_string_prefix.dart';
import '../../core/local_db_service.dart';
import '../../core/mesh_core_engine.dart';
import '../../core/locator.dart';
import '../../core/api_service.dart';
import '../../core/dm_chat_id.dart';
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
  /// После REAL↔DECOY [locator] отдаёт новый экземпляр — не кэшировать в [final].
  LocalDatabaseService get _db => LocalDatabaseService();
  List<Map<String, dynamic>> _friends = [];
  /// Входящие: собеседник прислал заявку ([status] == pending).
  List<Map<String, dynamic>> _pendingIncoming = [];
  /// Исходящие: мы отправили заявку ([status] == pending_outgoing).
  List<Map<String, dynamic>> _pendingOutgoing = [];
  bool _isLoading = true;
  Timer? _refreshTimer;
  StreamSubscription<Map<String, dynamic>>? _meshSub;
  /// [dr_handshake_session.state] по peer id (`COMPLETE` = сессия по вспомогательной таблице).
  Map<String, String?> _drHandshakeUiStateByPeer = {};

  @override
  void initState() {
    super.initState();
    _loadFriends();
    // Обновляем каждые 5 секунд для актуального статуса
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadFriends());
    
    // Слушаем входящие friend requests
    if (locator.isRegistered<MeshCoreEngine>()) {
      _meshSub = locator<MeshCoreEngine>().messageStream.listen((data) {
        final t = data['type']?.toString() ?? '';
        if (t == 'FRIEND_REQUEST' ||
            t == 'FRIEND_RESPONSE' ||
            t == 'FRIEND_OUTGOING_SAVED' ||
            t == 'DR_DH_SESSION_OK') {
          _loadFriends();
        }
      });
    } else {
      logMissingFor('FriendsListScreen.initState', requireMesh: true);
    }
  }

  @override
  void dispose() {
    _meshSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    if (!mounted) return;
    
    try {
      final allFriends = await _db.getFriends();
      final accepted =
          allFriends.where((f) => f['status'] == 'accepted').toList();
      Map<String, String?> drHs = {};
      try {
        if (locator.isRegistered<ApiService>()) {
          final uid = locator<ApiService>().currentUserId.trim();
          if (uid.isNotEmpty && accepted.isNotEmpty) {
            final peerIds = accepted
                .map((f) => f['id']?.toString() ?? '')
                .where((id) => id.isNotEmpty)
                .toList();
            drHs = await _db.getDrHandshakeSessionStatesForPeers(uid, peerIds);
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _friends = accepted;
        _pendingIncoming =
            allFriends.where((f) => f['status'] == 'pending').toList();
        _pendingOutgoing = allFriends
            .where((f) => f['status'] == 'pending_outgoing')
            .toList();
        _drHandshakeUiStateByPeer = drHs;
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
                // Входящие заявки (принять / отклонить)
                if (_pendingIncoming.isNotEmpty)
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
                        ..._pendingIncoming
                            .map((friend) => _buildPendingRequestCard(friend)),
                      ],
                    ),
                  ),
                // Исходящие заявки (мы ждём ответа — раньше строка не создавалась, инициатор ничего не видел)
                if (_pendingOutgoing.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.cyan.withOpacity(0.08),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'OUTGOING REQUESTS',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Ожидаем ответа на вашу заявку',
                          style: TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        const SizedBox(height: 8),
                        ..._pendingOutgoing
                            .map((friend) => _buildOutgoingPendingCard(friend)),
                      ],
                    ),
                  ),
                
                // Список друзей
                Expanded(
                  child: _friends.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                  minHeight: constraints.maxHeight,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.people_outline,
                                        size: constraints.maxHeight < 160 ? 40 : 64,
                                        color: Colors.white24,
                                      ),
                                      SizedBox(height: constraints.maxHeight < 160 ? 8 : 16),
                                      Text(
                                        'NO FRIENDS YET',
                                        style: TextStyle(
                                          color: Colors.white24,
                                          fontSize: constraints.maxHeight < 160 ? 12 : 14,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => const AddFriendScreen(),
                                            ),
                                          );
                                        },
                                        child: const Text(
                                          'ADD FRIEND',
                                          style: TextStyle(color: Colors.cyanAccent),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
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
              tooltip: 'Принять',
              onPressed: () => _handleFriendResponse(friendId, 'accepted'),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.red, size: 20),
              tooltip: 'Отклонить',
              onPressed: () => _handleFriendResponse(friendId, 'rejected'),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white38, size: 20),
              color: const Color(0xFF252525),
              onSelected: (v) {
                if (v == 'dismiss') {
                  _confirmDismissPendingRequest(friendId, username);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem<String>(
                  value: 'dismiss',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, color: Colors.orangeAccent),
                    title: Text(
                      'Убрать из списка',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: Text(
                      'Только на этом телефоне',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutgoingPendingCard(Map<String, dynamic> friend) {
    final friendId = friend['id']?.toString() ?? '';
    final username = friend['username']?.toString() ?? 'Unknown';
    final requestedAt = friend['requested_at'] as int?;
    final timeAgo = requestedAt != null
        ? DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(requestedAt))
            .inMinutes
        : 0;

    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.cyanAccent.withOpacity(0.2),
          child: const Icon(Icons.hourglass_top, color: Colors.cyanAccent, size: 20),
        ),
        title: Text(
          username,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Sent ${timeAgo}m ago — waiting for peer',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, color: Colors.white38, size: 20),
          tooltip: 'Убрать из списка',
          onPressed: () => _confirmDismissPendingRequest(friendId, username),
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
    final drHs = _drHandshakeUiStateByPeer[friendId];
    final bool e2eReady = drHs == 'COMPLETE';
    final bool e2ePending =
        drHs != null && drHs.isNotEmpty && drHs != 'COMPLETE';

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
          tacticalName ?? safePrefix(friendId, 8),
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e2eReady)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message:
                      'Сессия DR в порядке по локальной записи — можно писать с E2E после доставки.',
                  child: Icon(Icons.lock, color: Colors.greenAccent.shade200, size: 18),
                ),
              )
            else if (e2ePending)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message:
                      'Обмен ключами ещё не завершён — держите устройства в зоне связи.',
                  child: Icon(Icons.hourglass_empty, color: Colors.amber.shade200, size: 18),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.message, color: Colors.cyanAccent, size: 20),
              tooltip: 'Написать',
              onPressed: () async {
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
                  if (mounted) {
                    final uid = locator.isRegistered<ApiService>()
                        ? locator<ApiService>().currentUserId
                        : '';
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ConversationScreen(
                          friendId: friendId,
                          friendName: username,
                          chatRoomId: uid.isNotEmpty
                              ? canonicalDmForMeshPair(uid, friendId)
                              : null,
                        ),
                      ),
                    );
                  }
                }
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white38, size: 22),
              tooltip: 'Ещё',
              color: const Color(0xFF252525),
              onSelected: (value) {
                if (value == 'remove') {
                  _confirmAndRemoveFriend(friendId, username);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem<String>(
                  value: 'remove',
                  child: ListTile(
                    leading: Icon(Icons.person_remove, color: Colors.redAccent),
                    title: Text('Удалить из друзей', style: TextStyle(color: Colors.white)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: () async {
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
            if (mounted) {
              final uid = locator.isRegistered<ApiService>()
                  ? locator<ApiService>().currentUserId
                  : '';
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConversationScreen(
                    friendId: friendId,
                    friendName: username,
                    chatRoomId: uid.isNotEmpty
                        ? canonicalDmForMeshPair(uid, friendId)
                        : null,
                  ),
                ),
              );
            }
          }
        },
      ),
    );
  }

  /// Входящая заявка: стереть строку локально (без вызова accept/reject на API).
  Future<void> _confirmDismissPendingRequest(String friendId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Убрать заявку?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Запись от «$username» исчезнет только здесь. При появлении снова в mesh заявка может прийти повторно.',
          style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Убрать', style: TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _db.removeFriend(friendId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Заявка убрана из списка'),
            backgroundColor: Color(0xFF2A2A2A),
          ),
        );
        HapticFeedback.lightImpact();
        await _loadFriends();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _confirmAndRemoveFriend(String friendId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Удалить из друзей?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Контакт «$username» будет убран из друзей на этом устройстве вместе с '
          'локальной личкой: сообщения, очереди mesh/outbox, сессия DR и ключи TOFU/bundle. '
          'Так можно заново протестировать обмен после смены протокола. '
          'На сервере (если онлайн) удаление тоже будет запрошено.',
          style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (locator.isRegistered<ApiService>()) {
        try {
          await locator<ApiService>().removeFriend(friendId);
        } catch (_) {
          // GHOST / офлайн — только локальная запись
        }
      }
      final myId = locator.isRegistered<ApiService>()
          ? locator<ApiService>().currentUserId
          : '';
      await _db.removeFriendCompletely(friendId, ownerUserId: myId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('«$username» удалён; локальная личка и DR очищены'),
          backgroundColor: const Color(0xFF2A2A2A),
        ),
      );
      HapticFeedback.mediumImpact();
      await _loadFriends();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleFriendResponse(String friendId, String status) async {
    try {
      // Сначала mesh: на peripheral-only ответ должен попасть в dr_handshake_outbox до того,
      // как централь (Samsung) уйдёт из сессии после OUTBOX_REQUEST. Вызов API может занять секунды.
      final mesh = locator<MeshCoreEngine>();
      final sent = await mesh.sendFriendResponse(friendId: friendId, status: status);

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

      if (status == 'accepted') {
        unawaited(locator<MeshCoreEngine>()
            .startDrHandshakeWithPeerAfterFriendshipAccepted(friendId));
      }

      // Ответ по тому же пути, что заявка: TCP (P2P) или BLE GATT — иначе на 2 телефонах без Wi‑Fi Direct пир не получал FRIEND_RESPONSE и DR не замыкался.
      if (!sent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              status == 'accepted'
                  ? 'Принято локально. Ответ по mesh не доставлен — подойдите ближе и откройте радар (BLE), затем повторите.'
                  : 'Отклонено локально; ответ по mesh не доставлен — проверьте BLE.',
            ),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 5),
          ),
        );
      }

      _loadFriends();
      HapticFeedback.lightImpact();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
