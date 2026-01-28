import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'models/signal_node.dart';
import 'router/router_connection_service.dart';
import 'security_config.dart'; // 🔒 Certificate Pinning

enum MeshRole { GHOST, BRIDGE }

/// 🔒 P1: Гистерезис BRIDGE/GHOST — без демпфирования сеть дёргается и флапает.
/// Переход в GHOST только после N подряд неудач ping; переход в BRIDGE после 1 успеха (не задерживаем восстановление).
class NetworkMonitor {
  static final NetworkMonitor _instance = NetworkMonitor._internal();
  factory NetworkMonitor() => _instance;
  NetworkMonitor._internal();

  final String _pingUrl = 'https://89.125.131.63:3000/api/auth/ping';
  late final http.Client _httpClient = _createClient();

  MeshRole currentRole = MeshRole.GHOST;
  Timer? _timer;

  final StreamController<MeshRole> _roleController = StreamController.broadcast();
  Stream<MeshRole> get onRoleChanged => _roleController.stream;

  // 🔒 P1: Гистерезис — не переключаемся в GHOST по первому таймауту
  int _consecutivePingFailures = 0;
  static const int _roleSwitchFailuresRequired = 2;

  http.Client _createClient() {
    // 🔒 SECURITY FIX: Use centralized certificate validation
    final ioc = createSecureHttpClient();
    ioc.connectionTimeout = const Duration(seconds: 5);
    return IOClient(ioc);
  }

  // Метод старта
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
    _check(); // Первая проверка сразу
  }

  // Публичный метод для ручной проверки
  Future<void> checkNow() async {
    await _check();
  }

  // Все приватные методы должны быть в теле класса
  Future<void> _check() async {
    // 1. Сначала проверяем роутер (если подключен)
    final routerService = RouterConnectionService();
    final connectedRouter = routerService.connectedRouter;
    
    if (connectedRouter != null && connectedRouter.hasInternet) {
      _consecutivePingFailures = 0;
      if (currentRole != MeshRole.BRIDGE) {
        print("🛰️ [NET-TRANSITION] ROUTER -> ONLINE (BRIDGE MODE via Router)");
        currentRole = MeshRole.BRIDGE;
        _roleController.add(currentRole);
        unawaited(locator<ApiService>().syncOutbox());
      }
      return;
    }

    // 2. Проверяем прямой интернет (мобильный/проводной)
    try {
      final response = await _httpClient.get(Uri.parse(_pingUrl))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        _consecutivePingFailures = 0;
        if (currentRole != MeshRole.BRIDGE) {
          print("🌐 [NET-TRANSITION] OFFLINE -> ONLINE (BRIDGE MODE ACTIVE)");
          currentRole = MeshRole.BRIDGE;
          _roleController.add(currentRole);

          final mesh = locator<MeshService>();
          if (mesh.isP2pConnected) {
            print("🔗 [PERSISTENCE-CHECK] P2P Link maintained during Cloud uplink.");
          }

          unawaited(locator<ApiService>().syncOutbox());
        }
      } else {
        _consecutivePingFailures++;
        if (_consecutivePingFailures >= _roleSwitchFailuresRequired) {
          _goGhost();
        }
      }
    } catch (e) {
      _consecutivePingFailures++;
      if (_consecutivePingFailures >= _roleSwitchFailuresRequired) {
        _goGhost();
      }
    }
  }

  void _goGhost() {
    if (currentRole == MeshRole.GHOST) return;
    currentRole = MeshRole.GHOST;
    _roleController.add(currentRole);
    _consecutivePingFailures = 0;

    final mesh = locator<MeshService>();
    mesh.startDiscovery(SignalType.mesh);
  }




  void stop() {
    _timer?.cancel();
    _httpClient.close();
  }
}