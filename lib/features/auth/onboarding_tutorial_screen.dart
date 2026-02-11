import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui/terminal_style.dart';
import '../theme/app_colors.dart';
import '../../core/decoy/gate_storage.dart';
import '../../core/decoy/mode_resolver.dart';
import '../../core/decoy/app_mode.dart';
import '../../warning_screen.dart';
import '../../features/camouflage/calculator_gate.dart';

/// 📚 Onboarding Tutorial Screen
/// Brief tutorial after registration explaining BRIDGE/GHOST and mesh network
class OnboardingTutorialScreen extends StatefulWidget {
  final Map<String, dynamic>? userData;

  const OnboardingTutorialScreen({
    super.key,
    this.userData,
  });

  @override
  State<OnboardingTutorialScreen> createState() => _OnboardingTutorialScreenState();
}

class _OnboardingTutorialScreenState extends State<OnboardingTutorialScreen> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  final List<Map<String, dynamic>> _tutorialPages = [
    {
      'title': 'BRIDGE & GHOST',
      'content': '''BRIDGE devices have internet access and relay messages to the cloud.

GHOST devices work offline using mesh network to communicate with nearby devices.

Your device can switch between these roles automatically based on connectivity.''',
      'icon': Icons.devices,
      'color': Colors.cyanAccent,
    },
    {
      'title': 'MESH NETWORK',
      'content': '''Messages travel through nearby devices using:
• Bluetooth (BLE) - short range
• Wi-Fi Direct - medium range
• Sonar (ultrasonic) - last resort

Devices automatically find the best path to deliver your messages.''',
      'icon': Icons.network_check,
      'color': Colors.greenAccent,
    },
    {
      'title': 'SENDING MESSAGES',
      'content': '''1. Open a chat
2. Type your message
3. Tap send

Messages are automatically routed through the mesh network. If internet is available, they sync to the cloud.''',
      'icon': Icons.send,
      'color': Colors.yellowAccent,
    },
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _tutorialPages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _completeTutorial();
    }
  }

  void _skipTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tutorial_completed', true);
    if (!mounted) return;
    await _ensureGateCodesSet();
    if (!mounted) return;
    _navigateToMain();
  }

  void _completeTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tutorial_completed', true);
    if (!mounted) return;
    await _ensureGateCodesSet();
    if (!mounted) return;
    _navigateToMain();
  }

  /// Задаёт коды доступа калькулятора, если ещё не заданы (чтобы 3301 открывал приложение, а не Grid Access).
  Future<void> _ensureGateCodesSet() async {
    final hasHashes = await hasGateHashes();
    if (hasHashes) return;
    final primary = hashAccessCode('3301');
    final alternative = hashAccessCode('0000');
    await saveGateHashes(primary, alternative);
    await saveGateMode(AppMode.REAL);
  }

  void _navigateToMain() {
    if (widget.userData != null) {
      final deathDateStr = widget.userData!['deathDate'];
      final birthDateStr = widget.userData!['dateOfBirth'];
      if (deathDateStr != null && birthDateStr != null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => WarningScreen(
              deathDate: DateTime.parse(deathDateStr),
              birthDate: DateTime.parse(birthDateStr),
            ),
          ),
          (_) => false,
        );
        return;
      }
    }
    // После онбординга — сразу камуфляж (калькулятор). Не переходим на Splash:
    // Splash вызывает setupCoreLocator() → locator.reset() → новый Vault, и чтение auth_token даёт null.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const CalculatorGate()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextButton(
                  onPressed: _skipTutorial,
                  child: const TerminalText('SKIP', color: Colors.white54),
                ),
              ),
            ),

            // Tutorial content
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemCount: _tutorialPages.length,
                itemBuilder: (context, index) {
                  final page = _tutorialPages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          page['icon'] as IconData,
                          size: 80,
                          color: page['color'] as Color,
                        ),
                        const SizedBox(height: 32),
                        TerminalTitle(
                          page['title'] as String,
                          color: page['color'] as Color,
                        ),
                        const SizedBox(height: 24),
                        TerminalText(
                          page['content'] as String,
                          color: Colors.white70,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // Page indicator
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _tutorialPages.length,
                  (index) => Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index == _currentPage
                          ? Colors.greenAccent
                          : Colors.white24,
                    ),
                  ),
                ),
              ),
            ),

            // Next/Complete button
            Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: _nextPage,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: TerminalText(
                  _currentPage < _tutorialPages.length - 1 ? 'NEXT' : 'GET STARTED',
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
