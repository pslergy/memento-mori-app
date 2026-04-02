import 'dart:convert';
import 'package:battery_plus/battery_plus.dart';
import 'package:crypto/crypto.dart';
import 'discovery_context_service.dart';
import 'locator.dart';
import 'mesh/utils/mesh_utils.dart';
import 'network_monitor.dart' show NetworkMonitor, MeshRole;
import 'api_service.dart';
import 'network_phase_context.dart';

/// GO Election Service — BLE control plane for Wi-Fi Direct Group Owner election.
///
/// Uses willingness (battery, connectivity, internet) and deterministic hash(nodeId)
/// to avoid split-brain and race conditions when multiple nodes could create a group.
///
/// Integration: Call [shouldBecomeGo] before createGroup; call [computeMyWillingness]
/// for BLE advertising (when added).
class GoElectionService {
  static final GoElectionService _instance = GoElectionService._internal();
  factory GoElectionService() => _instance;
  GoElectionService._internal();

  final Battery _battery = Battery();

  /// Computes willingness to be GO (0–100).
  /// Higher = better candidate: battery, connectivity, internet.
  Future<int> computeMyWillingness() async {
    int score = 50; // base

    try {
      final level = await _battery.batteryLevel;
      if (level >= 80) {
        score += 25;
      } else if (level >= 50) {
        score += 15;
      } else if (level >= 20) {
        score += 5;
      } else {
        score -= 10;
      }
    } catch (_) {}

    final role = NetworkMonitor().currentRole;
    if (role == MeshRole.BRIDGE) {
      score += 30; // BRIDGE prefers GO
    } else if (role == MeshRole.CLIENT) {
      score += 10;
    }

    if (NetworkMonitor().hasValidBridgeLease) score += 15;

    return score.clamp(0, 100);
  }

  /// Deterministic tie-break: hash(nodeId) mod 100.
  int computePriority(String nodeId) {
    final bytes = utf8.encode(nodeId);
    final digest = sha256.convert(bytes);
    return digest.bytes.fold(0, (a, b) => (a + b) & 0x7FFFFFFF) % 100;
  }

  /// True if this node should create group (become GO).
  /// [peerWillingnesses] = map of peerId -> (willingness, priority) from BLE scan.
  /// If no peers or we win, return true.
  Future<bool> shouldBecomeGo(
    Map<String, ({int willingness, int priority})> peerWillingnesses,
  ) async {
    final myW = await computeMyWillingness();
    final nodeId = _getNodeId();
    final myP = computePriority(nodeId);

    if (peerWillingnesses.isEmpty) return true;

    for (final p in peerWillingnesses.values) {
      if (p.willingness > myW) return false;
      if (p.willingness == myW && p.priority > myP) return false;
    }
    return true;
  }

  String _getNodeId() {
    try {
      if (locator.isRegistered<ApiService>()) {
        final id = locator<ApiService>().currentUserId;
        if (id.isNotEmpty) return id;
      }
    } catch (_) {}
    return 'GHOST_NODE';
  }

  /// Check phase allows group create (avoids race with BLE transfer).
  bool get allowsGroupCreate =>
      locator.isRegistered<NetworkPhaseContext>()
          ? locator<NetworkPhaseContext>().allowsWifiDirectGroupCreate
          : true;

  // ---------------------------------------------------------------------------
  // Wi‑Fi Direct GO для двух GHOST (симметрично по meshStableDeviceUuidHex)
  // ---------------------------------------------------------------------------

  /// Стабильный mesh UUID этого узла (как в BLE adv и WIFI_CREDENTIAL.sourceId).
  String myMeshDeviceUuidHex() => meshStableDeviceUuidHex(_getNodeId());

  /// Множество {я + все видимые GHOST с deviceUuid} для симметричного выбора GO.
  Set<String> _visibleGhostMeshUuids() {
    final uuids = <String>{myMeshDeviceUuidHex()};
    if (!locator.isRegistered<DiscoveryContextService>()) return uuids;
    for (final g in locator<DiscoveryContextService>().validGhosts) {
      final u = g.deviceUuid;
      if (u != null && u.isNotEmpty) uuids.add(u);
    }
    return uuids;
  }

  /// Один выбранный GO среди видимых ghost-узлов: `max(uuid)` лексикографически (одинаково на всех).
  /// null — если в контексте только мы (нет других ghost uuid).
  String? designatedGoUuidAmongVisibleGhosts() {
    final uuids = _visibleGhostMeshUuids();
    if (uuids.length <= 1) return null;
    String maxU = uuids.first;
    for (final u in uuids) {
      if (u.compareTo(maxU) > 0) maxU = u;
    }
    return maxU;
  }

  /// true = этот узел **должен поднять** Wi‑Fi Direct группу (GO), false = клиент / join.
  ///
  /// BRIDGE не вызывает этот путь для relay. Нет других ghost в эфире → создаём группу (как раньше).
  bool shouldCreateWifiDirectGroupAsGhostRelay() {
    final go = designatedGoUuidAmongVisibleGhosts();
    if (go == null) return true;
    return myMeshDeviceUuidHex() == go;
  }
}
