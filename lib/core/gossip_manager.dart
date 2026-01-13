import 'dart:async';
import 'dart:convert';
import 'mesh_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'native_mesh_service.dart';
import 'models/signal_node.dart';
import '../features/chat/conversation_screen.dart';
import 'dart:math' as math;

class GossipManager {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  // Используем геттер для защиты от циклических зависимостей
  MeshService get _mesh => locator<MeshService>();

  Timer? _propagationTimer;

  /// Главная точка входа: решаем судьбу пакета
  Future<void> processEnvelope(Map<String, dynamic> packet) async {
    final String packetId = packet['h'] ?? "pulse_${packet['timestamp']}";

    // 1. Дедупликация (O(1) через SQLite)
    if (await _db.isPacketSeen(packetId)) return;

    // 2. Инкубация (Сохраняем для будущего)
    await _db.saveMessage(
        ChatMessage.fromJson(packet),
        packet['chatId'] ?? 'THE_BEACON_GLOBAL'
    );

    // 3. Немедленная попытка переслать (Push Phase)
    await attemptRelay(packet);
  }


  /// Оптимизирован для предотвращения сетевых штормов в плотных сетях.
  Future<void> attemptRelay(Map<String, dynamic> packet) async {
    final neighbors = _mesh.nearbyNodes;
    if (neighbors.isEmpty) return;

    // 1. АДАПТИВНЫЙ FAN-OUT (The Social Distancing Layer)
    // В большой толпе не шлем всем. Шлем максимум 5-ти случайным узлам.
    int relayCount = neighbors.length > 5 ? 5 : neighbors.length;
    final targets = (neighbors.toList()..shuffle()).take(relayCount);

    // 2. УПРАВЛЕНИЕ TTL
    int ttl = packet['ttl'] ?? 5;
    if (ttl <= 0) {
      _mesh.addLog("🚫 [Gossip] Packet lifetime ended. Dropping.");
      return;
    }
    packet['ttl'] = ttl - 1;

    // 3. ВЕРОЯТНОСТНЫЙ ФИЛЬТР (Для масштабируемости на 1000+ чел)
    // Чем меньше "прыжков" осталось у пакета, тем меньше шанс, что мы его перешлем.
    // Это экспоненциально гасит "эхо" в сети.
    double relayProbability = ttl / 5.0;
    if (math.Random().nextDouble() > relayProbability) {
      _mesh.addLog("📉 [Gossip] Network load balancing: Packet skipped.");
      return;
    }

    for (var node in targets) {
      if (node.type == SignalType.mesh) {
        String targetIp = !_mesh.isHost ? "192.168.49.1" : _mesh.lastKnownPeerIp;

        if (targetIp.isNotEmpty && targetIp != "127.0.0.1") {
          _mesh.addLog("⚡ [Gossip-Push] Relaying to ${node.name} @ $targetIp");
          NativeMeshService.sendTcp(jsonEncode(packet), host: targetIp);
        }
      }
    }
  }

  /// Активная фаза: раз в 30 секунд ищем, кого бы "заразить" данными из Outbox
  void startEpidemicCycle() {
    _propagationTimer?.cancel();
    _propagationTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      final pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;

      final neighbors = _mesh.nearbyNodes;
      if (neighbors.isEmpty) return;

      final targets = (neighbors.toList()..shuffle()).take(3);

      for (var node in targets) {
        for (var msg in pending) {
          // Формируем Gossip-пакет
          final gossipPacket = {
            'h': msg['id'],
            'type': 'OFFLINE_MSG',
            'chatId': msg['chatRoomId'],
            'content': msg['content'],
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'ttl': 4,
          };

          String targetIp = !_mesh.isHost ? "192.168.49.1" : _mesh.lastKnownPeerIp;

          if (targetIp.isNotEmpty && targetIp != "127.0.0.1") {
            _mesh.addLog("🦠 [Gossip-Cycle] Infecting ${node.name} @ $targetIp");
            NativeMeshService.sendTcp(jsonEncode(gossipPacket), host: targetIp);
          }
        }
      }
    });
  }

  void stop() {
    _propagationTimer?.cancel();
  }
}