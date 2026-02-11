import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/room_service.dart';
import '../../core/local_db_service.dart';
import '../../core/locator.dart';
import '../../core/api_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import 'conversation_screen.dart';
import '../friends/friends_list_screen.dart';

/// Room creation screen with maximum simplicity UX
class CreateRoomScreen extends StatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  final RoomService _roomService = RoomService();
  final LocalDatabaseService _db = LocalDatabaseService();
  final GhostController _groupNameGhost = GhostController();

  List<Map<String, dynamic>> _friends = [];
  bool _isLoading = false;
  String? _selectedStep; // 'select' or 'person' or 'group'

  @override
  void initState() {
    super.initState();
    _loadFriends();
    _selectedStep = 'select';
  }

  Future<void> _loadFriends() async {
    final allFriends = await _db.getFriends();
    setState(() {
      _friends = allFriends.where((f) => f['status'] == 'accepted').toList();
    });
  }

  void _showSelectType() {
    setState(() => _selectedStep = 'select');
  }

  void _selectPerson() {
    setState(() => _selectedStep = 'person');
  }

  void _selectGroup() {
    setState(() => _selectedStep = 'group');
  }

  Future<void> _createDirectRoom(String friendId, String friendName) async {
    if (_isLoading) return;
    
    setState(() => _isLoading = true);
    HapticFeedback.mediumImpact();

    try {
      final room = await _roomService.createDirectRoom(friendId);
      
      if (mounted) {
        // Navigate to conversation and pop create screen
        Navigator.of(context).pop(); // Close create screen first
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConversationScreen(
              friendId: friendId,
              friendName: friendName,
              chatRoomId: room['id'],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createGroupRoom() async {
    if (_isLoading) return;

    final name = _groupNameGhost.value.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter group name')),
      );
      return;
    }

    setState(() => _isLoading = true);
    HapticFeedback.mediumImpact();

    try {
      final room = await _roomService.createGroupRoom(name: name);
      
      if (mounted) {
        // Navigate to conversation and pop create screen
        Navigator.of(context).pop(); // Close create screen first
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConversationScreen(
              friendId: room['id'],
              friendName: room['name'],
              chatRoomId: room['id'],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: Text(
          _selectedStep == 'select' ? 'New Chat' : 
          _selectedStep == 'person' ? 'Select Contact' : 
          'Create Group',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        leading: _selectedStep != 'select'
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _showSelectType,
              )
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_selectedStep == 'select') {
      return _buildSelectType();
    } else if (_selectedStep == 'person') {
      return _buildPersonSelection();
    } else {
      return _buildGroupCreation();
    }
  }

  Widget _buildSelectType() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          // Button: Person
          GestureDetector(
            onTap: _selectPerson,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person, size: 64, color: Colors.cyanAccent),
                  SizedBox(height: 16),
                  Text(
                    '👤 Person',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
          // Button: Group
          GestureDetector(
            onTap: _selectGroup,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.group, size: 64, color: Colors.redAccent),
                  SizedBox(height: 16),
                  Text(
                    '👥 Group',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonSelection() {
    if (_friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_off, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'No Friends',
              style: TextStyle(color: Colors.white24, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FriendsListScreen()),
                );
              },
              child: const Text('Add Friend', style: TextStyle(color: Colors.cyanAccent)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _friends.length,
      itemBuilder: (context, index) {
        final friend = _friends[index];
        final friendId = friend['id'] as String;
        final friendName = friend['username'] as String? ?? 'Unknown';
        
        return Card(
          color: const Color(0xFF1A1A1A),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.cyanAccent,
              child: Icon(Icons.person, color: Colors.black),
            ),
            title: Text(
              friendName,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              friendId.substring(0, 8),
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
            onTap: () => _createDirectRoom(friendId, friendName),
          ),
        );
      },
    );
  }

  Widget _buildGroupCreation() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 40),
          const Text(
            'Group Name',
            style: TextStyle(color: Colors.white24, fontSize: 12),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => GhostKeyboard(
                  controller: _groupNameGhost,
                  onSend: () {
                    setState(() {});
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
              child: AnimatedBuilder(
                animation: _groupNameGhost,
                builder: (_, __) => Text(
                  _groupNameGhost.value.isEmpty ? 'Group' : _groupNameGhost.value,
                  style: TextStyle(
                    color: _groupNameGhost.value.isEmpty ? Colors.white24 : Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: _isLoading ? null : _createGroupRoom,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text(
                    'Create',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
