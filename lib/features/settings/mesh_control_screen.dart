import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:animate_do/animate_do.dart';
import '../../core/connection_status_panel.dart';
import '../../core/decoy/app_bootstrap.dart';
import '../../core/decoy/app_mode.dart';
import '../../core/bluetooth_service.dart';
import '../../core/mesh_core_engine.dart';
import '../../core/locator.dart';
import '../../core/models/signal_node.dart';
import '../../core/native_mesh_service.dart';
import '../../core/ultrasonic_service.dart';
import '../../core/network_monitor.dart';
import '../../core/router/router_connection_service.dart';
import 'router_management_screen.dart';
import 'mesh_debug_screen.dart';
import '../../core/mesh_debug_config.dart';
import '../../core/api_service.dart';
import '../../core/storage_service.dart';
import '../../core/extended_identity_test_mode.dart';
import '../../core/gossip_manager.dart';
import '../../core/mesh_stress_test_harness.dart';
import '../../core/security_config.dart';
import '../../core/internet/dpi_backend_channel_gate.dart';
import '../../core/transport/transport_config.dart';
import '../../core/mesh_ghost_idle_adv_settings.dart';
import '../../core/immune/immune_service.dart';
import '../../core/immune/attempt_log.dart';
import '../theme/app_colors.dart';
import '../ui/messenger_expectations_info.dart';

class MeshControlScreen extends StatefulWidget {
  const MeshControlScreen({super.key});

  @override
  State<MeshControlScreen> createState() => _MeshControlScreenState();
}

class _MeshControlScreenState extends State<MeshControlScreen>
    with TickerProviderStateMixin {
  late AnimationController _radarController;
  late AnimationController _pulseController;
  late AnimationController _glowController;
  bool _isAcousticTransmitting = false;
  Timer? _statusUpdateTimer;

  bool _extendedChurnRunning = false;
  Timer? _churnStatusTimer;
  Duration? _churnElapsed;
  Map<String, int>? _churnSnapshot;
  ExtendedChurnResult? _churnResult;

  bool _useBle5LongRange = false;
  int _ghostIdleAdvKeepaliveSec = MeshGhostIdleAdvSettings.defaultSeconds;
  bool _manualCrdtSyncBusy = false;

  /// Громкость Sonar (динамик), подгружается из [UltrasonicService].
  double _sonarOutputVolume = 0.10;
  int _sonarBeaconMs = 420;
  bool _sonarPrefsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadBle5LongRange();
    _loadGhostIdleAdv();
    _loadSonarStealthPrefs();
    _radarController =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..repeat();
    _pulseController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
    _glowController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);

    // Обновление статуса каждые 2 секунды
    _statusUpdateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadBle5LongRange() async {
    final value = await BluetoothMeshService.getUseBle5LongRange();
    if (mounted) setState(() => _useBle5LongRange = value);
  }

  Future<void> _loadGhostIdleAdv() async {
    final s = await MeshGhostIdleAdvSettings.getSeconds();
    if (mounted) setState(() => _ghostIdleAdvKeepaliveSec = s);
  }

  Future<void> _loadSonarStealthPrefs() async {
    if (!locator.isRegistered<UltrasonicService>()) return;
    final u = locator<UltrasonicService>();
    final vol = await u.getOutputVolume();
    final ms = await u.getBeaconDurationMs();
    if (mounted) {
      setState(() {
        _sonarOutputVolume = vol;
        _sonarBeaconMs = ms;
        _sonarPrefsLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _glowController.dispose();
    _statusUpdateTimer?.cancel();
    _churnStatusTimer?.cancel();
    super.dispose();
  }

  void _logAction(String msg) {
    if (!locator.isRegistered<MeshCoreEngine>()) return;
    Future.microtask(() {
      if (!locator.isRegistered<MeshCoreEngine>()) return;
      locator<MeshCoreEngine>().addLog("[CHAIN] $msg");
    });
  }

  String _lastCrdtSyncLine(MeshCoreEngine mesh) {
    final t = mesh.lastCrdtChatSyncTime;
    if (t == null) {
      return 'Последняя CRDT-синхронизация: в этой сессии ещё не было успешного обмена с соседом.';
    }
    return 'Последняя CRDT-синхронизация: ${DateFormat('dd.MM.yyyy HH:mm').format(t)}';
  }

  String _manualCrdtSyncUserMessage(ManualMeshSyncResult r) {
    switch (r) {
      case ManualMeshSyncResult.started:
        return 'Запущена синхронизация по BLE. Если рядом не было недавних узлов, перед этим уже выполнен поиск (mesh + Bluetooth, до ~15 с). Дождитесь завершения попытки.';
      case ManualMeshSyncResult.skippedAlreadyRunning:
        return 'Синхронизация уже выполняется. Подождите.';
      case ManualMeshSyncResult.skippedNotGhost:
        return 'Доступно в режиме GHOST (офлайн). В BRIDGE чат обновляется через интернет и mesh по другим правилам.';
      case ManualMeshSyncResult.skippedBleBusy:
        return 'BLE занят (передача или подключение). Повторите позже.';
      case ManualMeshSyncResult.skippedTransportBusy:
        return 'Сейчас занят mesh: каскад доставки, передача сообщения, подключение для доставки или BLE-сессия. Дождитесь завершения и нажмите снова.';
      case ManualMeshSyncResult.skippedLowBattery:
        return 'Низкий заряд батареи (ниже 15%). Синхронизация отложена.';
      case ManualMeshSyncResult.skippedNoPeers:
        return 'Не найдена нода для синхронизации: после поиска рядом нет доступного mesh-узла (или он не попал в список за ~15 с). Подойдите ближе, проверьте Bluetooth на обоих устройствах и повторите.';
      case ManualMeshSyncResult.skippedHuaweiInboundOnly:
        return 'На Huawei/Honor этот телефон не подключается к соседу как BLE Central (ограничение стека). Сосед виден — запустите «Синхронизировать» или mesh на другом устройстве: оно подключится к вам и обменяет CRDT (HEAD + сообщения) через ваш GATT server.';
    }
  }

  Future<void> _onManualCrdtSyncTap(MeshCoreEngine mesh) async {
    setState(() => _manualCrdtSyncBusy = true);
    try {
      final r = await mesh.tryManualChatHistorySync();
      if (!mounted) return;
      final msg = _manualCrdtSyncUserMessage(r);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: r == ManualMeshSyncResult.started
              ? AppColors.gridCyan.withOpacity(0.85)
              : Colors.orange.shade900,
          duration: const Duration(seconds: 4),
        ),
      );
      _logAction('[CRDT manual] $r — $msg');
    } finally {
      if (mounted) setState(() => _manualCrdtSyncBusy = false);
    }
  }

  void _executeEmergencySOS() async {
    _logAction("🚨 SOS EXECUTION STARTED");
    HapticFeedback.vibrate();

    final mesh =
        locator.isRegistered<MeshCoreEngine>() ? locator<MeshCoreEngine>() : null;
    final api =
        locator.isRegistered<ApiService>() ? locator<ApiService>() : null;
    String userId = 'GHOST';
    if (api != null) userId = api.currentUserId;
    if (userId.isEmpty) userId = (await _vaultUserId()) ?? 'GHOST';

    bool success = false;

    // 1. Cloud API (если зарегистрирован)
    if (api != null) {
      try {
        await api.sendAonymizedSOS();
        success = true;
        _logAction("✅ SOS sent via Cloud API");
      } catch (e) {
        _logAction("⚠️ Cloud SOS failed: $e");
      }
    }

    // 2. Mesh (если зарегистрирован)
    if (mesh != null) {
      try {
        final shortId = userId.length >= 4 ? userId.substring(0, 4) : userId;
        await mesh.sendAuto(
          content: "🚨 CRITICAL SOS: Nomad $shortId position compromised.",
          chatId: "THE_BEACON_GLOBAL",
          receiverName: "GLOBAL",
        );
        success = true;
        _logAction("✅ SOS sent via Mesh");
      } catch (e) {
        _logAction("⚠️ Mesh SOS failed: $e");
      }
    }

    // 3. Sonar (если зарегистрирован)
    if (locator.isRegistered<UltrasonicService>()) {
      try {
        await locator<UltrasonicService>().transmitFrame("SOS:$userId");
        success = true;
        _logAction("✅ SOS sent via Sonar");
      } catch (e) {
        _logAction("⚠️ Sonar SOS failed: $e");
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? "✅ EMERGENCY BROADCAST ACTIVE"
              : (mesh == null && api == null
                  ? "⚠️ Mesh/Cloud not available (Stealth mode)"
                  : "⚠️ SOS SENT (some channels may have failed)")),
          backgroundColor: success ? AppColors.warningRed : Colors.orange,
        ),
      );
    }

    if (!success) _logAction("❌ SOS FAILED on all channels");
  }

  Future<String?> _vaultUserId() async {
    try {
      return await Vault.read('user_id');
    } catch (_) {
      return null;
    }
  }

  /// Поднимает SESSION с текущим режимом (REAL/DECOY) и перестраивает экран — для призрака и бриджа одинаково.
  void _ensureSessionThenRebuild() {
    Future<void> run() async {
      final mode = await resolveAppMode();
      if (mode == AppMode.INVALID) return;
      setupSessionLocator(mode);
      if (mounted) setState(() {});
    }
    run();
  }

  @override
  Widget build(BuildContext context) {
    if (!locator.isRegistered<MeshCoreEngine>()) {
      if (isCoreReady) {
        // На призраке и бридже одинаково: поднимаем SESSION с текущим режимом
        _ensureSessionThenRebuild();
      }
      if (!locator.isRegistered<MeshCoreEngine>()) {
        return Scaffold(
          appBar: AppBar(title: const Text('THE CHAIN')),
          backgroundColor: AppColors.background,
          body: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.stealthOrange),
                SizedBox(height: 16),
                Text('Initializing mesh...',
                    style: TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        );
      }
    }
    final mesh = context.watch<MeshCoreEngine>();
    final nodes = mesh.nearbyNodes;
    final role = NetworkMonitor().currentRole;
    final routerService = RouterConnectionService();
    final connectedRouter = routerService.connectedRouter;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(mesh, role, connectedRouter),
            const ConnectionStatusPanel(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    MessengerExpectationsInfo.buildChainCard(),
                    const SizedBox(height: 20),
                    _buildDpiBackendChannelSection(),
                    const SizedBox(height: 20),
                    _buildRadarDisplay(nodes.length, mesh),
                    const SizedBox(height: 30),
                    _buildEmergencyButton(),
                    const SizedBox(height: 30),
                    _buildChannelsGrid(mesh, connectedRouter),
                    const SizedBox(height: 30),
                    _buildNetworkStats(mesh, role, connectedRouter),
                    if (kDebugMode) ...[
                      const SizedBox(height: 20),
                      _buildDebugTransportSection(mesh, role),
                      const SizedBox(height: 20),
                      _buildAttemptDiarySection(),
                      const SizedBox(height: 20),
                      _buildStressTestSection(mesh),
                    ],
                    if (meshDebugMode) ...[
                      const SizedBox(height: 20),
                      _buildMeshDebugButton(),
                    ],
                    const SizedBox(height: 20),
                    _buildAlliesList(nodes),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
            _buildFooterActions(mesh),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader(MeshCoreEngine mesh, MeshRole role, connectedRouter) {
    final isOnline = role == MeshRole.BRIDGE;
    final themeColor = isOnline
        ? AppColors.cloudGreen
        : (mesh.isP2pConnected ? AppColors.gridCyan : AppColors.stealthOrange);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            themeColor.withOpacity(0.1),
            AppColors.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
            bottom: BorderSide(color: themeColor.withOpacity(0.3), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildStatCard(
              "ROLE", isOnline ? "BRIDGE" : "GHOST", themeColor, Icons.cloud),
          _buildStatCard("NODES", "${mesh.nearbyNodes.length}",
              AppColors.gridCyan, Icons.hub),
          _buildStatCard("STEALTH", mesh.isPowerSaving ? "ON" : "OFF",
              AppColors.stealthOrange, Icons.visibility_off),
        ],
      ),
    );
  }

  Widget _buildStatCard(
      String label, String value, Color color, IconData icon) {
    return FadeInUp(
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.1),
              blurRadius: 8,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 8,
                color: AppColors.textDim,
                letterSpacing: 1,
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                color: color,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
                fontFamily: 'Orbitron',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadarDisplay(int count, MeshCoreEngine mesh) {
    return FadeInUp(
      duration: const Duration(milliseconds: 500),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 220,
            width: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.gridCyan.withOpacity(0.1),
                  AppColors.background,
                ],
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                _buildRadarAnimation(),
                _buildRadarPulse(),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 1.0 + (_pulseController.value * 0.1),
                      child: Icon(
                        Icons.radar,
                        color: AppColors.gridCyan,
                        size: 40,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          Text(
            count > 0 ? "$count NODES" : "SCANNING",
            style: TextStyle(
              fontSize: 12,
              color: AppColors.gridCyan,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontFamily: 'Orbitron',
            ),
          ),
          const SizedBox(height: 5),
          Text(
            mesh.isP2pConnected ? "P2P ACTIVE" : "AIR-GAP MODE",
            style: TextStyle(
              fontSize: 9,
              color: AppColors.textDim,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarAnimation() {
    return AnimatedBuilder(
      animation: _radarController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: List.generate(3, (index) {
            double value = (_radarController.value + index / 3) % 1;
            return Container(
              width: 220 * value,
              height: 220 * value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.gridCyan.withOpacity(1 - value * 0.8),
                  width: 1.5,
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildRadarPulse() {
    return AnimatedBuilder(
      animation: _glowController,
      builder: (context, child) {
        return Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                AppColors.gridCyan.withOpacity(0.3 * _glowController.value),
                AppColors.gridCyan.withOpacity(0),
              ],
            ),
          ),
        );
      },
    );
  }

  /// DPI: ручной выбор backend-канала (продвинутые пользователи).
  Widget _buildDpiBackendChannelSection() {
    final channels = SecurityConfig.effectiveBackendChannels;
    final idx = SecurityConfig.currentChannelIndex;
    final cur = SecurityConfig.currentChannel;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, color: AppColors.gridCyan, size: 22),
              const SizedBox(width: 8),
              const Text(
                'CLOUD API CHANNEL',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'If the cloud does not respond (DPI / block), try another channel. '
            'The app also rotates automatically after repeated errors.',
            style: TextStyle(
              color: AppColors.textDim,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Active: ${idx + 1}/${channels.length} — ${cur.host}:${cur.port}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (channels.length <= 1) ...[
            const SizedBox(height: 8),
            Text(
              'Only one channel configured. Add more in SecurityConfig.backendChannels.',
              style: TextStyle(color: AppColors.stealthOrange, fontSize: 11),
            ),
          ],
          if (channels.length > 1) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        SecurityConfig.cycleBackendChannelManual();
                        DpiBackendChannelGate.resetAfterManualChannelPick();
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.gridCyan,
                      side: const BorderSide(color: AppColors.gridCyan),
                    ),
                    child: const Text('Next channel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        SecurityConfig.resetToPrimaryChannel();
                        DpiBackendChannelGate.resetAfterManualChannelPick();
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textDim,
                      side: BorderSide(
                        color: AppColors.textDim.withOpacity(0.55),
                      ),
                    ),
                    child: const Text('Primary'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmergencyButton() {
    return FadeInUp(
      duration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onLongPress: _executeEmergencySOS,
        onTap: () {
          HapticFeedback.lightImpact();
        },
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 25),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.warningRed.withOpacity(0.15),
                    AppColors.warningRed.withOpacity(0.05),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.warningRed
                      .withOpacity(0.5 + _pulseController.value * 0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.warningRed
                        .withOpacity(0.3 * _pulseController.value),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Column(
                children: [
                  Pulse(
                    infinite: true,
                    child: Center(
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: AppColors.warningRed,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "HOLD FOR EMERGENCY SOS",
                    style: TextStyle(
                      color: AppColors.warningRed,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      fontFamily: 'Orbitron',
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    "DISPATCHES TO ALL NEARBY NODES",
                    style: TextStyle(
                      color: AppColors.textDim,
                      fontSize: 9,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildChannelsGrid(MeshCoreEngine mesh, connectedRouter) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "COMMUNICATION CHANNELS",
          style: TextStyle(
            fontSize: 10,
            color: AppColors.textDim,
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
            fontFamily: 'Orbitron',
          ),
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(
              child: _buildChannelCard(
                icon: Icons.wifi,
                label: "Wi-Fi Direct",
                status: mesh.isP2pConnected ? "CONNECTED" : "IDLE",
                color: AppColors.gridCyan,
                isActive: mesh.isP2pConnected,
                onTap: () {
                  if (!mesh.isP2pConnected) {
                    mesh.startDiscovery(SignalType.wifiDirect);
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildChannelCard(
                icon: Icons.bluetooth,
                label: "BLE GATT",
                status: mesh.nearbyNodes
                        .where((n) => n.type == SignalType.bluetooth)
                        .isNotEmpty
                    ? "ACTIVE"
                    : "IDLE",
                color: AppColors.sonarPurple,
                isActive: mesh.nearbyNodes
                    .where((n) => n.type == SignalType.bluetooth)
                    .isNotEmpty,
                onTap: () {
                  mesh.startDiscovery(SignalType.bluetooth);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildChannelCard(
                icon: Icons.record_voice_over,
                label: "SONAR",
                status: _isAcousticTransmitting ? "TRANSMITTING" : "READY",
                color: AppColors.sonarPurple,
                isActive: _isAcousticTransmitting,
                onTap: () async {
                  setState(() => _isAcousticTransmitting = true);
                  final userId = locator.isRegistered<ApiService>()
                      ? locator<ApiService>().currentUserId
                      : (await _vaultUserId()) ?? 'GHOST';
                  if (locator.isRegistered<UltrasonicService>()) {
                    await locator<UltrasonicService>()
                        .transmitFrame("LNK:$userId");
                  }
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted) {
                      setState(() => _isAcousticTransmitting = false);
                    }
                  });
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildChannelCard(
                icon: Icons.router,
                label: "ROUTER",
                status: connectedRouter != null ? "CONNECTED" : "NONE",
                color: AppColors.cloudGreen,
                isActive: connectedRouter != null,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RouterManagementScreen()),
                  );
                },
              ),
            ),
          ],
        ),
        if (locator.isRegistered<UltrasonicService>() && _sonarPrefsLoaded) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "SONAR — громкость и импульс",
              style: TextStyle(
                fontSize: 9,
                color: AppColors.textDim,
                letterSpacing: 1.2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text("Тише", style: TextStyle(fontSize: 9, color: AppColors.textDim)),
              Expanded(
                child: Slider(
                  value: _sonarOutputVolume,
                  min: 0.02,
                  max: 0.45,
                  divisions: 43,
                  label: "${(_sonarOutputVolume * 100).round()}%",
                  activeColor: AppColors.sonarPurple,
                  onChanged: (v) {
                    setState(() => _sonarOutputVolume = v);
                  },
                  onChangeEnd: (v) async {
                    await locator<UltrasonicService>().setOutputVolume(v);
                    _logAction(
                        "🔉 Sonar output volume → ${(v * 100).round()}%");
                  },
                ),
              ),
              Text("Выше", style: TextStyle(fontSize: 9, color: AppColors.textDim)),
            ],
          ),
          Row(
            children: [
              Text(
                "Маяк: $_sonarBeaconMs мс",
                style: TextStyle(fontSize: 9, color: AppColors.textDim),
              ),
              Expanded(
                child: Slider(
                  value: _sonarBeaconMs.toDouble(),
                  min: 200,
                  max: 1000,
                  divisions: 16,
                  label: "$_sonarBeaconMs мс",
                  activeColor: AppColors.sonarPurple.withOpacity(0.85),
                  onChanged: (v) {
                    setState(() => _sonarBeaconMs = v.round());
                  },
                  onChangeEnd: (v) async {
                    await locator<UltrasonicService>()
                        .setBeaconDurationMs(v.round());
                    _logAction("🔉 Sonar beacon duration → ${v.round()} ms");
                  },
                ),
              ),
            ],
          ),
          Text(
            "По радио анонимность относительная: BLE и Wi‑Fi всё равно дают устойчивые следы "
            "(мощность, расписание кадров, иногда стабильные идентификаторы). "
            "«Замусорить» эфир без потери mesh здесь не заявлено — иначе легко дать ложное чувство защиты. "
            "Практично: «только Wi‑Fi Direct», реже BLE, ниже громкость Sonar — меньше заметность в эфире и гармоники в слышимом диапазоне.",
            style: TextStyle(
              fontSize: 8,
              height: 1.35,
              color: AppColors.textDim.withOpacity(0.9),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildChannelCard({
    required IconData icon,
    required String label,
    required String status,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return FadeInUp(
      duration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isActive
                  ? [color.withOpacity(0.15), color.withOpacity(0.05)]
                  : [AppColors.surface, AppColors.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: isActive ? color.withOpacity(0.5) : AppColors.white05,
              width: isActive ? 2 : 1,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: color.withOpacity(0.2),
                      blurRadius: 12,
                      spreadRadius: 0,
                    ),
                  ]
                : [],
          ),
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Transform.scale(
                    scale:
                        isActive ? 1.0 + (_pulseController.value * 0.1) : 1.0,
                    child: Icon(
                      icon,
                      color: isActive ? color : AppColors.textDim,
                      size: 28,
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Orbitron',
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.white : AppColors.textDim,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isActive ? color.withOpacity(0.2) : AppColors.white05,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: isActive ? color : AppColors.textDim,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkStats(MeshCoreEngine mesh, MeshRole role, connectedRouter) {
    return FadeInUp(
      duration: const Duration(milliseconds: 500),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.white05, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "NETWORK STATUS",
              style: TextStyle(
                fontSize: 10,
                color: AppColors.textDim,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                fontFamily: 'Orbitron',
              ),
            ),
            const SizedBox(height: 15),
            _buildStatRow(
                "Role",
                role == MeshRole.BRIDGE ? "BRIDGE (Online)" : "GHOST (Offline)",
                role == MeshRole.BRIDGE
                    ? AppColors.cloudGreen
                    : AppColors.stealthOrange),
            const SizedBox(height: 10),
            _buildStatRow(
                "Wi-Fi Direct",
                mesh.isP2pConnected ? "Connected" : "Disconnected",
                mesh.isP2pConnected ? AppColors.gridCyan : AppColors.textDim),
            const SizedBox(height: 10),
            _buildStatRow(
                "Router",
                connectedRouter != null ? connectedRouter.ssid : "None",
                connectedRouter != null
                    ? AppColors.cloudGreen
                    : AppColors.textDim),
            const SizedBox(height: 10),
            _buildStatRow(
                "Power Saving",
                mesh.isPowerSaving ? "Enabled" : "Disabled",
                mesh.isPowerSaving
                    ? AppColors.stealthOrange
                    : AppColors.gridCyan),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "BLE 5.0 LR",
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textDim,
                    letterSpacing: 1,
                  ),
                ),
                Switch(
                  value: _useBle5LongRange,
                  onChanged: (value) async {
                    await BluetoothMeshService.setUseBle5LongRange(value);
                    if (mounted) setState(() => _useBle5LongRange = value);
                  },
                  activeColor: AppColors.gridCyan,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              "Дальний приём BLE (экспериментально)",
              style: TextStyle(fontSize: 9, color: AppColors.textDim),
            ),
            const SizedBox(height: 2),
            Text(
              BluetoothMeshService.isBle5LongRangeActive
                  ? "Сейчас: BLE 5.0 LR активен"
                  : (BluetoothMeshService.lastBleAdvertisingStrategy != null
                      ? "Сейчас: обычный BLE"
                      : "Сейчас: —"),
              style: TextStyle(
                fontSize: 9,
                color: BluetoothMeshService.isBle5LongRangeActive
                    ? AppColors.gridCyan
                    : AppColors.textDim,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              "Пульс BLE в простое",
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textDim,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              MeshGhostIdleAdvSettings.explanationShort,
              style: TextStyle(fontSize: 9, color: AppColors.textDim),
            ),
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(context).copyWith(canvasColor: AppColors.surface),
              child: DropdownButton<int>(
                isExpanded: true,
                value: _ghostIdleAdvKeepaliveSec,
                underline: Container(height: 1, color: AppColors.white05),
                dropdownColor: AppColors.surface,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textDim,
                  fontFamily: 'Orbitron',
                ),
                items: MeshGhostIdleAdvSettings.allowedSeconds
                    .map((e) => DropdownMenuItem<int>(
                          value: e,
                          child: Text(
                            MeshGhostIdleAdvSettings.labelForSeconds(e),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  await MeshGhostIdleAdvSettings.setSeconds(v);
                  if (mounted) setState(() => _ghostIdleAdvKeepaliveSec = v);
                  _logAction(
                      "Пульс BLE в простое: ${MeshGhostIdleAdvSettings.labelForSeconds(v)}");
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              MeshGhostIdleAdvSettings.explanationLong,
              style: TextStyle(
                fontSize: 8,
                color: AppColors.textDim,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              "История чатов с соседями (CRDT)",
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textDim,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _lastCrdtSyncLine(mesh),
              style: TextStyle(fontSize: 9, color: AppColors.textDim),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: (_manualCrdtSyncBusy || mesh.isManualCrdtSyncButtonLocked)
                    ? null
                    : () => _onManualCrdtSyncTap(mesh),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gridCyan,
                  side: BorderSide(color: AppColors.gridCyan.withOpacity(0.6)),
                ),
                child: _manualCrdtSyncBusy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.gridCyan,
                        ),
                      )
                    : const Text('Синхронизировать'),
              ),
            ),
            const SizedBox(height: 4),
            if (mesh.isManualCrdtSyncButtonLocked && !_manualCrdtSyncBusy)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  mesh.isManualCrdtSyncTransportBusy
                      ? 'Кнопка недоступна: идёт каскад, передача или BLE-подключение.'
                      : 'Кнопка недоступна: уже выполняется фоновая CRDT-синхронизация.',
                  style: TextStyle(
                    fontSize: 8,
                    color: Colors.amber.shade200,
                    height: 1.35,
                  ),
                ),
              ),
            Text(
              'Только в режиме GHOST и при свободном BLE. По нажатию сначала запускается поиск узлов (как на радаре), затем попытка синхронизации. История на каждом телефоне — локальная копия; полное совпадение с другими не гарантируется.',
              style: TextStyle(
                fontSize: 8,
                color: AppColors.textDim,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textDim,
            letterSpacing: 1,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color: valueColor,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
            fontFamily: 'Orbitron',
          ),
        ),
      ],
    );
  }

  Widget _buildDebugTransportSection(MeshCoreEngine mesh, MeshRole role) {
    return FadeInUp(
      duration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.gridCyan.withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "DEBUG: TRANSPORT & SYNC",
              style: TextStyle(
                fontSize: 10,
                color: AppColors.gridCyan,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                fontFamily: 'Orbitron',
              ),
            ),
            const SizedBox(height: 12),
            // Wi-Fi Direct only toggle
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Wi-Fi Direct only",
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textDim,
                    letterSpacing: 1,
                  ),
                ),
                Switch(
                  value: TransportConfig.debugForceWifiDirectOnly,
                  onChanged: (v) {
                    setState(() {
                      TransportConfig.debugForceWifiDirectOnly = v;
                    });
                    _logAction(
                        "🔧 Wi-Fi Direct only: ${v ? 'ON' : 'OFF'} (sendAuto + Gossip)");
                  },
                  activeColor: AppColors.gridCyan,
                ),
              ],
            ),
            Text(
              "Только Wi-Fi Direct (без BLE/Sonar)",
              style: TextStyle(fontSize: 9, color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            // Sonar SOS button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  if (locator.isRegistered<UltrasonicService>()) {
                    final userId = locator.isRegistered<ApiService>()
                        ? locator<ApiService>().currentUserId
                        : (await _vaultUserId()) ?? 'GHOST';
                    await locator<UltrasonicService>()
                        .transmitFrame("SOS:$userId");
                    _logAction("✅ Sonar SOS sent: SOS:$userId");
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Sonar SOS transmitted"),
                          backgroundColor: AppColors.sonarPurple,
                        ),
                      );
                    }
                  } else {
                    _logAction("⚠️ UltrasonicService not registered");
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Sonar not available"),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.record_voice_over, size: 18),
                label: const Text("Sonar SOS"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sonarPurple,
                  side: BorderSide(
                    color: AppColors.sonarPurple.withOpacity(0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Reset TCP crash flag (если TCP сервер падал — сброс позволяет снова поднимать)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  try {
                    await NativeMeshService.resetTcpServerCrashFlag();
                    _logAction("✅ TCP server crash flag reset — Wi-Fi Direct GO can host again");
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("TCP crash flag reset. Restart mesh to try Wi-Fi Direct GO."),
                          backgroundColor: AppColors.gridCyan,
                        ),
                      );
                    }
                  } catch (e) {
                    _logAction("⚠️ Reset TCP crash flag failed: $e");
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Reset failed: $e"),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text("Reset TCP crash flag"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gridCyan,
                  side: BorderSide(
                    color: AppColors.gridCyan.withOpacity(0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Trigger epidemic
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  if (locator.isRegistered<GossipManager>()) {
                    locator<GossipManager>().runEpidemicCycleOnce();
                    _logAction("🦠 Epidemic cycle triggered");
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Epidemic cycle started"),
                          backgroundColor: AppColors.gridCyan,
                        ),
                      );
                    }
                  } else {
                    _logAction("⚠️ GossipManager not registered");
                  }
                },
                icon: const Icon(Icons.public, size: 18),
                label: const Text("Trigger epidemic"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gridCyan,
                  side: BorderSide(
                    color: AppColors.gridCyan.withOpacity(0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Sync outbox (BRIDGE only)
            if (role == MeshRole.BRIDGE && locator.isRegistered<ApiService>())
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await locator<ApiService>().syncOutbox();
                      _logAction("☁️ Outbox synced to cloud");
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Outbox synced"),
                            backgroundColor: AppColors.cloudGreen,
                          ),
                        );
                      }
                    } catch (e) {
                      _logAction("⚠️ Sync failed: $e");
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Sync failed: $e"),
                            backgroundColor: Colors.orange,
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.cloud_upload, size: 18),
                  label: const Text("Sync outbox → Cloud"),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.cloudGreen,
                    side: BorderSide(
                      color: AppColors.cloudGreen.withOpacity(0.6),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttemptDiarySection() {
    if (!locator.isRegistered<ImmuneService>()) {
      return const SizedBox.shrink();
    }
    return FadeInUp(
      duration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.gridCyan.withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "ATTEMPT DIARY (DEBUG)",
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.gridCyan,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Orbitron',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {}),
                  child: Text(
                    "Refresh",
                    style: TextStyle(fontSize: 10, color: AppColors.gridCyan),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<AttemptLog>>(
              future: locator<ImmuneService>().getRecentAttempts(limit: 20),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Text(
                    "Loading…",
                    style: TextStyle(fontSize: 10, color: AppColors.textDim),
                  );
                }
                final logs = snapshot.data!;
                if (logs.isEmpty) {
                  return Text(
                    "No attempts yet. Make HTTP requests to fill.",
                    style: TextStyle(fontSize: 10, color: AppColors.textDim),
                  );
                }
                return Column(
                  children: logs.map((log) {
                    final resultColor = log.result == AttemptResult.success
                        ? AppColors.cloudGreen
                        : (log.result == AttemptResult.blockDetected
                            ? Colors.orange
                            : AppColors.textDim);
                    final time = _formatTime(log.timestamp);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 55,
                            child: Text(
                              time,
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textDim,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              log.donorSni,
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.textDim,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: resultColor.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _resultLabel(log.result),
                              style: TextStyle(
                                fontSize: 8,
                                color: resultColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    }
    return "${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  String _resultLabel(AttemptResult r) {
    switch (r) {
      case AttemptResult.success:
        return "OK";
      case AttemptResult.blockDetected:
        return "BLOCK";
      case AttemptResult.failure:
        return "FAIL";
    }
  }

  Widget _buildMeshDebugButton() {
    return FadeInUp(
      duration: const Duration(milliseconds: 400),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MeshDebugScreen()),
          ),
          icon: const Icon(Icons.bug_report),
          label: const Text('Mesh Debug (Real Device)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.gridCyan,
            side: BorderSide(color: AppColors.gridCyan.withOpacity(0.5)),
          ),
        ),
      ),
    );
  }

  Widget _buildStressTestSection(MeshCoreEngine mesh) {
    return FadeInUp(
      duration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.stealthOrange.withOpacity(0.5), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "STRESS TEST (DEBUG)",
              style: TextStyle(
                fontSize: 10,
                color: AppColors.stealthOrange,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                fontFamily: 'Orbitron',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "5 min each. Results in mesh log.",
              style: TextStyle(fontSize: 10, color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _stressTestButton(mesh, "A", runScenarioA, "Normal"),
                const SizedBox(width: 8),
                _stressTestButton(mesh, "B", runScenarioB, "High"),
                const SizedBox(width: 8),
                _stressTestButton(mesh, "C", runScenarioC, "Identity"),
              ],
            ),
            if (_extendedChurnRunning || _churnResult != null) ...[
              const SizedBox(height: 12),
              _buildExtendedChurnStatus(mesh),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.stealthOrange,
                side: BorderSide(color: AppColors.stealthOrange.withOpacity(0.6)),
              ),
              onPressed: _extendedChurnRunning
                  ? null
                  : () => _startExtendedIdentityChurnTest(mesh),
              child: const Text('Start Identity Churn Test (15 min)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtendedChurnStatus(MeshCoreEngine mesh) {
    if (_churnResult != null) {
      final r = _churnResult!;
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.stealthOrange.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('=== EXTENDED CHURN RESULT ===',
                style: TextStyle(fontSize: 10, color: AppColors.stealthOrange, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('duration: ${r.duration.inMinutes}m ${r.duration.inSeconds % 60}s', style: const TextStyle(fontSize: 11)),
            Text('maxIdentityFirstSeen: ${r.maxIdentityFirstSeen}', style: const TextStyle(fontSize: 11)),
            Text('identityCleanupRuns: ${r.identityCleanupRuns}', style: const TextStyle(fontSize: 11)),
            Text('maxGenerationWindow: ${r.maxGenerationWindowSize}', style: const TextStyle(fontSize: 11)),
            Text('relayAttempts: ${r.relayAttempts}', style: const TextStyle(fontSize: 11)),
            Text('relayDroppedByBudget: ${r.relayDroppedByBudget}', style: const TextStyle(fontSize: 11)),
            Text('hadCrash: ${r.hadCrash}', style: TextStyle(fontSize: 11, color: r.hadCrash ? Colors.red : null)),
          ],
        ),
      );
    }
    if (!_extendedChurnRunning || _churnElapsed == null || _churnSnapshot == null) {
      return const SizedBox.shrink();
    }
    final snap = _churnSnapshot!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.stealthOrange.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Running…', style: TextStyle(fontSize: 12, color: AppColors.stealthOrange, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Elapsed: ${_churnElapsed!.inMinutes}m ${_churnElapsed!.inSeconds % 60}s', style: const TextStyle(fontSize: 11)),
          Text('Active identities: ${snap['currentIdentityCount'] ?? 0}', style: const TextStyle(fontSize: 11)),
          Text('Cleanup runs: ${snap['identityCleanupRuns'] ?? 0}', style: const TextStyle(fontSize: 11)),
          Text('Generation window: ${snap['currentGenerationWindowSize'] ?? 0}', style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Future<void> _startExtendedIdentityChurnTest(MeshCoreEngine mesh) async {
    if (_extendedChurnRunning) return;
    setState(() {
      _extendedChurnRunning = true;
      _churnResult = null;
      _churnElapsed = Duration.zero;
      _churnSnapshot = null;
    });

    EXTENDED_IDENTITY_TEST_MODE = true;
    _churnStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_extendedChurnRunning) return;
      final start = extendedChurnStartTime;
      if (start == null) return;
      if (!locator.isRegistered<GossipManager>()) return;
      final snap = locator<GossipManager>().getStressTestSnapshot();
      setState(() {
        _churnElapsed = DateTime.now().difference(start);
        _churnSnapshot = snap;
      });
    });

    try {
      final result = await simulateIdentityChurn(duration: const Duration(minutes: 15));
      if (mounted) {
        setState(() {
          _extendedChurnRunning = false;
          _churnResult = result;
          _churnElapsed = result.duration;
          _churnSnapshot = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Churn test done. identities=${result.maxIdentityFirstSeen} cleanup=${result.identityCleanupRuns} crash=${result.hadCrash}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _extendedChurnRunning = false;
          _churnResult = ExtendedChurnResult(
            duration: _churnElapsed ?? Duration.zero,
            maxIdentityFirstSeen: _churnSnapshot?['currentIdentityCount'] ?? 0,
            identityCleanupRuns: _churnSnapshot?['identityCleanupRuns'] ?? 0,
            maxGenerationWindowSize: _churnSnapshot?['currentGenerationWindowSize'] ?? 0,
            relayAttempts: _churnSnapshot?['relayAttempts'] ?? 0,
            relayDroppedByBudget: _churnSnapshot?['relayDroppedByBudget'] ?? 0,
            hadCrash: true,
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Churn test error: $e')));
      }
    } finally {
      _churnStatusTimer?.cancel();
      _churnStatusTimer = null;
    }
  }

  Widget _stressTestButton(
    MeshCoreEngine mesh,
    String label,
    Future<StressTestResult> Function() scenario,
    String hint,
  ) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.stealthOrange,
          side: BorderSide(color: AppColors.stealthOrange.withOpacity(0.6)),
        ),
        onPressed: () async {
          MESH_STRESS_TEST_MODE = true;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Stress test $label started (5 min). See log.')),
            );
          }
          try {
            final result = await runScenarioAndPrint(label, scenario);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Stress $label done. accepted=${result.acceptedTotal} relay=${result.relayAttempts} crash=${result.hadCrash}',
                  ),
                ),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Stress test error: $e')),
              );
            }
          } finally {
            MESH_STRESS_TEST_MODE = false;
          }
        },
        child: Text('$label ($hint)'),
      ),
    );
  }

  Widget _buildAlliesList(List<SignalNode> nodes) {
    if (nodes.isEmpty) {
      return FadeInUp(
        duration: const Duration(milliseconds: 600),
        child: Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AppColors.white05, width: 1),
          ),
          child: Column(
            children: [
              Icon(Icons.hub_outlined, color: AppColors.textDim, size: 40),
              const SizedBox(height: 10),
              Text(
                "NO NODES DETECTED",
                style: TextStyle(
                  color: AppColors.textDim,
                  fontSize: 12,
                  letterSpacing: 1,
                  fontFamily: 'Orbitron',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return FadeInUp(
      duration: const Duration(milliseconds: 600),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "DETECTED NODES (${nodes.length})",
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textDim,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
              fontFamily: 'Orbitron',
            ),
          ),
          const SizedBox(height: 15),
          ...nodes.map((node) => _buildNodeCard(node)),
        ],
      ),
    );
  }

  Widget _buildNodeCard(SignalNode node) {
    final color = node.type == SignalType.mesh
        ? AppColors.gridCyan
        : node.type == SignalType.bluetooth
            ? AppColors.sonarPurple
            : AppColors.stealthOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              node.type == SignalType.mesh ? Icons.wifi : Icons.bluetooth,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  node.type == SignalType.mesh ? "Wi-Fi Direct" : "BLE GATT",
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              "LINKED",
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooterActions(MeshCoreEngine mesh) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.white05, width: 1)),
      ),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(
              color: AppColors.warningRed.withOpacity(0.5), width: 1.5),
          minimumSize: const Size(double.infinity, 50),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.power_settings_new,
            color: AppColors.warningRed, size: 18),
        label: Text(
          "HALT ALL SIGNALS",
          style: TextStyle(
            fontFamily: 'Orbitron',
            fontWeight: FontWeight.bold,
            color: AppColors.warningRed,
            fontSize: 11,
            letterSpacing: 1.5,
          ),
        ),
        onPressed: () {
          _logAction("EMERGENCY SHUTDOWN INITIATED.");
          mesh.stopAll();
        },
      ),
    );
  }
}
