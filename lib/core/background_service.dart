import 'dart:async';
import 'dart:isolate';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'mesh_service.dart';
import 'models/signal_node.dart';

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
    // Убираем проверку isRunningTask, так как в твоей версии библиотеки
    // это свойство называется иначе или отсутствует.
    // Библиотека сама не запустит сервис дважды.

    await FlutterForegroundTask.startService(
      notificationTitle: 'Memento Mori Mesh',
      notificationText: 'Тактическая связь активна...',
    );
  }

  static Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}
void onStart(DateTime timestamp, SendPort? sendPort) async {
  // Каждые 15 минут сервис "просыпается", делает короткий скан Mesh
  // и снова засыпает, если никого не нашел.
  Timer.periodic(const Duration(minutes: 15), (timer) async {
    await MeshService().startDiscovery(SignalType.mesh);
    await Future.delayed(Duration(seconds: 20));
    await MeshService().stopDiscovery();
  });
}
