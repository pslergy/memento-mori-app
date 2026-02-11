// lib/core/decoy/vault_interface.dart
//
// SECURITY INVARIANT: REAL and DECOY use separate vault namespaces.
// No shared keys, salts, or storage. Mode is implicit via injected implementation.

/// Abstraction for secure key-value storage. Implementations are mode-scoped.
/// App code MUST NOT check mode at runtime; mode is implicit via which implementation is injected.
abstract class VaultInterface {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
  Future<bool> containsKey(String key);
}
