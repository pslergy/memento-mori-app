import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/dpi_backend_channel_gate.dart';
import 'package:memento_mori_app/core/internet/dpi_policy_constants.dart';

void main() {
  group('DpiBackendChannelGate', () {
    setUp(DpiBackendChannelGate.resetForTest);

    test('increments until threshold then resets counter', () {
      expect(DpiBackendChannelGate.consecutiveEligibleFailuresForTest, 0);
      DpiBackendChannelGate.onEligibleForBackendChannelRotate();
      expect(
        DpiBackendChannelGate.consecutiveEligibleFailuresForTest,
        1,
      );
      DpiBackendChannelGate.onEligibleForBackendChannelRotate();
      expect(
        DpiBackendChannelGate.consecutiveEligibleFailuresForTest,
        2,
      );
      DpiBackendChannelGate.onEligibleForBackendChannelRotate();
      expect(
        DpiBackendChannelGate.consecutiveEligibleFailuresForTest,
        0,
      );
    });

    test('resetOnHttpSuccess clears counter', () {
      DpiBackendChannelGate.onEligibleForBackendChannelRotate();
      expect(DpiBackendChannelGate.consecutiveEligibleFailuresForTest, 1);
      DpiBackendChannelGate.resetOnHttpSuccess();
      expect(DpiBackendChannelGate.consecutiveEligibleFailuresForTest, 0);
    });

    test('threshold matches constant', () {
      expect(kDpiBackendChannelRotateAfterConsecutiveFailures, 3);
    });
  });
}
