// Test harness — In-memory fake database. Minimal interface for messages.
// DO NOT import production mesh_core_engine. Isolated for testing.

import 'dart:async';

/// Minimal in-memory storage for messages.
class FakeDatabase {
  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _outbox = [];

  List<Map<String, dynamic>> get messages => List.unmodifiable(_messages);
  List<Map<String, dynamic>> get outbox => List.unmodifiable(_outbox);

  Future<void> saveMessage(Map<String, dynamic> msg) async {
    _messages.add(Map.from(msg));
  }

  Future<void> addToOutbox(Map<String, dynamic> entry) async {
    _outbox.add(Map.from(entry));
  }

  Future<List<Map<String, dynamic>>> getPendingFromOutbox() async {
    return List.from(_outbox);
  }

  Future<int> getOutboxCount() async => _outbox.length;

  Future<void> removeFromOutbox(String id) async {
    _outbox.removeWhere((e) => e['id'] == id);
  }

  void clear() {
    _messages.clear();
    _outbox.clear();
  }
}
