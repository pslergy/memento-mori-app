// Fixes flutter_ble_peripheral 2.0.1 "Reply already submitted" on duplicate
// onAdvertisingSetStarted (e.g. Samsung). Run from repo root after `flutter pub get`:
//   dart run tool/apply_flutter_ble_peripheral_patch.dart

import 'dart:convert';
import 'dart:io';

void main() {
  final repoRoot = Directory.current;
  final deps = File('${repoRoot.path}/.flutter-plugins-dependencies');
  final patch = File(
    '${repoRoot.path}/scripts/patches/PeripheralAdvertisingSetCallback.kt',
  );
  if (!deps.existsSync()) {
    stderr.writeln('Missing .flutter-plugins-dependencies — run flutter pub get');
    exit(1);
  }
  if (!patch.existsSync()) {
    stderr.writeln('Missing ${patch.path}');
    exit(1);
  }
  final map = jsonDecode(deps.readAsStringSync()) as Map<String, dynamic>;
  final plugins = map['plugins'] as Map<String, dynamic>?;
  final android = plugins?['android'] as List<dynamic>?;
  if (android == null) {
    stderr.writeln('No android plugins in .flutter-plugins-dependencies');
    exit(1);
  }
  Map<String, dynamic>? entry;
  for (final e in android) {
    if (e is Map && e['name'] == 'flutter_ble_peripheral') {
      entry = e.cast<String, dynamic>();
      break;
    }
  }
  if (entry == null) {
    stderr.writeln('flutter_ble_peripheral not found for android');
    exit(1);
  }
  final rawPath = entry['path'] as String;
  final pluginRoot = Directory(rawPath.replaceAll(r'\\', r'\'));
  final target = File(
    '${pluginRoot.path}/android/src/main/kotlin/dev/steenbakker/flutter_ble_peripheral/callbacks/PeripheralAdvertisingSetCallback.kt',
  );
  if (!target.parent.existsSync()) {
    stderr.writeln('Unexpected plugin layout: ${target.parent.path}');
    exit(1);
  }
  patch.copySync(target.path);
  stdout.writeln('Patched: ${target.path}');
}
