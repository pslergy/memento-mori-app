import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animate_do/animate_do.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:memento_mori_app/features/auth/survival_guide_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_service.dart';
import '../../core/encryption_service.dart';
import '../../core/locator.dart';
import '../../core/network_monitor.dart';
import '../../core/storage_service.dart';
import '../../core/websocket_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import 'recovery_phrase_screen.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final PageController _pageController = PageController();

  final _usernameGhost = GhostController();
  final _emailGhost = GhostController();
  final _passwordGhost = GhostController();
  final _storage = const FlutterSecureStorage();

  DateTime _birthDate = DateTime(2000, 1, 1);
  bool _isUsernameChecking = false;
  bool? _isUsernameAvailable;
  Timer? _debounce;

  // 🔥 ТВОЙ НОВЫЙ АДРЕС VPS
  final String _serverIp = "89.125.131.63";

  bool _isLoading = false;

  final Map<String, String> _lifestyleAnswers = {
    'sport': 'SOMETIMES',
    'habits': 'NO',
    'optimism': 'YES',
    'stress': 'MEDIUM',
    'sleep': 'NORMAL',
    'social': 'SOMETIMES',
    'purpose': 'UNSURE',
    'diet': 'NORMAL',
    'satisfaction': 'MOSTLY_NO',
  };

  @override
  void initState() {
    super.initState();
    _usernameGhost.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _usernameGhost.dispose();
    _emailGhost.dispose();
    _passwordGhost.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onUsernameChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _checkUsername(_usernameGhost.value);
    });
  }

  Future<void> _checkUsername(String username) async {
    if (username.length < 3) {
      setState(() => _isUsernameAvailable = null);
      return;
    }

    // 🔥 НОВОЕ: Если мы оффлайн, даже не пытаемся стучать на сервер
    if (NetworkMonitor().currentRole == MeshRole.GHOST) {
      setState(() => _isUsernameAvailable = null);
      return;
    }

    setState(() => _isUsernameChecking = true);
    try {
      final url = Uri.parse('https://$_serverIp:3000/api/users/check-username?username=$username');
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _isUsernameAvailable = data['available']);
      }
    } catch (e) {
      // Если упало по таймауту или инету - обнуляем
      setState(() => _isUsernameAvailable = null);
    } finally {
      setState(() => _isUsernameChecking = false);
    }
  }

  // Обнови иконку-индикатор


  void _showGhostKeyboard(GhostController controller, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GhostKeyboard(
        controller: controller,
        onSend: () => Navigator.pop(context),
      ),
    );
  }

  Future<void> _register() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    final encryption = locator<EncryptionService>();
    final String username = _usernameGhost.value.trim();
    final String url = 'https://$_serverIp:3000/api/auth/register';

    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    final client = IOClient(httpClient);

    try {
      print("📡 [Registration] Attempting cloud uplink...");

      final response = await client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'email': _emailGhost.value.trim(),
          'password': _passwordGhost.value,
          'countryCode': 'RU',
          'gender': 'MALE',
          'dateOfBirth': _birthDate.toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 7));

      if (response.statusCode == 201) {
        // --- 🌐 КЕЙС: УСПЕХ В ОБЛАКЕ ---
        final data = jsonDecode(response.body);
        final String? token = data['token'];
        final user = data['user'];
        final String? recoveryPhrase = data['recoveryPhrase'];

        if (token != null) await Vault.write('auth_token', token);
        if (user != null) {
          await Vault.write('user_id', user['id']?.toString() ?? '');
          await Vault.write('user_deathDate', user['deathDate']?.toString() ?? "");
          await Vault.write('user_birthDate', user['dateOfBirth']?.toString() ?? "");
          await Vault.write('user_name', user['username']?.toString() ?? username);
        }

        // Кэшируем ID в ApiService и помечаем успешный вход
        await locator<ApiService>().loadSavedIdentity();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('isFirstRun', false);

        if (mounted) {
          if (recoveryPhrase != null && recoveryPhrase.isNotEmpty) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => RecoveryPhraseScreen(phrase: recoveryPhrase, isFlow: true)),
            );
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const SurvivalGuideScreen()),
            );
          }
        }
      } else {
        throw Exception(jsonDecode(response.body)['message'] ?? 'Server error');
      }

    } catch (e) {
      // --- 👻 КЕЙС: ОФФЛАЙН РЕЖИМ (GHOST PROTOCOL) ---
      print("⚠️ [Registration] Uplink failed: $e. Initiating Ghost Protocol...");

      final ghostData = await encryption.generateGhostIdentity(username);

      // ЗАПИСЬ В VAULT (Защита от null-safety через ??)
      await Vault.write('auth_token', 'GHOST_MODE_ACTIVE');
      await Vault.write('user_id', ghostData['userId'] ?? 'GHOST_ID');
      await Vault.write('user_name', ghostData['username'] ?? username);

      // Расчет даты смерти (+70 лет)
      final deathDate = DateTime.now().add(const Duration(days: 365 * 70)).toIso8601String();
      await Vault.write('user_deathDate', deathDate);
      await Vault.write('user_birthDate', _birthDate.toIso8601String());

      // ФИКСИРУЕМ ПЕРВЫЙ ЗАПУСК
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isFirstRun', false);

      // Обновляем личность в сервисе
      await locator<ApiService>().loadSavedIdentity();

      print("✅ [Registration] Ghost Identity Saved. FirstRun set to FALSE.");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("NETWORK OFFLINE. GHOST IDENTITY ESTABLISHED."),
            backgroundColor: Colors.deepPurple,
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const SurvivalGuideScreen()),
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _isLoading = false);
    }
  }


  Future<void> _saveSession(String token, String uid, String death, String birth) async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'auth_token', value: token);
    await storage.write(key: 'user_id', value: uid);
    await storage.write(key: 'user_deathDate', value: death);
    await storage.write(key: 'user_birthDate', value: birth);
    await locator<ApiService>().loadSavedIdentity(); // Обновляем в памяти
  }

  void _navigateNext(String? phrase) {
    if (phrase != null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => RecoveryPhraseScreen(phrase: phrase, isFlow: true)));
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SurvivalGuideScreen()));
    }
  }
  // --- ОСТАЛЬНАЯ ВЕРСТКА БЕЗ ИЗМЕНЕНИЙ ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _buildStep1_Credentials(),
          _buildStep2_BirthDate(),
          _buildStep3_LifestyleQuestions(),
        ],
      ),
    );
  }

  Widget _buildStep1_Credentials() {
    return _buildStepContainer(
      title: 'Create Account',
      children: [
        _buildGhostField(
          controller: _usernameGhost,
          hint: 'Username',
          icon: Icons.person_outline,
          suffix: _buildUsernameSuffixIcon(),
          onTap: () => _showGhostKeyboard(_usernameGhost, "USERNAME"),
        ),
        const SizedBox(height: 20),
        _buildGhostField(
          controller: _emailGhost,
          hint: 'Email',
          icon: Icons.alternate_email,
          onTap: () => _showGhostKeyboard(_emailGhost, "EMAIL"),
        ),
        const SizedBox(height: 20),
        _buildGhostField(
          controller: _passwordGhost,
          hint: 'Password',
          icon: Icons.lock_outline,
          isPassword: true,
          onTap: () => _showGhostKeyboard(_passwordGhost, "PASSWORD"),
        ),
      ],
      onNext: () {
        // 🔥 ПРОВЕРКА РЕЖИМА СЕТИ
        final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

        if (isOffline) {
          // --- 👻 ЛОГИКА ОФФЛАЙНА ---
          // В оффлайне мы не можем проверить ник на сервере,
          // поэтому просто проверяем, что поля заполнены.
          if (_usernameGhost.value.length >= 3 &&
              _passwordGhost.value.isNotEmpty) {

            print("🕵️ [Auth] Offline mode detected. Skipping server-side username check.");

            _pageController.nextPage(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Username and Password are required."))
            );
          }
        } else {
          // --- 🌐 ЛОГИКА ОНЛАЙНА ---
          // Здесь мы строго требуем, чтобы сервер вернул available: true
          if (_isUsernameAvailable == true &&
              _emailGhost.value.isNotEmpty &&
              _passwordGhost.value.isNotEmpty) {

            _pageController.nextPage(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut
            );
          } else if (_isUsernameAvailable == false) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Username is already taken."),
                  backgroundColor: Colors.orange,
                )
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Please fill all fields and wait for check."))
            );
          }
        }
      },
    );
  }

  Widget _buildGhostField({
    required GhostController controller,
    required String hint,
    required IconData icon,
    required VoidCallback onTap,
    bool isPassword = false,
    Widget? suffix,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade900),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.grey, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  String displayText = controller.value.isEmpty
                      ? hint
                      : (isPassword ? controller.masked : controller.value);
                  return Text(
                    displayText,
                    style: TextStyle(
                      color: controller.value.isEmpty ? Colors.grey : Colors.white,
                      fontSize: 16,
                    ),
                  );
                },
              ),
            ),
            if (suffix != null) suffix,
          ],
        ),
      ),
    );
  }

  Widget _buildStep2_BirthDate() {
    return _buildStepContainer(
      title: 'Starting Point',
      children: [
        const Text(
            'Select your date of birth. This will be the beginning of your countdown.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16)
        ),
        const SizedBox(height: 20),
        SizedBox(
            height: 200,
            child: CupertinoTheme(
              data: const CupertinoThemeData(brightness: Brightness.dark),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _birthDate,
                maximumDate: DateTime.now(),
                onDateTimeChanged: (DateTime newDate) => setState(() => _birthDate = newDate),
              ),
            )
        ),
      ],
      onNext: () => _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut),
    );
  }

  Widget _buildStep3_LifestyleQuestions() {
    // --- ЛОГИКА РАСЧЕТА (Твой перфекционизм) ---
    final int baseLifespanYears = 75;
    double adjustment = 0;

    final factors = {
      'sport': {'REGULAR': 5.0, 'NEVER': -3.0, 'SOMETIMES': 0.0},
      'habits': {'YES': -7.0, 'NO': 2.0},
      'optimism': {'YES': 2.0, 'NO': -1.0},
      'stress': {'HIGH': -4.0, 'LOW': 2.0, 'MEDIUM': 0.0},
      'sleep': {'POOR': -3.0, 'GOOD': 3.0, 'NORMAL': 0.0},
      'social': {'RARELY': -2.0, 'OFTEN': 2.0, 'SOMETIMES': 0.0},
      'purpose': {'YES': 3.0, 'NO': -1.0, 'UNSURE': 0.0},
      'diet': {'BALANCED': 4.0, 'FASTFOOD': -5.0, 'NORMAL': 0.0},
      'satisfaction': {'YES': 2.0, 'HATE': -3.0, 'MOSTLY_NO': -1.0},
    };

    factors.forEach((key, value) {
      if (_lifestyleAnswers.containsKey(key)) {
        adjustment += value[_lifestyleAnswers[key]] ?? 0.0;
      }
    });

    final totalLifespanDays = ((baseLifespanYears + adjustment) * 365).floor();
    final livedDays = DateTime.now().difference(_birthDate).inDays;
    final timeLeftDays = totalLifespanDays - livedDays;

    return _buildStepContainer(
      title: 'Your Path',
      isLastStep: true,
      isLoading: _isLoading,
      onNext: _register,
      children: [
        // ВИЗУАЛЬНЫЙ ТАЙМЕР
        FadeInUp(
          child: Column(
            children: [
              Text('ESTIMATED TIME LEFT',
                  style: GoogleFonts.orbitron(color: Colors.white38, letterSpacing: 3, fontSize: 10)),
              const SizedBox(height: 5),
              Text(
                '${(timeLeftDays / 365).floor()} years, ${timeLeftDays % 365} days',
                style: GoogleFonts.russoOne(
                    fontSize: 26,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 15.0, color: Colors.red.withOpacity(0.5))]
                ),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white10, height: 40),

        const Text(
          "Finalize your profile to enter the grid. In offline mode, your data will be incubated locally.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 30),

        // КРАСИВАЯ ТАКТИЧЕСКАЯ ИКОНКА
        Pulse(
          infinite: true,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.redAccent.withOpacity(0.2)),
            ),
            child: const Icon(Icons.psychology, color: Colors.redAccent, size: 50),
          ),
        ),

        const SizedBox(height: 20),

        // ИНДИКАТОР РЕЖИМА СЕТИ
        StreamBuilder<MeshRole>(
            stream: NetworkMonitor().onRoleChanged,
            initialData: NetworkMonitor().currentRole,
            builder: (context, snapshot) {
              final isOffline = snapshot.data == MeshRole.GHOST;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(isOffline ? Icons.cloud_off : Icons.cloud_done,
                      color: isOffline ? Colors.purpleAccent : Colors.greenAccent, size: 14),
                  const SizedBox(width: 8),
                  Text(
                    isOffline ? "GHOST REGISTRATION ACTIVE" : "CLOUD UPLINK READY",
                    style: TextStyle(
                        color: isOffline ? Colors.purpleAccent : Colors.greenAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace'
                    ),
                  ),
                ],
              );
            }
        ),
      ],
    );
  }

  Widget? _buildUsernameSuffixIcon() {
    if (_isUsernameChecking) {
      return const Padding(padding: EdgeInsets.all(12.0), child: CupertinoActivityIndicator());
    }
    if (_isUsernameAvailable != null) {
      return Icon(
          _isUsernameAvailable! ? Icons.check_circle_outline : Icons.error_outline,
          color: _isUsernameAvailable! ? Colors.greenAccent : Colors.redAccent
      );
    }
    return null;
  }

  Widget _buildStepContainer({
    required String title,
    required List<Widget> children,
    required VoidCallback onNext,
    bool isLastStep = false,
    bool isLoading = false,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        children: [
          const SizedBox(height: 20),
          FadeInDown(child: Text(title, textAlign: TextAlign.center, style: GoogleFonts.russoOne(fontSize: 32, color: Colors.white))),
          const SizedBox(height: 40),
          ...children,
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: isLoading ? null : onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(double.infinity, 50),
            ),
            child: isLoading
                ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : Text(isLastStep ? 'START' : 'NEXT', style: GoogleFonts.russoOne(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}