import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/tunnel_remote_config.dart';

void main() {
  /// 16-byte key for tests
  const testKey = <int>[
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  ];

  group('TunnelRemoteSignedConfig', () {
    test('parseAndVerify accepts valid HMAC', () {
      final inner = jsonEncode({
        'v': 1,
        'donors': [
          {'host': 'cdn.example.com', 'mode': 'm1', 'padding': 'p'},
        ],
      });
      final sig = Hmac(sha256, testKey).convert(utf8.encode(inner)).toString();
      final outer =
          jsonEncode({'blob': inner, 'signature': sig.toUpperCase()});
      final list = TunnelRemoteSignedConfig.parseAndVerify(outer, testKey);
      expect(list, isNotNull);
      expect(list!.length, 1);
      expect(list[0].donorHost, 'cdn.example.com');
      expect(list[0].mode, 'm1');
      expect(list[0].paddingConfig, 'p');
    });

    test('parseAndVerify rejects wrong signature', () {
      final inner = jsonEncode({
        'donors': [
          {'host': 'x.test', 'mode': 'unknown'},
        ],
      });
      final outer = jsonEncode({
        'blob': inner,
        'signature': '00' * 32,
      });
      expect(
        TunnelRemoteSignedConfig.parseAndVerify(outer, testKey),
        isNull,
      );
    });

    test('parseAndVerify rejects empty donors array', () {
      final inner = jsonEncode({'v': 1, 'donors': <Object>[]});
      final sig = Hmac(sha256, testKey).convert(utf8.encode(inner)).toString();
      final outer = jsonEncode({'blob': inner, 'signature': sig});
      expect(
        TunnelRemoteSignedConfig.parseAndVerify(outer, testKey),
        isNull,
      );
    });

    test('empty hmac key returns null', () {
      final outer = jsonEncode({'blob': '{}', 'signature': 'ab'});
      expect(
        TunnelRemoteSignedConfig.parseAndVerify(outer, <int>[]),
        isNull,
      );
    });

    test('invalid json returns null', () {
      expect(
        TunnelRemoteSignedConfig.parseAndVerify('not-json', testKey),
        isNull,
      );
    });
  });
}
