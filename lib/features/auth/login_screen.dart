import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import '../../core/network_monitor.dart';
import '../../core/websocket_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../../warning_screen.dart';
import 'recovery_phrase_screen.dart';
import 'restore_access_screen.dart'; // ✅ Импортируем новый экран

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ✅ Ghost контроллеры для защиты от краша на Tecno/Xiaomi
  final _emailGhost = GhostController();
  final _passwordGhost = GhostController();

  final _storage = const FlutterSecureStorage();
  bool _isLoading = false;

  @override
  void dispose() {
    _emailGhost.dispose();
    _passwordGhost.dispose();
    super.dispose();
  }

  // Вызов безопасной клавиатуры
  void _showGhostKeyboard(GhostController controller, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: const Color(0xFF1E1E1E),
              width: double.infinity,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            GhostKeyboard(
              controller: controller,
              onSend: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  // Главная логика входа
  Future<void> _login() async {
    final email = _emailGhost.value.trim();
    final password = _passwordGhost.value;

    final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

    if (isOffline) {
      // ПРОВЕРЯЕМ: А есть ли у нас уже локальный профиль?
      final savedId = await Vault.read( 'user_id');
      if (savedId != null && savedId.startsWith("GHOST_")) {
        _goToHome({'id': savedId, 'username': 'Ghost', 'deathDate': DateTime.now().add(Duration(days: 30000)).toIso8601String(), 'dateOfBirth': DateTime.now().toIso8601String()});
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Cloud login unavailable. Switch to Registration to create Ghost ID."))
      );
      return;
    }

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final api = ApiService();
      final data = await api.login(email, password);

      final token = data['token'];
      final user = data['user'];
      final bool requiresRecovery = data['requiresRecoverySetup'] ?? false;

      // Сохраняем токен (в обычном режиме для совместимости с Tecno)
      await Vault.write( 'auth_token',  token);
      await Vault.write( 'user_id',  user['id'].toString());

      if (user['deathDate'] != null) {
        await Vault.write( 'user_deathDate',  user['deathDate']);
      }
      if (user['dateOfBirth'] != null) {
        await Vault.write( 'user_birthDate',  user['dateOfBirth']);
      }

      await WebSocketService().connect();

      if (!mounted) return;

      if (requiresRecovery) {
        _goToRecovery();
      } else {
        _goToHome(user);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception:', '').trim()),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Генерация фразы для новых/старых пользователей
  Future<void> _goToRecovery() async {
    try {
      final response = await ApiService().generateRecoveryPhrase();
      final phrase = response['recoveryPhrase'];
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => RecoveryPhraseScreen(phrase: phrase)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString().replaceAll('Exception:', '').trim()}'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _goToHome(dynamic user) {
    final deathDateStr = user['deathDate'];
    final birthDateStr = user['dateOfBirth'];
    if (deathDateStr == null || birthDateStr == null) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => WarningScreen(
          deathDate: DateTime.parse(deathDateStr),
          birthDate: DateTime.parse(birthDateStr),
        ),
      ),
          (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SizedBox(
        height: size.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Memento Mori',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 60),

              // EMAIL
              const Text("Email Address", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              _buildGhostWrapper(
                controller: _emailGhost,
                hint: "Enter your email",
                icon: Icons.alternate_email,
                isPassword: false,
                onTap: () => _showGhostKeyboard(_emailGhost, "EMAIL INPUT"),
              ),

              const SizedBox(height: 20),

              // PASSWORD
              const Text("Security Password", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              _buildGhostWrapper(
                controller: _passwordGhost,
                hint: "Enter password",
                icon: Icons.lock_outline,
                isPassword: true,
                onTap: () => _showGhostKeyboard(_passwordGhost, "PASSWORD INPUT"),
              ),

              // ✅ КНОПКА ВОССТАНОВЛЕНИЯ
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RestoreAccessScreen()),
                    );
                  },
                  child: const Text(
                    'Forgot Password?',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: _isLoading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isLoading
                    ? const SizedBox(
                  height: 24, width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                )
                    : const Text('SIGN IN', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGhostWrapper({
    required GhostController controller,
    required String hint,
    required IconData icon,
    required bool isPassword,
    required VoidCallback onTap,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  String text = controller.value.isEmpty
                      ? hint
                      : (isPassword ? controller.masked : controller.value);
                  return Text(
                    text,
                    style: TextStyle(
                      color: controller.value.isEmpty ? Colors.grey : Colors.white,
                      fontSize: 16,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}