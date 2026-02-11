// Diagnostic agent: structured logging for BLE and Wi-Fi Direct.
// DO NOT change logic, timing, or roles. Logs only. Guarded by kMeshDiagnostics.

import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';

/// Set to true to enable single-line structured diagnostic logs (Huawei ↔ Tecno).
const bool kMeshDiagnostics = false;

/// Single-line structured log prefix for filtering.
const String kMeshDiagPrefix = 'MESH_DIAG';

/// Format a diagnostic log line: PREFIX step key=value key=value ...
String meshDiagLog(String step, Map<String, String> data) {
  final pairs = data.entries.map((e) => '${e.key}=${e.value}').join(' ');
  return '$kMeshDiagPrefix $step $pairs';
}

/// Returns device manufacturer, Android version, lifecycle (when kMeshDiagnostics).
/// Call once per attempt and include in first log; cache result for elapsed-only in later logs.
Future<Map<String, String>> getDiagnosticContext() async {
  if (!kMeshDiagnostics) return {};
  final Map<String, String> ctx = {};
  try {
    if (Platform.isAndroid) {
      final android = await DeviceInfoPlugin().androidInfo;
      ctx['manufacturer'] = android.manufacturer;
      ctx['androidVersion'] = android.version.release;
      ctx['model'] = android.model;
    }
  } catch (_) {}
  try {
    final state = WidgetsBinding.instance?.lifecycleState?.toString() ?? 'unknown';
    ctx['lifecycle'] = state.contains('resumed') ? 'foreground' : (state.contains('paused') || state.contains('inactive') ? 'background' : state);
  } catch (_) {}
  return ctx;
}
