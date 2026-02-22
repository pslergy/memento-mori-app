import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:animate_do/animate_do.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/decoy/mode_exit_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/security_service.dart';
import 'package:memento_mori_app/core/storage_service.dart';

import 'package:memento_mori_app/features/camouflage/calculator_gate.dart';
import 'package:memento_mori_app/ghost_input/ghost_controller.dart';
import 'package:memento_mori_app/ghost_input/ghost_keyboard.dart';
import 'package:memento_mori_app/l10n/app_localizations.dart';

import '../auth/change_access_codes_screen.dart';
import '../settings/mesh_control_screen.dart';
import '../theme/app_colors.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ApiService? _apiService;
  late Future<Map<String, dynamic>> _userFuture;
  bool _isLegalizing = false;

  static Future<Map<String, dynamic>> _loadGhostProfile() async {
    final id = await Vault.read('user_id');
    final name = await Vault.read('user_name');
    return {
      'id': id ?? 'GHOST',
      'username': name ?? 'Ghost',
      'isGhost': true,
      'createdAt': DateTime.now().toIso8601String(),
    };
  }

  @override
  void initState() {
    super.initState();
    _apiService =
        locator.isRegistered<ApiService>() ? locator<ApiService>() : null;
    _userFuture =
        _apiService != null ? _apiService!.getMe() : _loadGhostProfile();
  }

  // --- ЛОГИКА ВЫХОДА (Mode Exit + process exit; no return to login in same process) ---
  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.gridCyan),
              SizedBox(height: 16),
              Text(
                'Logging out…',
                style: TextStyle(color: AppColors.textDim, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 1500));
    if (_apiService != null) await _apiService!.logout();
    await ModeExitService.performExit();
    if (!mounted) return;
    Navigator.of(context).pop();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const CalculatorGate()),
      (route) => false,
    );
  }

  // --- ЛОГИКА ЛЕГАЛИЗАЦИИ (GHOST -> CITIZEN) ---
  void _showLegalizeDialog(BuildContext context) {
    if (_apiService == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cloud not available. Connect to network to legalize.'),
      ));
      return;
    }
    final usernameGhost = GhostController()
      ..add(_apiService!.currentUserId.split('_').last);
    final passwordGhost = GhostController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "IDENTITY LEGALIZATION",
                style: TextStyle(
                  color: AppColors.gridCyan,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                  "Connect your Ghost Identity to a permanent Cloud account.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              const SizedBox(height: 25),
              _buildSimpleInput(
                  usernameGhost, "DESIRED CALLSIGN", Icons.person),
              const SizedBox(height: 15),
              _buildSimpleInput(
                  passwordGhost, "SECURITY CIPHER (PASSWORD)", Icons.lock,
                  isPass: true),
              const SizedBox(height: 30),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gridCyan,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 55),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isLegalizing
                    ? null
                    : () async {
                        setState(() => _isLegalizing = true);
                        try {
                          await _apiService!.legalizeIdentity(
                              usernameGhost.value, passwordGhost.value);
                          if (mounted && _apiService != null) {
                            Navigator.pop(ctx);
                            setState(() {
                              _userFuture = _apiService!.getMe();
                            }); // Обновляем профиль
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(e.toString()),
                              backgroundColor: AppColors.warningRed));
                        } finally {
                          setState(() => _isLegalizing = false);
                        }
                      },
                child: _isLegalizing
                    ? const CircularProgressIndicator(color: Colors.black)
                    : const Text(
                        "EXECUTE UPLINK",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
              ),
              const SizedBox(height: 15),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = NetworkMonitor().currentRole == MeshRole.BRIDGE;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'IDENTITY_CORE',
          style: TextStyle(
            letterSpacing: 2,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _userFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppColors.gridCyan));
          }

          final user =
              snapshot.data ?? {'username': 'Nomad', 'id': 'LOCAL_NODE'};
          final createdAt =
              DateTime.tryParse(user['createdAt']?.toString() ?? '') ??
                  DateTime.now();
          final bool isGhost =
              _apiService?.isGhostMode ?? (user['isGhost'] == true);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              children: [
                // --- АВАТАР И СТАТУС ---
                _buildProfileHeader(user, createdAt, isGhost),

                const SizedBox(height: 30),

                // --- КНОПКА ЛЕГАЛИЗАЦИИ (Только для призраков онлайн) ---
                if (isGhost && isOnline)
                  FadeInDown(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _buildLegalizeButton(),
                    ),
                  ),

                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text("OPERATIONS",
                      style: TextStyle(
                          color: AppColors.textDim,
                          fontSize: 10,
                          letterSpacing: 2)),
                ),
                const SizedBox(height: 10),

                _MenuTile(
                  icon: Icons.wifi_tethering,
                  color: AppColors.gridCyan,
                  title: "The Chain (Mesh Net)",
                  subtitle: "Offline P2P Management",
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const MeshControlScreen())),
                ),
                const SizedBox(height: 10),
                _MenuTile(
                  icon: Icons.theater_comedy,
                  color: AppColors.stealthOrange,
                  title: "Visual Identity",
                  subtitle: "Change app camouflage",
                  onTap: () => _showCamouflageDialog(context),
                ),
                const SizedBox(height: 10),
                _MenuTile(
                  icon: Icons.pin,
                  color: AppColors.cloudGreen,
                  title: "Access Codes",
                  subtitle: "Change calculator gate codes",
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ChangeAccessCodesScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _MenuTile(
                  icon: Icons.logout,
                  color: Colors.white,
                  title: "Logout",
                  subtitle: "De-authorize this node",
                  onTap: _logout,
                ),

                const SizedBox(height: 40),

                // --- DANGER ZONE ---
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text("DANGER ZONE",
                      style: TextStyle(
                          color: AppColors.warningRed,
                          fontSize: 10,
                          letterSpacing: 2)),
                ),
                const SizedBox(height: 10),
                _buildNukeCard(),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showCamouflageDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.of(context)!.identityMaskingTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppLocalizations.of(context)!.identityMaskingSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
              const SizedBox(height: 25),
            _buildMaskTile(
              context: context,
              icon: Icons.calculate,
              titleKey: "Calculator",
              onTap: () {
                SecurityService.changeIcon("Calculator");
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
            _buildMaskTile(
              context: context,
              icon: Icons.notes,
              titleKey: "Notes",
              onTap: () {
                SecurityService.changeIcon("Notes");
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
            _buildMaskTile(
              context: context,
              icon: Icons.calendar_today,
              titleKey: "Calendar",
              onTap: () {
                SecurityService.changeIcon("Calendar");
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
            _buildMaskTile(
              context: context,
              icon: Icons.access_time,
              titleKey: "Clock",
              onTap: () {
                SecurityService.changeIcon("Clock");
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
            _buildMaskTile(
              context: context,
              icon: Icons.photo_library_outlined,
              titleKey: "Gallery",
              onTap: () {
                SecurityService.changeIcon("Gallery");
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
            _buildMaskTile(
              context: context,
              icon: Icons.folder_outlined,
              titleKey: "Files",
              onTap: () {
                SecurityService.changeIcon("Files");
                Navigator.pop(context);
              },
            ),
              const SizedBox(height: 20),
              Text(
                AppLocalizations.of(context)!.identityMaskingNote,
                style: TextStyle(
                  color: AppColors.warningRed.withOpacity(0.7),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMaskTile({
    required BuildContext context,
    required IconData icon,
    required String titleKey,
    required VoidCallback onTap,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final String title = switch (titleKey) {
      'Calculator' => l10n.appNameCalculator,
      'Notes' => l10n.appNameNotes,
      'Calendar' => l10n.appNameCalendar,
      'Clock' => l10n.appNameClock,
      'Gallery' => l10n.appNameGallery,
      'Files' => l10n.appNameFiles,
      _ => titleKey,
    };
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: Colors.white),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold)),
      trailing: const Icon(Icons.swap_horiz, color: AppColors.textDim),
      tileColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  // --- ВСПОМОГАТЕЛЬНЫЕ ВИДЖЕТЫ ---

  Widget _buildProfileHeader(
      Map<String, dynamic> user, DateTime createdAt, bool isGhost) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: isGhost
                ? AppColors.stealthOrange.withOpacity(0.3)
                : AppColors.gridCyan.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              CircleAvatar(
                radius: 45,
                backgroundColor: AppColors.background,
                child: Text(user['username']?[0].toUpperCase() ?? 'N',
                    style: const TextStyle(
                        fontSize: 32,
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
              _Badge(
                text: isGhost ? "GHOST" : "VERIFIED",
                color: isGhost ? AppColors.stealthOrange : AppColors.cloudGreen,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            user['username'] ?? 'Nomad',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            user['id'] ?? '',
            style: const TextStyle(
              color: AppColors.textDim,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 15),
          Text(
              "ACTIVE SINCE ${createdAt.year}.${createdAt.month}.${createdAt.day}",
              style: const TextStyle(
                  color: AppColors.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildLegalizeButton() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: AppColors.gridCyan.withOpacity(0.2), blurRadius: 20)
        ],
      ),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.gridCyan,
          foregroundColor: Colors.black,
          minimumSize: const Size(double.infinity, 55),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        ),
        icon: const Icon(Icons.verified_user_outlined),
        label: const Text(
          "LEGALIZE IDENTITY",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        onPressed: () => _showLegalizeDialog(context),
      ),
    );
  }

  Widget _buildNukeCard() {
    return InkWell(
      onTap: () => _apiService?.nukeAccount(),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.warningRed.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppColors.warningRed.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.delete_forever,
                color: AppColors.warningRed, size: 28),
            const SizedBox(width: 15),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "PROTOCOL NUKE",
                  style: TextStyle(
                    color: AppColors.warningRed,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const Text("Permanently erase all grid data",
                    style: TextStyle(color: AppColors.textDim, fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleInput(
      GhostController controller, String hint, IconData icon,
      {bool isPass = false}) {
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        builder: (_) => GhostKeyboard(
            controller: controller, onSend: () => Navigator.pop(context)),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.white10)),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textDim, size: 18),
            const SizedBox(width: 12),
            AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Text(
                controller.value.isEmpty
                    ? hint
                    : (isPass ? controller.masked : controller.value),
                style: TextStyle(
                    color: controller.value.isEmpty
                        ? AppColors.textDim
                        : Colors.white,
                    fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- ВСПОМОГАТЕЛЬНЫЕ ВНУТРЕННИЕ ВИДЖЕТЫ ---

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.black, width: 2)),
      child: Text(text,
          style: const TextStyle(
              color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold)),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile(
      {required this.icon,
      required this.color,
      required this.title,
      required this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      tileColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: color.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: AppColors.textDim, fontSize: 10)),
      trailing: const Icon(Icons.arrow_forward_ios,
          color: AppColors.textDim, size: 12),
    );
  }
}
