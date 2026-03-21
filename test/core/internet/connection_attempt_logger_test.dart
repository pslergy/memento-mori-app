import 'package:flutter_test/flutter_test.dart';

import 'package:memento_mori_app/core/internet/connection_attempt_logger.dart';
import 'package:memento_mori_app/core/internet/tunnel_config.dart';

void main() {
  group('ConnectionAttemptLogger', () {
    test('logSuccess does not throw when ImmuneService not registered', () {
      final logger = ConnectionAttemptLogger();
      expect(
        () => logger.logSuccess(config: TunnelConfig.defaultConfig),
        returnsNormally,
      );
    });

    test('logFailure does not throw when ImmuneService not registered', () {
      final logger = ConnectionAttemptLogger();
      expect(
        () => logger.logFailure(
          config: TunnelConfig.defaultConfig,
          error: Exception('test'),
        ),
        returnsNormally,
      );
    });

    test('logFailure with non-zero bytesTransferred does not throw', () {
      final logger = ConnectionAttemptLogger();
      expect(
        () => logger.logFailure(
          config: TunnelConfig.defaultConfig,
          error: Exception('Server Error (502)'),
          bytesTransferred: 2048,
          elapsed: const Duration(milliseconds: 100),
        ),
        returnsNormally,
      );
    });
  });
}
