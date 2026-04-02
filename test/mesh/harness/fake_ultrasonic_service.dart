// Test harness — Fake Sonar service. Simulates sonar broadcast.
// DO NOT import production mesh_core_engine. Isolated for testing.

import 'dart:async';

/// Minimal fake for ultrasonic/sonar transport simulation.
/// Simulates sonar broadcast, allows triggering signals manually.
class FakeUltrasonicService {
  final String nodeId;
  final StreamController<String> _sonarController =
      StreamController<String>.broadcast();
  final List<String> _broadcastHistory = [];

  FakeUltrasonicService({required this.nodeId});

  Stream<String> get sonarMessages => _sonarController.stream;
  List<String> get broadcastHistory => List.unmodifiable(_broadcastHistory);

  /// Simulate transmitting a frame.
  void transmitFrame(String payload) {
    _broadcastHistory.add(payload);
    _sonarController.add(payload);
  }

  /// Manually trigger a received signal (for testing).
  void triggerReceivedSignal(String signal) {
    _sonarController.add(signal);
  }

  Future<void> startListening() async {}
  Future<void> stopSonarListening() async {}

  void dispose() {
    _sonarController.close();
  }
}
