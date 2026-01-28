/// 🔥 LINK CAPABILITIES - Концептуальная абстракция для каналов связи
/// 
/// Цель: Ослабить "особость" Wi-Fi Direct, рассматривая его как один из типов линков.
/// 
/// ❗ КРИТИЧНО: Это концептуальное выравнивание, НЕ переписывание кода.
/// Порядок доставки НЕ изменен: Wi-Fi Direct → BLE GATT → TCP → Sonar
/// 
/// 🔒 АРХИТЕКТУРНОЕ ПРАВИЛО:
/// Wi-Fi Direct = link (bandwidth, latency) + topology (Group Owner, клиенты)
/// Другие каналы = только link (bandwidth, latency)
/// 
/// TODO: В будущем можно использовать для унификации выбора канала,
/// но сейчас это только концептуальная абстракция.

/// Характеристики канала связи
class LinkCapabilities {
  /// Пропускная способность (примерная, в байтах/сек)
  final int bandwidth;
  
  /// Задержка (средняя, в миллисекундах)
  final int latency;
  
  /// Требует ли канал топологию (например, Wi-Fi Direct требует Group Owner)
  final bool requiresTopology;
  
  /// Тип канала
  final LinkType type;
  
  LinkCapabilities({
    required this.bandwidth,
    required this.latency,
    required this.requiresTopology,
    required this.type,
  });
  
  /// Получить capabilities для Wi-Fi Direct
  static LinkCapabilities wifiDirect({
    bool isGroupOwner = false,
  }) {
    return LinkCapabilities(
      bandwidth: 10000000, // ~10 MB/s (высокая пропускная способность)
      latency: 50, // ~50ms (низкая задержка)
      requiresTopology: true, // Wi-Fi Direct требует топологию (GO/клиент)
      type: LinkType.wifiDirect,
    );
  }
  
  /// Получить capabilities для BLE GATT
  static LinkCapabilities bleGatt() {
    return LinkCapabilities(
      bandwidth: 20000, // ~20 KB/s (низкая пропускная способность)
      latency: 200, // ~200ms (средняя задержка)
      requiresTopology: false, // BLE GATT не требует топологию
      type: LinkType.bleGatt,
    );
  }
  
  /// Получить capabilities для TCP
  static LinkCapabilities tcp() {
    return LinkCapabilities(
      bandwidth: 1000000, // ~1 MB/s (средняя пропускная способность)
      latency: 100, // ~100ms (средняя задержка)
      requiresTopology: false, // TCP не требует топологию
      type: LinkType.tcp,
    );
  }
  
  /// Получить capabilities для Sonar
  static LinkCapabilities sonar() {
    return LinkCapabilities(
      bandwidth: 100, // ~100 B/s (очень низкая пропускная способность)
      latency: 500, // ~500ms (высокая задержка)
      requiresTopology: false, // Sonar не требует топологию
      type: LinkType.sonar,
    );
  }
  
  /// Сравнить два канала по приоритету доставки
  /// 🔒 КОНТРАКТ: Порядок приоритетов НЕ изменен
  /// Wi-Fi Direct > BLE GATT > TCP > Sonar
  int comparePriority(LinkCapabilities other) {
    // Приоритеты соответствуют существующему порядку доставки
    final priority = {
      LinkType.wifiDirect: 4,
      LinkType.bleGatt: 3,
      LinkType.tcp: 2,
      LinkType.sonar: 1,
    };
    
    final thisPriority = priority[type] ?? 0;
    final otherPriority = priority[other.type] ?? 0;
    
    return thisPriority.compareTo(otherPriority);
  }
  
  @override
  String toString() {
    return 'LinkCapabilities(type: $type, bandwidth: $bandwidth B/s, latency: ${latency}ms, requiresTopology: $requiresTopology)';
  }
}

/// Тип канала связи
enum LinkType {
  wifiDirect,
  bleGatt,
  tcp,
  sonar,
}
