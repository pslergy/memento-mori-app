import 'dart:async';
import 'dart:convert';
import 'package:memento_mori_app/core/beacon_country_helper.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_core_engine.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/gossip_manager.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';

/// 🔄 Message Sync Service
/// Периодически проверяет новые сообщения и отправляет их подключенным устройствам
/// Синхронизирует все beacon-чаты: THE_BEACON_GLOBAL, BEACON_NEARBY, THE_BEACON_XX
class MessageSyncService {
  Timer? _syncTimer;
  final MeshCoreEngine _mesh = locator<MeshCoreEngine>();
  final LocalDatabaseService _db = locator<LocalDatabaseService>();
  
  bool _isRunning = false;
  int _syncCycleCount = 0;
  static const Duration _syncInterval = Duration(seconds: 10); // Проверка каждые 10 секунд
  static const Duration _bleScanDuration = Duration(seconds: 3); // Сокращено с 8с для снижения конфликта с cascade
  static const int _bleScanEveryNCycles = 2; // BLE-скан только каждый 2-й цикл
  
  /// Запускает периодическую синхронизацию сообщений
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    
    _mesh.addLog("🔄 [SYNC] Message sync service started");
    
    _syncTimer = Timer.periodic(_syncInterval, (_) => _syncMessages());
    
    // Первая проверка сразу
    _syncMessages();
  }
  
  /// Останавливает синхронизацию
  void stop() {
    _isRunning = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _mesh.addLog("🔄 [SYNC] Message sync service stopped");
  }
  
  /// Список beacon-чатов для синхронизации (THE_BEACON_GLOBAL, BEACON_NEARBY, THE_BEACON_XX)
  static List<String> _beaconChatIds() {
    final ids = <String>{'THE_BEACON_GLOBAL', 'BEACON_NEARBY'};
    final countryChat = BeaconCountryHelper.beaconChatIdForCountry();
    if (countryChat.isNotEmpty) ids.add(countryChat);
    return ids.toList();
  }

  /// Синхронизирует новые сообщения с подключенными устройствами
  /// 🔥 FIX: Работает даже когда нет активных соединений (использует GossipManager для ретрансляции)
  /// 🔥 FIX: Синхронизирует все beacon-чаты (THE_BEACON_GLOBAL, BEACON_NEARBY, THE_BEACON_XX)
  /// 🔥 FIX: BLE-скан сокращён до 3с и выполняется каждый 2-й цикл (снижение конфликта с cascade)
  Future<void> _syncMessages() async {
    final currentRole = NetworkMonitor().currentRole;
    
    // Только BRIDGE синхронизирует сообщения
    if (currentRole != MeshRole.BRIDGE) return;
    
    try {
      _syncCycleCount++;
      final btService = _mesh.btService;
      final connectedCount = btService.connectedGattClientsCount;
      
      // Получаем последние сообщения из ВСЕХ beacon-чатов за последние 5 минут
      final since = DateTime.now().subtract(const Duration(minutes: 5));
      final seenIds = <String>{};
      final recentMessagesWithChat = <({dynamic message, String chatId})>[];
      for (final chatId in _beaconChatIds()) {
        final msgs = await _db.getRecentMessages(chatId: chatId, since: since);
        for (final m in msgs) {
          if (seenIds.add(m.id)) {
            recentMessagesWithChat.add((message: m, chatId: chatId));
          }
        }
      }
      recentMessagesWithChat.sort((a, b) =>
          a.message.createdAt.compareTo(b.message.createdAt));
      
      if (recentMessagesWithChat.isEmpty) return;
      
      _mesh.addLog("🔄 [SYNC] Checking for new messages to sync (${recentMessagesWithChat.length} message(s), $connectedCount connected device(s))...");
      
      // BLE-скан только каждый N-й цикл, чтобы не конфликтовать с cascade
      if (_syncCycleCount % _bleScanEveryNCycles == 0) {
        _mesh.addLog("   🔍 [SYNC] Scanning BLE for GHOST devices (connected: $connectedCount)...");
        try {
          await _mesh.startDiscovery(SignalType.bluetooth);
          await Future.delayed(_bleScanDuration);
          await _mesh.stopDiscovery();
          _mesh.addLog("   ✅ [SYNC] BLE scan completed - nearbyNodes updated");
        } catch (e) {
          _mesh.addLog("   ⚠️ [SYNC] BLE scan failed: $e");
        }
      }
      
      // 🔥 FIX: Если есть активные GATT соединения - отправляем напрямую
      if (connectedCount > 0) {
        final connectedClients = btService.connectedGattClients;
        _mesh.addLog("   📤 Sending ${recentMessagesWithChat.length} message(s) to ${connectedClients.length} connected client(s)...");
        
        int totalSent = 0;
        for (final entry in recentMessagesWithChat) {
          final message = entry.message;
          try {
            final messageData = {
              'type': 'OFFLINE_MSG',
              'h': message.id,
              'content': message.content,
              'senderId': message.senderId,
              'senderUsername': message.senderUsername ?? 'Unknown',
              'chatId': entry.chatId,
              'timestamp': message.createdAt.millisecondsSinceEpoch,
              'ttl': 5,
            };
            
            final messageJson = jsonEncode(messageData);
            int sentToClients = 0;
            
            // Отправляем каждому подключенному клиенту
            for (var clientAddress in connectedClients) {
              try {
                final success = await btService.sendMessageToGattClient(clientAddress, messageJson);
                if (success) {
                  sentToClients++;
                  final shortMac = clientAddress.length > 8 
                      ? clientAddress.substring(clientAddress.length - 8) 
                      : clientAddress;
                  _mesh.addLog("   ✅ Sent message ${message.id.substring(0, message.id.length > 8 ? 8 : message.id.length)}... to $shortMac");
                }
              } catch (e) {
                _mesh.addLog("   ⚠️ [SYNC] Failed to send to client: $e");
              }
            }
            
            if (sentToClients > 0) {
              totalSent++;
              await Future.delayed(const Duration(milliseconds: 100));
            }
          } catch (e) {
            _mesh.addLog("   ⚠️ [SYNC] Failed to sync message ${message.id}: $e");
          }
        }
        
        _mesh.addLog("   📊 [SYNC] Sent $totalSent/${recentMessagesWithChat.length} message(s) to ${connectedClients.length} client(s)");
      } else {
        // 🔥 FIX: Если нет активных соединений - используем GossipManager для ретрансляции
        // Это позволяет отправлять сообщения даже когда GHOST не подключен
        _mesh.addLog("   ⚠️ [SYNC] No connected GATT clients - using GossipManager for relay...");
        
        final gossipManager = locator<GossipManager>();
        int relayedCount = 0;
        
        for (final entry in recentMessagesWithChat) {
          final message = entry.message;
          try {
            final messageData = {
              'type': 'OFFLINE_MSG',
              'h': message.id,
              'content': message.content,
              'senderId': message.senderId,
              'senderUsername': message.senderUsername ?? 'Unknown',
              'chatId': entry.chatId,
              'timestamp': message.createdAt.millisecondsSinceEpoch,
              'ttl': 5,
            };
            
            // Используем GossipManager для ретрансляции (он проверит nearbyNodes и отправит через BLE)
            await gossipManager.attemptRelay(messageData);
            relayedCount++;
            
            await Future.delayed(const Duration(milliseconds: 100));
          } catch (e) {
            _mesh.addLog("   ⚠️ [SYNC] Failed to relay message ${message.id}: $e");
          }
        }
        
        _mesh.addLog("   📊 [SYNC] Relayed $relayedCount/${recentMessagesWithChat.length} message(s) via GossipManager");
      }
      
      _mesh.addLog("✅ [SYNC] Message sync completed");
    } catch (e) {
      _mesh.addLog("❌ [SYNC] Error during message sync: $e");
    }
  }
}
