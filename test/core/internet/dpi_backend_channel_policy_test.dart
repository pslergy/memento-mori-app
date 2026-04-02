import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:memento_mori_app/core/internet/dpi_backend_channel_policy.dart';

void main() {
  group('DpiBackendChannelPolicy', () {
    test('no rotation when HTTP error body was received', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: Exception('Server Error (502)'),
          httpFailureBodyBytes: 120,
          elapsed: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });

    test('no rotation on HandshakeException', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: HandshakeException('bad cert'),
          httpFailureBodyBytes: 0,
          elapsed: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });

    test('no rotation when DpiDetector says blockDetected (~60s cutoff)', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: SocketException('Connection reset'),
          httpFailureBodyBytes: 0,
          elapsed: const Duration(seconds: 60),
        ),
        isFalse,
      );
    });

    test('rotation on generic SocketException (failure, short elapsed)', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: SocketException('Failed host lookup'),
          httpFailureBodyBytes: 0,
          elapsed: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });

    test('rotation on ClientException when classified as failure', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: http.ClientException('oops'),
          httpFailureBodyBytes: 0,
          elapsed: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });

    test('plain Exception without body does not rotate channel', () {
      expect(
        DpiBackendChannelPolicy.shouldRecordBackendChannelFailure(
          error: Exception('parse error'),
          httpFailureBodyBytes: 0,
          elapsed: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });
  });
}
