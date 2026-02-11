import 'dart:async';
import 'dart:isolate';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// SECURITY (Decoy Iteration 2): The foreground task runs in a separate isolate
// with no access to the mode-scoped GetIt. We MUST NOT use MeshService(), DB,
// or vault here — that would run with default (REAL) identity and leak mode.
// Discovery runs in the main isolate only (mode-scoped). This task keeps the
// notification and a minimal wake loop so REAL and DECOY behave the same.

class BackgroundService {
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'memento_mori_mesh_v1',
        channelName: 'Memento Mori Mesh Service',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );
  }

  static Future<void> start() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Memento Mori Mesh',
      notificationText: 'Тактическая связь активна...',
    );
  }

  static Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}

/// Entry point for the foreground task isolate. Does NOT use DB, vault, or
/// MeshService so that REAL and DECOY have identical behavior and no mode leak.
void onStart(DateTime timestamp, SendPort? sendPort) async {
  Timer.periodic(const Duration(seconds: 45), (_) {
    // Minimal wake only; no identity-dependent work in this isolate.
  });
}
