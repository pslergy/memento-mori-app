import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animate_do/animate_do.dart';

import 'package:memento_mori_app/core/websocket_service.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/locator.dart';

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
    // В ApiService нужно будет добавить GET /api/emergency/active
    // Пока сделаем имитацию или пустой список
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
                style: GoogleFonts.russoOne(
                  color: Colors.white,
                  fontSize: 12,
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
                                zone['sectorId'] ?? "UNKNOWN_SECTOR",
                                style: GoogleFonts.robotoMono(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14
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
                      "Grid integrity compromised. Detected ${zone['count']} pulses in this sector.",
                      style: TextStyle(color: AppColors.textDim, fontSize: 10, height: 1.3),
                    ),
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
            onPressed: () {}, // Переход к карте (если будет)
            icon: const Icon(Icons.map_outlined, size: 14),
            label: Text("VIEW AREA", style: GoogleFonts.russoOne(fontSize: 10)),
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
            label: Text("JOIN RESCUE", style: GoogleFonts.russoOne(fontSize: 10)),
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
          child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.cloudGreen, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 6),
        Text("LIVE FEED", style: GoogleFonts.robotoMono(color: AppColors.cloudGreen, fontSize: 8, fontWeight: FontWeight.bold)),
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
          Text("ALL SECTORS CLEAR", style: GoogleFonts.russoOne(color: AppColors.textDim, fontSize: 14)),
          Text("No mass emergency signals detected on the global grid.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textDim, fontSize: 10)),
        ],
      ),
    );
  }
}