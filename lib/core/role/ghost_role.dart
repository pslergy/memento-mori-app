import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Intent advertised by GHOST nodes so peers can coordinate roles.
enum GhostRoleIntent {
  server,
  client,
  undecided,
}

extension GhostRoleIntentCodec on GhostRoleIntent {
  static GhostRoleIntent fromCode(int value) {
    switch (value) {
      case 0x53:
        return GhostRoleIntent.server;
      case 0x43:
        return GhostRoleIntent.client;
      case 0x55:
      default:
        return GhostRoleIntent.undecided;
    }
  }
}

class GhostRoleMetadata {
  GhostRoleMetadata({
    required this.intent,
    required this.token,
    this.hopsHint,
  });

  factory GhostRoleMetadata.fromScanResult(ScanResult result) {
    final advData = result.advertisementData.manufacturerData[0xFFFF];
    GhostRoleIntent intent = GhostRoleIntent.undecided;
    String? token;
    int? hopHint;

    if (advData != null &&
        advData.length >= 2 &&
        advData[0] == 0x47 &&
        advData[1] == 0x48) {
      if (advData.length >= 3) {
        intent = GhostRoleIntentCodec.fromCode(advData[2]);
      }
      if (advData.length >= 4) {
        hopHint = advData[3];
      }
      if (advData.length > 4) {
        try {
          token = String.fromCharCodes(advData.sublist(4)).trim();
          if (token != null && token!.isEmpty) token = null;
        } catch (_) {
          token = null;
        }
      }
    }

    final resolvedToken = (token != null && token!.isNotEmpty)
        ? token!
        : result.device.remoteId.str;

    return GhostRoleMetadata(
      intent: intent,
      token: resolvedToken.isNotEmpty ? resolvedToken : "peer",
      hopsHint: hopHint,
    );
  }

  final GhostRoleIntent intent;
  final String token;
  final int? hopsHint;
}

class GhostRoleDecision {
  const GhostRoleDecision(this.shouldConnect, this.reason);

  final bool shouldConnect;
  final String reason;
}

/// Determines whether current node should take BLE client role (CENTRAL) against another GHOST.
/// Deterministic tie-breaker: when hops equal, lower MAC becomes PERIPHERAL (host), higher MAC becomes CENTRAL (connect).
class GhostRoleSelector {
  static GhostRoleDecision decide({
    required GhostRoleIntent myIntent,
    required GhostRoleIntent peerIntent,
    required int myHops,
    required int peerHops,
    required int myPending,
    required String myToken,
    required String peerToken,
    String? myMac,
    String? peerMac,
  }) {
    if (myPending <= 0) {
      return const GhostRoleDecision(false, "no pending payloads");
    }

    // If peer declares it will host, we take client role.
    if (peerIntent == GhostRoleIntent.server &&
        myIntent == GhostRoleIntent.client) {
      return const GhostRoleDecision(true, "peer advertising as server");
    }

    // If peer declares client intent, we stay as host to avoid collision.
    if (peerIntent == GhostRoleIntent.client) {
      return const GhostRoleDecision(false, "peer already taking client role");
    }

    // Prefer nodes with worse gradient (larger hops) to connect upward.
    if (myHops > peerHops) {
      return const GhostRoleDecision(true, "peer closer to internet");
    }

    if (myHops < peerHops) {
      return const GhostRoleDecision(false, "better gradient, prefer hosting");
    }

    // Equal hops — honour explicit intent first.
    if (myIntent == GhostRoleIntent.server) {
      return const GhostRoleDecision(false, "explicit server intent");
    }
    if (myIntent == GhostRoleIntent.client) {
      return const GhostRoleDecision(true, "explicit client intent");
    }

    // Deterministic tie-breaker: lower MAC = PERIPHERAL (host), higher MAC = CENTRAL (connect).
    if (myMac != null && peerMac != null && myMac != peerMac) {
      final connect = myMac.compareTo(peerMac) > 0;
      return GhostRoleDecision(
        connect,
        connect
            ? "mac tie-breaker -> connect (we are higher MAC)"
            : "mac tie-breaker -> host (we are lower MAC)",
      );
    }

    // Fallback: token comparison (when MAC not available or equal).
    final normalizedSelf = myToken.isNotEmpty ? myToken : "self";
    final normalizedPeer = peerToken.isNotEmpty ? peerToken : "peer";
    final cmp = normalizedSelf.compareTo(normalizedPeer);
    if (cmp == 0) {
      final connect = normalizedSelf.hashCode.isOdd;
      return GhostRoleDecision(
        connect,
        connect ? "hash parity -> connect" : "hash parity -> host",
      );
    }

    final connect = cmp > 0;
    return GhostRoleDecision(
      connect,
      connect ? "id priority -> connect" : "id priority -> host",
    );
  }
}
