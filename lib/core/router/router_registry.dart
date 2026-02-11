import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import '../local_db_service.dart';
import 'models/router_info.dart';

/// Реестр известных Wi-Fi роутеров
/// 
/// TODO: Реализация протокола захвата роутера
/// - Хранение информации о роутерах в БД
/// - Управление паролями в SecureStorage
/// - Синхронизация между устройствами
class RouterRegistry {
  static final RouterRegistry _instance = RouterRegistry._internal();
  factory RouterRegistry() => _instance;
  RouterRegistry._internal();

  final _db = LocalDatabaseService();

  /// Сохраняет роутер в БД и пароль в SecureStorage
  Future<void> saveRouter(RouterInfo router) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'known_routers',
      {
        'id': router.id,
        'ssid': router.ssid,
        'mac_address': router.macAddress,
        'ip_address': router.ipAddress,
        'priority': router.priority,
        'is_trusted': router.isTrusted ? 1 : 0,
        'last_seen': router.lastSeen?.millisecondsSinceEpoch ?? now,
        'rssi': router.rssi,
        'has_internet': router.hasInternet ? 1 : 0,
        'is_open': router.isOpen ? 1 : 0,
        'use_as_relay': router.useAsRelay ? 1 : 0,
        'created_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Сохраняем пароль в SecureStorage (если есть)
    if (router.password != null && router.password!.isNotEmpty) {
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'router_password_${router.ssid}', value: router.password);
    }
  }

  /// Получает все известные роутеры из БД
  Future<List<RouterInfo>> getAllKnownRouters() async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'known_routers',
      orderBy: 'priority DESC, last_seen DESC',
    );

    final List<RouterInfo> routers = [];
    final storage = const FlutterSecureStorage();

    for (var map in maps) {
      final router = RouterInfo.fromDbRow(map);
      // Загружаем пароль из SecureStorage (только если роутер не открытый)
      final password = router.isOpen ? null : await storage.read(key: 'router_password_${router.ssid}');
      routers.add(RouterInfo(
        id: router.id,
        ssid: router.ssid,
        password: password,
        macAddress: router.macAddress,
        ipAddress: router.ipAddress,
        priority: router.priority,
        isTrusted: router.isTrusted,
        lastSeen: router.lastSeen,
        rssi: router.rssi,
        hasInternet: router.hasInternet,
        isOpen: router.isOpen,
        useAsRelay: router.useAsRelay,
      ));
    }

    return routers;
  }

  /// Ищет роутер по SSID
  Future<RouterInfo?> findRouterBySsid(String ssid) async {
    final db = await _db.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'known_routers',
      where: 'ssid = ?',
      whereArgs: [ssid],
      limit: 1,
    );

    if (maps.isEmpty) return null;

    final router = RouterInfo.fromDbRow(maps.first);
    final storage = const FlutterSecureStorage();
    final password = router.isOpen ? null : await storage.read(key: 'router_password_${router.ssid}');

    return RouterInfo(
      id: router.id,
      ssid: router.ssid,
      password: password,
      macAddress: router.macAddress,
      ipAddress: router.ipAddress,
      priority: router.priority,
      isTrusted: router.isTrusted,
      lastSeen: router.lastSeen,
      rssi: router.rssi,
      hasInternet: router.hasInternet,
      isOpen: router.isOpen,
      useAsRelay: router.useAsRelay,
    );
  }

  /// Удаляет роутер из БД и пароль из SecureStorage
  Future<void> removeRouter(String routerId) async {
    final db = await _db.database;
    
    // Получаем SSID перед удалением
    final List<Map<String, dynamic>> maps = await db.query(
      'known_routers',
      where: 'id = ?',
      whereArgs: [routerId],
      limit: 1,
    );

    if (maps.isNotEmpty) {
      final ssid = maps.first['ssid'] as String;
      // Удаляем пароль из SecureStorage
      final storage = const FlutterSecureStorage();
      await storage.delete(key: 'router_password_$ssid');
    }

    // Удаляем из БД
    await db.delete('known_routers', where: 'id = ?', whereArgs: [routerId]);
  }

  /// Обновляет информацию о роутере
  Future<void> updateRouter(RouterInfo router) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update(
      'known_routers',
      {
        'ssid': router.ssid,
        'mac_address': router.macAddress,
        'ip_address': router.ipAddress,
        'priority': router.priority,
        'is_trusted': router.isTrusted ? 1 : 0,
        'last_seen': router.lastSeen?.millisecondsSinceEpoch ?? now,
        'rssi': router.rssi,
        'has_internet': router.hasInternet ? 1 : 0,
        'is_open': router.isOpen ? 1 : 0,
        'use_as_relay': router.useAsRelay ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [router.id],
    );

    // Обновляем пароль в SecureStorage (если изменился)
    if (router.password != null && router.password!.isNotEmpty) {
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'router_password_${router.ssid}', value: router.password);
    }
  }
}
