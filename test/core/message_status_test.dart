import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/message_status.dart';

void main() {
  group('MessageStatus', () {
    test('getDisplayText returns non-empty for all known statuses', () {
      expect(MessageStatus.getDisplayText(MessageStatus.sending), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.sentLocal), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.deliveredMesh), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.deliveredServer), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.deliveredToNetwork), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.deliveredToParticipants), isNotEmpty);
      expect(MessageStatus.getDisplayText(MessageStatus.localOnly), isNotEmpty);
    });

    test('isDelivered returns true for delivered statuses', () {
      expect(MessageStatus.isDelivered(MessageStatus.deliveredMesh), isTrue);
      expect(MessageStatus.isDelivered(MessageStatus.deliveredServer), isTrue);
      expect(MessageStatus.isDelivered(MessageStatus.deliveredToNetwork), isTrue);
      expect(MessageStatus.isDelivered(MessageStatus.deliveredToParticipants), isTrue);
    });

    test('isDelivered returns false for sending statuses', () {
      expect(MessageStatus.isDelivered(MessageStatus.sending), isFalse);
      expect(MessageStatus.isDelivered(MessageStatus.sentLocal), isFalse);
    });

    test('getStatusIcon returns single character for known statuses', () {
      expect(MessageStatus.getStatusIcon(MessageStatus.sending), isNotEmpty);
      expect(MessageStatus.getStatusIcon(MessageStatus.deliveredMesh), isNotEmpty);
    });

    test('getDisplayText returns status string for unknown status', () {
      expect(MessageStatus.getDisplayText('UNKNOWN'), equals('UNKNOWN'));
    });
  });
}
