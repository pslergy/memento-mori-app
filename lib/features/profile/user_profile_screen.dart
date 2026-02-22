import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/mesh_service.dart';
import '../../core/room_id_normalizer.dart';
import '../chat/conversation_screen.dart';

/// Экран профиля другого пользователя по [userId].
/// Показывает имя, кнопку «Написать в ЛС», «Добавить в друзья» / «Удалить из друзей».
class UserProfileScreen extends StatefulWidget {
  final String userId;
  final String? displayName;

  const UserProfileScreen({
    super.key,
    required this.userId,
    this.displayName,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final ApiService _api = locator<ApiService>();
  final LocalDatabaseService _db = LocalDatabaseService();
  final MeshService _mesh = locator<MeshService>();

  bool _isLoading = true;
  bool _isMe = false;
  String? _friendStatus; // 'accepted' | 'pending' | null
  String _displayName = '';

  @override
  void initState() {
    super.initState();
    _displayName = widget.displayName ?? _shortId(widget.userId);
    _load();
  }

  String _shortId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
  }

  Future<void> _load() async {
    if (!mounted) return;
    final currentUserId = _api.currentUserId;
    setState(() => _isMe = currentUserId == widget.userId);

    if (_isMe) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final friend = await _db.getFriend(widget.userId);
      if (mounted) {
        setState(() {
          _friendStatus = friend?['status'] as String?;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openDm() async {
    try {
      HapticFeedback.mediumImpact();
      final chatData = await _api.findOrCreateChat(widget.userId);
      final roomId = chatData['id'] as String?;
      final name = _displayName;
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ConversationScreen(
          friendId: widget.userId,
          friendName: name,
          chatRoomId: roomId,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      final myId = _api.currentUserId;
      final roomId = RoomIdNormalizer.canonicalDmRoomId(myId, widget.userId);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ConversationScreen(
          friendId: widget.userId,
          friendName: _displayName,
          chatRoomId: roomId,
        ),
      ));
    }
  }

  Future<void> _addFriend() async {
    try {
      HapticFeedback.mediumImpact();
      await _api.sendFriendRequest(widget.userId);
      await _mesh.sendFriendRequest(widget.userId, message: 'Привет! Добавь меня в друзья');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.profileRequestSent), backgroundColor: Colors.green),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppLocalizations.of(context)!.profileErrorPrefix}$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeFriend() async {
    try {
      HapticFeedback.mediumImpact();
      await _api.removeFriend(widget.userId);
      await _db.removeFriend(widget.userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.profileFriendRemoved), backgroundColor: Colors.orange),
        );
        setState(() => _friendStatus = null);
      }
    } catch (e) {
      await _db.removeFriend(widget.userId);
      if (mounted) {
        setState(() => _friendStatus = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppLocalizations.of(context)!.profileFriendRemovedLocal}$e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: Text(
          _displayName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Text(
                    _isMe ? AppLocalizations.of(context)!.profileThisIsYou : _displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (!_isMe) ...[
                    const SizedBox(height: 8),
                    Text(
                      'ID: ${_shortId(widget.userId)}',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 32),
                  if (_isMe)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        AppLocalizations.of(context)!.profileOpenViaMenu,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    )
                  else ...[
                    OutlinedButton.icon(
                      onPressed: _openDm,
                      icon: const Icon(Icons.chat_bubble_outline, color: Colors.redAccent, size: 20),
                      label: Text(AppLocalizations.of(context)!.profileWriteDm, style: const TextStyle(color: Colors.redAccent)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_friendStatus == 'accepted')
                      OutlinedButton.icon(
                        onPressed: _removeFriend,
                        icon: const Icon(Icons.person_remove, color: Colors.orange, size: 20),
                        label: Text(AppLocalizations.of(context)!.profileRemoveFriend, style: const TextStyle(color: Colors.orange)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.orange),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      )
                    else if (_friendStatus == 'pending')
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          AppLocalizations.of(context)!.profileRequestPending,
                          style: const TextStyle(color: Colors.orange, fontSize: 12),
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _addFriend,
                        icon: const Icon(Icons.person_add, color: Colors.cyanAccent, size: 20),
                        label: Text(AppLocalizations.of(context)!.profileAddFriend, style: const TextStyle(color: Colors.cyanAccent)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.cyanAccent),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}
