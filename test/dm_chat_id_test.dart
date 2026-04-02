import 'package:memento_mori_app/core/dm_chat_id.dart';
import 'package:memento_mori_app/core/dm_chat_id_migration.dart';
import 'package:test/test.dart';

void main() {
  test('canonicalDirectChatId is commutative', () {
    final a = canonicalDirectChatId('user_a', 'user_b');
    final b = canonicalDirectChatId('user_b', 'user_a');
    expect(a, b);
    expect(a.startsWith('dm_'), isTrue);
    expect(a.length, greaterThan(10));
  });

  test('directChatIdMatchesPeer', () {
    final id = canonicalDirectChatId('alice', 'bob');
    expect(directChatIdMatchesPeer(id, 'alice', 'bob'), isTrue);
    expect(directChatIdMatchesPeer(id, 'bob', 'alice'), isTrue);
    expect(directChatIdMatchesPeer(id, 'alice', 'carol'), isFalse);
  });

  test('migrateDmHistoryChatId maps legacy dm_*_peer to canonical', () {
    final canonical = canonicalDirectChatId('alice', 'bob');
    final legacy = 'dm_oldhash_bob';
    expect(
      migrateDmHistoryChatId(
        storedChatId: legacy,
        myUserId: 'alice',
        peerUserId: 'bob',
      ),
      canonical,
    );
    expect(
      migrateDmHistoryChatId(
        storedChatId: canonical,
        myUserId: 'alice',
        peerUserId: 'bob',
      ),
      canonical,
    );
  });
}
