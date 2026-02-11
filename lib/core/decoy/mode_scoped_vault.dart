// lib/core/decoy/mode_scoped_vault.dart
//
// SECURITY INVARIANT: Each AppMode uses a physically separate storage namespace.
// REAL keys MUST NOT decrypt DECOY data. Key derivation MUST include mode as entropy.
// Do not expose mode names in logs; use neutral identifiers.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_mode.dart';
import 'vault_interface.dart';

/// Storage namespace identifiers. Not user-visible; do not log.
const String _namespaceA = 'mm_va';
const String _namespaceB = 'mm_vb';

String _storageNameForMode(AppMode mode) {
  switch (mode) {
    case AppMode.REAL:
      return _namespaceA;
    case AppMode.DECOY:
      return _namespaceB;
    case AppMode.INVALID:
      return _namespaceA;
  }
}

/// Vault implementation scoped to one [AppMode]. Separate Android SharedPreferences
/// and key namespace so REAL and DECOY data never coexist.
class ModeScopedVault implements VaultInterface {
  ModeScopedVault(this._mode) {
    _storage = FlutterSecureStorage(
      aOptions: AndroidOptions(
        sharedPreferencesName: _storageNameForMode(_mode),
        resetOnError: true,
      ),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  }

  final AppMode _mode;
  late final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  @override
  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }

  @override
  Future<bool> containsKey(String key) async {
    return _storage.containsKey(key: key);
  }
}
