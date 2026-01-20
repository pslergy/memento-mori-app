import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';

import 'api_service.dart';
import 'mesh_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'native_mesh_service.dart';
import 'models/signal_node.dart';
import '../features/chat/conversation_screen.dart';
import 'network_monitor.dart';
import 'MeshOrchestrator.dart';

class GossipManager {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  // Используем геттер для защиты от циклических зависимостей
  MeshService get _mesh => locator<MeshService>();

  Timer? _propagationTimer;

  // ============================================================
  // 📥 ВХОДЯЩИЙ ПОТОК (INGRESS)
  // ============================================================

  /// Главная точка входа для любого пакета из Mesh-эфира.
  Future<void> processEnvelope(Map<String, dynamic> packet) async {
    final String type = packet['type'] ?? 'UNKNOWN';
    final String packetId = packet['h'] ?? "pulse_${packet['timestamp']}_${packet['senderId']}";

    // 1. СТРАТЕГИЧЕСКАЯ ДЕДУПЛИКАЦИЯ
    if (type == 'MAGNET_WAVE') {
      // Для поисковой волны проверяем: не видели ли мы этот путь короче?
      await _handleMagnetWave(packet);
      return;
    }

    // Обычная дедупликация для данных (O(1) через SQLite)
    if (await _db.isPacketSeen(packetId)) return;

    // 2. СЕМАНТИЧЕСКИЙ РАЗБОР
    if (type == 'MSG_FRAG') {
      // КЕЙС А: Фрагмент (Meaning Unit)
      await _handleFragment(packet);
    } else if (type == 'OFFLINE_MSG' || type == 'SOS') {
      // КЕЙС Б: Цельное сообщение
      await _incubateAndRelay(packet, packetId);
    }
  }

  // ============================================================
  // 🌊 MAGNET PROTOCOL (ПОИСК ОПТИМАЛЬНОГО ПУТИ)
  // ============================================================

  /// Обработка волны "Интернет-Магнита"
  Future<void> _handleMagnetWave(Map<String, dynamic> wave) async {
    final int peerHops = wave['hops'] ?? 255;
    final String senderId = wave['senderId'] ?? "Unknown";
    final orchestrator = locator<TacticalMeshOrchestrator>();

    // Если этот путь через соседа дает нам меньшее количество прыжков до интернета
    if (peerHops + 1 < orchestrator.myHops) {
      _mesh.addLog("🌊 Magnet Wave: Internet detected via $senderId (${peerHops + 1} hops)");

      // 1. Обновляем градиент в Оркестраторе (теперь мы знаем, куда слать данные)
      orchestrator.processRoutingPulse(RoutingPulse(
        nodeId: senderId,
        hopsToInternet: peerHops,
        batteryLevel: 1.0,
        queuePressure: 0,
      ));

      // 2. Ретранслируем волну дальше (Epidemic Spread)
      // Ограничиваем глубину прострела сети (15 хопов максимум)
      if (peerHops < 15) {
        final nextWave = {
          ...wave,
          'senderId': locator<ApiService>().currentUserId,
          'hops': peerHops + 1,
        };
        // Вирусное распространение градиента
        await _mesh.sendTcpBurst(jsonEncode(nextWave));
      }
    }
  }

  // ============================================================
  // 🧩 MEANING UNITS (СБОРКА ПАЗЛА)
  // ============================================================

  Future<void> _handleFragment(Map<String, dynamic> frag) async {
    final String messageId = frag['mid'];
    final int index = frag['idx'];
    final int total = frag['tot'];

    await _db.saveFragment(
        messageId: messageId,
        index: index,
        total: total,
        data: frag['data']
    );

    final List<Map<String, dynamic>> allFrags = await _db.getFragments(messageId);

    if (allFrags.length == total) {
      _mesh.addLog("🧩 [Sync] Message $messageId assembled!");

      allFrags.sort((a, b) => (a['index_num'] as int).compareTo(b['index_num'] as int));
      String fullContent = allFrags.map((f) => f['data']).join("");

      final fullPacket = {
        ...frag,
        'type': 'OFFLINE_MSG',
        'content': fullContent,
        'h': messageId,
      };

      _mesh.messageController.add(fullPacket);
      await _db.saveMessage(ChatMessage.fromJson(fullPacket), frag['chatId']);
      await _db.clearFragments(messageId);

      // Ретранслируем уже собранное сообщение дальше по градиенту
      await attemptRelay(fullPacket);
    }
  }

  Future<void> _incubateAndRelay(Map<String, dynamic> packet, String id) async {
    await _db.saveMessage(
        ChatMessage.fromJson(packet),
        packet['chatId'] ?? 'THE_BEACON_GLOBAL'
    );
    _mesh.addLog("📥 [Grid] Signal captured: ${id.substring(0,8)}");
    await attemptRelay(packet);
  }

  // ============================================================
  // 🚀 ТАКТИЧЕСКАЯ РЕТРАНСЛЯЦИЯ (PUSH PHASE)
  // ============================================================

  Future<void> attemptRelay(Map<String, dynamic> packet) async {
    if (!_mesh.isP2pConnected) return;

    // 1. Управление жизненным циклом
    int ttl = packet['ttl'] ?? 5;
    if (ttl <= 0) return;
    packet['ttl'] = ttl - 1;

    // 2. Вероятностный фильтр нагрузки (масштабируемость)
    double relayProbability = math.pow(ttl / 5.0, 1.5).toDouble().clamp(0.0, 1.0);
    if (math.Random().nextDouble() > relayProbability) return;

    // 3. Фрагментация перед отправкой
    final List<Map<String, dynamic>> fragments = _fragmentMessage(packet);

    // 4. Выбор цели на основе градиента (ищем аплинк)
    final bestUplink = locator<TacticalMeshOrchestrator>().getBestUplink();
    String targetIp = "192.168.49.1"; // Default WiFi Direct Host

    if (bestUplink != null) {
      _mesh.addLog("🧭 Routing packet towards Magnet: ${bestUplink.nodeId}");
      // Если у нас есть IP соседа в метаданных - шлем туда, иначе на шлюз группы
      targetIp = bestUplink.nodeId.contains(".") ? bestUplink.nodeId : "192.168.49.1";
    }

    await _transmitWithRetry(fragments, targetIp, "Relay-Node");
  }

  List<Map<String, dynamic>> _fragmentMessage(Map<String, dynamic> packet) {
    final String content = packet['content'] ?? "";
    final String messageId = packet['h'] ?? "m_${DateTime.now().millisecondsSinceEpoch}";
    const int chunkSize = 160;

    if (content.length <= chunkSize) return [packet];

    List<Map<String, dynamic>> fragments = [];
    int total = (content.length / chunkSize).ceil();

    for (int i = 0; i < total; i++) {
      int start = i * chunkSize;
      int end = (start + chunkSize < content.length) ? start + chunkSize : content.length;

      fragments.add({
        'type': 'MSG_FRAG',
        'mid': messageId,
        'idx': i,
        'tot': total,
        'data': content.substring(start, end),
        'chatId': packet['chatId'],
        'senderId': packet['senderId'],
        'h': "${messageId}_$i",
        'ttl': packet['ttl'] ?? 5,
        'timestamp': packet['timestamp'],
      });
    }
    return fragments;
  }

  Future<void> _transmitWithRetry(List<Map<String, dynamic>> units, String ip, String name) async {
    for (var unit in units) {
      try {
        await NativeMeshService.sendTcp(jsonEncode(unit), host: ip);
      } catch (e) {
        // Если TCP упал, пакет остается в Outbox и будет подхвачен циклом Epidemic
        _mesh.addLog("⚠️ [Gossip] Hop failed to $ip. Deferred.");
      }
    }
  }

  // ============================================================
  // 🔄 EPIDEMIC CYCLE (PULL/PUSH SYNC)
  // ============================================================

  void startEpidemicCycle() {
    _propagationTimer?.cancel();
    _propagationTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!_mesh.isP2pConnected) return;

      final List<Map<String, dynamic>> pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;

      // Если я сам стал мостом - выгружаю всё в облако
      if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
        await locator<ApiService>().syncOutbox();
        return;
      }

      // Иначе ищем лучший аплинк через Оркестратор
      final bestUplink = locator<TacticalMeshOrchestrator>().getBestUplink();
      if (bestUplink != null) {
        _mesh.addLog("🦠 [Epidemic] Infecting superior node: ${bestUplink.nodeId}");
        for (var msg in pending) {
          await attemptRelay(msg);
        }
      }
    });
  }

  void stop() {
    _propagationTimer?.cancel();
  }

  void _log(String msg) => print("🦠 [GossipManager] $msg");
}