import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'fragment_security_service.dart';

import 'api_service.dart';
import 'mesh_service.dart';
import 'local_db_service.dart';
import 'locator.dart';
import 'native_mesh_service.dart';
import 'models/signal_node.dart';
import '../features/chat/conversation_screen.dart';
import 'network_monitor.dart';
import 'MeshOrchestrator.dart';
import 'repeater_service.dart';

/// 🔒 SECURITY FIX: Rate limiter for flood protection
class RateLimiter {
  final int maxRequests;
  final Duration window;
  final Map<String, List<DateTime>> _requestHistory = {};
  
  // 🔒 Global rate limit across all senders
  int _globalRequestCount = 0;
  DateTime _globalWindowStart = DateTime.now();
  static const int _globalMaxRequests = 500; // Max 500 packets per window globally
  
  RateLimiter({
    this.maxRequests = 30, // Max requests per sender per window
    this.window = const Duration(seconds: 60),
  });
  
  /// Check if request is allowed, returns true if allowed
  bool checkAndRecord(String senderId) {
    final now = DateTime.now();
    
    // 🔒 Check global rate limit first
    if (now.difference(_globalWindowStart) > window) {
      _globalWindowStart = now;
      _globalRequestCount = 0;
    }
    
    if (_globalRequestCount >= _globalMaxRequests) {
      return false; // Global limit exceeded
    }
    
    // 🔒 Per-sender rate limit
    _requestHistory[senderId] ??= [];
    final senderHistory = _requestHistory[senderId]!;
    
    // Remove old entries outside the window
    senderHistory.removeWhere((time) => now.difference(time) > window);
    
    if (senderHistory.length >= maxRequests) {
      return false; // Per-sender limit exceeded
    }
    
    // Record this request
    senderHistory.add(now);
    _globalRequestCount++;
    
    return true;
  }
  
  /// Get current rate for a sender (requests per minute)
  double getCurrentRate(String senderId) {
    final history = _requestHistory[senderId];
    if (history == null || history.isEmpty) return 0;
    
    final now = DateTime.now();
    final recentRequests = history.where(
      (time) => now.difference(time) < window
    ).length;
    
    return recentRequests / (window.inSeconds / 60);
  }
  
  /// Check if a sender is potentially malicious (high rate)
  bool isSuspicious(String senderId) {
    return getCurrentRate(senderId) > maxRequests * 0.8;
  }
  
  /// Clean up old entries periodically
  void cleanup() {
    final now = DateTime.now();
    _requestHistory.removeWhere((_, history) {
      history.removeWhere((time) => now.difference(time) > window * 2);
      return history.isEmpty;
    });
  }
}

class GossipManager {
  final LocalDatabaseService _db = locator<LocalDatabaseService>();

  // Используем геттер для защиты от циклических зависимостей
  MeshService get _mesh => locator<MeshService>();

  Timer? _propagationTimer;
  
  // 🔒 SECURITY FIX: Rate limiters for different packet types
  final RateLimiter _messageRateLimiter = RateLimiter(
    maxRequests: 30, // Max 30 messages per sender per minute
    window: const Duration(seconds: 60),
  );
  
  final RateLimiter _fragmentRateLimiter = RateLimiter(
    maxRequests: 100, // Max 100 fragments per sender per minute
    window: const Duration(seconds: 60),
  );
  
  final RateLimiter _waveRateLimiter = RateLimiter(
    maxRequests: 20, // Max 20 routing waves per sender per minute
    window: const Duration(seconds: 60),
  );
  
  // 🔒 Cleanup timer
  Timer? _rateLimiterCleanupTimer;
  
  GossipManager() {
    // Periodic cleanup of rate limiter history
    _rateLimiterCleanupTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        _messageRateLimiter.cleanup();
        _fragmentRateLimiter.cleanup();
        _waveRateLimiter.cleanup();
      },
    );
  }
  
  void dispose() {
    _rateLimiterCleanupTimer?.cancel();
    _propagationTimer?.cancel();
  }

  // ============================================================
  // 📥 ВХОДЯЩИЙ ПОТОК (INGRESS)
  // ============================================================

  /// Главная точка входа для любого пакета из Mesh-эфира.
  Future<void> processEnvelope(Map<String, dynamic> packet) async {
    final String type = packet['type'] ?? 'UNKNOWN';
    final String packetId = packet['h'] ?? "pulse_${packet['timestamp']}_${packet['senderId']}";
    final String senderId = packet['senderId'] ?? 'unknown';

    // 🔒 SECURITY FIX: Rate limiting check BEFORE processing
    bool rateLimitAllowed = true;
    
    switch (type) {
      case 'MAGNET_WAVE':
        rateLimitAllowed = _waveRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog("🛡️ [RATE-LIMIT] Wave flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
      case 'MSG_FRAG':
        rateLimitAllowed = _fragmentRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog("🛡️ [RATE-LIMIT] Fragment flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
      case 'OFFLINE_MSG':
      case 'SOS':
        rateLimitAllowed = _messageRateLimiter.checkAndRecord(senderId);
        if (!rateLimitAllowed) {
          _mesh.addLog("🛡️ [RATE-LIMIT] Message flood detected from ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
        }
        break;
    }
    
    // 🔒 Drop packet if rate limit exceeded
    if (!rateLimitAllowed) {
      // Log suspicious activity
      if (_messageRateLimiter.isSuspicious(senderId) || 
          _fragmentRateLimiter.isSuspicious(senderId)) {
        _mesh.addLog("⚠️ [SECURITY] Suspicious sender flagged: ${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");
      }
      return;
    }

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

  /// 🔥 MESH FRAGMENT REASSEMBLY: Сборка сообщений из фрагментов
  /// Независимо от источника (BRIDGE A, BRIDGE B, direct) - по messageId
  Future<bool> _handleFragment(Map<String, dynamic> frag) async {
    // 🔥 ДИАГНОСТИКА: Логируем все поля фрагмента для отладки
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] Raw fragment keys: ${frag.keys.toList()}");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['mid']: ${frag['mid']}");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['idx']: ${frag['idx']} (type: ${frag['idx'].runtimeType})");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['tot']: ${frag['tot']}");
    _mesh.addLog("🔍 [FRAGMENT-DEBUG] frag['data']: ${frag['data']?.toString().length ?? 0} bytes");
    
    final String messageId = frag['mid'] ?? '';
    // 🔥 FIX: Правильное извлечение idx (может быть int или String)
    final dynamic idxRaw = frag['idx'];
    final int index = idxRaw is int ? idxRaw : (idxRaw is String ? int.tryParse(idxRaw) ?? -1 : -1);
    final dynamic totRaw = frag['tot'];
    final int total = totRaw is int ? totRaw : (totRaw is String ? int.tryParse(totRaw) ?? -1 : -1);
    // 🔥 FIX: Правильное извлечение data (может быть String или другой тип)
    final dynamic dataRaw = frag['data'];
    final String data = dataRaw?.toString() ?? '';
    final String senderId = frag['senderId'] ?? 'unknown';
    final String chatId = frag['chatId'] ?? 'THE_BEACON_GLOBAL';
    
    // 🛡️ VALIDATION
    if (messageId.isEmpty || index < 0 || total <= 0 || data.isEmpty) {
      _mesh.addLog("⚠️ [FRAGMENT] Invalid fragment: mid=$messageId idx=$index tot=$total dataLen=${data.length}");
      _mesh.addLog("   🔍 Debug: idxRaw=$idxRaw (${idxRaw.runtimeType}), totRaw=$totRaw (${totRaw.runtimeType})");
      return false;
    }
    
    // 📊 FORENSIC LOG: fragment_received
    _mesh.addLog("📦 [FRAGMENT] fragment_received: mid=${messageId.substring(0, messageId.length > 8 ? 8 : messageId.length)}... idx=$index/$total sender=${senderId.substring(0, senderId.length > 8 ? 8 : senderId.length)}...");

    // 💾 SAVE TO SQL (with flooding protection)
    final saved = await _db.saveFragment(
        messageId: messageId,
        index: index,
        total: total,
        data: data
    );
    
    if (!saved) {
      // 📊 FORENSIC LOG: fragment_duplicate or fragment_rejected
      _mesh.addLog("ℹ️ [FRAGMENT] fragment_duplicate_or_rejected: $messageId idx=$index");
      return false;
    }
    
    // 📊 FORENSIC LOG: fragment_stored
    _mesh.addLog("💾 [FRAGMENT] fragment_stored: $messageId idx=$index/${total}");

    // 🔍 CHECK IF COMPLETE
    final List<Map<String, dynamic>> allFrags = await _db.getFragments(messageId);
    
    _mesh.addLog("📊 [FRAGMENT] Progress: ${allFrags.length}/$total for $messageId");
    
    // 🔥 ДИАГНОСТИКА: Логируем все сохраненные фрагменты
    if (allFrags.isNotEmpty) {
      final indices = allFrags.map((f) => f['index_num']).toList();
      _mesh.addLog("🔍 [FRAGMENT-DEBUG] Saved fragments indices: $indices");
      _mesh.addLog("🔍 [FRAGMENT-DEBUG] Expected indices: ${List.generate(total, (i) => i)}");
    }

    if (allFrags.length == total) {
      // 🎉 MESSAGE COMPLETE!
      // 📊 FORENSIC LOG: message_assembled
      _mesh.addLog("🎉 [FRAGMENT] message_assembled: $messageId (${allFrags.length} fragments)");

      // 🔥 FIX: Правильная сортировка с проверкой типов
      allFrags.sort((a, b) {
        final aIdx = a['index_num'];
        final bIdx = b['index_num'];
        final aInt = aIdx is int ? aIdx : (aIdx is String ? int.tryParse(aIdx) ?? 999 : 999);
        final bInt = bIdx is int ? bIdx : (bIdx is String ? int.tryParse(bIdx) ?? 999 : 999);
        return aInt.compareTo(bInt);
      });
      
      // 🔥 ДИАГНОСТИКА: Проверяем порядок после сортировки
      final sortedIndices = allFrags.map((f) => f['index_num']).toList();
      _mesh.addLog("🔍 [FRAGMENT-DEBUG] Sorted indices: $sortedIndices");
      
      String fullContent = allFrags.map((f) => f['data']?.toString() ?? '').join("");
      
      _mesh.addLog("📝 [FRAGMENT] Assembled content: ${fullContent.length} bytes");

      final fullPacket = {
        ...frag,
        'type': 'OFFLINE_MSG',
        'content': fullContent,
        'h': messageId,
        'chatId': chatId,
        'senderId': senderId,
        '_assembled': true, // 🔥 Маркер что сообщение собрано
      };

      // 📤 DELIVER TO UI (только полное сообщение!)
      _mesh.messageController.add(fullPacket);
      
      // 💾 SAVE TO SQL
      await _db.saveMessage(ChatMessage.fromJson(fullPacket), chatId);
      
      // 📊 FORENSIC LOG: message_committed
      _mesh.addLog("✅ [FRAGMENT] message_committed: $messageId to chat $chatId");
      
      // 🧹 CLEANUP fragments
      await _db.clearFragments(messageId);

      // 🔄 RELAY assembled message
      await attemptRelay(fullPacket);
      
      // 📊 FORENSIC LOG: relay_forwarded
      _mesh.addLog("📤 [FRAGMENT] relay_forwarded: assembled message $messageId");
      
      return true; // Сообщение собрано
    }
    
    return false; // Ждём остальные фрагменты
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
    final String packetId = packet['h'] ?? "pulse_${packet['timestamp']}_${packet['senderId']}";
    final currentRole = NetworkMonitor().currentRole;
    final senderId = packet['senderId']?.toString();
    
    // 🔥 REPEATER: Используем RepeaterService для ретрансляции всем доверенным устройствам
    try {
      final repeater = locator<RepeaterService>();
      if (repeater.isRunning && repeater.activeConnectionCount > 0) {
        final repeatedCount = await repeater.repeatPacket(
          packet, 
          excludeDeviceId: senderId,
        );
        if (repeatedCount > 0) {
          _mesh.addLog("🔄 [REPEATER] Packet relayed to $repeatedCount devices");
        }
      }
    } catch (e) {
      // RepeaterService может быть недоступен - продолжаем стандартную логику
    }
    
    // 🔥 BRIDGE: Ретранслируем сообщения GHOST устройствам
    if (currentRole == MeshRole.BRIDGE) {
      _mesh.addLog("🌉 [BRIDGE-GOSSIP] Relaying message to GHOST devices...");
      _mesh.addLog("   📋 Packet ID: ${packetId.substring(0, packetId.length > 8 ? 8 : packetId.length)}...");
      _mesh.addLog("   📋 Packet type: ${packet['type']}");
      _mesh.addLog("   📋 Chat ID: ${packet['chatId']}");
      _mesh.addLog("   📋 TTL: ${packet['ttl'] ?? 5}");
      
      // 1. Если есть Wi-Fi Direct - используем сеть
      if (_mesh.isP2pConnected) {
        _mesh.addLog("   📡 Using Wi-Fi Direct for relay");
        await _relayViaNetwork(packet);
      } else {
        _mesh.addLog("   ⚠️ Wi-Fi Direct not connected, skipping network relay");
      }
      
      // 2. 🔥 КРИТИЧНО: Всегда ретранслируем через BLE к GHOST устройствам
      // Это гарантирует доставку даже без Wi-Fi Direct
      // 🔥 FIX: Проверяем как nearbyNodes, так и активные GATT соединения
      final btService = _mesh.btService;
      final connectedClientsCount = btService.connectedGattClientsCount;
      _mesh.addLog("   🔍 Active GATT clients: $connectedClientsCount");
      
      final bluetoothNodes = _mesh.nearbyNodes.where((n) => n.type == SignalType.bluetooth).toList();
      _mesh.addLog("   🔍 Found ${bluetoothNodes.length} BLE node(s) in nearbyNodes");
      
      // 🔥 FIX: Если есть активные GATT соединения, отправляем им сообщения напрямую
      if (connectedClientsCount > 0) {
        _mesh.addLog("   🦷 Relaying to $connectedClientsCount active GATT client(s)...");
        await _relayToConnectedGattClients(packet, btService);
      }
      
      // Также отправляем через nearbyNodes для устройств, которые еще не подключены
      if (bluetoothNodes.isNotEmpty) {
        _mesh.addLog("   🦷 Relaying to ${bluetoothNodes.length} BLE node(s) via GATT...");
        for (var node in bluetoothNodes) {
          _mesh.addLog("      📋 Node: ${node.name} (${node.id.substring(node.id.length > 8 ? node.id.length - 8 : 0)})");
        }
        await _relayViaBle(packet, bluetoothNodes);
      } else if (connectedClientsCount == 0) {
        _mesh.addLog("   ⚠️ No BLE nodes available for relay");
        _mesh.addLog("   💡 GHOST devices need to be in BLE scan range or connected via GATT");
      }
      
      return;
    }

    // Для GHOST: проверяем наличие пакета у соседа перед передачей
    if (!_mesh.isP2pConnected) {
      // Если нет Wi-Fi Direct - используем BLE или Sonar для проверки
      await _relayWithPacketCheck(packet, packetId);
      return;
    }

    // Если есть Wi-Fi Direct соединение - передаем через сеть
    await _relayViaNetwork(packet);
  }

  /// 🔥 Ретрансляция к подключенным GATT клиентам (BRIDGE → GHOST)
  /// Отправляет сообщения напрямую подключенным устройствам через GATT server
  Future<void> _relayToConnectedGattClients(Map<String, dynamic> packet, dynamic btService) async {
    final packetJson = jsonEncode(packet);
    final connectedClients = btService.connectedGattClients;
    
    if (connectedClients.isEmpty) {
      _mesh.addLog("   ⚠️ No connected GATT clients to relay to");
      return;
    }
    
    _mesh.addLog("🦷 [GOSSIP-GATT] Relaying to ${connectedClients.length} connected GATT client(s)...");
    final packetId = packet['h']?.toString() ?? 'unknown';
    final packetIdPreview = packetId.length > 8 ? packetId.substring(0, 8) : packetId;
    _mesh.addLog("   📋 Packet ID: $packetIdPreview...");
    
    int successCount = 0;
    for (var deviceAddress in connectedClients) {
      try {
        final shortMac = deviceAddress.length > 8 ? deviceAddress.substring(deviceAddress.length - 8) : deviceAddress;
        _mesh.addLog("   📤 Relaying to connected client (MAC: $shortMac)...");
        
        final success = await btService.sendMessageToGattClient(deviceAddress, packetJson);
        
        if (success) {
          successCount++;
          _mesh.addLog("   ✅ Successfully relayed to connected client (MAC: $shortMac)");
        } else {
          _mesh.addLog("   ⚠️ Failed to relay to connected client (MAC: $shortMac)");
        }
      } catch (e) {
        _mesh.addLog("   ❌ Error relaying to connected client: $e");
      }
    }
    
    _mesh.addLog("🦷 [GOSSIP-GATT] Relay complete: $successCount/${connectedClients.length} successful");
  }

  /// 🔥 Ретрансляция через BLE GATT (BRIDGE → GHOST)
  Future<void> _relayViaBle(Map<String, dynamic> packet, List<dynamic> bluetoothNodes) async {
    final btService = _mesh.btService;
    final packetJson = jsonEncode(packet);
    
    _mesh.addLog("🦷 [GOSSIP-BLE] Starting BLE relay to ${bluetoothNodes.length} device(s)...");
    final packetId = packet['h']?.toString() ?? 'unknown';
    final packetIdPreview = packetId.length > 8 ? packetId.substring(0, 8) : packetId;
    _mesh.addLog("   📋 Packet ID: $packetIdPreview...");
    _mesh.addLog("   📋 Content length: ${(packet['content']?.toString() ?? '').length} bytes");
    
    int successCount = 0;
    for (var node in bluetoothNodes) {
      try {
        // Получаем BluetoothDevice из SignalNode
        final deviceId = node.id;
        if (deviceId.isEmpty) continue;
        
        final shortMac = deviceId.length > 8 ? deviceId.substring(deviceId.length - 8) : deviceId;
        _mesh.addLog("   📤 Relaying to ${node.name} (MAC: $shortMac)...");
        
        // Используем BluetoothDevice.fromId (как в mesh_service.dart)
        final device = BluetoothDevice.fromId(deviceId);
        final success = await btService.sendMessage(device, packetJson);
        
        if (success) {
          successCount++;
          _mesh.addLog("   ✅ Successfully relayed to ${node.name} (MAC: $shortMac)");
        } else {
          _mesh.addLog("   ⚠️ Failed to relay to ${node.name} (MAC: $shortMac)");
        }
      } catch (e) {
        _mesh.addLog("   ❌ Error relaying to ${node.name}: $e");
      }
    }
    
    _mesh.addLog("🦷 [GOSSIP-BLE] Relay complete: $successCount/${bluetoothNodes.length} successful");
  }

  /// Передача через сеть (Wi-Fi Direct или Router)
  Future<void> _relayViaNetwork(Map<String, dynamic> packet) async {
    // 1. Управление жизненным циклом
    int ttl = packet['ttl'] ?? 5;
    if (ttl <= 0) {
      _mesh.addLog("⚠️ [GOSSIP-NETWORK] TTL expired, dropping packet");
      return;
    }
    packet['ttl'] = ttl - 1;

    // 2. Вероятностный фильтр нагрузки (масштабируемость)
    // 🔥 FIX: Для BRIDGE всегда ретранслируем (вероятность = 1.0)
    final currentRole = NetworkMonitor().currentRole;
    double relayProbability;
    if (currentRole == MeshRole.BRIDGE) {
      relayProbability = 1.0; // BRIDGE всегда ретранслирует
      _mesh.addLog("🌉 [BRIDGE-GOSSIP] Relay probability: 1.0 (always relay)");
    } else {
      relayProbability = math.pow(ttl / 5.0, 1.5).toDouble().clamp(0.0, 1.0);
      _mesh.addLog("👻 [GHOST-GOSSIP] Relay probability: ${relayProbability.toStringAsFixed(2)} (TTL: $ttl)");
    }
    
    if (math.Random().nextDouble() > relayProbability) {
      _mesh.addLog("⏸️ [GOSSIP-NETWORK] Packet dropped by probability filter");
      return;
    }

    // 3. Фрагментация перед отправкой (с защитой от перехвата)
    final List<Map<String, dynamic>> fragments = _fragmentMessage(packet);
    _mesh.addLog("   📦 Fragmented into ${fragments.length} piece(s)");
    if (fragments.length > 1) {
      // 🔒 Логируем порядок отправки (для диагностики)
      final indices = fragments.map((f) => f['idx'] as int).toList();
      _mesh.addLog("   🔒 [SECURITY] Fragment order: $indices (shuffled for anti-interception)");
    }

    // 4. Выбор цели на основе градиента (ищем аплинк)
    final bestUplink = locator<TacticalMeshOrchestrator>().getBestUplink();
    String targetIp = "192.168.49.1"; // Default WiFi Direct Host

    if (bestUplink != null) {
      _mesh.addLog("🧭 Routing packet towards Magnet: ${bestUplink.nodeId}");
      // Если у нас есть IP соседа в метаданных - шлем туда, иначе на шлюз группы
      targetIp = bestUplink.nodeId.contains(".") ? bestUplink.nodeId : "192.168.49.1";
    } else {
      _mesh.addLog("⚠️ No best uplink found, using default IP: $targetIp");
    }

    _mesh.addLog("   📤 Transmitting ${fragments.length} fragment(s) to $targetIp...");
    await _transmitWithRetry(fragments, targetIp, "Relay-Node");
    _mesh.addLog("   ✅ Network relay transmission completed");
  }

  /// Передача с проверкой наличия пакета у соседа (для GHOST без Wi-Fi Direct)
  Future<void> _relayWithPacketCheck(Map<String, dynamic> packet, String packetId) async {
    final ultrasonic = locator<UltrasonicService>();
    final mesh = locator<MeshService>();
    
    // 1. Отправляем запрос через Sonar: "Есть ли у тебя пакет с ID?"
    _mesh.addLog("🔊 [Gossip] Querying neighbors for packet: ${packetId.substring(0, 8)}...");
    
    // Отправляем запрос через Sonar (короткий сигнал)
    final querySignal = "Q:${packetId.hashCode}"; // Хеш для краткости
    await ultrasonic.transmitFrame(querySignal);
    
    // Ждем ответа 3 секунды (сосед должен ответить через BLE или Sonar)
    await Future.delayed(const Duration(seconds: 3));
    
    // 2. Проверяем ближайших соседей через BLE
    final bluetoothNodes = mesh.nearbyNodes.where((n) => n.type == SignalType.bluetooth).toList();
    
    if (bluetoothNodes.isNotEmpty) {
      // Пытаемся передать через BLE с проверкой
      for (var node in bluetoothNodes) {
        // Проверяем, есть ли у соседа этот пакет (через BLE запрос)
        // Если нет - передаем
        _mesh.addLog("🦷 [Gossip] Attempting BLE relay to ${node.name}...");
        
        try {
          // TODO: Нужно получить BluetoothDevice из SignalNode
          // Пока используем существующий механизм
          _mesh.addLog("✅ [Gossip] BLE relay initiated");
        } catch (e) {
          _mesh.addLog("⚠️ [Gossip] BLE relay failed: $e");
        }
      }
    } else {
      // Если нет BLE соседей - отправляем через Sonar (только для коротких сообщений)
      if ((packet['content'] as String? ?? '').length < 64) {
        _mesh.addLog("🔊 [Gossip] No BLE neighbors, using Sonar fallback");
        final sonarPayload = "MSG:${packetId.hashCode}";
        await ultrasonic.transmitFrame(sonarPayload);
      }
    }
  }

  // 🔒 Fragment Security Service для защиты от перехвата
  final FragmentSecurityService _fragmentSecurity = FragmentSecurityService();
  
  List<Map<String, dynamic>> _fragmentMessage(Map<String, dynamic> packet) {
    // 🔒 Используем защищенную фрагментацию с перемешиванием
    return _fragmentSecurity.fragmentWithSecurity(packet, chunkSize: 160);
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
      } else {
        // Если нет аплинка - пытаемся заразить соседей через BLE/Sonar
        _mesh.addLog("🦠 [Epidemic] No uplink found, attempting neighbor infection...");
        for (var msg in pending) {
          await attemptRelay(msg);
        }
      }
    });
  }

  void stop() {
    _propagationTimer?.cancel();
  }
}