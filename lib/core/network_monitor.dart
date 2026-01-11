import 'dart:async';
import 'dart:io';
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

  MeshRole currentRole = MeshRole.GHOST;
  Timer? _timer;

  // 🔥 ДОБАВЛЕНО: Стрим для обновления UI
  final StreamController<MeshRole> _roleController = StreamController.broadcast();
  Stream<MeshRole> get onRoleChanged => _roleController.stream;

  http.Client _createClient() {
    final ioc = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    return IOClient(ioc);
  }

  void _goGhost() {
    if (currentRole != MeshRole.GHOST) {
      currentRole = MeshRole.GHOST;
      _roleController.add(currentRole);

      // 🚨 АКТИВИРУЕМ РЕЖИМ ВЫЖИВАНИЯ
      MeshService().startDiscovery(SignalType.mesh);
      MeshService().startDiscovery(SignalType.bluetooth);
    }
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check());
    _check();
  }

  Future<void> _check() async {
    try {
      final client = _createClient();
      final response = await client.get(Uri.parse(_pingUrl))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        if (currentRole != MeshRole.BRIDGE) {
          print("🌐 [NetMonitor] NODE IS ONLINE. Initializing Sync Protocol...");
          currentRole = MeshRole.BRIDGE;
          _roleController.add(currentRole);

          // 🔥 ВОТ ОНО: Как только инет появился — запускаем выгрузку данных
          unawaited(locator<ApiService>().syncOutbox());
        }
      } else {
        _goGhost();
      }
      client.close();
    } catch (e) {
      _goGhost();
    }
  }



  // Метод для ручной проверки (при нажатии на кнопку)
  Future<void> checkNow() async {
    await _check();
  }
}