import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/tunnel_config.dart';
import 'package:memento_mori_app/core/internet/tunnel_donors.dart';

void main() {
  group('T05 donor pool consistency', () {
    test('first cycle entry matches kDefaultTunnelDonorHost and defaultConfig', () {
      expect(kDefaultTunnelDonorCycle.first.donorHost, kDefaultTunnelDonorHost);
      expect(TunnelConfig.defaultConfig.donorHost, kDefaultTunnelDonorHost);
    });

    test('cycle has at least one donor', () {
      expect(kDefaultTunnelDonorCycle, isNotEmpty);
    });
  });
}
