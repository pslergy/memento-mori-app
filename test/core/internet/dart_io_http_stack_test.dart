import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/internet/dart_io_http_stack.dart';
import 'package:memento_mori_app/core/internet/http_stack.dart';

void main() {
  group('DartIoHttpStack', () {
    test('createClient returns closable client', () {
      final stack = DartIoHttpStack();
      final client = stack.createClient(const HttpClientCreationParams());
      expect(client, isNotNull);
      expect(() => client.close(), returnsNormally);
    });
  });
}
