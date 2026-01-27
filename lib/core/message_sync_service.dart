import 'dart:async';
import 'dart:convert';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/gossip_manager.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';

/// 🔄 Message Sync Service
/// Периодически проверяет новые сообщения и отправляет их подключенным устройствам
/// Также синхронизирует чат "The Beacon" между устройствами
class MessageSyncService {
  Timer? _syncTimer;
  final MeshService _mesh = locator<MeshService>();
  final LocalDatabaseService _db = locator<LocalDatabaseService>();
  
  bool _isRunning = false;
  static const Duration _syncInterval = Duration(seconds: 10); // Проверка каждые 10 секунд
  
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
  
  /// Синхронизирует новые сообщения с подключенными устройствами
  /// 🔥 FIX: Работает даже когда нет активных соединений (использует GossipManager для ретрансляции)
  /// 🔥 FIX: Автоматически сканирует BLE для поиска GHOST устройств перед синхронизацией
  Future<void> _syncMessages() async {
    final currentRole = NetworkMonitor().currentRole;
    
    // Только BRIDGE синхронизирует сообщения
    if (currentRole != MeshRole.BRIDGE) return;
    
    try {
      // Проверяем активные GATT соединения
      final btService = _mesh.btService;
      final connectedCount = btService.connectedGattClientsCount;
      
      // Получаем последние сообщения из чата "The Beacon" за последние 5 минут
      final recentMessages = await _db.getRecentMessages(
        chatId: 'THE_BEACON_GLOBAL',
        since: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      
      if (recentMessages.isEmpty) {
        return;
      }
      
      _mesh.addLog("🔄 [SYNC] Checking for new messages to sync (${recentMessages.length} message(s), $connectedCount connected device(s))...");
      
      // 🔥 FIX: Всегда сканируем BLE для поиска GHOST устройств (даже если есть активные соединения)
      // Это гарантирует, что nearbyNodes обновляется регулярно, и BRIDGE может найти новых GHOST устройств
      _mesh.addLog("   🔍 [SYNC] Scanning BLE for GHOST devices (connected: $connectedCount)...");
      try {
        // Запускаем короткий BLE scan для поиска GHOST устройств
        // BRIDGE сканирует БЕЗ фильтра SERVICE_UUID, чтобы видеть GHOST по тактическому имени
        await _mesh.startDiscovery(SignalType.bluetooth);
        await Future.delayed(const Duration(seconds: 8)); // Увеличено с 5 до 8 секунд для лучшего обнаружения
        await _mesh.stopDiscovery();
        _mesh.addLog("   ✅ [SYNC] BLE scan completed - nearbyNodes updated");
      } catch (e) {
        _mesh.addLog("   ⚠️ [SYNC] BLE scan failed: $e");
      }
      
      // 🔥 FIX: Если есть активные GATT соединения - отправляем напрямую
      if (connectedCount > 0) {
        final connectedClients = btService.connectedGattClients;
        _mesh.addLog("   📤 Sending ${recentMessages.length} message(s) to ${connectedClients.length} connected client(s)...");
        
        int totalSent = 0;
        for (var message in recentMessages) {
          try {
            final messageData = {
              'type': 'OFFLINE_MSG',
              'h': message.id,
              'content': message.content,
              'senderId': message.senderId,
              'senderUsername': message.senderUsername ?? 'Unknown',
              'chatId': 'THE_BEACON_GLOBAL',
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
        
        _mesh.addLog("   📊 [SYNC] Sent $totalSent/${recentMessages.length} message(s) to ${connectedClients.length} client(s)");
      } else {
        // 🔥 FIX: Если нет активных соединений - используем GossipManager для ретрансляции
        // Это позволяет отправлять сообщения даже когда GHOST не подключен
        _mesh.addLog("   ⚠️ [SYNC] No connected GATT clients - using GossipManager for relay...");
        
        final gossipManager = locator<GossipManager>();
        int relayedCount = 0;
        
        for (var message in recentMessages) {
          try {
            final messageData = {
              'type': 'OFFLINE_MSG',
              'h': message.id,
              'content': message.content,
              'senderId': message.senderId,
              'senderUsername': message.senderUsername ?? 'Unknown',
              'chatId': 'THE_BEACON_GLOBAL',
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
        
        _mesh.addLog("   📊 [SYNC] Relayed $relayedCount/${recentMessages.length} message(s) via GossipManager");
      }
      
      _mesh.addLog("✅ [SYNC] Message sync completed");
    } catch (e) {
      _mesh.addLog("❌ [SYNC] Error during message sync: $e");
    }
  }
}
