import 'dart:async';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/gossip_manager.dart';
import 'package:memento_mori_app/core/local_db_service.dart';

/// 🔄 Message Sync Service
/// Периодически проверяет новые сообщения и отправляет их подключенным устройствам
/// Также синхронизирует чат "The Beacon" между устройствами
class MessageSyncService {
  Timer? _syncTimer;
  final MeshService _mesh = locator<MeshService>();
  final GossipManager _gossip = locator<GossipManager>();
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
  Future<void> _syncMessages() async {
    final currentRole = NetworkMonitor().currentRole;
    
    // Только BRIDGE синхронизирует сообщения
    if (currentRole != MeshRole.BRIDGE) return;
    
    try {
      // Проверяем активные GATT соединения
      final btService = _mesh.btService;
      final connectedCount = btService.connectedGattClientsCount;
      
      if (connectedCount == 0) {
        // Нет подключенных устройств - пропускаем
        return;
      }
      
      _mesh.addLog("🔄 [SYNC] Checking for new messages to sync ($connectedCount connected device(s))...");
      
      // Получаем последние сообщения из чата "The Beacon" за последние 5 минут
      // Это позволяет синхронизировать новые сообщения подключенным устройствам
      final recentMessages = await _db.getRecentMessages(
        chatId: 'THE_BEACON_GLOBAL',
        since: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      
      if (recentMessages.isEmpty) {
        return;
      }
      
      _mesh.addLog("   📋 Found ${recentMessages.length} recent message(s) to sync");
      
      // Отправляем каждое сообщение подключенным устройствам
      for (var message in recentMessages) {
        try {
          final messageData = {
            'type': 'OFFLINE_MSG',
            'h': message.id,
            'content': message.content,
            'senderId': message.senderId,
            'senderUsername': message.senderUsername,
            'chatId': 'THE_BEACON_GLOBAL',
            'timestamp': message.createdAt.millisecondsSinceEpoch,
            'ttl': 5,
          };
          
          // Ретранслируем через GossipManager
          await _gossip.attemptRelay(messageData);
        } catch (e) {
          _mesh.addLog("   ⚠️ [SYNC] Failed to sync message ${message.id}: $e");
        }
      }
      
      _mesh.addLog("✅ [SYNC] Message sync completed");
    } catch (e) {
      _mesh.addLog("❌ [SYNC] Error during message sync: $e");
    }
  }
}
