// Stress test — BLE fake with failure injection.
// Extends FakeBluetoothService. Test utilities only.

import 'dart:math' as math;

import 'fake_bluetooth_service.dart';

/// BLE fake that randomly fails sends. For stress testing cascade fallback.
class StressFakeBluetoothService extends FakeBluetoothService {
  StressFakeBluetoothService({required super.nodeId, this.random});

  final math.Random? random;
  double _failureRate = 0.0;

  /// Set failure rate 0.0–1.0. When > 0, sendMessage randomly fails.
  void setFailureRate(double rate) {
    _failureRate = rate.clamp(0.0, 1.0);
  }

  double get failureRate => _failureRate;

  @override
  Future<void> sendMessage(String targetId, List<int> payload) async {
    if (_failureRate > 0) {
      final r = random ?? math.Random();
      if (r.nextDouble() < _failureRate) {
        throw StateError('StressFakeBle: simulated BLE send failure');
      }
    }
    return super.sendMessage(targetId, payload);
  }
}
