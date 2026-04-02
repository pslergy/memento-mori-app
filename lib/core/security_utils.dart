import 'dart:typed_data';

/// Этап 1: утилиты для минимизации утечек в памяти.
/// Этап 2.1: граница отправки — в транспорт (сокет/GATT) передаётся только ciphertext;
/// см. mesh_service.sendAuto (инвариант: только encryptedContent/offlinePacket).
/// В Dart нельзя затереть String (immutable). Callers должны не хранить
/// plaintext/ключи в долгоживущих переменных и не логировать их.

/// Затирает байты буфера нулями. Вызывать после использования секрета.
void wipeBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return;
  for (int i = 0; i < bytes.length; i++) bytes[i] = 0;
}
