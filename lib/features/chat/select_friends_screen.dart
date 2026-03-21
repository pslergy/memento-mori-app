// lib/features/chat/select_friends_screen.dart
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';

import 'create_group_screen.dart';

class SelectFriendsScreen extends StatefulWidget {
  const SelectFriendsScreen({super.key});

  @override
  State<SelectFriendsScreen> createState() => _SelectFriendsScreenState();
}

class _SelectFriendsScreenState extends State<SelectFriendsScreen> {
  final ApiService _apiService = ApiService();
  late Future<List<dynamic>> _friendsFuture;
  final Set<String> _selectedFriendIds = {}; // Храним ID выбранных друзей

  @override
  void initState() {
    super.initState();
    _friendsFuture = _apiService.getFriends();
  }

  void _toggleFriend(String friendId) {
    setState(() {
      if (_selectedFriendIds.contains(friendId)) {
        _selectedFriendIds.remove(friendId);
      } else {
        _selectedFriendIds.add(friendId);
      }
    });
  }

  void _createGroup() {
    if (_selectedFriendIds.isEmpty) return;
    // Переходим на экран ввода имени, передавая ID участников
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateGroupScreen(memberIds: _selectedFriendIds),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Group'),
        backgroundColor: Colors.black,
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _friendsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final friends = snapshot.data!;
          return ListView.builder(
            itemCount: friends.length,
            itemBuilder: (context, index) {
              final friend = friends[index];
              final friendId = friend['id'];
              final isSelected = _selectedFriendIds.contains(friendId);
              return CheckboxListTile(
                title: Text(friend['username'], style: const TextStyle(color: Colors.white)),
                value: isSelected,
                onChanged: (bool? value) => _toggleFriend(friendId),
                activeColor: Colors.red,
                checkColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              );
            },
          );
        },
      ),
      floatingActionButton: _selectedFriendIds.isNotEmpty
          ? FloatingActionButton(
        onPressed: _createGroup,
        backgroundColor: Colors.red,
        child: const Icon(Icons.arrow_forward),
      )
          : null,
    );
  }
}