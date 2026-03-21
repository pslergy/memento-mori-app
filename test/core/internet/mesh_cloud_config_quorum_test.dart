import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/mesh_cloud_config_quorum.dart';

void main() {
  group('MeshCloudConfigQuorum', () {
    test('minDistinctSenders 1 always true', () {
      final q = MeshCloudConfigQuorum(
        minDistinctSenders: 1,
        window: const Duration(minutes: 5),
      );
      expect(
        q.recordAndCheckQuorum(envelopeHash: 'h1', senderId: 'a'),
        isTrue,
      );
    });

    test('requires two distinct senders when min is 2', () {
      final q = MeshCloudConfigQuorum(
        minDistinctSenders: 2,
        window: const Duration(minutes: 5),
      );
      expect(
        q.recordAndCheckQuorum(envelopeHash: 'hx', senderId: 'u1'),
        isFalse,
      );
      expect(
        q.recordAndCheckQuorum(envelopeHash: 'hx', senderId: 'u2'),
        isTrue,
      );
    });

    test('same sender twice does not increase quorum', () {
      final q = MeshCloudConfigQuorum(
        minDistinctSenders: 2,
        window: const Duration(minutes: 5),
      );
      expect(
        q.recordAndCheckQuorum(envelopeHash: 'hy', senderId: 'u1'),
        isFalse,
      );
      expect(
        q.recordAndCheckQuorum(envelopeHash: 'hy', senderId: 'u1'),
        isFalse,
      );
    });
  });
}
