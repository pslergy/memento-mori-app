import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/features/settings/mesh_control_screen.dart'; // Убедись, что файл существует
import 'package:memento_mori_app/splash_screen.dart';
import '../../core/security_service.dart';
import '../../core/websocket_service.dart';
import '../camouflage/calculator_gate.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ApiService _apiService = ApiService();
  late Future<Map<String, dynamic>> _userFuture;

  @override
  void initState() {
    super.initState();
    _userFuture = _apiService.getMe();
  }

  // Логика выхода (Logout)
  Future<void> _logout() async {
    const storage = FlutterSecureStorage();
    await storage.delete(key: 'auth_token'); // Удаляем только токен или всё сразу через deleteAll()

    if (!mounted) return;

    // Возвращаем в начало (на калькулятор)
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const CalculatorGate()),
          (route) => false,
    );
  }

  // Логика самоуничтожения (Nuke)
  Future<void> _nukeAccount() async {
    // 1. Показываем страшное предупреждение
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red[900],
        title: const Text('⚠️ PROTOCOL NUKE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'This action is IRREVERSIBLE.\n\nAll your messages, chats, and account data will be permanently wiped from the server.\n\nAre you absolutely sure?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black),
            child: const Text('EXECUTE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 2. Вызываем API уничтожения (Нужно добавить этот метод в ApiService!)
      await _apiService.nukeAccount();

      // 3. Если успех - чистим локальные данные и выходим
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account obliterated.'), backgroundColor: Colors.red),
        );
      }
      await _logout();

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nuke failed: $e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Еще более темный фон
      appBar: AppBar(
        title: const Text('Identity'),
        backgroundColor: Colors.grey[900],
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _userFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text('Failed to verify identity', style: TextStyle(color: Colors.white)),
                  TextButton(onPressed: () => setState(() {_userFuture = _apiService.getMe();}), child: const Text("Retry"))
                ],
              ),
            );
          }

          final user = snapshot.data!;
          final createdAt = DateTime.parse(user['createdAt']);

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  // --- АВАТАР И ИМЯ ---
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey[800]!),
                    ),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: Colors.black,
                          child: Text(
                            user['username']?[0].toUpperCase() ?? '?',
                            style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          user['username'] ?? 'Unknown',
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                        Text(
                          user['email'] ?? '',
                          style: TextStyle(color: Colors.grey[500], fontSize: 14),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Badge(text: user['countryCode'] ?? 'UNK', color: Colors.blueGrey),
                            const SizedBox(width: 8),
                            _Badge(text: "SINCE ${createdAt.year}", color: Colors.blueGrey),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // --- СЕКЦИЯ RESISTANCE (Инструменты) ---
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text("OPERATIONS", style: TextStyle(color: Colors.grey, fontSize: 12, letterSpacing: 2)),
                  ),
                  const SizedBox(height: 10),


                  // Кнопка Mesh-сети
                  _MenuTile(
                    icon: Icons.wifi_tethering,
                    color: Colors.greenAccent,
                    title: "The Chain (Mesh Net)",
                    subtitle: "Offline P2P communication",
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const MeshControlScreen()),
                      );
                    },
                  ),

                  const SizedBox(height: 10),

                  // Кнопка выхода
                  _MenuTile(
                    icon: Icons.logout,
                    color: Colors.white,
                    title: "Logout",
                    subtitle: "Clear local session",
                    onTap: _logout,
                  ),

                  const SizedBox(height: 40),

                  // --- СЕКЦИЯ DANGER ZONE ---
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text("DANGER ZONE", style: TextStyle(color: Colors.red, fontSize: 12, letterSpacing: 2)),
                  ),
                  const SizedBox(height: 10),

                  _MenuTile(
                    icon: Icons.theater_comedy, // Иконка маски
                    color: Colors.amberAccent,
                    title: "Change Visual Identity",
                    subtitle: "Switch app icon and label",
                    onTap: () => _showCamouflageDialog(context),
                  ),

                  // Кнопка NUKE
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.red.withOpacity(0.5)),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.red.withOpacity(0.1),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.delete_forever, color: Colors.red, size: 30),
                      title: const Text("NUKE ACCOUNT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      subtitle: const Text("Permanently delete everything", style: TextStyle(color: Colors.redAccent)),
                      onTap: _nukeAccount,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
void _showCamouflageDialog(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF121212),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) => Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("SELECT MASK", style: GoogleFonts.russoOne(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.calculate, color: Colors.white),
            title: const Text("Standard Calculator"),
            onTap: () {
              SecurityService.changeIcon("Calculator");
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.notes, color: Colors.white),
            title: const Text("System Notes"),
            onTap: () async {
              // 1. Показываем индикатор "Перезагрузка протокола"
              Navigator.pop(context); // Закрываем диалог выбора

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => const AlertDialog(
                  backgroundColor: Colors.black,
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.redAccent),
                      SizedBox(height: 20),
                      Text("RECONFIGURING IDENTITY...",
                          style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
                      Text("System will restart",
                          style: TextStyle(color: Colors.white24, fontSize: 10)),
                    ],
                  ),
                ),
              );

              // 2. Даем пользователю 1.5 секунды, чтобы он понял, что происходит
              await Future.delayed(const Duration(seconds: 1, milliseconds: 500));

              // 3. Вызываем смену иконки (после этого приложение закроется само)
              SecurityService.changeIcon("Calculator");
            },
          ),
          const SizedBox(height: 20),
          const Text("Note: App may take a few seconds to update identity.",
              style: TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    ),
  );
}


// Вспомогательные виджеты для красоты
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: Colors.grey[900],
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, color: color),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      onTap: onTap,
      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 14),
    );
  }
}