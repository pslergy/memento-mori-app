import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Huawei / race: второй [FlutterBluePlus.startScan] пока скан ещё активен
/// → `SCAN_FAILED_ALREADY_STARTED` / android-code: 1.
bool isBleScanAlreadyStartedError(Object e) {
  final s = e.toString();
  return s.contains('SCAN_FAILED_ALREADY_STARTED') ||
      (s.contains('| scan |') && s.contains('android-code: 1'));
}

/// stopScan + короткая пауза + startScan; при «already started» — повтор после stop.
///
/// Используется из [MeshCoreEngine] и из [BluetoothMeshService] (pre-connect rescan),
/// чтобы не гоняться с параллельным mesh-сканом.
Future<void> flutterBluePlusStartScanSafe({
  required Duration timeout,
  AndroidScanMode androidScanMode = AndroidScanMode.balanced,
  List<Guid>? withServices,
}) async {
  Future<void> doStart() async {
    if (withServices != null && withServices.isNotEmpty) {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: withServices,
        androidScanMode: androidScanMode,
      );
    } else {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidScanMode: androidScanMode,
      );
    }
  }

  try {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await doStart();
  } catch (e) {
    if (isBleScanAlreadyStartedError(e)) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await doStart();
    } else {
      rethrow;
    }
  }
}
