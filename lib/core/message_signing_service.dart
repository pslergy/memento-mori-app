import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'storage_service.dart';

/// Service for signing and verifying critical messages
/// Uses Ed25519 for message authentication
class MessageSigningService {
  static final MessageSigningService _instance = MessageSigningService._internal();
  factory MessageSigningService() => _instance;
  MessageSigningService._internal();

  static const _storage = StorageService.storage;
  static const _privateKeyKey = 'ed25519_private_key';
  static const _publicKeyKey = 'ed25519_public_key';
  
  final _algorithm = Ed25519();
  List<int>? _privateKeyBytes;
  SimplePublicKey? _publicKey;

  /// Initialize or load Ed25519 key pair
  Future<void> initialize() async {
    try {
      // Try to load existing keys
      final privateKeyBase64 = await _storage.read(key: _privateKeyKey);
      final publicKeyBase64 = await _storage.read(key: _publicKeyKey);

      if (privateKeyBase64 != null && publicKeyBase64 != null) {
        _privateKeyBytes = base64Decode(privateKeyBase64);
        _publicKey = SimplePublicKey(
          base64Decode(publicKeyBase64),
          type: KeyPairType.ed25519,
        );
        print('🔐 [Signing] Loaded existing Ed25519 key pair');
        return;
      }

      // Generate new key pair
      final keyPair = await _algorithm.newKeyPair();
      _privateKeyBytes = await keyPair.extractPrivateKeyBytes();
      _publicKey = await keyPair.extractPublicKey();

      // Store keys securely
      await _storage.write(
        key: _privateKeyKey,
        value: base64Encode(_privateKeyBytes!),
      );
      await _storage.write(
        key: _publicKeyKey,
        value: base64Encode(_publicKey!.bytes),
      );

      print('🔐 [Signing] Generated new Ed25519 key pair');
    } catch (e) {
      print('❌ [Signing] Failed to initialize: $e');
      rethrow;
    }
  }

  /// Get public key for sharing (e.g., in BLE advertising)
  Future<String?> getPublicKeyBase64() async {
    if (_publicKey == null) {
      await initialize();
    }
    return _publicKey != null ? base64Encode(_publicKey!.bytes) : null;
  }

  /// Sign a message
  Future<String> signMessage(Map<String, dynamic> message) async {
    if (_privateKeyBytes == null || _publicKey == null) {
      await initialize();
    }

    try {
      // Create canonical JSON for signing (deterministic)
      final canonicalJson = _canonicalizeJson(message);
      final messageBytes = utf8.encode(canonicalJson);

      // Sign message using stored key pair data
      // Reconstruct key pair from stored bytes
      final privateKey = SecretKey(_privateKeyBytes!);
      
      // Create key pair data for signing
      // Note: SimpleKeyPairData requires private key bytes (List<int>), not SecretKey
      final signature = await _algorithm.sign(
        messageBytes,
        keyPair: SimpleKeyPairData(
          _privateKeyBytes!,
          publicKey: _publicKey!,
          type: KeyPairType.ed25519,
        ),
      );

      return base64Encode(signature.bytes);
    } catch (e) {
      print('❌ [Signing] Failed to sign message: $e');
      rethrow;
    }
  }

  /// Verify a message signature
  Future<bool> verifyMessage(
    Map<String, dynamic> message,
    String signatureBase64,
    String publicKeyBase64,
  ) async {
    try {
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );

      final canonicalJson = _canonicalizeJson(message);
      final messageBytes = utf8.encode(canonicalJson);
      final signatureBytes = base64Decode(signatureBase64);

      final signature = Signature(
        signatureBytes,
        publicKey: publicKey,
      );

      final isValid = await _algorithm.verify(
        messageBytes,
        signature: signature,
      );

      if (!isValid) {
        print('⚠️ [Signing] Message signature verification failed');
      }

      return isValid;
    } catch (e) {
      print('❌ [Signing] Verification error: $e');
      return false;
    }
  }

  /// Create canonical JSON (deterministic, sorted keys)
  String _canonicalizeJson(Map<String, dynamic> json) {
    // Remove signature field if present (we sign without it)
    final cleanJson = Map<String, dynamic>.from(json);
    cleanJson.remove('signature');
    cleanJson.remove('publicKey');

    // Sort keys and create deterministic JSON
    final sortedKeys = cleanJson.keys.toList()..sort();
    final sortedMap = <String, dynamic>{};
    for (final key in sortedKeys) {
      sortedMap[key] = cleanJson[key];
    }

    return jsonEncode(sortedMap);
  }

  /// Encrypt token for BLE advertising (short, one-way hash)
  /// Returns first 8 characters of HMAC-SHA256(token + timestamp)
  Future<String> encryptTokenForAdvertising(String token, int expiresAt) async {
    if (_privateKeyBytes == null) {
      await initialize();
    }

    try {
      // Use private key bytes as HMAC key
      final keyBytes = _privateKeyBytes!;
      final hmac = Hmac.sha256();
      
      // Create HMAC of token + expiresAt
      final message = '$token:$expiresAt';
      final mac = await hmac.calculateMac(
        utf8.encode(message),
        secretKey: SecretKey(keyBytes),
      );

      // Return first 8 hex characters (16 hex chars = 8 bytes)
      final hex = mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return hex.substring(0, 8).toUpperCase();
    } catch (e) {
      print('❌ [Signing] Failed to encrypt token: $e');
      // Fallback: return first 8 chars of token (less secure but works)
      return token.length >= 8 ? token.substring(0, 8) : token;
    }
  }

  /// Verify token from BLE advertising
  /// Returns true if token matches the encrypted value
  Future<bool> verifyTokenFromAdvertising(
    String encryptedToken,
    String actualToken,
    int expiresAt,
  ) async {
    try {
      final expected = await encryptTokenForAdvertising(actualToken, expiresAt);
      return encryptedToken == expected;
    } catch (e) {
      print('❌ [Signing] Token verification error: $e');
      return false;
    }
  }
}
