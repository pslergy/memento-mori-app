enum SignalType { cloud, mesh, bluetooth, wifiDirect }

class SignalNode {
  final String id;
  final String name;
  final SignalType type;
  final bool isGroup;

  // 🔥 ФИКС: metadata теперь строго String.
  // Это гарантирует, что NativeMeshService.sendTcp(host: node.metadata) не упадет.
  final String metadata;

  int bridgeDistance;

  /// OS Bluetooth device name ([BluetoothDevice.platformName]) — имя телефона в настройках BT.
  /// Маячок в эфире может быть `M_hops_…`; для списка «рядом» показываем это имя как основной ярлык.
  final String? blePlatformName;

  SignalNode({
    required this.id,
    required this.name,
    required this.type,
    this.isGroup = false,
    // 🔥 ФИКС: Делаем поле обязательным в конструкторе
    required this.metadata,
    this.bridgeDistance = 99,
    this.blePlatformName,
  });

  /// Метод для быстрой конвертации из JSON (если понадобится)
  factory SignalNode.fromJson(Map<String, dynamic> json) {
    return SignalNode(
      id: json['id'] ?? '',
      name: json['name'] ?? 'Unknown Node',
      type: SignalType.mesh, // По умолчанию для оффлайна
      metadata: json['metadata'] ?? '',
      isGroup: json['isGroup'] ?? false,
      bridgeDistance: json['bridgeDistance'] ?? 99,
      blePlatformName: json['blePlatformName'] as String?,
    );
  }

  /// Метод для отладки
  @override
  String toString() {
    return 'Node($name, Dist: $bridgeDistance, IP: $metadata)';
  }
}