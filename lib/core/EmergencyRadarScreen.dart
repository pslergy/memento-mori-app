import 'dart:async';
import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';

import 'package:memento_mori_app/core/websocket_service.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/location_name_service.dart';

import '../features/theme/app_colors.dart';

class EmergencyRadarScreen extends StatefulWidget {
  const EmergencyRadarScreen({super.key});

  @override
  State<EmergencyRadarScreen> createState() => _EmergencyRadarScreenState();
}

class _EmergencyRadarScreenState extends State<EmergencyRadarScreen> {
  final List<Map<String, dynamic>> _hotZones = [];
  StreamSubscription? _wsSubscription;

  @override
  void initState() {
    super.initState();
    _loadInitialZones();

    // Слушаем живые обновления от сервера
    _wsSubscription = WebSocketService().stream.listen((payload) {
      if (payload['type'] == 'MASS_EMERGENCY') {
        _handleNewAlert(payload['data']);
      }
    });
  }

  Future<void> _loadInitialZones() async {
    // Загружаем зоны из локальной БД (оффлайн) и с сервера (онлайн)
    final db = LocalDatabaseService();
    final locationService = LocationNameService();

    try {
      // Загружаем агрегированные SOS сигналы из локальной БД
      final localZones = await db.getAggregatedSosSignals();
      
      // Обновляем названия мест для зон, где их еще нет
      for (var zone in localZones) {
        if (zone['locationName'] == null && zone['sectorId'] != null) {
          final locationName = await locationService.getLocationNameFromSectorId(zone['sectorId'] as String);
          if (locationName != null) {
            zone['locationName'] = locationName;
          }
        }
      }

      if (mounted) {
        setState(() {
          _hotZones.clear();
          _hotZones.addAll(localZones);
        });
      }
    } catch (e) {
      print("⚠️ [EmergencyRadar] Failed to load initial zones: $e");
    }

    // Пытаемся загрузить с сервера (если есть интернет)
    try {
      // TODO: Добавить GET /api/emergency/active в ApiService
      // final api = locator<ApiService>();
      // final serverZones = await api.getActiveEmergencyZones();
      // Объединяем с локальными зонами
    } catch (e) {
      print("⚠️ [EmergencyRadar] Server sync failed (offline mode): $e");
    }
  }

  void _handleNewAlert(Map<String, dynamic> alert) {
    if (!mounted) return;
    setState(() {
      // Если зона уже есть — обновляем, если нет — добавляем в начало
      int index = _hotZones.indexWhere((z) => z['sectorId'] == alert['sectorId']);
      if (index != -1) {
        _hotZones[index] = alert;
      } else {
        _hotZones.insert(0, alert);
      }
    });
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildRadarHeader(),
          Expanded(
            child: _hotZones.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
              padding: const EdgeInsets.all(15),
              itemCount: _hotZones.length,
              itemBuilder: (context, i) => _buildEmergencyCard(_hotZones[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 15),
      color: AppColors.surface,
      child: Row(
        children: [
          const Icon(Icons.satellite_alt,
              color: AppColors.warningRed, size: 20),
          const SizedBox(width: 12),

          // ✅ FIX OVERFLOW
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                "GRID INTELLIGENCE // HOT ZONES",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),

          const SizedBox(width: 8),
          _buildLiveIndicator(),
        ],
      ),
    );
  }


  Widget _buildEmergencyCard(Map<String, dynamic> zone) {
    bool isCritical = (zone['count'] ?? 0) >= 20;

    return FadeInUp(
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
              color: isCritical ? AppColors.warningRed : AppColors.stealthOrange.withOpacity(0.5),
              width: isCritical ? 1.5 : 0.5
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 🔥 РЕШЕНИЕ OVERFLOW: FittedBox + Expanded
                    SizedBox(
                      width: double.infinity,
                      height: 30, // Жестко ограничиваем высоту заголовка
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: FittedBox(
                              alignment: Alignment.centerLeft,
                              fit: BoxFit.scaleDown, // Сжимает текст, если он не лезет
                              child: Text(
                                zone['locationName'] ?? zone['sectorId'] ?? "UNKNOWN_SECTOR",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _buildIntensityBadge(isCritical ? "CRITICAL" : "ACTIVE"),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Grid integrity compromised. Detected ${zone['count']} SOS signal(s) in this sector.",
                      style: TextStyle(color: AppColors.textDim, fontSize: 10, height: 1.3),
                    ),
                    if (zone['sectorId'] != null && zone['locationName'] == null) ...[
                      const SizedBox(height: 4),
                      Text(
                        "Sector: ${zone['sectorId']}",
                        style: TextStyle(color: AppColors.textDim.withOpacity(0.6), fontSize: 8),
                      ),
                    ],
                    const SizedBox(height: 15),
                    _buildCardActions(zone['sectorId']),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 🔥 Оптимизированный бейдж (минимальный размер)
  Widget _buildIntensityBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warningRed.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: AppColors.warningRed,
            fontSize: 8,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5
        ),
      ),
    );
  }

  Widget _buildCardActions(String sectorId) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.white05, foregroundColor: Colors.white),
            onPressed: () => _showLocationDetails(sectorId),
            icon: const Icon(Icons.map_outlined, size: 14),
            label: const Text(
              "VIEW AREA",
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.warningRed, foregroundColor: Colors.black),
            onPressed: () {
              // Логика переключения Gossip-менеджера в режим приоритета для этой зоны
            },
            icon: const Icon(Icons.wifi_tethering, size: 14),
            label: const Text(
              "JOIN RESCUE",
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
          ),
        ),
      ],
    );
  }



  Widget _buildLiveIndicator() {
    return Row(
      children: [
        Pulse(
          infinite: true,
          child: Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: AppColors.cloudGreen,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          "LIVE FEED",
          style: TextStyle(
            color: AppColors.cloudGreen,
            fontSize: 8,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 50, color: AppColors.textMuted),
          const SizedBox(height: 20),
          const Text(
            "ALL SECTORS CLEAR",
            style: TextStyle(
              color: AppColors.textDim,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const Text(
            "No mass emergency signals detected on the global grid.",
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textDim, fontSize: 10),
          ),
        ],
      ),
    );
  }

  /// Показывает детали локации с кодировкой 1x1 км
  Future<void> _showLocationDetails(String sectorId) async {
    final locationService = LocationNameService();
    String? locationName;
    
    // Пытаемся получить название локации
    try {
      locationName = await locationService.getLocationNameFromSectorId(sectorId);
    } catch (e) {
      print("⚠️ [EmergencyRadar] Failed to get location name: $e");
    }

    // Парсим sectorId для отображения координат
    String coordinates = "Unknown";
    try {
      final parts = sectorId.replaceFirst('S_', '').split('_');
      if (parts.length == 2) {
        final latStr = parts[0];
        final lonStr = parts[1];
        
        // Восстанавливаем координаты (формат: 6412 -> 64.12)
        if (latStr.length >= 4 && lonStr.length >= 4) {
          final lat = double.parse('${latStr.substring(0, latStr.length - 2)}.${latStr.substring(latStr.length - 2)}');
          final lon = double.parse('${lonStr.substring(0, lonStr.length - 2)}.${lonStr.substring(lonStr.length - 2)}');
          
          // Огрубляем до 1x1 км (2 знака после запятой = ~1.1 км)
          final blurredLat = lat.toStringAsFixed(2);
          final blurredLon = lon.toStringAsFixed(2);
          coordinates = "$blurredLat, $blurredLon";
        }
      }
    } catch (e) {
      print("⚠️ [EmergencyRadar] Failed to parse sectorId: $e");
    }

    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          "LOCATION DETAILS",
          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (locationName != null) ...[
              Text(
                "Location:",
                style: TextStyle(color: AppColors.textDim, fontSize: 10),
              ),
              const SizedBox(height: 4),
              Text(
                locationName,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              "Coordinates (1x1 km zone):",
              style: TextStyle(color: AppColors.textDim, fontSize: 10),
            ),
            const SizedBox(height: 4),
            Text(
              coordinates,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'RobotoMono'),
            ),
            const SizedBox(height: 8),
            Text(
              "Sector ID:",
              style: TextStyle(color: AppColors.textDim, fontSize: 10),
            ),
            const SizedBox(height: 4),
            Text(
              sectorId,
              style: const TextStyle(color: AppColors.textDim, fontSize: 10, fontFamily: 'RobotoMono'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CLOSE", style: TextStyle(color: AppColors.warningRed)),
          ),
        ],
      ),
    );
  }
}