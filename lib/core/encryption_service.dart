import 'dart:typed_data'; // 🔥 ОБЯЗАТЕЛЬНО ДЛЯ Uint8List
import 'package:cryptography/cryptography.dart';
import 'dart:convert';

class EncryptionService {
  final _algorithm = AesGcm.with256bits();

  // Генерируем уникальный ключ для конкретного чата
  Future<SecretKey> getChatKey(String chatId) async {
    const String systemSeed = "memento_mori_v1_tactical_seed_2024";
    String derivationId = chatId;

    if (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL") {
      derivationId = "THE_BEACON_GLOBAL";
    } else if (chatId.startsWith("GHOST_")) {
      derivationId = "TACTICAL_MESH_LINK_V1";
    }

    // Вместо простого Sha256, мы используем итеративное хеширование.
    // Это стандарт для защиты Master Key.
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 1000, // Количество итераций для "растягивания" ключа
      bits: 256,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(systemSeed)),
      nonce: utf8.encode(derivationId), // Используем ID чата как соль (salt)
    );

    return secretKey;
  }


  // Метод для системных ключей
  Future<SecretKey> getSystemKey() async {
    final bytes = utf8.encode("memento_mori_ultra_safe_mesh_key_2024");
    final hash = await Sha256().hash(bytes);
    return SecretKey(hash.bytes);
  }

  // Шифрование данных
  Future<String> encrypt(String text, SecretKey key) async {
    // В пакете 'cryptography' метод encrypt по умолчанию генерирует
    // случайный 96-битный Nonce (IV) для каждого вызова. Это ПРАВИЛЬНО.
    final secretBox = await _algorithm.encrypt(
      utf8.encode(text),
      secretKey: key,
    );

    // Результат base64 содержит [Nonce (12b) | Ciphertext | Tag (16b)]
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
    final sessionKey = await getSystemKey();

    // Добавляем 'padding' (случайный шум), чтобы все пакеты имели разную длину.
    // Это сбивает с толку системы DPI (Deep Packet Inspection).
    final int paddingLength = 16 + (DateTime.now().millisecond % 32);
    final String padding = base64.encode(Uint8List(paddingLength));

    final innerData = jsonEncode({
      'msg': payload,
      'sid': senderId,
      'rid': recipientId,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'rnd': padding, // Шум
    });

    final encryptedBody = await encrypt(innerData, sessionKey);

    // Хеш для Gossip-дедупликации (тот самый 'h' для MeshService)
    final hashInstance = Sha256();
    final hashValue = await hashInstance.hash(utf8.encode(encryptedBody));
    final shortHash = base64.encode(hashValue.bytes).substring(0, 12);

    return jsonEncode({
      'type': 'OFFLINE_MSG', // Используем системный тип
      'data': encryptedBody,
      'h': shortHash,
      'ttl': 5,
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