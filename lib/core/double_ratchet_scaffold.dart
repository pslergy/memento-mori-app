// Скелет для будущего Double Ratchet (E2EE с forward secrecy).
// Production-путь не использует этот класс; EncryptionService не изменён.
// См. DOUBLE_RATCHET_DESIGN.md.

/// Заглушка будущей сессии Double Ratchet для одного чата/пары.
/// Реализация — в следующих итерациях; не вызывать из sendAuto/processIncomingPacket.
class DoubleRatchetSession {
  final String chatOrPeerId;

  DoubleRatchetSession({required this.chatOrPeerId});

  /// Зашифровать payload (пока не реализовано).
  Future<List<int>?> encrypt(List<int> plaintext) async => null;

  /// Расшифровать payload (пока не реализовано).
  Future<List<int>?> decrypt(List<int> ciphertext) async => null;

  /// Есть ли активная сессия (пока всегда false).
  bool get isActive => false;
}
