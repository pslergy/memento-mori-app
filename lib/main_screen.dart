import 'package:flutter/material.dart';
 // 🔥 Импорт встряски
import 'package:memento_mori_app/core/panic_service.dart';
import 'package:memento_mori_app/features/chat/chat_list_screen.dart';
import 'package:memento_mori_app/timer_screen.dart';
import 'package:memento_mori_app/features/settings/mesh_control_screen.dart';

import 'core/api_service.dart';
import 'core/local_db_service.dart';
import 'core/locator.dart';
import 'core/models/ad_packet.dart';
import 'core/shake_detector.dart';
import 'features/ads/tactical_banner.dart';



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

  // 🔥 Используем наш новый детектор
  late TacticalShakeDetector _shakeDetector;

  @override
  void initState() {
    super.initState();

    // 🔥 Инициализация встряски
    _shakeDetector = TacticalShakeDetector(
      onShake: () {
        print("☢️ [PANIC] Manual shake detected! Executing Wipe...");
        PanicService.killSwitch(context);
      },
    );
    _shakeDetector.start();
    _loadInitialData();

    _widgetOptions = <Widget>[
      TimerScreen(deathDate: widget.deathDate, birthDate: widget.birthDate),
      const ChatListScreen(),
      const ChannelsPlaceholderScreen(),
      const MeshControlScreen(),
    ];
  }
  void _loadInitialData() async {
    final api = locator<ApiService>();
    // Пробуем скачать рекламу (если есть интернет)
    await api.syncAdsFromServer();

    // После загрузки проверяем, нужно ли показать баннер
    _checkAndShowAds();
  }

  void _checkAndShowAds() async {
    try {
      final api = locator<ApiService>();
      final db = LocalDatabaseService();

      // Используем безопасный вызов профиля
      final profile = await api.getMe();
      bool isPro = profile['isPro'] == true;

      if (!isPro) {
        final List<AdPacket> ads = await db.getActiveAds();
        // Пытаемся найти баннер, если нет - просто выходим без ошибки
        final bannerAd = ads.where((a) => a.isInterstitial).firstOrNull;

        if (bannerAd != null && mounted) {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => TacticalBanner(ad: bannerAd, onClose: () => Navigator.pop(context)),
          );
        }
      }
    } catch (e) {
      print("ℹ️ Ads system hibernated: No signal or no ads.");
    }
  }

  @override
  void dispose() {
    _shakeDetector.stop(); // Остановка слушателя
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: _widgetOptions.elementAt(_selectedIndex)),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.hourglass_bottom), label: 'MEMENTO'),
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline), label: 'COMMS'),
          BottomNavigationBarItem(icon: Icon(Icons.campaign), label: 'CHANNELS'),
          BottomNavigationBarItem(icon: Icon(Icons.hub), label: 'THE CHAIN'),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        backgroundColor: const Color(0xFF0A0A0A),
        selectedItemColor: Colors.redAccent,
        unselectedItemColor: Colors.grey[800],
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}

// Заглушка (без изменений)
class ChannelsPlaceholderScreen extends StatelessWidget {
  const ChannelsPlaceholderScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 60, color: Colors.grey),
            SizedBox(height: 20),
            Text("NO SIGNAL", style: TextStyle(color: Colors.white, letterSpacing: 2)),
          ],
        ),
      ),
    );
  }
}