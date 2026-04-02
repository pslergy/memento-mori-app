import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/dpi_backend_channel_gate.dart';
import 'package:memento_mori_app/core/security_config.dart';

void main() {
  group('SecurityConfig manual backend channel', () {
    tearDown(() {
      SecurityConfig.clearMeshCloudRuntimeChannels();
      SecurityConfig.selectBackendChannelIndex(0);
      DpiBackendChannelGate.resetForTest();
    });

    test('cycleBackendChannelManual rotates within effective list', () {
      SecurityConfig.clearMeshCloudRuntimeChannels();
      final n = SecurityConfig.effectiveBackendChannels.length;
      expect(n, greaterThanOrEqualTo(2));

      expect(SecurityConfig.currentChannelIndex, 0);
      SecurityConfig.cycleBackendChannelManual();
      expect(SecurityConfig.currentChannelIndex, 1);
      SecurityConfig.cycleBackendChannelManual();
      expect(SecurityConfig.currentChannelIndex, 0);
    });

    test('selectBackendChannelIndex ignores out of range', () {
      SecurityConfig.clearMeshCloudRuntimeChannels();
      SecurityConfig.selectBackendChannelIndex(0);
      SecurityConfig.selectBackendChannelIndex(-1);
      expect(SecurityConfig.currentChannelIndex, 0);
      SecurityConfig.selectBackendChannelIndex(99999);
      expect(SecurityConfig.currentChannelIndex, 0);
    });
  });
}
