import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_service.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'models/signal_node.dart';
import 'router/router_connection_service.dart';
import 'security_config.dart'; // 🔒 Certificate Pinning
import 'network_phase_context.dart';
import 'role/network_role.dart' show InternetStatus;
import 'role/role_negotiator.dart';

enum MeshRole { GHOST, CLIENT, BRIDGE, IOS_EDGE_BEACON }

/// Internet presence alone → ONLINE_UNCONFIRMED. Only backend (POST /mesh/hello) sets role and ONLINE_CONFIRMED.
/// A node becomes BRIDGE only when backend assigns a lease.
class NetworkMonitor {
  static final NetworkMonitor _instance = NetworkMonitor._internal();
  factory NetworkMonitor() => _instance;
  NetworkMonitor._internal();

  String get _pingUrl => SecurityConfig.backendPingUrl;
  late final http.Client _httpClient = _createClient();

  MeshRole currentRole = MeshRole.GHOST;
  InternetStatus _internetStatus = InternetStatus.OFFLINE;
  InternetStatus get internetStatus => _internetStatus;

  Timer? _timer;
  RoleNegotiator? _roleNegotiator;

  final StreamController<MeshRole> _roleController =
      StreamController.broadcast();
  Stream<MeshRole> get onRoleChanged => _roleController.stream;

  int _consecutivePingFailures = 0;
  static const int _roleSwitchFailuresRequired = 2;

  /// True only when backend assigned BRIDGE with valid lease. Used for routing and syncOutbox.
  bool get hasValidBridgeLease => _roleNegotiator?.hasValidLease ?? false;

  http.Client _createClient() {
    // 🔒 SECURITY FIX: Use centralized certificate validation
    final ioc = createSecureHttpClient();
    ioc.connectionTimeout = const Duration(seconds: 5);
    return IOClient(ioc);
  }

  void start() {
    // iOS: fixed role. No backend negotiation, no role changes. Passive observer only.
    if (Platform.isIOS) {
      currentRole = MeshRole.IOS_EDGE_BEACON;
      _roleController.add(currentRole);
      return;
    }
    _roleNegotiator ??= RoleNegotiator(onLeaseLost: forceRoleToClient);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
    _check();
  }

  // Публичный метод для ручной проверки
  Future<void> checkNow() async {
    await _check();
  }

  Future<void> _check() async {
    if (currentRole == MeshRole.IOS_EDGE_BEACON) return;
    final routerService = RouterConnectionService();
    final connectedRouter = routerService.connectedRouter;
    final hasConnectivity =
        connectedRouter != null && connectedRouter.hasInternet;
    final ts = DateTime.now().toIso8601String();
    print("[ROUTER-DIAG] network state role=$currentRole hasConnectivity=$hasConnectivity connectedRouterSSID=${connectedRouter?.ssid} localIp=${connectedRouter?.ipAddress} ts=$ts");

    if (hasConnectivity) {
      _consecutivePingFailures = 0;
      await _onInternetAvailable();
      return;
    }

    try {
      final response = await _httpClient
          .get(Uri.parse(_pingUrl))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        _consecutivePingFailures = 0;
        SecurityConfig.resetToPrimaryChannel();
        await _onInternetAvailable();
        return;
      }
    } catch (_) {
      SecurityConfig.recordBackendFailure();
    }
    _consecutivePingFailures++;
    if (_consecutivePingFailures >= _roleSwitchFailuresRequired) {
      _goGhost();
    }
  }

  /// Internet present (router or ping). Set ONLINE_UNCONFIRMED and negotiate role with backend.
  Future<void> _onInternetAvailable() async {
    if (currentRole == MeshRole.IOS_EDGE_BEACON) return;
    _internetStatus = InternetStatus.ONLINE_UNCONFIRMED;
    final negotiator = _roleNegotiator;
    if (negotiator == null) {
      currentRole = MeshRole.CLIENT;
      _internetStatus = InternetStatus.ONLINE_CONFIRMED;
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().syncFromRole(MeshRole.CLIENT);
      }
      _roleController.add(currentRole);
      return;
    }
    try {
      final hello = await negotiator.hello();
      final prev = currentRole;
      currentRole = _roleFromString(hello.role);
      _internetStatus = InternetStatus.ONLINE_CONFIRMED;
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().syncFromRole(currentRole);
      }
      _roleController.add(currentRole);
      if (prev != currentRole) {
        print('[ROLE] $prev → $currentRole (backend assigned)');
        if (prev == MeshRole.GHOST && currentRole == MeshRole.BRIDGE)
          print(
              '🌉 [GHOST→BRIDGE] Internet available, role BRIDGE. Scanning local ghosts and syncing offline messages to server.');
      }
      if (hello.leaseId != null)
        print(
            '[ROLE] Lease assigned: leaseId=${hello.leaseId} expiresAt=${hello.expiresAt}');
      if (currentRole == MeshRole.BRIDGE &&
          negotiator.hasValidLease &&
          locator.isRegistered<ApiService>()) {
        print('📤 [BRIDGE] Sending offline messages to server (syncOutbox).');
        unawaited(locator<ApiService>().syncOutbox());
      }
      final mesh = locator<MeshService>();
      if (mesh.isP2pConnected) {
        print(
            "🔗 [PERSISTENCE-CHECK] P2P Link maintained during Cloud uplink.");
      }
    } catch (e) {
      print('[ROLE] hello failed: $e — staying CLIENT');
      currentRole = MeshRole.CLIENT;
      _internetStatus = InternetStatus.ONLINE_CONFIRMED;
      if (locator.isRegistered<NetworkPhaseContext>()) {
        locator<NetworkPhaseContext>().syncFromRole(MeshRole.CLIENT);
      }
      _roleController.add(currentRole);
    }
  }

  static MeshRole _roleFromString(String s) {
    if (s == 'BRIDGE') return MeshRole.BRIDGE;
    if (s == 'GHOST') return MeshRole.GHOST;
    return MeshRole.CLIENT;
  }

  void _goGhost() {
    if (currentRole == MeshRole.IOS_EDGE_BEACON) return;
    if (currentRole == MeshRole.GHOST) return;
    final prev = currentRole;
    currentRole = MeshRole.GHOST;
    _internetStatus = InternetStatus.OFFLINE;
    print('[ROLE] $prev → GHOST');
    if (locator.isRegistered<NetworkPhaseContext>()) {
      locator<NetworkPhaseContext>().syncFromRole(MeshRole.GHOST);
    }
    _roleController.add(currentRole);
    _consecutivePingFailures = 0;

    final mesh = locator<MeshService>();
    mesh.startDiscovery(SignalType.mesh);
  }

  /// Called by RoleNegotiator when lease is lost or heartbeat fails. Downgrade BRIDGE → CLIENT.
  void forceRoleToClient() {
    if (currentRole == MeshRole.IOS_EDGE_BEACON) return;
    if (currentRole != MeshRole.BRIDGE) return;
    currentRole = MeshRole.CLIENT;
    print('[ROLE] BRIDGE → CLIENT (lease lost)');
    if (locator.isRegistered<NetworkPhaseContext>()) {
      locator<NetworkPhaseContext>().syncFromRole(MeshRole.CLIENT);
    }
    _roleController.add(currentRole);
  }

  void stop() {
    _timer?.cancel();
    _httpClient.close();
  }
}
