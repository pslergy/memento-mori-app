import 'dart:async';
import '../native_mesh_service.dart';
import 'models/router_info.dart';
import 'router_registry.dart';

/// Сервис для управления подключением к Wi-Fi роутерам
class RouterConnectionService {
  static final RouterConnectionService _instance = RouterConnectionService._internal();
  factory RouterConnectionService() => _instance;
  RouterConnectionService._internal();

  final _registry = RouterRegistry();
  RouterInfo? _connectedRouter;
  Timer? _connectionCheckTimer;

  RouterInfo? get connectedRouter => _connectedRouter;

  /// Подключается к роутеру
  /// Если роутер открытый (без пароля) или useAsRelay=true - используем как ретранслятор без подключения
  Future<bool> connectToRouter(RouterInfo router) async {
    try {
      // Если роутер используется как ретранслятор - не подключаемся, просто используем его сигнал
      if (router.useAsRelay && router.isOpen) {
        print("🛰️ [RouterConnection] Using router ${router.ssid} as relay (no connection needed)");
        _connectedRouter = router;
        startConnectionMonitoring();
        return true;
      }

      print("🛰️ [RouterConnection] Connecting to router: ${router.ssid}");

      // Подключаемся через native метод (с паролем или без)
      final success = await NativeMeshService.connectToRouter(
        router.ssid,
        router.password, // null для открытых роутеров
      );

      if (!success) {
        print("❌ [RouterConnection] Failed to connect to ${router.ssid}");
        return false;
      }

      // Ждем подключения (до 10 секунд)
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final info = await NativeMeshService.getConnectedRouterInfo();
        if (info != null && info['ssid']?.toString().replaceAll('"', '') == router.ssid) {
          // Подключение успешно
          final localIp = await getLocalIpAddress();
          final hasInternet = await checkInternetViaRouter();

          _connectedRouter = RouterInfo(
            id: router.id,
            ssid: router.ssid,
            password: router.password,
            macAddress: router.macAddress ?? info['bssid'] as String?,
            ipAddress: localIp,
            priority: router.priority,
            isTrusted: router.isTrusted,
            lastSeen: DateTime.now(),
            rssi: router.rssi ?? (info['rssi'] as num?)?.toDouble(),
            hasInternet: hasInternet,
            isOpen: router.isOpen,
            useAsRelay: router.useAsRelay,
          );

          // Обновляем информацию в БД
          await _registry.updateRouter(_connectedRouter!);

          print("✅ [RouterConnection] Connected to ${router.ssid}, IP: $localIp, Internet: $hasInternet");
          return true;
        }
      }

      print("⏱️ [RouterConnection] Connection timeout for ${router.ssid}");
      return false;
    } catch (e) {
      print("❌ [RouterConnection] Error connecting: $e");
      return false;
    }
  }

  /// Отключается от текущего роутера
  Future<void> disconnectFromRouter() async {
    try {
      await NativeMeshService.disconnectFromRouter();
      _connectedRouter = null;
      _connectionCheckTimer?.cancel();
      print("🛰️ [RouterConnection] Disconnected from router");
    } catch (e) {
      print("❌ [RouterConnection] Error disconnecting: $e");
    }
  }

  /// Получает локальный IP адрес устройства в сети роутера
  Future<String?> getLocalIpAddress() async {
    try {
      return await NativeMeshService.getLocalIpAddress();
    } catch (e) {
      print("❌ [RouterConnection] Error getting local IP: $e");
      return null;
    }
  }

  /// Проверяет доступность интернета через роутер
  Future<bool> checkInternetViaRouter() async {
    try {
      return await NativeMeshService.checkInternetViaRouter();
    } catch (e) {
      print("❌ [RouterConnection] Error checking internet: $e");
      return false;
    }
  }

  /// Запускает периодическую проверку подключения к роутеру
  void startConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (_connectedRouter == null) return;

      final hasInternet = await checkInternetViaRouter();
      final localIp = await getLocalIpAddress();

      if (localIp != null && _connectedRouter != null) {
        _connectedRouter = RouterInfo(
          id: _connectedRouter!.id,
          ssid: _connectedRouter!.ssid,
          password: _connectedRouter!.password,
          macAddress: _connectedRouter!.macAddress,
          ipAddress: localIp,
          priority: _connectedRouter!.priority,
          isTrusted: _connectedRouter!.isTrusted,
          lastSeen: DateTime.now(),
          rssi: _connectedRouter!.rssi,
          hasInternet: hasInternet,
          isOpen: _connectedRouter!.isOpen,
          useAsRelay: _connectedRouter!.useAsRelay,
        );
      }
    });
  }

  /// Останавливает мониторинг подключения
  void stopConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
  }
}
