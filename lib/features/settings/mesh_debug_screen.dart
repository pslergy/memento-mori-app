// Real device mesh debug screen.
// Shows nearby nodes, connections, logs, manual actions.
// NO core logic changes — debug hooks only.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_service.dart';
import '../../core/decoy/vault_interface.dart';
import '../../core/locator.dart';
import '../../core/mesh_core_engine.dart';
import '../../core/mesh/diagnostics/mesh_metrics.dart';
import '../../core/mesh_debug_config.dart';
import '../../core/models/signal_node.dart';
import '../../core/network_monitor.dart';
import '../theme/app_colors.dart';

class MeshDebugScreen extends StatefulWidget {
  const MeshDebugScreen({super.key});

  @override
  State<MeshDebugScreen> createState() => _MeshDebugScreenState();
}

class _MeshDebugScreenState extends State<MeshDebugScreen> {
  Timer? _refreshTimer;
  String _deviceName = '';
  String _nodeId = '';

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final android = await DeviceInfoPlugin().androidInfo;
      _deviceName = '${android.manufacturer} ${android.model}';
    } catch (_) {
      _deviceName = 'Unknown';
    }
    try {
      if (locator.isRegistered<ApiService>()) {
        _nodeId = locator<ApiService>().currentUserId;
      }
      if (_nodeId.isEmpty && locator.isRegistered<VaultInterface>()) {
        _nodeId = await locator<VaultInterface>().read('user_id') ?? 'GHOST';
      }
      if (_nodeId.isEmpty) _nodeId = 'GHOST';
    } catch (_) {
      _nodeId = 'GHOST';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!meshDebugMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mesh Debug')),
        body: const Center(child: Text('meshDebugMode is false')),
      );
    }

    final mesh = context.watch<MeshCoreEngine>();
    final ctx = mesh.getContextSnapshot();
    final role = NetworkMonitor().currentRole;
    final metrics = MeshMetrics.instance;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Mesh Debug (Real Device)'),
        backgroundColor: AppColors.surface,
      ),
      body: RefreshIndicator(
        onRefresh: () async => setState(() {}),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDeviceCard(),
              const SizedBox(height: 16),
              _buildStateCard(mesh, ctx, role),
              const SizedBox(height: 16),
              _buildMetricsCard(metrics),
              const SizedBox(height: 16),
              _buildManualActions(mesh),
              const SizedBox(height: 16),
              _buildNearbyNodes(ctx.nearbyNodes),
              const SizedBox(height: 16),
              _buildLogsSection(mesh),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCard() {
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 4),
            Text('nodeId: $_nodeId', style: const TextStyle(color: Colors.white)),
            Text('deviceName: $_deviceName', style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _buildStateCard(MeshCoreEngine mesh, dynamic ctx, dynamic role) {
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('State', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            _row('Role', role.toString().split('.').last),
            _row('isTransferring', '${mesh.isTransferring}'),
            _row('lastKnownPeerIp', mesh.lastKnownPeerIp.isEmpty ? '(empty)' : mesh.lastKnownPeerIp),
            _row('isP2pConnected', '${mesh.isP2pConnected}'),
            _row('nearbyNodes', '${ctx.nearbyNodeCount}'),
            _row('cooldowns', '${ctx.cooldownCount}'),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 140, child: Text(label, style: TextStyle(color: AppColors.textDim, fontSize: 12))),
            Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 12))),
          ],
        ),
      );

  Widget _buildMetricsCard(MeshMetrics metrics) {
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Metrics', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            _row('sendAutoCount', '${metrics.sendAutoCount}'),
            _row('cascadeStart', '${metrics.cascadeStartCount}'),
            _row('cascadeSuccess', '${metrics.cascadeSuccessCount}'),
            _row('cascadeWatchdog', '${metrics.cascadeWatchdogCount}'),
            _row('cooldownHit', '${metrics.cooldownHitCount}'),
            _row('bleScanCount', '${metrics.bleScanCount}'),
            _row('lastDelivery', metrics.lastDeliveryDuration != null ? '${metrics.lastDeliveryDuration!.inMilliseconds}ms' : '-'),
          ],
        ),
      ),
    );
  }

  Widget _buildManualActions(MeshCoreEngine mesh) {
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manual Actions', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: () => _sendTestMessage(mesh),
                  child: const Text('Send test message'),
                ),
                ElevatedButton(
                  onPressed: () => _forceCascade(mesh),
                  child: const Text('Force cascade'),
                ),
                ElevatedButton(
                  onPressed: () => _toggleWifiDiscovery(mesh),
                  child: const Text('Toggle Wi-Fi discovery'),
                ),
                ElevatedButton(
                  onPressed: () => _toggleBleScan(mesh),
                  child: const Text('Toggle BLE scan'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendTestMessage(MeshCoreEngine mesh) async {
    mesh.addLog('[DEBUG] Sending test message...');
    try {
      await mesh.sendAuto(
        content: 'DEBUG_TEST_${DateTime.now().millisecondsSinceEpoch}',
        chatId: 'THE_BEACON_GLOBAL',
        receiverName: 'DEBUG',
        messageId: 'debug_${DateTime.now().millisecondsSinceEpoch}',
      );
      mesh.addLog('[DEBUG] Test message sent');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test message sent')));
    } catch (e) {
      mesh.addLog('[DEBUG] Test send failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  void _forceCascade(MeshCoreEngine mesh) {
    mesh.requestAutoScanForOutbox();
    mesh.addLog('[DEBUG] Force cascade requested');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cascade triggered')));
  }

  void _toggleWifiDiscovery(MeshCoreEngine mesh) {
    mesh.startDiscovery(SignalType.mesh);
    mesh.addLog('[DEBUG] Wi-Fi discovery toggled');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wi-Fi discovery started')));
  }

  void _toggleBleScan(MeshCoreEngine mesh) {
    mesh.startDiscovery(SignalType.bluetooth);
    mesh.addLog('[DEBUG] BLE scan toggled');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('BLE scan started')));
  }

  Widget _buildNearbyNodes(List<SignalNode> nodes) {
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nearby Nodes (${nodes.length})', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            if (nodes.isEmpty)
              const Text('None', style: TextStyle(color: Colors.white54))
            else
              ...nodes.take(20).map((n) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('${n.name} (${n.type.name}) ${n.metadata}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsSection(MeshCoreEngine mesh) {
    final logs = mesh.getAllLogs();
    final recent = logs.length > 100 ? logs.sublist(logs.length - 100) : logs;

    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Logs (live)', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                TextButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: recent.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    recent[recent.length - 1 - i],
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
