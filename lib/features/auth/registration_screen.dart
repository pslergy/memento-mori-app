import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_service.dart';
import '../../core/encryption_service.dart';
import '../../core/locator.dart';
import '../../core/network_monitor.dart';
import '../../core/storage_service.dart';

import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../theme/app_colors.dart';
import 'recovery_phrase_screen.dart';
import 'survival_guide_screen.dart';

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

  DateTime _birthDate = DateTime(2000, 1, 1);
  bool _isUsernameChecking = false;
  bool? _isUsernameAvailable;
  Timer? _debounce;
  bool _isLoading = false;

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
    if (username.length < 3 || NetworkMonitor().currentRole == MeshRole.GHOST) {
      setState(() => _isUsernameAvailable = null);
      return;
    }

    setState(() => _isUsernameChecking = true);
    try {
      final api = locator<ApiService>();
      // Используем метод из ApiService для проверки (нужно добавить его туда)
      final response = await _apiService_CheckUsername(username);
      setState(() => _isUsernameAvailable = response);
    } catch (e) {
      setState(() => _isUsernameAvailable = null);
    } finally {
      setState(() => _isUsernameChecking = false);
    }
  }

  // --- 🔥 ГЛАВНАЯ ЛОГИКА: ОНЛАЙН VS ОФФЛАЙН ---

  Future<void> _handleFinalStep() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    HapticFeedback.mediumImpact();

    final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

    if (isOffline) {
      await _initGhostProtocol();
    } else {
      await _performCloudRegistration();
    }
  }

  // 👻 КЕЙС 1: Оффлайн регистрация (Ghost Mode)
  Future<void> _initGhostProtocol() async {
    try {
      final api = locator<ApiService>();
      final String username = _usernameGhost.value.trim();
      final String email = _emailGhost.value.trim();

      // Создаем локальную личность и Landing Pass
      await api.initGhostMode(username, email);

      _finalizeAndNavigate(null); // Фраза восстановления в оффлайне не генерится сервером
    } catch (e) {
      _showError("Identity formation failed: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🌐 КЕЙС 2: Облачная регистрация
  Future<void> _performCloudRegistration() async {
    try {
      final api = locator<ApiService>();
      final response = await api.register(
        username: _usernameGhost.value.trim(),
        email: _emailGhost.value.trim(),
        password: _passwordGhost.value,
        birthDate: _birthDate,
      );

      _finalizeAndNavigate(response['recoveryPhrase']);
    } catch (e) {
      // Если во время регистрации инет пропал — фолбек на Ghost
      print("📡 Uplink lost during registration. Falling back to Ghost...");
      await _initGhostProtocol();
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _finalizeAndNavigate(String? phrase) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isFirstRun', false);

    if (!mounted) return;

    if (phrase != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => RecoveryPhraseScreen(phrase: phrase, isFlow: true)),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SurvivalGuideScreen()),
      );
    }
  }

  // --- UI СТРОИТЕЛЬ ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white24, size: 18),
          onPressed: () => _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildStep1(),
                _buildStep2(),
                _buildStep3(),
              ],
            ),
          ),
          _buildNetworkStatusBar(),
        ],
      ),
    );
  }

  Widget _buildStep1() {
    return _buildPageWrapper(
      title: "INITIALIZE IDENTITY",
      desc: "Choose your callsign and secure your communication link.",
      children: [
        _buildGhostInput(
          controller: _usernameGhost,
          hint: "Tactical Callsign (Username)",
          icon: Icons.person_outline,
          suffix: _buildUsernameIndicator(),
          onTap: () => _showKeyboard(_usernameGhost, "CALLSIGN"),
        ),
        const SizedBox(height: 16),
        _buildGhostInput(
          controller: _emailGhost,
          hint: "Email (For future legalization)",
          icon: Icons.alternate_email,
          onTap: () => _showKeyboard(_emailGhost, "SECURE EMAIL"),
        ),
        const SizedBox(height: 16),
        _buildGhostInput(
          controller: _passwordGhost,
          hint: "Security Cipher (Password)",
          icon: Icons.lock_outline,
          isPassword: true,
          onTap: () => _showKeyboard(_passwordGhost, "CIPHER"),
        ),
      ],
      onNext: () {
        if (_usernameGhost.value.length < 3) return _showError("Callsign too short");
        _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
      },
    );
  }

  Widget _buildStep2() {
    return _buildPageWrapper(
      title: "CHRONOS START",
      desc: "Select your arrival date to synchronize the life-timer.",
      children: [
        SizedBox(
          height: 200,
          child: CupertinoTheme(
            data: const CupertinoThemeData(brightness: Brightness.dark),
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.date,
              initialDateTime: _birthDate,
              maximumDate: DateTime.now(),
              onDateTimeChanged: (val) => setState(() => _birthDate = val),
            ),
          ),
        ),
      ],
      onNext: () => _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut),
    );
  }

  Widget _buildStep3() {
    return _buildPageWrapper(
      title: "FINALIZE",
      desc: "Your data will be encrypted and stored in the local grid.",
      isLast: true,
      children: [
        Center(
          child: Pulse(
            infinite: true,
            child: Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.gridCyan.withOpacity(0.2), width: 2),
              ),
              child: const Icon(Icons.shield_outlined, color: AppColors.gridCyan, size: 50),
            ),
          ),
        ),
        const SizedBox(height: 30),
        Text(
          "By starting, you establish a Ghost Identity.\nThis process is irreversible in offline mode.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textDim, fontSize: 10),
        ),
      ],
      onNext: _handleFinalStep,
    );
  }

  // --- ВСПОМОГАТЕЛЬНЫЕ КОМПОНЕНТЫ ---

  Widget _buildPageWrapper({required String title, required String desc, required List<Widget> children, required VoidCallback onNext, bool isLast = false}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          FadeInDown(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          FadeInDown(delay: const Duration(milliseconds: 100), child: Text(desc, style: TextStyle(color: AppColors.textDim, fontSize: 12))),
          const SizedBox(height: 40),
          ...children,
          const SizedBox(height: 40),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : onNext,
            child: _isLoading
                ? const CupertinoActivityIndicator(color: Colors.black)
                : Text(
                    isLast ? "START" : "CONTINUE",
                    style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGhostInput({required GhostController controller, required String hint, required IconData icon, bool isPassword = false, Widget? suffix, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.white05)),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textDim, size: 20),
            const SizedBox(width: 15),
            Expanded(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Text(
                  controller.value.isEmpty ? hint : (isPassword ? controller.masked : controller.value),
                  style: TextStyle(color: controller.value.isEmpty ? AppColors.textDim : Colors.white, fontSize: 14),
                ),
              ),
            ),
            if (suffix != null) suffix,
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkStatusBar() {
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final bool isOffline = snapshot.data == MeshRole.GHOST;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          color: isOffline ? AppColors.stealthOrange.withOpacity(0.1) : AppColors.cloudGreen.withOpacity(0.1),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isOffline ? Icons.wifi_off : Icons.cloud_done, size: 12, color: isOffline ? AppColors.stealthOrange : AppColors.cloudGreen),
              const SizedBox(width: 8),
              Text(
                isOffline ? "GHOST PROTOCOL ACTIVE (OFFLINE)" : "CLOUD UPLINK SECURED",
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isOffline ? AppColors.stealthOrange : AppColors.cloudGreen,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildUsernameIndicator() {
    if (_isUsernameChecking) return const CupertinoActivityIndicator(radius: 8);
    if (_isUsernameAvailable == null) return null;
    return Icon(
      _isUsernameAvailable! ? Icons.check_circle_outline : Icons.error_outline,
      color: _isUsernameAvailable! ? AppColors.cloudGreen : AppColors.warningRed,
      size: 18,
    );
  }

  void _showKeyboard(GhostController controller, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GhostKeyboard(controller: controller, onSend: () => Navigator.pop(context)),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.warningRed));
  }

  // Заглушка для проверки (реализуй в ApiService)
  Future<bool> _apiService_CheckUsername(String username) async {
    return await locator<ApiService>().checkUsernameAvailable(username);
  }
}