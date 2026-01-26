import 'dart:typed_data'; // 🔥 ОБЯЗАТЕЛЬНО ДЛЯ Uint8List
import 'dart:math' as math;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

class EncryptionService {
  final _algorithm = AesGcm.with256bits();
  
  // 🔒 SECURITY FIX: Secure storage for user-specific salt
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  
  // 🔒 SECURITY FIX: Cache user salt in memory for performance
  static String? _cachedUserSalt;
  
  // 🔒 SECURITY FIX: PBKDF2 iterations - OWASP recommendation for HMAC-SHA256
  static const int _pbkdf2Iterations = 100000;

  /// 🔒 SECURITY FIX: Generate or retrieve user-specific salt
  /// Each user has a unique salt stored in secure storage
  Future<String> _getUserSalt() async {
    if (_cachedUserSalt != null) return _cachedUserSalt!;
    
    String? salt = await _secureStorage.read(key: 'user_encryption_salt');
    
    if (salt == null) {
      // Generate new cryptographically secure salt (32 bytes = 256 bits)
      final random = math.Random.secure();
      final saltBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        saltBytes[i] = random.nextInt(256);
      }
      salt = base64.encode(saltBytes);
      
      // Store salt securely
      await _secureStorage.write(key: 'user_encryption_salt', value: salt);
      print("🔐 [Security] New user encryption salt generated");
    }
    
    _cachedUserSalt = salt;
    return salt;
  }

  /// 🔒 SECURITY FIX: Per-user key derivation instead of hardcoded key
  /// Generates unique key for each chat using user-specific salt
  Future<SecretKey> getChatKey(String chatId) async {
    // 🔒 Get user-specific salt (unique per device/user)
    final userSalt = await _getUserSalt();
    
    String derivationId = chatId;

    if (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL") {
      derivationId = "THE_BEACON_GLOBAL";
    } else if (chatId.startsWith("GHOST_")) {
      derivationId = "TACTICAL_MESH_LINK_V1";
    }

    // 🔒 SECURITY FIX: PBKDF2 with 100,000 iterations (OWASP recommendation)
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256,
    );

    // 🔒 Derive key using user salt + chat ID
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(base64.decode(userSalt)),
      nonce: utf8.encode(derivationId),
    );

    return secretKey;
  }

  /// 🔒 SECURITY FIX: System key now uses user-specific derivation
  Future<SecretKey> getSystemKey() async {
    final userSalt = await _getUserSalt();
    
    // 🔒 Derive system key from user salt with different context
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256,
    );
    
    return await pbkdf2.deriveKey(
      secretKey: SecretKey(base64.decode(userSalt)),
      nonce: utf8.encode('MEMENTO_MORI_SYSTEM_KEY_V2'),
    );
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

    // 🔒 Fix Ghost Identity collision: Add secure random to prevent collisions
    final random = math.Random.secure();
    final randomSuffix = random.nextInt(999999);
    final String ghostId = "GHOST_${DateTime.now().millisecondsSinceEpoch}_${username.hashCode.abs()}_$randomSuffix";

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

  /// 🔒 SECURITY FIX: Landing pass now uses user-specific salt
  /// Creates unique "Landing Pass" for offline account legalization
  Future<String> generateLandingPass(String email, String ghostId) async {
    final userSalt = await _getUserSalt();
    
    // 🔒 Use PBKDF2 for landing pass derivation
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256,
    );
    
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(base64.decode(userSalt)),
      nonce: utf8.encode('$email:$ghostId:LANDING_PASS_V2'),
    );
    
    final keyBytes = await key.extractBytes();
    return base64.encode(keyBytes);
  }

  // 🔥 Метод для "затирания" конфиденциальных данных в памяти
  // Теперь Uint8List распознается благодаря импорту
  void clearSensitiveData(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      data[i] = 0; // Заполняем нулями
    }
  }
}