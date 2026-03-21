// lib/core/panic/panic_display_service.dart
//
// Управляет отображением: нейтральная подмена или реальный контент.
// showRealContent сбрасывается при уходе в фон / закрытии приложения.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../decoy/gate_storage.dart';
import '../decoy/mode_resolver.dart';
import '../decoy/vault_interface.dart';
import '../locator.dart';
import '../panic_service.dart';

const String _keyRevealCodeHash = 'panic_reveal_code_hash';

/// Сервис режима отображения при панике.
/// showRealContent = true только после ввода пользовательской комбинации.
class PanicDisplayService extends ChangeNotifier {
  bool _showRealContent = false;

  /// Показывать ли реальный контент (после ввода reveal-кода).
  bool get showRealContent => _showRealContent;

  /// Нужна ли подмена (паника активна и пользователь не ввёл код).
  Future<bool> get shouldSubstitute async {
    final panic = await PanicService.isPanicProtocolActivated();
    return panic && !_showRealContent;
  }

  /// Проверить ввод и при совпадении показать реальный контент.
  Future<bool> revealIfCodeMatches(String input) async {
    if (input.isEmpty) return false;
    final stored = await _getStoredRevealHash();
    if (stored == null) {
      // Fallback: primary access hash (если reveal не задан)
      final hashes = await getGateHashes();
      if (hashes != null) {
        final inputHash = hashAccessCode(input);
        if (_constantTimeEquals(inputHash, hashes.primary)) {
          _showRealContent = true;
          notifyListeners();
          return true;
        }
      }
      return false;
    }
    final inputHash = hashAccessCode(input);
    if (_constantTimeEquals(inputHash, stored)) {
      _showRealContent = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int v = 0;
    for (int i = 0; i < a.length; i++) {
      v |= a[i] ^ b[i];
    }
    return v == 0;
  }

  /// Сбросить в нейтральный режим (при уходе в фон, закрытии).
  void resetToNeutral() {
    if (_showRealContent) {
      _showRealContent = false;
      notifyListeners();
    }
  }

  /// Задать reveal-код (хэш сохраняется в Vault).
  static Future<void> setRevealCode(String code) async {
    if (code.isEmpty) return;
    final hash = hashAccessCode(code);
    final vault = locator.isRegistered<VaultInterface>()
        ? locator<VaultInterface>()
        : null;
    if (vault != null) {
      await vault.write(_keyRevealCodeHash, base64Encode(hash));
    }
  }

  /// Проверить, задан ли reveal-код.
  static Future<bool> hasRevealCode() async {
    final stored = await _getStoredRevealHashStatic();
    return stored != null;
  }

  Future<List<int>?> _getStoredRevealHash() async {
    return _getStoredRevealHashStatic();
  }

  static Future<List<int>?> _getStoredRevealHashStatic() async {
    final vault = locator.isRegistered<VaultInterface>()
        ? locator<VaultInterface>()
        : null;
    if (vault == null) return null;
    final s = await vault.read(_keyRevealCodeHash);
    if (s == null || s.isEmpty) return null;
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }
}
