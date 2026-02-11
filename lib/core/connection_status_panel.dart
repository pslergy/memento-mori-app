// lib/core/connection_status_panel.dart
//
// Минимальный статус для пользователя: только «Соединение» и «Отправка/Ожидание».
// Без слов panic, security, trap. Можно скрыть в настройках.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'locator.dart';
import 'mesh_service.dart';
import 'ghost_transfer_manager.dart';

/// Панель: Соединение (подключено / поиск / нет) и Сообщения (отправляются / в очереди).
/// Использует locator только в build — не в конструкторе.
class ConnectionStatusPanel extends StatelessWidget {
  const ConnectionStatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    if (!locator.isRegistered<MeshService>()) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('Соединение: нет',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
      );
    }
    return ChangeNotifierProvider<MeshService>.value(
      value: locator<MeshService>(),
      child: const _ConnectionStatusContent(),
    );
  }
}

class _ConnectionStatusContent extends StatelessWidget {
  const _ConnectionStatusContent();

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final bool connected = mesh.isP2pConnected;
    final String connText = connected ? 'подключено' : 'поиск';
    final Color connColor = connected ? Colors.green : Colors.orange;

    int queueLength = 0;
    if (locator.isRegistered<GhostTransferManager>()) {
      queueLength = locator<GhostTransferManager>().totalQueueLength;
    }
    final String msgText = queueLength > 0 ? 'в очереди' : 'отправляются';
    final Color msgColor = queueLength > 0 ? Colors.orange : Colors.green;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'Соединение', connText, connColor),
          const SizedBox(height: 4),
          _row(context, 'Сообщения', msgText, msgColor),
        ],
      ),
    );
  }

  Widget _row(
      BuildContext context, String label, String value, Color valueColor) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            fontSize: 13,
          ),
        ),
        Text(
          value,
          style: TextStyle(
              color: valueColor, fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
