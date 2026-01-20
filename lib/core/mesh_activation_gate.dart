import 'dart:async';

class MeshActivationGate {
  static final _lock = Completer<void>();

  static Future<bool> requestAll() async {
    // Запрос permissions (bluetooth, location, nearby, etc)
    // Вернуть true ТОЛЬКО если система реально дала всё
    return true;
  }

  static Future<void> lock() async {
    if (!_lock.isCompleted) {
      return;
    }
  }

  static Future<void> unlock() async {
    if (!_lock.isCompleted) {
      _lock.complete();
    }
  }

  static Future<void> waitUntilReady() async {
    await _lock.future;
  }
}
