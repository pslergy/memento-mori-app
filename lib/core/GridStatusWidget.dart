import 'package:animate_do/animate_do.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:provider/provider.dart';

import 'locator.dart';
import 'mesh_service.dart';
import 'network_monitor.dart';

class GridPulseIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();

    // Определяем состояние "Глубины связи"
    Color statusColor = Colors.redAccent; // Нет связи
    String label = "SILENCE";
    IconData icon = Icons.gps_off;

    if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
      statusColor = Colors.greenAccent;
      label = "COMMAND CENTER (ONLINE)";
      icon = Icons.cloud_done;
    } else if (mesh.isP2pConnected) {
      statusColor = Colors.cyanAccent;
      label = "LINKED: ${mesh.nearbyNodes.length} NODES";
      icon = Icons.hub;
    } else if (mesh.nearbyNodes.isNotEmpty) {
      statusColor = Colors.orangeAccent;
      label = "SIGNALS DETECTED";
      icon = Icons.radar;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        border: Border(bottom: BorderSide(color: statusColor.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          Pulse(child: Center(child: Icon(icon, color: statusColor, size: 16)), infinite: true),
          SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: statusColor,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          Spacer(),
          // Кнопка быстрого SOS (через Сонар)
          IconButton(
            icon: Icon(Icons.record_voice_over, color: Colors.purpleAccent, size: 18),
            onPressed: () => locator<UltrasonicService>().transmitFrame("LNK:${mesh.apiService.currentUserId}"),
          )
        ],
      ),
    );
  }
}