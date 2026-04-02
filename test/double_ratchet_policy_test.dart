import 'package:test/test.dart';
import 'package:memento_mori_app/core/double_ratchet_scaffold.dart'
    show DoubleRatchetSessionState, ratchetEligibleChatId;
import 'package:memento_mori_app/core/double_ratchet/dr_symmetric_engine.dart'
    show parseDmPeerId;

void main() {
  group('ratchetEligibleChatId', () {
    test('dm_ prefix is eligible', () {
      expect(ratchetEligibleChatId('dm_hash_peer'), isTrue);
    });

    test('public beacons are not eligible', () {
      expect(ratchetEligibleChatId('THE_BEACON_GLOBAL'), isFalse);
      expect(ratchetEligibleChatId('GLOBAL'), isFalse);
      expect(ratchetEligibleChatId('BEACON_NEARBY'), isFalse);
      expect(ratchetEligibleChatId('THE_BEACON_RU'), isFalse);
    });

    test('GHOST tactical ids are not eligible', () {
      expect(ratchetEligibleChatId('GHOST_abc_def'), isFalse);
    });

    test('empty is not eligible', () {
      expect(ratchetEligibleChatId(''), isFalse);
    });
  });

  group('parseDmPeerId', () {
    test('extracts suffix after dm_part_part', () {
      expect(parseDmPeerId('dm_abc_peer'), 'peer');
    });
  });

  group('DoubleRatchetSessionState', () {
    test('roundtrip json', () {
      final s = DoubleRatchetSessionState(
        chatId: 'dm_x_y',
        handshakeComplete: true,
        opaque: {'k': 1},
      );
      final decoded = DoubleRatchetSessionState.fromJson(s.toJson());
      expect(decoded.chatId, s.chatId);
      expect(decoded.handshakeComplete, isTrue);
      expect(decoded.opaque['k'], 1);
    });

    test('tryDeserialize invalid returns null', () {
      expect(DoubleRatchetSessionState.tryDeserialize('not-json'), isNull);
    });
  });
}
