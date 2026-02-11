// lib/core/ble_hardware_strategy.dart
//
// Adaptive, hardware-aware BLE connection strategy so message delivery works
// across heterogeneous Android devices (Huawei, Honor, Xiaomi, Tecno, etc.).
// ADDITIVE ONLY: does not replace or weaken existing Huawei guards in
// bluetooth_service / mesh_service (batch order, quiet timings, stopAdvertising
// before Central, single cascade, no Central+Peripheral in parallel).

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'hardware_check_service.dart';

/// Stable vendor label for logging and strategy. Used to decide who may
/// initiate GATT (Central) vs who should wait (Peripheral).
/// Huawei/Honor are policy-locked: no adaptive logic, PERIPHERAL only.
enum BleVendor {
  huawei,
  honor,
  xiaomi,
  mtk, // Tecno, Infinix, other MTK-based
  samsung,
  other,
  unknown, // Peer not identified (e.g. no vendor in advertisement yet)
}

/// Hardware capability profile for BLE link decisions.
/// - preferPeripheral: true on Huawei/Honor — BLE GATT as Central often
///   times out (20s); these devices MUST NOT initiate, only wait for peer.
/// - allowGattInitiate: true when device can safely call connectGatt.
/// - preferCentral: true when device can be Central (same as allowGattInitiate
///   for current policy; kept for future tuning).
class HardwareCapabilityProfile {
  const HardwareCapabilityProfile({
    required this.vendor,
    required this.preferCentral,
    required this.preferPeripheral,
    required this.allowGattInitiate,
  });

  final BleVendor vendor;
  final bool preferCentral;
  final bool preferPeripheral;
  final bool allowGattInitiate;

  /// Profile for this device. Учитывает «документацию» + кэш самоадаптации (HardwareCheckService).
  /// Tecno→Huawei не трогаем: для известных вендоров результат как раньше.
  static Future<HardwareCapabilityProfile> forLocal() async {
    final hw = HardwareCheckService();
    await hw.canHostServer();
    final brand = (await hw.getDeviceInfo())['brand']?.toString().toLowerCase() ?? '';
    final p = _fromBrand(brand);
    final preferPeripheral = await hw.preferGattPeripheral();
    if (preferPeripheral) {
      return HardwareCapabilityProfile(
        vendor: p.vendor,
        preferCentral: false,
        preferPeripheral: true,
        allowGattInitiate: false,
      );
    }
    return p;
  }

  /// Profile for peer when vendor is unknown (e.g. not yet in advertisement).
  /// Strategy will treat unknown as "peer may initiate" so we don't force
  /// initiation from restrictive local side.
  static const HardwareCapabilityProfile unknownPeer = HardwareCapabilityProfile(
    vendor: BleVendor.unknown,
    preferCentral: true,
    preferPeripheral: false,
    allowGattInitiate: true,
  );

  static HardwareCapabilityProfile _fromBrand(String brand) {
    if (brand.contains('huawei')) {
      return const HardwareCapabilityProfile(
        vendor: BleVendor.huawei,
        preferCentral: false,
        preferPeripheral: true,
        allowGattInitiate: false,
      );
    }
    if (brand.contains('honor')) {
      return const HardwareCapabilityProfile(
        vendor: BleVendor.honor,
        preferCentral: false,
        preferPeripheral: true,
        allowGattInitiate: false,
      );
    }
    if (brand.contains('xiaomi') || brand.contains('redmi') || brand.contains('poco')) {
      return const HardwareCapabilityProfile(
        vendor: BleVendor.xiaomi,
        preferCentral: true,
        preferPeripheral: false,
        allowGattInitiate: true,
      );
    }
    if (brand.contains('tecno') || brand.contains('infinix')) {
      return const HardwareCapabilityProfile(
        vendor: BleVendor.mtk,
        preferCentral: true,
        preferPeripheral: false,
        allowGattInitiate: true,
      );
    }
    // Soft hint: Samsung prefers Central; tolerates Peripheral if peer is reliable.
    if (brand.contains('samsung')) {
      return const HardwareCapabilityProfile(
        vendor: BleVendor.samsung,
        preferCentral: true,
        preferPeripheral: false,
        allowGattInitiate: true,
      );
    }
    return const HardwareCapabilityProfile(
      vendor: BleVendor.other,
      preferCentral: true,
      preferPeripheral: false,
      allowGattInitiate: true,
    );
  }

  /// Build peer profile from ScanResult. Today we do not encode vendor in
  /// BLE advertisement, so this returns [unknownPeer]. When vendor byte is
  /// added to manufacturerData (GH/BR), parse it here to enable
  /// Huawei↔Huawei passive-only and finer logging.
  static HardwareCapabilityProfile fromScanResult(ScanResult result) {
    final mf = result.advertisementData.manufacturerData[0xFFFF];
    if (mf != null && mf.length >= 3) {
      // Optional: byte 2 after GH/BR could be vendor code (reserved for future).
      // For now we do not interpret it — keep unknown to avoid breaking.
    }
    return unknownPeer;
  }

  String get vendorLabel {
    switch (vendor) {
      case BleVendor.huawei:
        return 'HUAWEI';
      case BleVendor.honor:
        return 'HONOR';
      case BleVendor.xiaomi:
        return 'XIAOMI';
      case BleVendor.mtk:
        return 'MTK';
      case BleVendor.samsung:
        return 'SAMSUNG';
      case BleVendor.other:
        return 'OTHER';
      case BleVendor.unknown:
        return 'UNKNOWN';
    }
  }
}

/// Soft hints (do not override Huawei policy): Xiaomi/Redmi/Poco prefer BLE over Wi‑Fi;
/// GATT initiation allowed unless repeated failures (handled by adaptation; failures decay).

/// Result of BLE link strategy: who initiates GATT and whether we only wait.
class BleLinkStrategy {
  const BleLinkStrategy({
    required this.localInitiatesGatt,
    required this.peerInitiatesGatt,
    required this.passiveWaitOnly,
    this.isHuaweiBreakGlass = false,
  });

  final bool localInitiatesGatt;
  final bool peerInitiatesGatt;
  final bool passiveWaitOnly;
  /// ADAPTIVE: true when Huawei is allowed one Central attempt (single attempt, ≤12s watchdog, then restore Peripheral-only).
  final bool isHuaweiBreakGlass;
}

/// Context for adaptive resolution. Used ONLY when BLE-only, no relay, no Wi‑Fi Direct, peerCount ≤ 1.
class BleAdaptiveContext {
  const BleAdaptiveContext({
    required this.hasRelayNearby,
    required this.hasWifiDirect,
    required this.bleOnly,
    required this.peerCount,
    required this.localPeerId,
    required this.remotePeerId,
    this.outboxNonEmpty = false,
  });

  final bool hasRelayNearby;
  final bool hasWifiDirect;
  final bool bleOnly;
  final int peerCount;
  final String localPeerId;
  final String remotePeerId;
  final bool outboxNonEmpty;

  /// Adaptive mode allowed only when no relay, no Wi‑Fi, BLE-only, at most one peer.
  bool get useAdaptiveMode =>
      !hasRelayNearby && !hasWifiDirect && bleOnly && peerCount <= 1;
}

/// Deterministic initiator: exactly one side gets true. Pure, no side effects.
/// Tie-breaker: lexicographic order of peerIds so both devices compute the same.
bool decideGattInitiator(String localPeerId, String remotePeerId) {
  return localPeerId.compareTo(remotePeerId) < 0;
}

/// Pair-specific GATT write strategy. Applied only when using adaptive/degraded path.
class BleWriteStrategy {
  const BleWriteStrategy({
    required this.useWriteWithResponse,
    required this.useNotify,
    this.delayNotify = false,
  });
  final bool useWriteWithResponse;
  final bool useNotify;
  final bool delayNotify;
}

/// Resolves BLE link strategy from local and peer hardware profiles.
/// Huawei/Honor: policy-locked; default path unchanged. Tecno→Huawei preserved.
class BleLinkStrategyResolver {
  /// Default resolution. Never overrides preferGattPeripheral for known paths.
  static BleLinkStrategy resolve(
    HardwareCapabilityProfile local,
    HardwareCapabilityProfile peer,
  ) {
    if (local.preferPeripheral && !local.allowGattInitiate) {
      final passiveOnly = peer.preferPeripheral && !peer.allowGattInitiate;
      return BleLinkStrategy(
        localInitiatesGatt: false,
        peerInitiatesGatt: true,
        passiveWaitOnly: passiveOnly,
      );
    }
    if (peer.preferPeripheral && !peer.allowGattInitiate) {
      return const BleLinkStrategy(
        localInitiatesGatt: true,
        peerInitiatesGatt: false,
        passiveWaitOnly: false,
      );
    }
    return const BleLinkStrategy(
      localInitiatesGatt: true,
      peerInitiatesGatt: true,
      passiveWaitOnly: false,
    );
  }

  /// ADAPTIVE / DEGRADED: Evaluated ONLY when context.useAdaptiveMode (no relay, no Wi‑Fi, BLE-only, peerCount ≤ 1).
  /// Prevents deadlock for Huawei↔Huawei, Huawei↔Samsung, Samsung↔Samsung. Tecno→Huawei path identical to resolve().
  static BleLinkStrategy resolveAdaptive(
    HardwareCapabilityProfile local,
    HardwareCapabilityProfile peer,
    BleAdaptiveContext context,
    void Function(String message) log,
  ) {
    if (!context.useAdaptiveMode) {
      return resolve(local, peer);
    }
    log('[BLE][ADAPTIVE][DEGRADED] reason=NO_RELAY');
    final localIsHuawei = local.vendor == BleVendor.huawei || local.vendor == BleVendor.honor;
    final peerIsHuawei = peer.vendor == BleVendor.huawei || peer.vendor == BleVendor.honor;
    final peerIsInitiatorFriendly =
        peer.vendor == BleVendor.samsung ||
        peer.vendor == BleVendor.xiaomi ||
        peer.vendor == BleVendor.mtk;

    // Tecno→Huawei / Xiaomi→Huawei: unchanged — local initiates.
    if (!localIsHuawei && peerIsHuawei) {
      return resolve(local, peer);
    }

    // Huawei→Tecno/Samsung/Xiaomi: normally peer initiates; break-glass allows one attempt.
    if (localIsHuawei && peerIsInitiatorFriendly) {
      final deterministicLocal = decideGattInitiator(context.localPeerId, context.remotePeerId);
      final allowBreakGlass =
          deterministicLocal && canHuaweiBreakGlassAttempt(context.outboxNonEmpty);
      return BleLinkStrategy(
        localInitiatesGatt: allowBreakGlass,
        peerInitiatesGatt: !allowBreakGlass,
        passiveWaitOnly: false,
        isHuaweiBreakGlass: allowBreakGlass,
      );
    }

    // Huawei↔Huawei or Samsung↔Samsung or Huawei↔Samsung (Samsung side): deterministic tie-break.
    final shouldLocal = decideGattInitiator(context.localPeerId, context.remotePeerId);
    if (localIsHuawei && peerIsHuawei) {
      return BleLinkStrategy(
        localInitiatesGatt: shouldLocal,
        peerInitiatesGatt: !shouldLocal,
        passiveWaitOnly: false,
      );
    }
    return BleLinkStrategy(
      localInitiatesGatt: shouldLocal,
      peerInitiatesGatt: !shouldLocal,
      passiveWaitOnly: false,
    );
  }

  /// Break-glass: Huawei may initiate once if outbox non-empty and cooldowns met. Single attempt, then long cooldown.
  static DateTime? _lastHuaweiBreakGlassAttempt;
  static DateTime? _lastHuaweiBreakGlassFailure;
  static const Duration _breakGlassCooldownAfterAttempt = Duration(seconds: 60);
  static const Duration _breakGlassCooldownAfterFailure = Duration(minutes: 3);

  static bool canHuaweiBreakGlassAttempt(bool outboxNonEmpty) {
    if (!outboxNonEmpty) return false;
    final now = DateTime.now();
    if (_lastHuaweiBreakGlassFailure != null &&
        now.difference(_lastHuaweiBreakGlassFailure!).inSeconds <
            _breakGlassCooldownAfterFailure.inSeconds) {
      return false;
    }
    if (_lastHuaweiBreakGlassAttempt != null &&
        now.difference(_lastHuaweiBreakGlassAttempt!).inSeconds <
            _breakGlassCooldownAfterAttempt.inSeconds) {
      return false;
    }
    return true;
  }

  static void recordHuaweiBreakGlassAttempt() {
    _lastHuaweiBreakGlassAttempt = DateTime.now();
  }

  static void recordHuaweiBreakGlassFailure() {
    _lastHuaweiBreakGlassFailure = DateTime.now();
  }
}

/// Pair-specific write strategy. If first write fails, caller should switch once then abort (no retry same strategy).
BleWriteStrategy getWriteStrategyForPair(
  HardwareCapabilityProfile local,
  HardwareCapabilityProfile peer,
) {
  final lH = local.vendor == BleVendor.huawei || local.vendor == BleVendor.honor;
  final pH = peer.vendor == BleVendor.huawei || peer.vendor == BleVendor.honor;
  final lS = local.vendor == BleVendor.samsung;
  final pS = peer.vendor == BleVendor.samsung;
  if (lH && pS) return const BleWriteStrategy(useWriteWithResponse: false, useNotify: false);
  if (lS && pH) return const BleWriteStrategy(useWriteWithResponse: true, useNotify: true, delayNotify: true);
  if (lH && pH) return const BleWriteStrategy(useWriteWithResponse: false, useNotify: false);
  if (lS && pS) return const BleWriteStrategy(useWriteWithResponse: false, useNotify: true);
  return const BleWriteStrategy(useWriteWithResponse: false, useNotify: true);
}
