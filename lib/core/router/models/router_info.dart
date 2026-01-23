/// Модель данных для информации о роутере
class RouterInfo {
  final String id;
  final String ssid;
  final String? password; // Зашифрован, хранится в SecureStorage (null = открытый роутер)
  final String? macAddress;
  final String? ipAddress;
  final int priority; // 0-100, выше = приоритетнее
  final bool isTrusted;
  final DateTime? lastSeen;
  final double? rssi; // Сила сигнала в dBm
  final bool hasInternet;
  final bool isOpen; // Открытый роутер (без пароля)
  final bool useAsRelay; // Использовать как ретранслятор (без подключения)

  RouterInfo({
    required this.id,
    required this.ssid,
    this.password,
    this.macAddress,
    this.ipAddress,
    this.priority = 50,
    this.isTrusted = false,
    this.lastSeen,
    this.rssi,
    this.hasInternet = false,
    this.isOpen = false,
    this.useAsRelay = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'ssid': ssid,
      'macAddress': macAddress,
      'ipAddress': ipAddress,
      'priority': priority,
      'isTrusted': isTrusted ? 1 : 0,
      'lastSeen': lastSeen?.millisecondsSinceEpoch,
      'rssi': rssi,
      'hasInternet': hasInternet ? 1 : 0,
      'isOpen': isOpen ? 1 : 0,
      'useAsRelay': useAsRelay ? 1 : 0,
    };
  }

  factory RouterInfo.fromJson(Map<String, dynamic> json) {
    return RouterInfo(
      id: json['id'] as String,
      ssid: json['ssid'] as String,
      macAddress: json['macAddress'] as String?,
      ipAddress: json['ipAddress'] as String?,
      priority: json['priority'] as int? ?? 50,
      isTrusted: (json['isTrusted'] as int? ?? 0) == 1,
      lastSeen: json['lastSeen'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int)
          : null,
      rssi: json['rssi'] != null ? (json['rssi'] as num).toDouble() : null,
      hasInternet: (json['hasInternet'] as int? ?? 0) == 1,
      isOpen: (json['isOpen'] as int? ?? 0) == 1,
      useAsRelay: (json['useAsRelay'] as int? ?? 0) == 1,
    );
  }
}
