import 'network_monitor.dart';

/// Global network phase — источник истины для порядка запуска подсистем.
/// Таймеры только проверяют фазу; действия выполняются только при разрешённой фазе.
enum NetworkPhase {
  boot,
  localDiscovery,
  localLinkSetup,
  localTransfer,
  uplinkAvailable,
  bridgeActive,
  idle,
}

/// Централизованный контекст фаз. Read-only для подсистем.
/// Переходы логируются [PHASE] from -> to.
class NetworkPhaseContext {
  static final NetworkPhaseContext _instance = NetworkPhaseContext._internal();
  factory NetworkPhaseContext() => _instance;
  NetworkPhaseContext._internal();

  NetworkPhase _phase = NetworkPhase.boot;
  NetworkPhase get phase => _phase;

  void transitionTo(NetworkPhase to) {
    if (_phase == to) return;
    final prev = _phase;
    _phase = to;
    print('[PHASE] $prev -> $to');
  }

  /// BLE scan разрешён: НЕ во время Wi-Fi setup, НЕ во время BLE transfer
  bool get allowsBleScan =>
      _phase != NetworkPhase.localLinkSetup &&
      _phase != NetworkPhase.localTransfer &&
      _phase != NetworkPhase.boot;

  /// Wi-Fi Direct group create разрешён: НЕ во время BLE transfer, НЕ во время другого Wi-Fi setup
  bool get allowsWifiDirectGroupCreate =>
      _phase != NetworkPhase.localTransfer &&
      _phase != NetworkPhase.localLinkSetup &&
      _phase != NetworkPhase.boot;

  /// Wi-Fi Direct discovery/setup: НЕ во время BLE scan/transfer
  bool get allowsWifiDirectSetup =>
      _phase != NetworkPhase.localTransfer &&
      _phase != NetworkPhase.boot;

  /// TCP server только в bridgeActive
  bool get allowsTcpServer => _phase == NetworkPhase.bridgeActive;

  /// Sonar — разрешён везде кроме boot (акустика не конфликтует с радио)
  bool get allowsSonar => _phase != NetworkPhase.boot;

  /// Grosii (excitation) — разрешён везде кроме boot
  bool get allowsGrosii => _phase != NetworkPhase.boot;

  /// BLE GATT transfer разрешён
  bool get allowsBleTransfer =>
      _phase == NetworkPhase.localTransfer ||
      _phase == NetworkPhase.localDiscovery ||
      _phase == NetworkPhase.uplinkAvailable ||
      _phase == NetworkPhase.bridgeActive ||
      _phase == NetworkPhase.idle;

  /// Сообщить о начале BLE transfer (для блокировки Wi-Fi group create)
  void onBleTransferStarted() {
    if (_phase != NetworkPhase.localTransfer) {
      transitionTo(NetworkPhase.localTransfer);
    }
  }

  /// Сообщить о завершении BLE transfer
  void onBleTransferEnded() {
    if (_phase == NetworkPhase.localTransfer) {
      transitionTo(NetworkPhase.idle);
    }
  }

  /// Сообщить о начале Wi-Fi link setup (для блокировки BLE scan)
  void onWifiLinkSetupStarted() {
    if (_phase != NetworkPhase.localLinkSetup) {
      transitionTo(NetworkPhase.localLinkSetup);
    }
  }

  /// Сообщить о завершении Wi-Fi link setup
  void onWifiLinkSetupEnded() {
    if (_phase == NetworkPhase.localLinkSetup) {
      transitionTo(NetworkPhase.idle);
    }
  }

  /// Обновить фазу по роли (BRIDGE → bridgeActive; CLIENT/GHOST → idle when leaving bridge)
  void syncFromRole(MeshRole role) {
    if (role == MeshRole.BRIDGE && _phase != NetworkPhase.bridgeActive) {
      transitionTo(NetworkPhase.bridgeActive);
    } else if ((role == MeshRole.GHOST || role == MeshRole.CLIENT) &&
        (_phase == NetworkPhase.bridgeActive || _phase == NetworkPhase.uplinkAvailable)) {
      transitionTo(NetworkPhase.idle);
    }
  }
}
