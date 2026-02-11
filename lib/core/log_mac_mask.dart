// lib/core/log_mac_mask.dart
// Скрытие MAC в логах, чтобы нельзя было отследить устройство по первым байтам.

/// Возвращает маскированную строку для логов: только последние 5 символов (••:••:••:••:XX:XX).
/// Для пустой строки возвращает '••••'.
String maskMacForLog(String mac) {
  if (mac.isEmpty) return '••••';
  return mac.length >= 5 ? '••:••:••:••:${mac.substring(mac.length - 5)}' : '••••';
}
