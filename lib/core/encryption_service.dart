import 'dart:typed_data'; // 🔥 ОБЯЗАТЕЛЬНО ДЛЯ Uint8List
import 'package:cryptography/cryptography.dart';
import 'dart:convert';

class EncryptionService {
  final _algorithm = AesGcm.with256bits();

  // Генерируем уникальный ключ для конкретного чата
  Future<SecretKey> getChatKey(String chatId) async {
    // 🔥 УНИФИКАЦИЯ: Всегда используем один сид для Глобального маяка
    final String derivationId = (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL")
        ? "THE_BEACON_GLOBAL"
        : chatId;

    final systemSeed = "memento_mori_v1_tactical_seed_2024";
    final bytes = utf8.encode(systemSeed + derivationId);
    final hash = await Sha256().hash(bytes);
    return SecretKey(hash.bytes);
  }

  // Метод для системных ключей
  Future<SecretKey> getSystemKey() async {
    final bytes = utf8.encode("memento_mori_ultra_safe_mesh_key_2024");
    final hash = await Sha256().hash(bytes);
    return SecretKey(hash.bytes);
  }

  // Шифрование данных
  Future<String> encrypt(String text, SecretKey key) async {
    final secretBox = await _algorithm.encrypt(
      utf8.encode(text),
      secretKey: key,
    );
    return base64.encode(secretBox.concatenation());
  }

  Future<Map<String, String>> generateGhostIdentity(String username) async {
    final algorithm = Ed25519();

    // Генерируем пару ключей (Приватный/Публичный)
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

    // Создаем уникальный Ghost ID
    final String ghostId = "GHOST_${DateTime.now().millisecondsSinceEpoch}_${username.hashCode.abs()}";

    print("🛡️ [Security] Ghost Identity established locally for: $username");

    return {
      'userId': ghostId,
      'username': username,
      'privateKey': base64.encode(privateKeyBytes),
      'publicKey': base64.encode(publicKey.bytes),
    };
  }

  /// Создает зашифрованный контейнер (Stealth Packet)
  Future<String> createStealthPacket({
    required String payload,
    required String recipientId,
    required String senderId,
  }) async {
    final sessionKey = await getSystemKey(); // Общий ключ сети

    final innerData = jsonEncode({
      'msg': payload,
      'sid': senderId,
      'rid': recipientId,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    // Шифруем тело
    final encryptedBody = await encrypt(innerData, sessionKey);

    // Вычисляем хеш для проверки целостности через Sha256 из пакета cryptography
    final hashInstance = Sha256();
    final hashValue = await hashInstance.hash(utf8.encode(encryptedBody));
    final shortHash = base64.encode(hashValue.bytes).substring(0, 8);

    return jsonEncode({
      'type': 'GOSSIP_PULSE',
      'data': encryptedBody,
      'h': shortHash,
    });
  }

  // Расшифровка данных
  Future<String> decrypt(String cipherText, SecretKey key) async {
    // 1. Простейшая проверка: шифр не может содержать пробелов и должен быть длинным
    if (cipherText.contains(" ") || cipherText.length < 20) {
      return cipherText; // Возвращаем как есть, это не шифр
    }

    try {
      // 2. Проверка на валидность Base64
      final bytes = base64.decode(cipherText);

      final secretBox = SecretBox.fromConcatenation(
          bytes,
          nonceLength: 12,
          macLength: 16
      );

      final decryptedBytes = await _algorithm.decrypt(secretBox, secretKey: key);
      return utf8.decode(decryptedBytes);
    } catch (e) {
      // Если это не Base64 или ошибка ключа — не паникуем, отдаем оригинал
      print("⚠️ [Decrypt] Not a valid ciphertext or wrong key. Returning raw.");
      return cipherText;
    }
  }

  /// Создает уникальный "Посадочный талон" для легализации оффлайн-аккаунта
  Future<String> generateLandingPass(String email, String ghostId) async {
    final bytes = utf8.encode(email + ghostId + "memento_mori_salt_2024");
    final hash = await Sha256().hash(bytes);
    return base64.encode(hash.bytes);
  }

  // 🔥 Метод для "затирания" конфиденциальных данных в памяти
  // Теперь Uint8List распознается благодаря импорту
  void clearSensitiveData(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      data[i] = 0; // Заполняем нулями
    }
  }
}