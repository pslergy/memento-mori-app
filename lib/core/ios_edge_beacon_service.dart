// lib/core/ios_edge_beacon_service.dart
//
// iOS-only EDGE BEACON: passive observer, scan-only, no RELAY/BRIDGE/cascade.
// All logic is behind Platform.isIOS. Does not touch Android BLE, timings, or mesh guarantees.
// Ephemeral sightings only (TTL 30–120s). Optional best-effort EDGE_PRESENCE signal.
//
// iOS constraints: opportunistic observer only; no relay role; no store-and-forward
// guarantees; no long-lived connections; must never block or delay Android cascades.

import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Single sighting of a mesh peer (BRIDGE / GHOST / RELAY). Ephemeral; not persisted.
class EdgeBeaconSighting {
  EdgeBeaconSighting({
    required this.peerId,
    required this.peerRole,
    required this.rssi,
    required this.timestamp,
  });

  final String peerId;
  final String peerRole; // "BRIDGE" | "GHOST" | "RELAY"
  final int rssi;
  final DateTime timestamp;
}

/// Lightweight EDGE_PRESENCE signal: best-effort, non-blocking, discardable.
class EdgePresenceSignal {
  EdgePresenceSignal({
    required this.peerId,
    required this.role,
    required this.rssi,
    required this.timestamp,
  });

  final String peerId;
  final String role;
  final int rssi;
  final DateTime timestamp;
}

/// iOS-only service: BLE scan for mesh devices (SERVICE_UUID, BR/GH/RL).
/// Never advertises, never initiates long-lived GATT, never participates in cascade.
/// On any BLE failure → silently abort, no retries. No persistence across restarts.
class IosEdgeBeaconService {
  IosEdgeBeaconService._();
  static final IosEdgeBeaconService _instance = IosEdgeBeaconService._();
  factory IosEdgeBeaconService() => _instance;

  static const String _serviceUuid = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
  static const Duration _sightingTtl = Duration(seconds: 60); // within 30–120s
  static const Duration _scanDuration = Duration(seconds: 8);

  final Map<String, EdgeBeaconSighting> _sightings = {};
  final StreamController<EdgePresenceSignal> _presenceController =
      StreamController<EdgePresenceSignal>.broadcast();

  /// Best-effort presence stream. Discardable; non-blocking.
  Stream<EdgePresenceSignal> get onEdgePresence => _presenceController.stream;

  /// Read-only copy of current sightings (ephemeral; TTL applied on read).
  Map<String, EdgeBeaconSighting> get sightings {
    _evictExpired();
    return Map.unmodifiable(_sightings);
  }

  void _evictExpired() {
    final now = DateTime.now();
    _sightings.removeWhere((_, s) => now.difference(s.timestamp) > _sightingTtl);
  }

  /// Returns peer role from manufacturerData (BR/GH/RL) or null if not mesh.
  String? _peerRoleFromMfData(Map<int, List<int>> mf) {
    final raw = mf[0xFFFF];
    if (raw == null || raw.length < 2) return null;
    if (raw[0] == 0x42 && raw[1] == 0x52) return 'BRIDGE';
    if (raw[0] == 0x47 && raw[1] == 0x48) return 'GHOST';
    if (raw[0] == 0x52 && raw[1] == 0x4C) return 'RELAY';
    return null;
  }

  bool _isMeshDevice(ScanResult r) {
    final adv = r.advertisementData;
    final hasUuid = adv.serviceUuids.any((u) =>
        u.toString().toLowerCase().contains(_serviceUuid.substring(0, 8)));
    if (hasUuid) return true;
    final role = _peerRoleFromMfData(adv.manufacturerData);
    return role != null;
  }

  /// Start one scan cycle. Scan only; no advertise, no GATT. On failure → silent return.
  /// Call only when Platform.isIOS.
  Future<void> start() async {
    if (!Platform.isIOS) return;
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 200));
      }
      await FlutterBluePlus.startScan(timeout: _scanDuration);
      await Future.delayed(_scanDuration);
    } catch (_) {
      // Silently abort. No retries. No cascading effects.
      return;
    }
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    try {
      final results = await FlutterBluePlus.lastScanResults;
      final now = DateTime.now();
      for (final r in results) {
        if (!_isMeshDevice(r)) continue;
        final mac = r.device.remoteId.str;
        final role = _peerRoleFromMfData(r.advertisementData.manufacturerData) ??
            (r.advertisementData.serviceUuids.isNotEmpty ? 'GHOST' : 'UNKNOWN');
        final sighting = EdgeBeaconSighting(
          peerId: mac,
          peerRole: role,
          rssi: r.rssi,
          timestamp: now,
        );
        _sightings[mac] = sighting;
        // Best-effort, non-blocking presence signal
        if (!_presenceController.isClosed) {
          _presenceController.add(EdgePresenceSignal(
            peerId: mac,
            role: role,
            rssi: r.rssi,
            timestamp: now,
          ));
        }
      }
      _evictExpired();
    } catch (_) {}
  }

  void dispose() {
    if (!_presenceController.isClosed) _presenceController.close();
  }
}
