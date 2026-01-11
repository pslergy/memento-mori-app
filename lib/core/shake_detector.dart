import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class TacticalShakeDetector {
  final Function onShake;
  final double shakeThresholdGravity;
  final int minimumShakeInterval;

  StreamSubscription? _subscription;
  int _lastShakeTime = 0;

  TacticalShakeDetector({
    required this.onShake,
    this.shakeThresholdGravity = 2.7,
    this.minimumShakeInterval = 1000,
  });

  void start() {
    // Слушаем акселерометр
    _subscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gX = event.x / 9.80665;
      double gY = event.y / 9.80665;
      double gZ = event.z / 9.80665;

      // Вычисляем общую силу ускорения
      double gForce = sqrt(gX * gX + gY * gY + gZ * gZ);

      if (gForce > shakeThresholdGravity) {
        var now = DateTime.now().millisecondsSinceEpoch;
        // Проверяем интервал, чтобы не срабатывало 100 раз за одну встряску
        if (_lastShakeTime + minimumShakeInterval > now) return;

        _lastShakeTime = now;
        onShake();
      }
    });
  }

  void stop() {
    _subscription?.cancel();
  }
}