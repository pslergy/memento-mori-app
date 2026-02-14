// lib/core/role/message_router.dart
// Single place to resolve exactly ONE DeliveryPath per message.
// Ghost nodes MUST NOT send directly to backend.

import '../network_monitor.dart';
import 'delivery_path.dart';

/// Context for routing a single message (targetId, etc.).
class MessageRoutingContext {
  final String targetId;
  final String? messageId;
  final bool isEmergency;
  /// Когда true (MESSENGER MODE = OFFLINE), BRIDGE не шлёт в Cloud — только mesh.
  final bool preferOfflineMode;

  MessageRoutingContext({
    required this.targetId,
    this.messageId,
    this.isEmergency = false,
    this.preferOfflineMode = false,
  });
}

/// Resolves exactly one DeliveryPath per message. No duplicate delivery across backend and mesh.
class MessageRouter {
  /// Resolve delivery path for this message. Called once per message before any transport.
  static DeliveryPath resolvePath(MessageRoutingContext ctx) {
    final role = NetworkMonitor().currentRole;
    final hasValidBridgeLease = NetworkMonitor().hasValidBridgeLease;

    if (role == MeshRole.GHOST) {
      return DeliveryPath.meshDtn;
    }
    if (role == MeshRole.CLIENT) {
      return DeliveryPath.meshDtn;
    }
    if (role == MeshRole.BRIDGE && hasValidBridgeLease) {
      if (ctx.preferOfflineMode) return DeliveryPath.meshDtn;
      return DeliveryPath.backendDirect;
    }
    return DeliveryPath.meshDtn;
  }

  /// Whether backend (Cloud/Router) transport is allowed for this path.
  static bool allowsBackend(DeliveryPath path) => path == DeliveryPath.backendDirect;

  /// Whether mesh DTN (BLE, Wi-Fi Direct, Sonar) transport is allowed for this path.
  static bool allowsMeshDtn(DeliveryPath path) => path == DeliveryPath.meshDtn;
}
