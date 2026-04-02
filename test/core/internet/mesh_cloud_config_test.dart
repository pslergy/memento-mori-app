import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/mesh_cloud_config.dart';

Future<String> _signedEnvelope({
  required String bodyStr,
  required SimplePublicKey publicKey,
  required List<int> privateKeyBytes,
}) async {
  final algorithm = Ed25519();
  final keyPairData = SimpleKeyPairData(
    privateKeyBytes,
    publicKey: publicKey,
    type: KeyPairType.ed25519,
  );
  final signature = await algorithm.sign(
    utf8.encode(bodyStr),
    keyPair: keyPairData,
  );
  final sigHex = signature.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return jsonEncode({
    'v': 1,
    'body': bodyStr,
    'sig': sigHex,
  });
}

void main() {
  group('MeshCloudSignedBundle', () {
    test('parseAndVerify accepts valid Ed25519 signature', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

      final bodyStr = jsonEncode({
        'config_version': 42,
        'issued_at': DateTime.now().toUtc().toIso8601String(),
        'ttl_sec': 3600,
        'channels': [
          {'host': 'api.example.com', 'port': 443},
        ],
        'donors': [
          {'host': 'd.example.com', 'mode': 'm', 'padding': null},
        ],
      });

      final envelope = await _signedEnvelope(
        bodyStr: bodyStr,
        publicKey: publicKey,
        privateKeyBytes: privateKeyBytes,
      );

      final snap = await MeshCloudSignedBundle.parseAndVerify(
        envelope,
        publicKey.bytes,
      );

      expect(snap, isNotNull);
      expect(snap!.configVersion, 42);
      expect(snap.channels.length, 1);
      expect(snap.channels.first.host, 'api.example.com');
      expect(snap.channels.first.port, 443);
      expect(snap.donors, isNotNull);
      expect(snap.donors!.first.donorHost, 'd.example.com');
    });

    test('parseAndVerify rejects wrong signature', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      final bodyStr = jsonEncode({
        'config_version': 1,
        'issued_at': DateTime.now().toUtc().toIso8601String(),
        'ttl_sec': 3600,
        'channels': [
          {'host': 'x.test', 'port': 443},
        ],
      });

      final broken = jsonEncode({
        'v': 1,
        'body': bodyStr,
        'sig': '00' * 32,
      });

      final snapBad = await MeshCloudSignedBundle.parseAndVerify(
        broken,
        publicKey.bytes,
      );
      expect(snapBad, isNull);
    });

    test('parseAndVerify rejects expired ttl', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

      final bodyStr = jsonEncode({
        'config_version': 1,
        'issued_at': '2020-01-01T00:00:00.000Z',
        'ttl_sec': 60,
        'channels': [
          {'host': 'old.test', 'port': 443},
        ],
      });

      final envelope = await _signedEnvelope(
        bodyStr: bodyStr,
        publicKey: publicKey,
        privateKeyBytes: privateKeyBytes,
      );

      final snap = await MeshCloudSignedBundle.parseAndVerify(
        envelope,
        publicKey.bytes,
      );
      expect(snap, isNull);
    });

    test('parseAndVerify rejects wrong envelope version', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

      final bodyStr = jsonEncode({
        'config_version': 1,
        'issued_at': DateTime.now().toUtc().toIso8601String(),
        'ttl_sec': 3600,
        'channels': [
          {'host': 'a.test', 'port': 1},
        ],
      });

      final inner = await _signedEnvelope(
        bodyStr: bodyStr,
        publicKey: publicKey,
        privateKeyBytes: privateKeyBytes,
      );
      final map = jsonDecode(inner) as Map<String, dynamic>;
      map['v'] = 2;
      final envelope = jsonEncode(map);

      final snap = await MeshCloudSignedBundle.parseAndVerify(
        envelope,
        publicKey.bytes,
      );
      expect(snap, isNull);
    });

    test('parseAndVerify rejects invalid public key length', () async {
      final snap = await MeshCloudSignedBundle.parseAndVerify('{}', [1, 2, 3]);
      expect(snap, isNull);
    });
  });
}
