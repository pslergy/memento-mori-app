import 'package:shared_preferences/shared_preferences.dart';

/// Локальный UX для DM: лимит исходящих сообщений до ротации ключа (повторный DR_DH).
class DmSessionUiGuard {
  DmSessionUiGuard._();

  static const int outboundMessagesBeforeRotation = 10;

  static String _prefsCount(String chatId) => 'dm_outbound_since_hs_$chatId';

  static Future<int> getOutboundCountSinceHandshake(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsCount(chatId)) ?? 0;
  }

  static Future<void> resetOutboundCount(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsCount(chatId));
  }

  /// Учитывает одно успешно отправленное сообщение по mesh. При достижении лимита
  /// вызывает [onRotationRequired] (очистка сессии + повторный handshake).
  /// Возвращает `true`, если запущена ротация.
  static Future<bool> recordOutboundSuccessfulSend({
    required String chatId,
    required Future<void> Function() onRotationRequired,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _prefsCount(chatId);
    final n = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setInt(key, n);
    if (n >= outboundMessagesBeforeRotation) {
      await prefs.remove(key);
      await onRotationRequired();
      return true;
    }
    return false;
  }
}
