import 'dart:convert';
import 'dart:typed_data';

import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:memento_mori_app/core/double_ratchet/dr_x25519_material.dart';
import 'package:test/test.dart';

void _wireVersionSanity() {
  expect(drDhWireVersionSupported(1), isTrue);
  expect(drDhWireVersionSupported(2), isTrue);
  expect(drDhWireVersionSupported(0), isFalse);
  expect(drDhWireVersionSupported('2'), isTrue);
}

void main() {
  test('drDhWireVersionSupported', _wireVersionSanity);

  test('X25519 + HKDF: обе стороны получают одинаковый root', () async {
    const chatId = 'dm_test_pair_ab';
    final alice = await drDhGenerateKeyPair();
    final bob = await drDhGenerateKeyPair();
    final alicePub = await alice.extractPublicKey();
    final bobPub = await bob.extractPublicKey();

    final sharedA = await drDhSharedSecretBytes(
      localKeyPair: alice,
      remotePublicKeyBytes: bobPub.bytes,
    );
    final sharedB = await drDhSharedSecretBytes(
      localKeyPair: bob,
      remotePublicKeyBytes: alicePub.bytes,
    );
    expect(sharedA, sharedB);

    final rootA = await deriveDrRootFromDhMaterial(
      sharedSecretBytes: sharedA,
      chatId: chatId,
      ephPubA: alicePub.bytes,
      ephPubB: bobPub.bytes,
    );
    final rootB = await deriveDrRootFromDhMaterial(
      sharedSecretBytes: sharedB,
      chatId: chatId,
      ephPubA: alicePub.bytes,
      ephPubB: bobPub.bytes,
    );
    expect(rootA, rootB);
    expect(rootA.length, 32);
  });

  test('drDhRootKdfFieldValid: v2 только с bundle', () {
    expect(
      drDhRootKdfFieldValid({
        'drDhRootKdf': kDrDhRootKdfV2Bundle,
        'drBundlePreKeyPub64': 'AAAA',
      }),
      isFalse,
    );
    final key32 = List<int>.generate(32, (i) => i);
    final b64 = base64Encode(key32);
    expect(
      drDhRootKdfFieldValid({
        'drDhRootKdf': kDrDhRootKdfV2Bundle,
        'drBundlePreKeyPub64': b64,
      }),
      isTrue,
    );
    expect(drDhRootKdfFieldValid({'drDhRootKdf': kDrDhRootKdfV1}), isTrue);
    expect(
      drDhRootKdfFieldValid({'drDhRootKdf': kDrDhRootKdfV2Bundle}),
      isFalse,
    );
  });

  test('Bundle KDF (фаза 7): инициатор и ответчик — один root', () async {
    const chatId = 'dm_phase7_test';
    final x = X25519();

    Future<SimpleKeyPair> kpFromSeed() async {
      final seed =
          List<int>.generate(32, (_) => math.Random.secure().nextInt(256));
      return x.newKeyPairFromSeed(seed);
    }

    final ephI = await drDhGenerateKeyPair();
    final ephR = await drDhGenerateKeyPair();
    final preI = await kpFromSeed();
    final preR = await kpFromSeed();

    final pubI = await ephI.extractPublicKey();
    final pubR = await ephR.extractPublicKey();
    final prePubI = await preI.extractPublicKey();
    final prePubR = await preR.extractPublicKey();

    final rootR = await drDhComputeRootAsResponderBundleKdf(
      responderEphKp: ephR,
      initiatorEphPub: pubI.bytes,
      initiatorInstallPrePub: prePubI.bytes,
      responderInstallKp: preR,
      chatId: chatId,
    );
    final rootI = await drDhComputeRootAsInitiatorBundleKdf(
      initiatorEphKp: ephI,
      responderEphPub: pubR.bytes,
      responderInstallPrePub: prePubR.bytes,
      initiatorInstallKp: preI,
      chatId: chatId,
    );
    expect(rootR, rootI);
    expect(rootR.length, 32);
  });

  test('HMAC init/ack: совпадение при том же legacy key', () async {
    final legacy = Uint8List.fromList(utf8.encode('01234567890123456789012345678901'));
    final msg = drDhInitHmacMessage(
      chatId: 'dm_x',
      fromUserId: 'a',
      toUserId: 'b',
      nonce64: 'bnVvbmNl',
      ephPub64: 'ZXBo',
    );
    final h1 = await drDhHmacBase64(legacy, msg);
    final h2 = await drDhHmacBase64(legacy, msg);
    expect(drDhConstantTimeEquals(h1, h2), isTrue);
    expect(drDhConstantTimeEquals(h1, 'AAAA'), isFalse);
  });
}
