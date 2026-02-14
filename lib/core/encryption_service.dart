import 'dart:typed_data';
import 'dart:math' as math;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

import 'decoy/vault_interface.dart';

/// SECURITY INVARIANT: Key derivation MUST include mode as entropy. When [VaultInterface]
/// is injected (mode-scoped), salt is stored in that vault. No shared crypto singletons.
class EncryptionService {
  EncryptionService([VaultInterface? vault]) : _vault = vault;

  final VaultInterface? _vault;
  final _algorithm = AesGcm.with256bits();

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? _cachedUserSalt;
  static const int _pbkdf2Iterations = 100000;

  /// Mode exit: wipe in-memory crypto material. Call before DI reset.
  void clearCachedSecrets() {
    _cachedUserSalt = null;
  }

  Future<String> _getUserSalt() async {
    if (_cachedUserSalt != null) return _cachedUserSalt!;
    String? salt;
    if (_vault != null) {
      salt = await _vault!.read('user_encryption_salt');
    } else {
      salt = await _secureStorage.read(key: 'user_encryption_salt');
    }
    if (salt == null) {
      final random = math.Random.secure();
      final saltBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) saltBytes[i] = random.nextInt(256);
      salt = base64.encode(saltBytes);
      if (_vault != null) {
        await _vault!.write('user_encryption_salt', salt);
      } else {
        await _secureStorage.write(key: 'user_encryption_salt', value: salt);
      }
    }
    _cachedUserSalt = salt;
    return salt;
  }

  /// 🔒 SECURITY FIX: Per-user key derivation instead of hardcoded key
  /// Generates unique key for each chat using user-specific salt.
  /// THE_BEACON_GLOBAL uses a shared fixed seed so all devices can decrypt mesh messages in global chat.
  Future<SecretKey> getChatKey(String chatId) async {
    String derivationId = chatId;
    if (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL") {
      derivationId = "THE_BEACON_GLOBAL";
    } else if (chatId.startsWith("GHOST_")) {
      derivationId = "TACTICAL_MESH_LINK_V1";
    }

    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256,
    );

    // 🔒 THE_BEACON_GLOBAL: shared key so mesh peers can decrypt each other's messages
    if (chatId == "GLOBAL" || chatId == "THE_BEACON_GLOBAL") {
      const fixedSeed = "MEMENTO_BEACON_GLOBAL_SHARED_V1";
      return pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(fixedSeed)),
        nonce: utf8.encode(derivationId),
      );
    }

    final userSalt = await _getUserSalt();
    return pbkdf2.deriveKey(
      secretKey: SecretKey(base64.decode(userSalt)),
      nonce: utf8.encode(derivationId),
    );
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

  /// Этап 1: макс. длина случайного padding (байт) для рандомизации размера пакета.
  static const int _paddingMaxBytes = 64;

  // Шифрование данных
  Future<String> encrypt(String text, SecretKey key) async {
    // Этап 1: случайный padding для рандомизации длины (снижение паттернов).
    final rnd = math.Random.secure();
    final padLen = rnd.nextInt(_paddingMaxBytes + 1);
    final padBytes = padLen > 0
        ? Uint8List.fromList(List.generate(padLen, (_) => rnd.nextInt(256)))
        : null;
    final plaintext = padBytes != null
        ? '$text\x00${base64.encode(padBytes)}'
        : text;

    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
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
    final String ghostId =
        "GHOST_${DateTime.now().millisecondsSinceEpoch}_${username.hashCode.abs()}_$randomSuffix";

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

      final secretBox =
          SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16);

      final decryptedBytes =
          await _algorithm.decrypt(secretBox, secretKey: key);
      final decoded = utf8.decode(decryptedBytes);
      // Этап 1: убираем padding (формат content + "\x00" + base64)
      final idx = decoded.indexOf('\x00');
      return idx >= 0 ? decoded.substring(0, idx) : decoded;
    } catch (e) {
      // Не показываем сырой шифртекст в UI — возвращаем placeholder
      print("⚠️ [Decrypt] Not a valid ciphertext or wrong key. Returning placeholder.");
      return "[Secure message unavailable]";
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
