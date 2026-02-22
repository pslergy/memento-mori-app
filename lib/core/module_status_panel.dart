import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'locator.dart';
import 'mesh_service.dart';
import 'network_monitor.dart';

/// Панель статуса модулей для передачи сообщений.
/// Показывает, какие модули включены (геолокация, Bluetooth, Wi‑Fi/сеть),
/// и подсказку, что нужно включить для работы mesh-доставки.
/// Для устройств Tecno и аналогов: пользователь видит, чего не хватает.
class ModuleStatusPanel extends StatefulWidget {
  /// Компактный режим — одна строка с иконками и подсказкой.
  final bool compact;

  const ModuleStatusPanel({super.key, this.compact = true});

  @override
  State<ModuleStatusPanel> createState() => _ModuleStatusPanelState();
}

class _ModuleStatusPanelState extends State<ModuleStatusPanel> {
  bool _locationOk = false;
  bool _bluetoothOk = false;
  bool _networkOk = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final locGranted = await Permission.location.isGranted;
      final locEnabled = await Geolocator.isLocationServiceEnabled();
      final btScan = await Permission.bluetoothScan.isGranted;
      final btConnect = await Permission.bluetoothConnect.isGranted;
      bool hasP2p = false;
      if (locator.isRegistered<MeshService>()) {
        final mesh = locator<MeshService>();
        hasP2p = mesh.isP2pConnected;
      }
      final isBridge = NetworkMonitor().currentRole == MeshRole.BRIDGE;

      if (mounted) {
        setState(() {
          _locationOk = locGranted && locEnabled;
          _bluetoothOk = btScan && btConnect;
          _networkOk = hasP2p || isBridge;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _allOk => _locationOk && _bluetoothOk && _networkOk;

  List<String> get _missing {
    final list = <String>[];
    if (!_locationOk) list.add('Геолокация');
    if (!_bluetoothOk) list.add('Bluetooth');
    if (!_networkOk) list.add('Wi‑Fi / Сеть');
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SizedBox(
          height: 20,
          width: 20,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
        ),
      );
    }

    if (widget.compact) {
      return InkWell(
        onTap: _refresh,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _allOk
                ? Colors.green.withOpacity(0.15)
                : Colors.orange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _allOk
                  ? Colors.green.withOpacity(0.4)
                  : Colors.orange.withOpacity(0.4),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              _icon(Icons.location_on, _locationOk),
              const SizedBox(width: 6),
              _icon(Icons.bluetooth, _bluetoothOk),
              const SizedBox(width: 6),
              _icon(Icons.wifi, _networkOk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _allOk
                      ? 'Передача: все модули включены'
                      : 'Для передачи включите: ${_missing.join(', ')}',
                  style: TextStyle(
                    fontSize: 11,
                    color: _allOk ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Модули для передачи',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 10),
          _row('Геолокация', Icons.location_on, _locationOk,
              'Нужна для поиска устройств (Tecno и др.)'),
          _row('Bluetooth', Icons.bluetooth, _bluetoothOk,
              'Нужен для mesh и BLE-канала'),
          _row('Wi‑Fi / Сеть', Icons.wifi, _networkOk,
              'Wi‑Fi Direct или интернет для доставки'),
          if (!_allOk) ...[
            const SizedBox(height: 8),
            Text(
              'Включите в настройках телефона: ${_missing.join(', ')}',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.orangeAccent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _icon(IconData icon, bool ok) {
    return Icon(
      icon,
      size: 18,
      color: ok ? Colors.greenAccent : Colors.orangeAccent,
    );
  }

  Widget _row(String label, IconData icon, bool ok, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon,
              size: 20, color: ok ? Colors.greenAccent : Colors.orangeAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          Text(
            ok ? 'Вкл' : 'Выкл',
            style: TextStyle(
              fontSize: 11,
              color: ok ? Colors.greenAccent : Colors.orangeAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
