import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../features/ui/terminal_style.dart';
import '../features/theme/app_colors.dart';
import 'mesh_permission_screen.dart';

/// 📋 Permissions Explanation Screen
/// Explains why each permission is needed before requesting them
class PermissionsExplanationScreen extends StatefulWidget {
  const PermissionsExplanationScreen({super.key});

  @override
  State<PermissionsExplanationScreen> createState() => _PermissionsExplanationScreenState();
}

class _PermissionsExplanationScreenState extends State<PermissionsExplanationScreen> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  final List<Map<String, dynamic>> _permissionPages = [
    {
      'title': 'BLUETOOTH',
      'icon': Icons.bluetooth,
      'color': Colors.blueAccent,
      'description': 'Required for mesh network',
      'details': 'Allows your device to connect to nearby GHOST and BRIDGE devices using Bluetooth Low Energy (BLE). This enables offline communication when internet is unavailable.',
      'why': 'Without Bluetooth, you cannot participate in the mesh network and messages cannot be delivered offline.',
    },
    {
      'title': 'LOCATION',
      'icon': Icons.location_on,
      'color': Colors.greenAccent,
      'description': 'For emergency SOS signals',
      'details': 'Used only for emergency SOS signals. Your location is blurred to 1x1 km zones for privacy. Precise coordinates are never shared.',
      'why': 'SOS signals help others find you in emergencies. Location is only used when you explicitly send an SOS signal.',
    },
    {
      'title': 'MICROPHONE',
      'icon': Icons.mic,
      'color': Colors.purpleAccent,
      'description': 'Ultrasonic communication (last resort)',
      'details': 'Used for Sonar protocol - ultrasonic communication at 18-20 kHz. This is a last-resort method when Bluetooth and Wi-Fi are unavailable.',
      'why': 'Sonar allows communication in radio-silent environments or when other methods fail. Audio is only used for data transmission, not recording.',
    },
  ];

  @override
  void initState() {
    super.initState();
    // 🔥 FIX: Скрываем системную навигацию для полноэкранного режима
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
  }

  @override
  void dispose() {
    // Восстанавливаем системную навигацию при выходе
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _permissionPages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _proceedToPermissions();
    }
  }

  void _skip() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const TerminalTitle('Skip Permissions?', color: Colors.redAccent),
        content: const TerminalText(
          'Without these permissions, the mesh network will not work. You will not be able to send or receive messages offline.',
          color: Colors.white70,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const TerminalText('Cancel', color: Colors.white54),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _proceedToPermissions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const TerminalText('Skip Anyway', color: Colors.white),
          ),
        ],
      ),
    );
  }

  void _proceedToPermissions() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MeshPermissionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header with progress
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TerminalText(
                    'Step ${_currentPage + 1}/${_permissionPages.length + 1}: Permissions',
                    color: Colors.white54,
                  ),
                  TextButton(
                    onPressed: _skip,
                    child: const TerminalText('SKIP', color: Colors.white54),
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemCount: _permissionPages.length,
                itemBuilder: (context, index) {
                  final page = _permissionPages[index];
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
                        const SizedBox(height: 8),
                        TerminalSubtitle(
                          page['description'] as String,
                        ),
                        const SizedBox(height: 24),
                        TerminalInfoBox(
                          title: 'What it does:',
                          content: page['details'] as String,
                          icon: Icons.info_outline,
                          color: page['color'] as Color,
                        ),
                        const SizedBox(height: 16),
                        TerminalInfoBox(
                          title: 'Why it\'s needed:',
                          content: page['why'] as String,
                          icon: Icons.help_outline,
                          color: Colors.yellowAccent,
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
                  _permissionPages.length,
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

            // Next button
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
                  _currentPage < _permissionPages.length - 1 ? 'NEXT' : 'GRANT PERMISSIONS',
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
