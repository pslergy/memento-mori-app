import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/immune/attempt_log.dart';
import 'package:memento_mori_app/core/internet/dpi_detector.dart';

void main() {
  group('DpiDetector', () {
    test('stall window with SocketException and ~20KB suggests block', () {
      final d = DpiDetector();
      final r = d.classifyError(
        error: SocketException('reset'),
        bytesTransferred: 20 * 1024,
        elapsed: const Duration(seconds: 10),
      );
      expect(r, AttemptResult.blockDetected);
    });

    test('HTTP-style Exception with body bytes stays failure unless time matches', () {
      final d = DpiDetector();
      final r = d.classifyError(
        error: Exception('Server Error (500)'),
        bytesTransferred: 512,
        elapsed: const Duration(milliseconds: 200),
      );
      expect(r, AttemptResult.failure);
    });
  });
}
