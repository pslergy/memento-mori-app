// Экран управления известными Wi‑Fi роутерами (канал 0).
// Список из RouterRegistry, удаление. Добавление — через обнаружение (RouterConnectionService)
// или вручную позже; не меняем существующую логику подключения.

import 'package:flutter/material.dart';

import '../../core/router/models/router_info.dart';
import '../../core/router/router_connection_service.dart';
import '../../core/router/router_registry.dart';
import '../theme/app_colors.dart';

class RouterManagementScreen extends StatefulWidget {
  const RouterManagementScreen({super.key});

  @override
  State<RouterManagementScreen> createState() => _RouterManagementScreenState();
}

class _RouterManagementScreenState extends State<RouterManagementScreen> {
  final RouterRegistry _registry = RouterRegistry();
  List<RouterInfo> _routers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _registry.getAllKnownRouters();
      if (mounted) setState(() {
        _routers = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _remove(RouterInfo r) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Удалить роутер?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${r.ssid} будет удалён из списка известных. Пароль также будет удалён.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить', style: TextStyle(color: AppColors.warningRed))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await _registry.removeRouter(r.id);
      await _load();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ошибка удаления')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = RouterConnectionService().connectedRouter;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Роутеры', style: TextStyle(color: Colors.white, fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.stealthOrange))
          : _routers.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.router, size: 48, color: Colors.white24),
                      const SizedBox(height: 16),
                      Text(
                        'Нет сохранённых роутеров',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Подключённые роутеры появляются здесь при использовании канала «Роутер».',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _routers.length,
                  itemBuilder: (context, i) {
                    final r = _routers[i];
                    final isConnected = connected?.ssid == r.ssid;
                    return Card(
                      color: AppColors.surface,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: Icon(
                          Icons.router,
                          color: isConnected ? AppColors.cloudGreen : AppColors.textDim,
                        ),
                        title: Text(r.ssid, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                        subtitle: Text(
                          [if (r.ipAddress != null) r.ipAddress, if (r.hasInternet) 'Интернет', if (r.isTrusted) 'Доверенный'].join(' · '),
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: AppColors.textDim),
                          onPressed: () => _remove(r),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
