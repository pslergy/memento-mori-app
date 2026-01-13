import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../core/mesh_service.dart';
import '../../core/network_monitor.dart';

enum GridStatus { cloud, mesh, isolated }

class TacticalHUD extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final role = NetworkMonitor().currentRole;

    GridStatus status = GridStatus.isolated;
    if (role == MeshRole.BRIDGE) status = GridStatus.cloud;
    else if (mesh.isP2pConnected) status = GridStatus.mesh;

    return Container(
      height: 40,
      width: double.infinity,
      decoration: BoxDecoration(
        color: _getStatusColor(status).withOpacity(0.15),
        border: Border(bottom: BorderSide(color: _getStatusColor(status), width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildPulseDot(status),
          const SizedBox(width: 8),
          Text(
            _getStatusLabel(status),
            style: GoogleFonts.orbitron(
                color: _getStatusColor(status),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2
            ),
          ),
          if (status == GridStatus.mesh) ...[
            const SizedBox(width: 10),
            Text(
              "| NODES: ${mesh.nearbyNodes.length}",
              style: TextStyle(color: Colors.white38, fontSize: 9),
            )
          ]
        ],
      ),
    );
  }

  Color _getStatusColor(GridStatus s) {
    switch(s) {
      case GridStatus.cloud: return Colors.greenAccent;
      case GridStatus.mesh: return Colors.cyanAccent;
      case GridStatus.isolated: return Colors.orangeAccent;
    }
  }

  String _getStatusLabel(GridStatus s) {
    switch(s) {
      case GridStatus.cloud: return "UPLINK SECURED";
      case GridStatus.mesh: return "GRID ACTIVE (P2P)";
      case GridStatus.isolated: return "STEALTH MODE (AIR-GAP)";
    }
  }

  Widget _buildPulseDot(GridStatus s) {
    return Container(
      width: 8, height: 8,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _getStatusColor(s),
          boxShadow: [BoxShadow(color: _getStatusColor(s), blurRadius: 4)]
      ),
    );
  }
}