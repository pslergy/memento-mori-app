import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:animate_do/animate_do.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/decoy/app_mode.dart';
import 'package:memento_mori_app/core/decoy/vault_interface.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/decoy/timed_panic_lifecycle_bridge.dart'
    show startTimedPanicAfterLogin;
import 'package:memento_mori_app/core/panic_service.dart';
import 'package:memento_mori_app/core/shake_detector.dart';

import 'package:memento_mori_app/core/models/ad_packet.dart';
import 'package:memento_mori_app/timer_screen.dart';
import 'package:memento_mori_app/features/chat/chat_list_screen.dart';
import 'package:memento_mori_app/features/settings/mesh_control_screen.dart';
import 'package:memento_mori_app/features/ads/tactical_banner.dart';

import 'core/EmergencyRadarScreen.dart';
import 'features/theme/app_colors.dart';
import 'features/ui/sonar_overlay.dart';

class MainScreen extends StatefulWidget {
  final DateTime deathDate;
  final DateTime birthDate;

  const MainScreen({
    super.key,
    required this.deathDate,
    required this.birthDate,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  late final List<Widget> _widgetOptions;
  late TacticalShakeDetector _shakeDetector;
  StreamSubscription? _linkSubscription;
  String _appVersion = '—';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = 'v${info.version}+${info.buildNumber}');
    });

    // Ensure SESSION (MeshService, etc.) is registered — do not reset when only MeshService was missing.
    if (!locator.isRegistered<MeshService>()) {
      if (!locator.isRegistered<VaultInterface>()) {
        setupCoreLocator(AppMode.REAL);
      }
      setupSessionLocator(AppMode.REAL);
    }
    if (!locator.isRegistered<MeshService>()) {
      logMissingFor('MainScreen', requireMesh: true);
    }

    // 1. Инициализация ПАНИК-детектора (встряска)
    _shakeDetector = TacticalShakeDetector(
      onShake: () {
        print("☢️ [PANIC] Manual shake detected! Executing Wipe...");
        PanicService.killSwitch(context);
      },
    );
    _shakeDetector.start();

    // 2. Слушатель входящих запросов на связь через Сонар (только если Mesh зарегистрирован)
    if (locator.isRegistered<MeshService>()) {
      _linkSubscription =
          locator<MeshService>().linkRequestStream.listen((senderId) {
        _showTacticalLinkDialog(senderId);
        SonarOverlay.show(context, senderId);
      });
    }

    _loadInitialData();

    startTimedPanicAfterLogin();

    _widgetOptions = <Widget>[
      TimerScreen(deathDate: widget.deathDate, birthDate: widget.birthDate),
      const ChatListScreen(),
      const EmergencyRadarScreen(),
      const MeshControlScreen(),
    ];
  }

  void _showTacticalLinkDialog(String senderId) {
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => FadeInUp(
        duration: const Duration(milliseconds: 300),
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
                color: AppColors.sonarPurple.withOpacity(0.5), width: 1),
          ),
          title: Row(
            children: [
              const Icon(Icons.record_voice_over, color: AppColors.sonarPurple),
              const SizedBox(width: 12),
              const Text(
                "INCOMING SONAR LINK",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          content: Text(
            "Nomad #$senderId is nearby and requesting a secure Wi-Fi Bridge. Establish trust?",
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("IGNORE",
                  style: TextStyle(color: AppColors.warningRed)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gridCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _establishSecureLink(senderId);
              },
              child: const Text("ACCEPT LINK",
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _loadInitialData() async {
    final api = locator<ApiService>();
    // Пробуем скачать рекламу (если есть интернет)
    await api.syncAdsFromServer();
    _checkAndShowAds();
  }

  // 🔥 UI МЕТОД: Подтверждение связи через Сонар
  void _showLinkConfirmation(String senderId) {
    HapticFeedback.heavyImpact(); // Сильная вибрация: "Вас вызывают!"

    showDialog(
      context: context,
      barrierDismissible: false, // Пользователь обязан принять решение
      builder: (ctx) => FadeInUp(
        duration: const Duration(milliseconds: 300),
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.gridCyan, width: 0.5),
          ),
          title: Row(
            children: [
              const Icon(Icons.record_voice_over, color: AppColors.sonarPurple),
              const SizedBox(width: 10),
              const Text(
                "SIGNAL CAPTURED",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          content: Text(
            "Nomad #$senderId is requesting a secure P2P link via Sonar pulse. Establish trust?",
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("ABORT",
                  style: TextStyle(color: AppColors.warningRed)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gridCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _establishSecureLink(senderId);
              },
              child: const Text("ESTABLISH",
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _establishSecureLink(String targetId) async {
    if (!locator.isRegistered<MeshService>()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text("Handshaking... Connecting to grid."),
          backgroundColor: AppColors.gridCyan),
    );
    await locator<MeshService>().connectToNode(targetId);
  }

  void _checkAndShowAds() async {
    try {
      final api = locator<ApiService>();
      final db = LocalDatabaseService();
      final profile = await api.getMe();
      bool isPro = profile['isPro'] == true;

      if (!isPro) {
        final List<AdPacket> ads = await db.getActiveAds();
        final bannerAd = ads.where((a) => a.isInterstitial).firstOrNull;
        if (bannerAd != null && mounted) {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => TacticalBanner(
                ad: bannerAd, onClose: () => Navigator.pop(context)),
          );
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _shakeDetector.stop();
    _linkSubscription?.cancel(); // Критично для предотвращения утечек
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // Вставляем Tactical HUD в AppBar или сразу под него
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(45),
        child: _buildTacticalHUD(),
      ),
      body: _widgetOptions.elementAt(_selectedIndex),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
              icon: Icon(Icons.hourglass_bottom), label: 'MEMENTO'),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline), label: 'COMMS'),
          BottomNavigationBarItem(
              icon: Icon(Icons.warning_amber_rounded), label: 'HOT ZONES'),
          BottomNavigationBarItem(icon: Icon(Icons.hub), label: 'THE CHAIN'),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        backgroundColor: AppColors.surface,
        selectedItemColor: AppColors.warningRed,
        unselectedItemColor: AppColors.textDim,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: const TextStyle(
            fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.1),
        unselectedLabelStyle: const TextStyle(fontSize: 9, letterSpacing: 1.0),
      ),
    );
  }

  // 🔥 ВИДЖЕТ ТАКТИЧЕСКОГО HUD (Вверху экрана)
  Widget _buildTacticalHUD() {
    if (!locator.isRegistered<MeshService>()) {
      return Container(
        color: AppColors.surface,
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(width: 24),
            Expanded(
              child: Center(
                child: Text('MODE: STEALTH',
                    style: TextStyle(
                        color: AppColors.stealthOrange.withOpacity(0.8),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(_appVersion,
                  style: TextStyle(
                      fontFamily: 'RobotoMono',
                      color: AppColors.stealthOrange.withOpacity(0.6),
                      fontSize: 9,
                      letterSpacing: 0.5)),
            ),
          ],
        ),
      );
    }
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final bool isOnline = snapshot.data == MeshRole.BRIDGE;
        final mesh = context.watch<MeshService>();

        Color themeColor = isOnline
            ? AppColors.cloudGreen
            : (mesh.isP2pConnected
                ? AppColors.gridCyan
                : AppColors.stealthOrange);
        String label = isOnline
            ? "UPLINK: SECURED"
            : (mesh.isP2pConnected ? "GRID: ACTIVE (P2P)" : "MODE: STEALTH");

        return Container(
          color: AppColors.surface,
          padding: const EdgeInsets.only(top: 10),
          child: Container(
            decoration: BoxDecoration(
              color: themeColor.withOpacity(0.05),
              border: Border(
                  bottom: BorderSide(
                      color: themeColor.withOpacity(0.3), width: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(width: 24),
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PulseIcon(color: themeColor),
                        const SizedBox(width: 8),
                        Text(label,
                            style: TextStyle(
                                fontFamily: 'RobotoMono',
                                color: themeColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1)),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(_appVersion,
                      style: TextStyle(
                          fontFamily: 'RobotoMono',
                          color: themeColor.withOpacity(0.7),
                          fontSize: 9,
                          letterSpacing: 0.5)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Вспомогательный виджет пульсации
class _PulseIcon extends StatefulWidget {
  final Color color;
  const _PulseIcon({required this.color});
  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(color: widget.color, blurRadius: 4 * _c.value + 2)
            ]),
      ),
    );
  }
}
