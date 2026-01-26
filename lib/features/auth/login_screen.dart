import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/storage_service.dart';
import '../../core/network_monitor.dart';
import '../../core/websocket_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../../warning_screen.dart';
import '../ui/terminal_style.dart';
import 'recovery_phrase_screen.dart';
import 'restore_access_screen.dart';
import 'registration_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ✅ Ghost контроллеры для защиты от краша на Tecno/Xiaomi
  final _emailGhost = GhostController();
  final _passwordGhost = GhostController();

  bool _isLoading = false;
  String? _currentError;
  bool _isCheckingConnection = false;

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
      final savedId = await Vault.read('user_id');
      final savedName = await Vault.read('user_name');
      
      if (savedId != null && savedId.startsWith("GHOST_")) {
        // Есть локальный Ghost ID - можно войти
        setState(() {
          _isLoading = true;
          _isCheckingConnection = false;
        });
        
        await Future.delayed(const Duration(milliseconds: 500));
        
        _goToHome({
          'id': savedId,
          'username': savedName ?? 'Ghost',
          'deathDate': DateTime.now().add(const Duration(days: 30000)).toIso8601String(),
          'dateOfBirth': DateTime.now().toIso8601String()
        });
        return;
      }

      // Нет локального Ghost ID - предлагаем создать
      _showOfflineOptions(context);
      return;
    }

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _currentError = null;
      _isCheckingConnection = true;
    });

    try {
      // Check connection first
      await Future.delayed(const Duration(milliseconds: 500));
      
      setState(() => _isCheckingConnection = false);
      
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
      setState(() {
        _currentError = _getUserFriendlyError(e);
      });
      _showErrorDialog(
        title: "Login Failed",
        message: _getUserFriendlyError(e),
        solution: _getErrorSolution(e),
        onRetry: () {
          setState(() => _currentError = null);
          _login();
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCheckingConnection = false;
        });
      }
    }
  }

  String _getUserFriendlyError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('network') || errorStr.contains('timeout') || errorStr.contains('connection')) {
      return "Network connection failed";
    } else if (errorStr.contains('invalid') || errorStr.contains('credentials') || errorStr.contains('password')) {
      return "Invalid email or password";
    } else if (errorStr.contains('not found') || errorStr.contains('user')) {
      return "User not found";
    } else {
      return "Login failed. Please try again.";
    }
  }

  String? _getErrorSolution(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('network') || errorStr.contains('timeout')) {
      return "Check your internet connection and try again.";
    } else if (errorStr.contains('invalid') || errorStr.contains('credentials')) {
      return "Verify your email and password are correct.";
    }
    return null;
  }

  void _showErrorDialog({
    required String title,
    required String message,
    String? solution,
    VoidCallback? onRetry,
  }) {
    showDialog(
      context: context,
      builder: (_) => TerminalErrorDialog(
        title: title,
        message: message,
        solution: solution,
        onRetry: onRetry,
        onDismiss: () => Navigator.pop(context),
      ),
    );
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

  /// Показывает диалог с опциями для оффлайн режима
  void _showOfflineOptions(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: TerminalText(
          'OFFLINE MODE',
          color: Colors.orangeAccent,
        ),
        content: TerminalText(
          'No local Ghost ID found.\n\nYou can:\n1. Create a new Ghost ID\n2. Register for Cloud Mode',
          color: Colors.greenAccent,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const RegistrationScreen()),
              );
            },
            child: TerminalText(
              'REGISTER',
              color: Colors.greenAccent,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: TerminalText(
              'CANCEL',
              color: Colors.redAccent,
            ),
          ),
        ],
      ),
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
              TerminalTitle(
              'MEMENTO MORI',
              color: Colors.greenAccent,
            ),
            const SizedBox(height: 40),
            
            // Connection status indicator
            StreamBuilder<MeshRole>(
              stream: NetworkMonitor().onRoleChanged,
              initialData: NetworkMonitor().currentRole,
              builder: (context, snapshot) {
                final bool isOffline = snapshot.data == MeshRole.GHOST;
                return Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isOffline 
                        ? Colors.orangeAccent.withOpacity(0.1)
                        : Colors.greenAccent.withOpacity(0.1),
                    border: Border.all(
                      color: isOffline 
                          ? Colors.orangeAccent.withOpacity(0.3)
                          : Colors.greenAccent.withOpacity(0.3),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isOffline ? Icons.wifi_off : Icons.cloud_done,
                        size: 16,
                        color: isOffline ? Colors.orangeAccent : Colors.greenAccent,
                      ),
                      const SizedBox(width: 8),
                      TerminalText(
                        isOffline ? "OFFLINE MODE" : "CLOUD UPLINK",
                        color: isOffline ? Colors.orangeAccent : Colors.greenAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ],
                  ),
                );
              },
            ),

            const SizedBox(height: 20),

            // EMAIL
            TerminalSubtitle("Email Address"),
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
              TerminalSubtitle("Security Password"),
              const SizedBox(height: 8),
              _buildGhostWrapper(
                controller: _passwordGhost,
                hint: "Enter password",
                icon: Icons.lock_outline,
                isPassword: true,
                onTap: () => _showGhostKeyboard(_passwordGhost, "PASSWORD INPUT"),
              ),

              // ✅ КНОПКА ВОССТАНОВЛЕНИЯ
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF0D0D0D),
                          title: const TerminalTitle('Recovery Options', color: Colors.cyanAccent),
                          content: const Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TerminalText(
                                'You can recover access using:',
                                color: Colors.white70,
                              ),
                              SizedBox(height: 12),
                              TerminalText('1. Recovery Phrase', color: Colors.greenAccent, fontWeight: FontWeight.bold),
                              TerminalText('   The 12-word phrase you saved during registration', color: Colors.white54, fontSize: 11),
                              SizedBox(height: 8),
                              TerminalText('2. Email Recovery', color: Colors.greenAccent, fontWeight: FontWeight.bold),
                              TerminalText('   Reset password via email link', color: Colors.white54, fontSize: 11),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const TerminalText('Cancel', color: Colors.white54),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.pop(context);
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const RestoreAccessScreen()),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.greenAccent,
                              ),
                              child: const TerminalText('Continue', color: Colors.black, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const TerminalText(
                      'Forgot Password?',
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),

              if (_currentError != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TerminalText(
                    _currentError!,
                    color: Colors.redAccent,
                  ),
                ),
              ],

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: _isLoading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isLoading
                    ? (_isCheckingConnection
                        ? const TerminalLoadingIndicator(
                            message: "Checking connection",
                            color: Colors.black,
                          )
                        : const TerminalLoadingIndicator(
                            message: "Signing in",
                            color: Colors.black,
                          ))
                    : const TerminalText(
                        'SIGN IN',
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                      ),
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