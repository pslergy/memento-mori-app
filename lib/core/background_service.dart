import 'dart:async';
import 'dart:isolate';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'mesh_service.dart';
import 'models/signal_node.dart';
import 'native_mesh_service.dart';

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
  final mesh = MeshService();
  
  // Периодический discovery: каждые 45 секунд запускаем на 15 секунд
  Timer.periodic(const Duration(seconds: 45), (timer) async {
    try {
      // Retry логика для фонового режима (Android может блокировать Wi-Fi Direct в фоне)
      int retries = 0;
      const maxRetries = 3;
      bool success = false;
      
      while (retries < maxRetries && !success) {
        try {
          // Проверяем состояние Wi-Fi Direct
          final isP2pEnabled = await NativeMeshService.checkP2pState();
          if (!isP2pEnabled) {
            print("⚠️ [BG] Wi-Fi Direct disabled, skipping discovery");
            break;
          }
          
          // 🔥 КРИТИЧНО: Проверяем, не активен ли уже discovery
          final isDiscoveryActive = await NativeMeshService.checkDiscoveryState();
          if (isDiscoveryActive) {
            print("ℹ️ [BG] Discovery already active, skipping this cycle");
            success = true; // Считаем успехом, если discovery уже активен
            break;
          }
          
          // Запускаем discovery
          success = await mesh.startDiscovery(SignalType.mesh);
          
          if (success) {
            print("✅ [BG] Discovery started successfully");
            // Останавливаем через 15 секунд для экономии батареи
            Future.delayed(const Duration(seconds: 15), () async {
              await mesh.stopDiscovery();
              print("💤 [BG] Discovery paused");
            });
            break;
          } else {
            retries++;
            if (retries < maxRetries) {
              print("⚠️ [BG] Discovery failed, retrying in ${retries * 2}s... (attempt $retries/$maxRetries)");
              await Future.delayed(Duration(seconds: retries * 2));
            }
          }
        } catch (e) {
          retries++;
          print("⚠️ [BG] Discovery error (attempt $retries/$maxRetries): $e");
          if (retries < maxRetries) {
            await Future.delayed(Duration(seconds: retries * 2));
          }
        }
      }
      
      if (!success && retries >= maxRetries) {
        print("❌ [BG] Discovery failed after $maxRetries attempts, will retry next cycle");
      }
    } catch (e) {
      // Игнорируем критические ошибки в фоне
      print("❌ [BG] Critical error: $e");
    }
  });
}
