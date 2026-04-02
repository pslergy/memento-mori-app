// Stress test — Wi-Fi fake with failure injection.
// Extends FakeWifiService. Test utilities only.

import 'dart:math' as math;

import 'fake_wifi_service.dart';

/// Wi-Fi fake that randomly fails sends. For stress testing cascade fallback.
class StressFakeWifiService extends FakeWifiService {
  StressFakeWifiService({required super.nodeId, this.random});

  final math.Random? random;
  double _failureRate = 0.0;

  /// Set failure rate 0.0–1.0. When > 0, sendTcp randomly fails.
  void setFailureRate(double rate) {
    _failureRate = rate.clamp(0.0, 1.0);
  }

  double get failureRate => _failureRate;

  @override
  Future<void> sendTcp(String message, {String? host, int? port}) async {
    if (_failureRate > 0) {
      final r = random ?? math.Random();
      if (r.nextDouble() < _failureRate) {
        throw StateError('StressFakeWifi: simulated Wi-Fi send failure');
      }
    }
    return super.sendTcp(message, host: host, port: port);
  }
}
