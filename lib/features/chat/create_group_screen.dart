// lib/features/chat/create_group_screen.dart
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/ghost_input/ghost_controller.dart';
import 'package:memento_mori_app/ghost_input/ghost_keyboard.dart';

import 'conversation_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  final Set<String> memberIds;
  const CreateGroupScreen({super.key, required this.memberIds});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final GhostController _nameGhost = GhostController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;

  void _createGroup() async {
    if (_nameGhost.value.trim().isEmpty || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      final newGroup = await _apiService.createGroupChat(
        _nameGhost.value.trim(),
        widget.memberIds.toList(),
      );

      if (!mounted) return;

      // Переходим в созданный чат, очищая стек до списка чатов
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            friendId: '', // Для групп friendId не нужен
            friendName: newGroup['name'],
            // TODO: Передавать ID группы и флаг, что это группа
          ),
        ),
            (route) => route.isFirst, // Удаляем все, кроме самого первого экрана (MainScreen)
      );

    } catch (e) {
      // ...
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Name')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            GestureDetector(
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (context) => GhostKeyboard(
                    controller: _nameGhost,
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
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: AnimatedBuilder(
                  animation: _nameGhost,
                  builder: (_, __) => Text(
                    _nameGhost.value.isEmpty ? 'Enter group name' : _nameGhost.value,
                    style: TextStyle(
                      color: _nameGhost.value.isEmpty ? Colors.grey : Colors.black,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: _createGroup,
              child: _isLoading ? const CircularProgressIndicator() : const Text('Create Group'),
            )
          ],
        ),
      ),
    );
  }
}