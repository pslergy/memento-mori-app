import 'dart:math';
import '../native_mesh_service.dart';
import 'models/router_info.dart';
import 'router_registry.dart';

/// Сервис для обнаружения и сканирования доступных Wi-Fi роутеров
class RouterDiscoveryService {
  static final RouterDiscoveryService _instance = RouterDiscoveryService._internal();
  factory RouterDiscoveryService() => _instance;
  RouterDiscoveryService._internal();

  final _registry = RouterRegistry();
  final _minRssi = -70.0; // Минимальная сила сигнала в dBm

  /// Сканирует доступные Wi-Fi сети и преобразует в RouterInfo
  Future<List<RouterInfo>> scanAvailableRouters() async {
    try {
      final networks = await NativeMeshService.scanWifiNetworks();
      final routers = <RouterInfo>[];

      for (var network in networks) {
        final ssid = network['ssid'] as String? ?? '';
        if (ssid.isEmpty) continue;

        final rssi = (network['rssi'] as num?)?.toDouble() ?? -100.0;
        if (rssi < _minRssi) continue; // Пропускаем слабые сигналы

        final isSecure = network['isSecure'] as bool? ?? true;
        final isOpen = !isSecure; // Открытый роутер = без пароля

        final router = RouterInfo(
          id: 'router_${ssid.hashCode}',
          ssid: ssid,
          macAddress: network['bssid'] as String?,
          rssi: rssi,
          priority: 50, // Будет обновлено из БД если роутер известен
          isTrusted: false,
          lastSeen: DateTime.now(),
          isOpen: isOpen,
          useAsRelay: isOpen, // Открытые роутеры можно использовать как ретрансляторы
        );

        routers.add(router);
      }

      return routers;
    } catch (e) {
      print("⚠️ [RouterDiscovery] Scan error: $e");
      return [];
    }
  }

  /// Фильтрует известные роутеры из списка
  Future<List<RouterInfo>> filterKnownRouters(List<RouterInfo> routers) async {
    final knownRouters = await _registry.getAllKnownRouters();
    final knownSsidSet = knownRouters.map((r) => r.ssid).toSet();

    final filtered = <RouterInfo>[];

    for (var router in routers) {
      final knownRouter = knownRouters.firstWhere(
        (r) => r.ssid == router.ssid,
        orElse: () => router,
      );

      if (knownSsidSet.contains(router.ssid)) {
        // Обновляем информацию из БД
        filtered.add(RouterInfo(
          id: knownRouter.id,
          ssid: router.ssid,
          password: knownRouter.password,
          macAddress: router.macAddress ?? knownRouter.macAddress,
          ipAddress: knownRouter.ipAddress,
          priority: knownRouter.priority,
          isTrusted: knownRouter.isTrusted,
          lastSeen: router.lastSeen,
          rssi: router.rssi,
          hasInternet: knownRouter.hasInternet,
          isOpen: router.isOpen || knownRouter.isOpen,
          useAsRelay: knownRouter.useAsRelay || router.isOpen,
        ));
      } else {
        // Неизвестный роутер
        filtered.add(router);
      }
    }

    return filtered;
  }

  /// Приоритизирует роутеры по приоритету, RSSI, наличию интернета
  List<RouterInfo> prioritizeRouters(List<RouterInfo> routers) {
    routers.sort((a, b) {
      // 1. Сначала по приоритету (выше = лучше)
      final priorityComp = b.priority.compareTo(a.priority);
      if (priorityComp != 0) return priorityComp;

      // 2. Затем по наличию интернета
      final internetComp = (b.hasInternet ? 1 : 0).compareTo(a.hasInternet ? 1 : 0);
      if (internetComp != 0) return internetComp;

      // 3. Затем по RSSI (сильнее сигнал = лучше)
      final rssiA = a.rssi ?? -100.0;
      final rssiB = b.rssi ?? -100.0;
      return rssiB.compareTo(rssiA);
    });

    return routers;
  }

  /// Находит лучший доступный роутер для подключения
  /// Приоритет: 1) Доверенные с паролем, 2) Открытые как ретрансляторы, 3) Остальные
  Future<RouterInfo?> findBestRouter() async {
    final scanned = await scanAvailableRouters();
    final known = await filterKnownRouters(scanned);
    final prioritized = prioritizeRouters(known);

    // 1. Ищем доверенный роутер с паролем (или открытый доверенный)
    final trusted = prioritized.where((r) => r.isTrusted).firstOrNull;
    if (trusted != null) return trusted;

    // 2. Ищем открытый роутер для использования как ретранслятор
    final openRouter = prioritized.where((r) => r.isOpen && r.useAsRelay).firstOrNull;
    if (openRouter != null) return openRouter;

    // 3. Ищем роутер с интернетом
    final withInternet = prioritized.where((r) => r.hasInternet).firstOrNull;
    if (withInternet != null) return withInternet;

    // 4. Возвращаем первый доступный
    return prioritized.isNotEmpty ? prioritized.first : null;
  }
}
