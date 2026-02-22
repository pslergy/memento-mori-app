import 'package:flutter/material.dart';

import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

/// Вкладка Sector map: анонимный статус сетки (без мест, без идентификаторов).
/// Только счётчики: outbox, SOS за 24 ч. Обновляется при изменении MeshService (отправка/удаление из outbox).
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  int _outboxPending = 0;
  int _sos24h = 0;
  bool _loading = true;

  void _onMeshOrOutboxChanged() {
    if (mounted) _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (locator.isRegistered<MeshService>()) {
      locator<MeshService>().addListener(_onMeshOrOutboxChanged);
    }
  }

  @override
  void dispose() {
    if (locator.isRegistered<MeshService>()) {
      locator<MeshService>().removeListener(_onMeshOrOutboxChanged);
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final db = LocalDatabaseService();
      final pending = await db.getPendingFromOutbox();
      final sos = await db.getSosSignalsCountLast24h();
      if (mounted) {
        setState(() {
          _outboxPending = pending.length;
          _sos24h = sos;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.gridCyan,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            if (_loading)
              const Center(
                  child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(color: AppColors.gridCyan),
              ))
            else ...[
              _buildSectionTitle('GRID STATUS'),
              const SizedBox(height: 8),
              _buildStatCard(
                icon: Icons.outbox_outlined,
                label: 'Outbox (pending)',
                value: '$_outboxPending',
                subtitle: 'Messages waiting for relay',
              ),
              const SizedBox(height: 8),
              _buildStatCard(
                icon: Icons.warning_amber_rounded,
                label: 'SOS signals (24h)',
                value: '$_sos24h',
                subtitle: 'Anonymous count, no locations',
              ),
              const SizedBox(height: 24),
              _buildLegend(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(Icons.grid_on_outlined, color: AppColors.gridCyan, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SECTOR MAP',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Anonymous grid status. No locations, no identifiers.',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white24,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.gridCyan.withOpacity(0.9), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.white38, fontSize: 9),
                ),
              ],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: AppColors.gridCyan,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.white24, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Anonymous grid status only. No coordinates, no place names, no user data. Hot zones — see bottom tab HOT ZONES.',
              style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
