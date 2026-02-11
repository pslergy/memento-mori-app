// lib/core/decoy/gate_storage.dart
//
// Нейтральное хранилище для двух кодов доступа (REAL / DECOY).
// Хранит только хеши и последний режим; не раскрывает, какой код «основной», какой «аварийный».
// Константное время и одинаковое поведение для обоих режимов.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_mode.dart';

const _keyHashPrimary = 'gate_hash_primary';
const _keyHashAlternative = 'gate_hash_alternative';
const _keyMode = 'gate_mode';

final _secure = const FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// Сохраняет хеши двух кодов (bytes → base64). Порядок: первый = основной месс, второй = аварийный.
Future<void> saveGateHashes(List<int> primaryHash, List<int> alternativeHash) async {
  await _secure.write(key: _keyHashPrimary, value: base64Encode(primaryHash));
  await _secure.write(key: _keyHashAlternative, value: base64Encode(alternativeHash));
}

/// Возвращает оба хеша или null, если ещё не заданы.
Future<({List<int> primary, List<int> alternative})?> getGateHashes() async {
  final p = await _secure.read(key: _keyHashPrimary);
  final a = await _secure.read(key: _keyHashAlternative);
  if (p == null || p.isEmpty || a == null || a.isEmpty) return null;
  try {
    return (primary: base64Decode(p), alternative: base64Decode(a));
  } catch (_) {
    return null;
  }
}

/// Проверяет, заданы ли оба кода (для показа экрана установки кодов).
Future<bool> hasGateHashes() async {
  final h = await getGateHashes();
  return h != null;
}

/// Сохраняет последний использованный режим (для холодного старта и смены режима).
Future<void> saveGateMode(AppMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyMode, mode.name);
}

/// Читает последний режим. По умолчанию REAL (до первой установки кодов).
Future<AppMode> getGateMode() async {
  final prefs = await SharedPreferences.getInstance();
  final s = prefs.getString(_keyMode);
  if (s == AppMode.DECOY.name) return AppMode.DECOY;
  return AppMode.REAL;
}
