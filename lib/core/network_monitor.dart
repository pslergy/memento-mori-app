import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'models/signal_node.dart';

enum MeshRole { GHOST, BRIDGE }

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

  http.Client _createClient() {
    final ioc = HttpClient();
    ioc.badCertificateCallback = (cert, host, port) => true;
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
    try {
      final response = await _httpClient.get(Uri.parse(_pingUrl))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        if (currentRole != MeshRole.BRIDGE) {
          currentRole = MeshRole.BRIDGE;
          _roleController.add(currentRole);
          unawaited(locator<ApiService>().syncOutbox());
        }
      } else {
        _goGhost();
      }
    } catch (e) {
      _goGhost();
    }
  }

  void _goGhost() {
    if (currentRole == MeshRole.GHOST) return;
    currentRole = MeshRole.GHOST;
    _roleController.add(currentRole);

    final mesh = locator<MeshService>();
    mesh.startDiscovery(SignalType.mesh);
  }




  void stop() {
    _timer?.cancel();
    _httpClient.close();
  }
}