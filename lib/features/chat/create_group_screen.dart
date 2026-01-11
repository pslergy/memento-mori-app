// lib/features/chat/create_group_screen.dart
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';

import 'conversation_screen.dart';
// TODO: Импортировать ConversationScreen

class CreateGroupScreen extends StatefulWidget {
  final Set<String> memberIds;
  const CreateGroupScreen({super.key, required this.memberIds});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;

  void _createGroup() async {
    // --- ГЛАВНОЕ ИЗМЕНЕНИЕ ---
    // Если имя пустое ИЛИ процесс уже запущен, ничего не делаем
    if (_nameController.text.isEmpty || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      final newGroup = await _apiService.createGroupChat(
        _nameController.text,
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
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Enter group name'),
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