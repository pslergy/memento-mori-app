// lib/core/decoy/mode_resolver.dart
//
// SECURITY INVARIANT: Mode resolution MUST take identical time for REAL and DECOY.
// No conditional delays, no early exits. Deterministic mapping: input -> AppMode.
// Resolver does NOT reveal which mode was entered. Uses constant-time comparison.

import 'package:crypto/crypto.dart';

import 'app_mode.dart';

/// Constant-time byte comparison. Prevents timing leaks.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int v = 0;
  for (int i = 0; i < a.length; i++) {
    v |= a[i] ^ b[i];
  }
  return v == 0;
}

/// Resolves hashed user input to [AppMode]. Primary hash -> REAL, alternative hash -> DECOY.
///
/// INVARIANTS:
/// - Execution path and timing identical for REAL and DECOY.
/// - No early return; always compares input against both stored hashes.
/// - All three lists must be same length (e.g. 32 bytes from SHA-256).
///
/// [inputHash] = hashAccessCode(userTypedCode). [primaryAccessHash] and
/// [alternativeAccessHash] are the two stored hashes (from onboarding).
AppMode resolveMode({
  required List<int> inputHash,
  required List<int> primaryAccessHash,
  required List<int> alternativeAccessHash,
}) {
  final int len = primaryAccessHash.length;
  if (alternativeAccessHash.length != len || inputHash.length != len) {
    return AppMode.INVALID;
  }

  final matchPrimary = _constantTimeEquals(inputHash, primaryAccessHash);
  final matchAlternative =
      _constantTimeEquals(inputHash, alternativeAccessHash);

  if (matchPrimary && !matchAlternative) return AppMode.REAL;
  if (matchAlternative && !matchPrimary) return AppMode.DECOY;
  return AppMode.INVALID;
}

/// Canonical hash for access codes. Use for both storing and comparing.
/// Same algorithm for primary and alternative so timing is identical.
List<int> hashAccessCode(String code) {
  final bytes = code.codeUnits;
  final digest = sha256.convert(bytes);
  return digest.bytes;
}
