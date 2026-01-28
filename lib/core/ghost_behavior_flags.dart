import 'network_monitor.dart';
import 'mesh_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'MeshOrchestrator.dart';
import 'models/signal_node.dart';
import 'api_service.dart';

/// 🔥 GHOST BEHAVIOR FLAGS - Временные флаги поведения для GHOST
/// 
/// НЕ новые роли enum, а локальные флаги для принятия решений.
/// Вычисляются локально, не передаются по сети как обязательные.
/// 
/// ❗ КРИТИЧНО: Не меняют существующий gossip и fallback.
/// 
/// 🔒 КОНТРАКТ ИСПОЛЬЗОВАНИЯ (НЕ НАРУШАТЬ):
/// - canRelay → влияет ТОЛЬКО на gossip (может ли ретранслировать)
/// - isEdge → узел никогда не ретранслирует (краевой узел)
/// - isUplinkCandidate → влияет ТОЛЬКО на bridge_score (хороший маршрут к BRIDGE)
/// 
/// ⚠️ ЗАПРЕЩЕНО использовать флаги для:
/// - отключения каналов
/// - изменения fallback-логики
/// - изменения порядка доставки (Wi-Fi Direct → BLE GATT → TCP → Sonar)
class GhostBehaviorFlags {
  final String ghostId;
  
  /// Может ли этот GHOST ретранслировать сообщения другим GHOST
  bool canRelay = false;
  
  /// Является ли этот GHOST краевым узлом (нет соседей с лучшим маршрутом)
  bool isEdge = false;
  
  /// Является ли этот GHOST кандидатом для uplink (имеет хороший маршрут к BRIDGE)
  bool isUplinkCandidate = false;
  
  DateTime lastUpdated = DateTime.now();
  
  GhostBehaviorFlags({required this.ghostId});
  
  /// Вычислить флаги для текущего GHOST устройства
  static Future<GhostBehaviorFlags> computeForSelf() async {
    final currentRole = NetworkMonitor().currentRole;
    if (currentRole != MeshRole.GHOST) {
      // Для BRIDGE флаги не применяются
      return GhostBehaviorFlags(ghostId: 'BRIDGE');
    }
    
    final flags = GhostBehaviorFlags(ghostId: locator<ApiService>().currentUserId);
    final mesh = locator<MeshService>();
    final db = locator<LocalDatabaseService>();
    
    // Вычисляем canRelay: есть ли pending сообщения для ретрансляции
    final pending = await db.getPendingFromOutbox();
    flags.canRelay = pending.isNotEmpty;
    
    // Вычисляем isEdge: нет соседей с лучшим маршрутом
    final nearbyNodes = mesh.nearbyNodes;
    final orchestrator = locator<TacticalMeshOrchestrator>();
    final myHops = orchestrator.myHops;
    
    bool hasBetterNeighbor = false;
    for (final node in nearbyNodes) {
      // Проверяем, есть ли сосед с меньшими hops
      // Это упрощенная проверка - в реальности нужно смотреть на routing table
      if (node.type == SignalType.bluetooth || node.type == SignalType.mesh) {
        // Если есть активные соседи - возможно есть лучший маршрут
        hasBetterNeighbor = true;
        break;
      }
    }
    flags.isEdge = !hasBetterNeighbor || myHops >= 254;
    
    // Вычисляем isUplinkCandidate: имеет хороший маршрут к BRIDGE (hops < 5)
    flags.isUplinkCandidate = myHops < 5 && myHops < 255;
    
    flags.lastUpdated = DateTime.now();
    
    return flags;
  }
  
  /// Вычислить флаги для другого GHOST (на основе наблюдений)
  static GhostBehaviorFlags computeForPeer({
    required String peerId,
    required int peerHops,
    required bool hasPendingMessages,
  }) {
    final flags = GhostBehaviorFlags(ghostId: peerId);
    
    // canRelay: если у пира есть pending сообщения
    flags.canRelay = hasPendingMessages;
    
    // isEdge: если hops очень высокие (>= 254)
    flags.isEdge = peerHops >= 254;
    
    // isUplinkCandidate: если hops низкие (< 5)
    flags.isUplinkCandidate = peerHops < 5;
    
    flags.lastUpdated = DateTime.now();
    
    return flags;
  }
  
  /// Следует ли ретранслировать сообщение этому GHOST
  /// 🔒 КОНТРАКТ: Используется ТОЛЬКО в gossip, не влияет на доставку
  bool shouldRelayTo() {
    // 🔒 КОНТРАКТ: canRelay влияет ТОЛЬКО на gossip
    if (!canRelay) {
      return false; // Не ретранслируем если флаг canRelay = false
    }
    
    // Ретранслируем если:
    // 1. Это uplink candidate (хороший маршрут к BRIDGE)
    // 2. Или это edge node (может быть единственный путь)
    return isUplinkCandidate || isEdge;
  }
  
  /// Следует ли принимать сообщения от этого GHOST
  /// 🔒 КОНТРАКТ: Всегда true, флаги не блокируют прием
  bool shouldAcceptFrom() {
    // 🔒 КОНТРАКТ: Принимаем от всех GHOST (существующая логика)
    // Флаги используются только для оптимизации gossip, не для блокировки доставки
    return true;
  }
  
  /// Влияет ли этот GHOST на bridge_score
  /// 🔒 КОНТРАКТ: isUplinkCandidate влияет ТОЛЬКО на bridge_score
  bool affectsBridgeScore() {
    // 🔒 КОНТРАКТ: isUplinkCandidate влияет ТОЛЬКО на bridge_score
    // Не влияет на выбор канала или порядок доставки
    return isUplinkCandidate;
  }
  
  @override
  String toString() {
    return 'GhostBehaviorFlags(id: $ghostId, canRelay: $canRelay, isEdge: $isEdge, isUplinkCandidate: $isUplinkCandidate)';
  }
}
