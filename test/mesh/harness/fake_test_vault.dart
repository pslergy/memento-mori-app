// Real engine stress test — in-memory vault. No FlutterSecureStorage.
// Test utilities only.

import 'package:memento_mori_app/core/decoy/vault_interface.dart';

/// In-memory vault for tests. Avoids FlutterSecureStorage platform channel.
class FakeTestVault implements VaultInterface {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _store.clear();
  }

  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);
}
