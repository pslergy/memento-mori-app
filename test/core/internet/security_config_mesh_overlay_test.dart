import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/mesh_cloud_config.dart';
import 'package:memento_mori_app/core/security_config.dart';

void main() {
  group('SecurityConfig mesh overlay (D4)', () {
    tearDown(SecurityConfig.clearMeshCloudRuntimeChannels);

    test('effectiveBackendChannels falls back to const when no overlay', () {
      SecurityConfig.clearMeshCloudRuntimeChannels();
      expect(
        SecurityConfig.effectiveBackendChannels,
        SecurityConfig.backendChannels,
      );
    });

    test('applyMeshCloudBackendChannels switches effective list', () {
      SecurityConfig.clearMeshCloudRuntimeChannels();
      final snap = MeshCloudConfigSnapshot(
        configVersion: 99,
        issuedAt: DateTime.now().toUtc(),
        ttlSec: 3600,
        channels: const [
          MeshCloudBackendChannel(host: 'overlay.test', port: 8443),
        ],
      );
      SecurityConfig.applyMeshCloudBackendChannels(snap);
      expect(SecurityConfig.effectiveBackendChannels.length, 1);
      expect(SecurityConfig.effectiveBackendChannels.first.host, 'overlay.test');
      expect(SecurityConfig.effectiveBackendChannels.first.port, 8443);
      expect(SecurityConfig.meshAppliedConfigVersion, 99);
      expect(SecurityConfig.backendBaseUrl, contains('overlay.test'));
      expect(SecurityConfig.backendBaseUrl, contains('8443'));
    });
  });
}
