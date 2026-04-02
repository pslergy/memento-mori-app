import 'dart:convert';
import 'dart:typed_data';

import 'package:memento_mori_app/core/double_ratchet/dr_symmetric_engine.dart';
import 'package:test/test.dart';

void main() {
  test('low/high chains: roundtrip alternating', () async {
    const chatId = 'dm_x_peer';
    final root = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      root[i] = i ^ 0x5a;
    }
    final low = await DrSymmetricEngine.bootstrapFromLegacyKey(
      legacyKeyMaterial: root,
      chatId: chatId,
      iAmLow: true,
    );
    final high = await DrSymmetricEngine.bootstrapFromLegacyKey(
      legacyKeyMaterial: root,
      chatId: chatId,
      iAmLow: false,
    );

    final w0 = await low.encryptOutgoing(utf8.encode('hello'));
    final p0 = await high.decryptIncoming(w0.ciphertext, w0.headerJson);
    expect(utf8.decode(p0!), 'hello');

    final w1 = await high.encryptOutgoing(utf8.encode('world'));
    final p1 = await low.decryptIncoming(w1.ciphertext, w1.headerJson);
    expect(utf8.decode(p1!), 'world');
  });

  test('out-of-order within skip window', () async {
    const chatId = 'dm_a_b';
    final root = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final alice = await DrSymmetricEngine.bootstrapFromLegacyKey(
      legacyKeyMaterial: root,
      chatId: chatId,
      iAmLow: true,
    );
    final bob = await DrSymmetricEngine.bootstrapFromLegacyKey(
      legacyKeyMaterial: root,
      chatId: chatId,
      iAmLow: false,
    );

    final w0 = await alice.encryptOutgoing(utf8.encode('m0'));
    final w2 = await alice.encryptOutgoing(utf8.encode('m2'));
    final p2 = await bob.decryptIncoming(w2.ciphertext, w2.headerJson);
    expect(utf8.decode(p2!), 'm2');
    final p0 = await bob.decryptIncoming(w0.ciphertext, w0.headerJson);
    expect(utf8.decode(p0!), 'm0');
  });

  test('parseDmPeerId', () {
    expect(parseDmPeerId('dm_hash123_friendId'), 'friendId');
    expect(parseDmPeerId('THE_BEACON_GLOBAL'), isNull);
  });

  test('gap larger than kDrMaxReceiveSkip fails', () async {
    const chatId = 'dm_gap';
    final root = Uint8List.fromList(List.generate(32, (i) => i + 3));
    final low = DrSymmetricEngine.bootstrapFromRoot32(root32: root, iAmLow: true);
    final high = DrSymmetricEngine.bootstrapFromRoot32(root32: root, iAmLow: false);

    for (var i = 0; i <= kDrMaxReceiveSkip + 1; i++) {
      await low.encryptOutgoing(utf8.encode('x$i'));
    }
    final wBig = await low.encryptOutgoing(utf8.encode('too_far'));
    final fail = await high.decryptIncoming(wBig.ciphertext, wBig.headerJson);
    expect(fail, isNull);
  });

  test('replay same ciphertext after decrypt is rejected', () async {
    const chatId = 'dm_repl';
    final root = Uint8List.fromList(List.generate(32, (i) => 0xab));
    final alice = DrSymmetricEngine.bootstrapFromRoot32(root32: root, iAmLow: true);
    final bob = DrSymmetricEngine.bootstrapFromRoot32(root32: root, iAmLow: false);

    final w = await alice.encryptOutgoing(utf8.encode('once'));
    final p1 = await bob.decryptIncoming(w.ciphertext, w.headerJson);
    expect(utf8.decode(p1!), 'once');
    final p2 = await bob.decryptIncoming(w.ciphertext, w.headerJson);
    expect(p2, isNull);
  });
}
