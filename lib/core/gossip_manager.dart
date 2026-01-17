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

class GossipManager {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  // Используем геттер для защиты от циклических зависимостей при старте
  MeshService get _mesh => locator<MeshService>();

  Timer? _propagationTimer;

  // ============================================================
  // 📥 ВХОДЯЩИЙ ПОТОК (INGRESS)
  // ============================================================

  /// Главная точка входа для любого пакета из Mesh-эфира.
  Future<void> processEnvelope(Map<String, dynamic> packet) async {
    // 1. Нормализация ID пакета (Content-addressable ID)
    final String packetId = packet['h'] ??
        "pulse_${packet['timestamp']}_${packet['senderId']}";

    // 2. Дедупликация (O(1) через SQLite seen_pulses)
    // Защита от "Broadcast Storm" (широковещательного шторма)
    if (await _db.isPacketSeen(packetId)) return;

    // 3. Распознавание семантики пакета
    final String type = packet['type'] ?? 'UNKNOWN';

    if (type == 'MSG_FRAG') {
      // КЕЙС А: Фрагмент (Meaning Unit). Отправляем в сборщик.
      await _handleFragment(packet);
    } else if (type == 'OFFLINE_MSG' || type == 'SOS') {
      // КЕЙС Б: Цельное сообщение.

      // Инкубация (Сохраняем в локальную базу)
      await _db.saveMessage(
          ChatMessage.fromJson(packet),
          packet['chatId'] ?? 'THE_BEACON_GLOBAL'
      );

      _mesh.addLog("📥 [Grid] Signal captured: ${packetId.substring(0,8)}");

      // Ретрансляция (Push Phase)
      await attemptRelay(packet);
    }
  }

  // ============================================================
  // 🧩 MEANING UNITS (СБОРКА ПАЗЛА)
  // ============================================================

  /// Обработка и накопление фрагментов сообщения
  Future<void> _handleFragment(Map<String, dynamic> frag) async {
    final String messageId = frag['mid'];
    final int index = frag['idx'];
    final int total = frag['tot'];

    // Сохраняем фрагмент в БД
    await _db.saveFragment(
        messageId: messageId,
        index: index,
        total: total,
        data: frag['data']
    );

    // Проверяем, собрали ли мы все части
    final List<Map<String, dynamic>> allFrags = await _db.getFragments(messageId);

    if (allFrags.length == total) {
      _mesh.addLog("🧩 [Reconstruction] Message $messageId fully assembled!");

      // Сортировка по индексу для правильной склейки
      allFrags.sort((a, b) => (a['index_num'] as int).compareTo(b['index_num'] as int));
      String fullContent = allFrags.map((f) => f['data']).join("");

      final fullPacket = {
        ...frag,
        'type': 'OFFLINE_MSG',
        'content': fullContent,
        'h': messageId, // Хеш сообщения — это его оригинальный ID
      };

      // Впрыскиваем в UI стрим и сохраняем как полноценное сообщение
      _mesh.messageController.add(fullPacket);
      await _db.saveMessage(ChatMessage.fromJson(fullPacket), frag['chatId']);

      // Очистка временных данных (Оптимизация кэша)
      await _db.clearFragments(messageId);
    } else {
      _mesh.addLog("📥 [Gossip] MU cached: ${index + 1}/$total");
    }
  }

  /// Нарезка сообщения на фрагменты по 160 байт
  List<Map<String, dynamic>> _fragmentMessage(Map<String, dynamic> packet) {
    final String content = packet['content'] ?? "";
    final String messageId = packet['h'] ?? "m_${DateTime.now().millisecondsSinceEpoch}";
    const int chunkSize = 160; // Оптимально для MTU Bluetooth и кадров Сонара

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
        'senderUsername': packet['senderUsername'] ?? "Nomad",
        'h': "${messageId}_$i",
        'ttl': packet['ttl'] ?? 5,
        'timestamp': packet['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      });
    }
    return fragments;
  }

  // ============================================================
  // 🚀 ТАКТИЧЕСКАЯ РЕТРАНСЛЯЦИЯ (EGRESS)
  // ============================================================

  /// Немедленная попытка пересылки пакета (Push Phase)
  Future<void> attemptRelay(Map<String, dynamic> packet) async {
    // Проверка физической готовности канала (предотвращение ENETUNREACH)
    if (!_mesh.isP2pConnected || !_mesh.isRouteReady) return;

    final neighbors = _mesh.nearbyNodes;
    if (neighbors.isEmpty) return;

    // 1. Адаптивный Fan-out (не шлем всем, выбираем цели)
    final targets = (neighbors.toList()..shuffle()).take(3);

    // 2. Управление жизненным циклом (TTL)
    int ttl = packet['ttl'] ?? 5;
    if (ttl <= 0) {
      _mesh.addLog("🚫 [Gossip] TTL expired for pulse ${packet['h']}");
      return;
    }
    packet['ttl'] = ttl - 1;

    // 3. Вероятностный фильтр (Масштабируемость на 1000+ узлов)
    // Вероятность ретрансляции падает нелинейно по мере "старения" пакета
    double relayProbability = math.pow(ttl / 5.0, 1.5).toDouble().clamp(0.0, 1.0);
    if (math.Random().nextDouble() > relayProbability) {
      _mesh.addLog("📉 [Gossip] Load balancer: Packet deferred.");
      return;
    }

    // 4. Подготовка фрагментов
    final List<Map<String, dynamic>> fragments = _fragmentMessage(packet);

    // 5. Пакетная отправка с экспоненциальным ретраем
    for (var node in targets) {
      if (node.type != SignalType.mesh) continue;

      String targetIp = !_mesh.isHost ? "192.168.49.1" : _mesh.lastKnownPeerIp;
      if (targetIp.isEmpty || targetIp == "127.0.0.1") continue;

      await _transmitWithRetry(fragments, targetIp, node.name);
    }
  }

  /// Метод передачи с механизмом Exponential Backoff
  Future<void> _transmitWithRetry(List<Map<String, dynamic>> units, String ip, String nodeName) async {
    for (var unit in units) {
      int maxRetries = 3;
      Duration delay = const Duration(milliseconds: 300);

      for (int i = 0; i < maxRetries; i++) {
        try {
          await NativeMeshService.sendTcp(jsonEncode(unit), host: ip);
          break; // Успех
        } catch (e) {
          if (i == maxRetries - 1) {
            _mesh.addLog("❌ [Gossip] Failed to deliver to $nodeName.");
          } else {
            // Экспоненциальная пауза перед повтором
            await Future.delayed(delay);
            delay *= 2;
          }
        }
      }
    }
  }

  // ============================================================
  // 🔄 EPIDEMIC CYCLE (PULL/PUSH SYNC)
  // ============================================================

  /// Фоновый цикл "заражения" сети накопленными в Outbox данными
  /// Активная фаза: синхронизация очереди Outbox с учетом тактической ситуации
  void startEpidemicCycle() {
    _propagationTimer?.cancel();
    _propagationTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      // 1. Проверка физического уровня
      if (!_mesh.isP2pConnected || !_mesh.isRouteReady) return;

      // 2. Получаем все пакеты, ждущие отправки
      final List<Map<String, dynamic>> pending = await _db.getPendingFromOutbox();
      if (pending.isEmpty) return;

      final neighbors = _mesh.nearbyNodes;
      if (neighbors.isEmpty) return;

      // 3. ПРОВЕРКА РОЛИ: Если я BRIDGE — сразу выгружаю в облако
      if (NetworkMonitor().currentRole == MeshRole.BRIDGE) {
        _mesh.addLog("🌉 [Bridge] I am the exit node. Syncing to Command Center...");
        await locator<ApiService>().syncOutbox();
        return;
      }

      // 4. ЦИКЛ ОБРАБОТКИ ОЧЕРЕДИ
      for (var msg in pending) {
        final String routingState = msg['routing_state'] ?? 'PENDING';
        final String? preferredUplink = msg['preferred_uplink'];

        // Готовим фрагменты (Meaning Units)
        final fragments = _fragmentMessage({
          'content': msg['content'],
          'chatId': msg['chatRoomId'],
          'senderId': msg['senderId'],
          'senderUsername': "Nomad",
          'ttl': 4,
          'h': msg['id'],
          'type': 'OFFLINE_MSG',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });

        // --- ЛОГИКА ВЫБОРА ЦЕЛИ ---
        String? targetIp;
        String nodeName = "Unknown";

        if (routingState == 'ROUTING' && preferredUplink != null) {
          // КЕЙС А: Направленный роутинг (Directed)
          // Ищем конкретного соседа, которого оркестратор пометил как лучший путь
          final targetNode = neighbors.firstWhere(
                  (n) => n.id == preferredUplink,
              orElse: () => SignalNode(id: '', name: '', type: SignalType.mesh, metadata: '')
          );

          if (targetNode.id.isNotEmpty) {
            targetIp = !_mesh.isHost ? "192.168.49.1" : _mesh.lastKnownPeerIp;
            nodeName = targetNode.name;
            _mesh.addLog("🧭 [Routing] Forwarding priority signal to Bridge-Proxy: $nodeName");
          }
        }

        if (targetIp == null) {
          // КЕЙС Б: Обычный Gossip (Infection)
          // Если пути нет, выбираем случайного соседа
          final randomNode = (neighbors.toList()..shuffle()).first;
          targetIp = !_mesh.isHost ? "192.168.49.1" : _mesh.lastKnownPeerIp;
          nodeName = randomNode.name;
          _mesh.addLog("🦠 [Gossip] No direct path. Infecting random neighbor: $nodeName");
        }

        // 5. ФИЗИЧЕСКАЯ ОТПРАВКА
        if (targetIp != null && targetIp.isNotEmpty) {
          await _transmitWithRetry(fragments, targetIp, nodeName);
        }
      }
    });
  }

  void stop() {
    _propagationTimer?.cancel();
  }
}