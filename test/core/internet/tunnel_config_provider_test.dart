import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/tunnel_config.dart';
import 'package:memento_mori_app/core/internet/tunnel_config_provider.dart';

void main() {
  group('TunnelConfigProvider', () {
    test('rotateDonorOnDpiSignal cycles static donors', () async {
      final p = TunnelConfigProvider(donorCycle: const [
        TunnelConfig(donorHost: 'a.test', mode: 'unknown'),
        TunnelConfig(donorHost: 'b.test', mode: 'unknown'),
      ]);
      final first = await p.selectConfig();
      expect(first.donorHost, 'a.test');
      p.rotateDonorOnDpiSignal();
      final second = await p.selectConfig();
      expect(second.donorHost, 'b.test');
      p.rotateDonorOnDpiSignal();
      final third = await p.selectConfig();
      expect(third.donorHost, 'a.test');
    });

    test('single donor: rotate does not change host', () async {
      final p = TunnelConfigProvider(donorCycle: const [
        TunnelConfig(donorHost: 'only.test', mode: 'unknown'),
      ]);
      expect((await p.selectConfig()).donorHost, 'only.test');
      p.rotateDonorOnDpiSignal();
      expect((await p.selectConfig()).donorHost, 'only.test');
    });

    test('applyMeshOverlayDonors overrides static pool until cleared', () async {
      final p = TunnelConfigProvider(donorCycle: const [
        TunnelConfig(donorHost: 'static.test', mode: 'unknown'),
      ]);
      p.applyMeshOverlayDonors(const [
        TunnelConfig(donorHost: 'mesh.test', mode: 'm'),
      ]);
      expect((await p.selectConfig()).donorHost, 'mesh.test');
      p.clearMeshOverlayDonors();
      expect((await p.selectConfig()).donorHost, 'static.test');
    });
  });
}
