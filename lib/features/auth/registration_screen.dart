import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_service.dart';
import '../../core/decoy/app_mode.dart';
import '../../core/encryption_service.dart';
import '../../core/locator.dart';
import '../../core/network_monitor.dart';
import '../../core/storage_service.dart';

import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';
import '../theme/app_colors.dart';
import '../ui/terminal_style.dart';
import 'recovery_phrase_screen.dart';
import 'onboarding_tutorial_screen.dart';
import 'validation_helper.dart';

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
  String? _currentError;
  int _registrationStep = 0; // 0: input, 1: date, 2: finalize, 3: processing

  // Validation states
  String? _usernameError;
  String? _emailError;
  String? _passwordError;
  String? _passwordStrength;

  @override
  void initState() {
    super.initState();
    _usernameGhost.addListener(_onUsernameChanged);
    _emailGhost.addListener(_onEmailChanged);
    _passwordGhost.addListener(_onPasswordChanged);
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
    // Validate locally first
    setState(() {
      _usernameError = ValidationHelper.validateUsername(_usernameGhost.value);
    });

    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (_usernameError == null) {
        _checkUsername(_usernameGhost.value);
      }
    });
  }

  void _onEmailChanged() {
    setState(() {
      _emailError = ValidationHelper.validateEmail(_emailGhost.value);
    });
  }

  void _onPasswordChanged() {
    setState(() {
      _passwordError = ValidationHelper.validatePassword(_passwordGhost.value);
      _passwordStrength = _passwordGhost.value.isNotEmpty
          ? ValidationHelper.getPasswordStrength(_passwordGhost.value)
          : null;
    });
  }

  Future<void> _checkUsername(String username) async {
    if (username.length < 3 || NetworkMonitor().currentRole == MeshRole.GHOST) {
      setState(() => _isUsernameAvailable = null);
      return;
    }

    setState(() => _isUsernameChecking = true);
    try {
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
    HapticFeedback.mediumImpact();

    final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

    if (isOffline) {
      // FSM: if ghost identity already in Vault, START always proceeds — no online/retry guard.
      final String? token = await Vault.read('auth_token');
      final String? userId = await Vault.read('user_id');
      if (token == 'GHOST_MODE_ACTIVE' && userId != null && userId.isNotEmpty) {
        setState(() {
          _currentError = null;
          _isLoading = false;
        });
        _finalizeAndNavigate(null);
        return;
      }
      setState(() => _isLoading = true);
      await _initGhostProtocol();
    } else {
      setState(() => _isLoading = true);
      await _performCloudRegistration();
    }
  }

  // 👻 КЕЙС 1: Оффлайн регистрация (Ghost Mode). OFFLINE FIRST: only Vault + Encryption, no ApiService.
  Future<void> _initGhostProtocol() async {
    setState(() {
      _isLoading = true;
      _registrationStep = 3; // Processing
      _currentError = null;
    });

    final String username = _usernameGhost.value.trim();
    final String email = _emailGhost.value.trim();

    try {
      // Ensure CORE is set (Vault + EncryptionService). Fallback if we opened Registration without going through PostPermissions.
      if (!locator.isRegistered<EncryptionService>()) {
        setupCoreLocator(AppMode.REAL);
        setupSessionLocator(AppMode.REAL);
      }
      // OFFLINE FIRST: create ghost locally; never depends on network or ApiService.
      await createGhostIdentityLocal(username, email);

      // FSM: local success = SUCCESS state; clear error and navigate. No guard on online.
      if (!mounted) return;
      setState(() {
        _currentError = null;
      });
      await _finalizeAndNavigate(null);

      // ONLINE OPTIONAL: after navigation; must not block or throw into outer catch.
      if (mounted && locator.isRegistered<ApiService>()) {
        try {
          await locator<ApiService>().loadSavedIdentity();
        } catch (_) {}
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const TerminalText(
                'Ghost ID created successfully! Legalize it when internet is available.',
                color: Colors.white,
              ),
              backgroundColor: Colors.greenAccent.withOpacity(0.2),
              duration: const Duration(seconds: 3),
            ),
          );
        } catch (_) {}
      }
    } catch (e, st) {
      // Log so logcat shows root cause (e.g. EncryptionService not registered, Vault write failure).
      print('⚠️ [Ghost] createGhostIdentityLocal failed: $e');
      print('⚠️ [Ghost] stack: $st');
      setState(() => _currentError = _getUserFriendlyError(e));
      // If ghost is already in Vault (e.g. creation succeeded but later step threw, or previous attempt), still let user in.
      try {
        final String? token = await Vault.read('auth_token');
        final String? userId = await Vault.read('user_id');
        if (token == 'GHOST_MODE_ACTIVE' &&
            userId != null &&
            userId.isNotEmpty &&
            mounted) {
          setState(() => _currentError = null);
          _finalizeAndNavigate(null);
          return;
        }
      } catch (_) {}
      // OFFLINE FIRST: do not block with "Check your internet"; soft info only.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: TerminalText(
              _getUserFriendlyError(e),
              color: Colors.white70,
            ),
            backgroundColor: Colors.orange.withOpacity(0.3),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🌐 КЕЙС 2: Облачная регистрация
  Future<void> _performCloudRegistration() async {
    setState(() {
      _isLoading = true;
      _registrationStep = 3; // Processing
      _currentError = null;
    });

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
      final errorMsg = e.toString().toLowerCase();
      if (errorMsg.contains('network') ||
          errorMsg.contains('timeout') ||
          errorMsg.contains('connection')) {
        // Network error - fallback to Ghost
        setState(() {
          _currentError =
              "Internet connection lost. Switching to Ghost Mode...";
        });

        // Show informative dialog
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF0D0D0D),
              title: const TerminalTitle('Connection Lost',
                  color: Colors.orangeAccent),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TerminalText(
                    'Internet connection was lost during registration.',
                    color: Colors.white70,
                  ),
                  SizedBox(height: 12),
                  TerminalText(
                    'Switching to Ghost Mode...',
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                  SizedBox(height: 12),
                  TerminalText(
                    'Your Ghost ID will be created locally. You can legalize it later when internet is available.',
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ],
              ),
            ),
          );
        }

        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.pop(context); // Close dialog

        await _initGhostProtocol();
      } else {
        // Other error - show dialog
        setState(() {
          _currentError = _getUserFriendlyError(e);
        });
        _showErrorDialog(
          title: "Registration Failed",
          message: _getUserFriendlyError(e),
          solution: _getErrorSolution(e),
          onRetry: () {
            setState(() => _currentError = null);
            _performCloudRegistration();
          },
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _getUserFriendlyError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('network') || errorStr.contains('timeout')) {
      return "Network connection failed";
    } else if (errorStr.contains('username') || errorStr.contains('taken')) {
      return "Username is already taken";
    } else if (errorStr.contains('email')) {
      return "Invalid email address";
    } else if (errorStr.contains('password')) {
      return "Password is too weak";
    } else {
      return "Registration failed. Please try again.";
    }
  }

  String? _getErrorSolution(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('network') || errorStr.contains('timeout')) {
      return "Check your internet connection and try again.";
    } else if (errorStr.contains('username') || errorStr.contains('taken')) {
      return "Choose a different username.";
    } else if (errorStr.contains('email')) {
      return "Enter a valid email address.";
    } else if (errorStr.contains('password')) {
      return "Use at least 8 characters with letters and numbers.";
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

  Future<void> _finalizeAndNavigate(String? phrase) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isFirstRun', false);

    if (!mounted) return;

    if (phrase != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
            builder: (_) => RecoveryPhraseScreen(phrase: phrase, isFlow: true)),
      );
    } else {
      // Ghost mode - show tutorial then survival guide
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const OnboardingTutorialScreen(),
        ),
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
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.white24, size: 18),
          onPressed: () => _pageController.previousPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut),
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
    final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

    return _buildPageWrapper(
      title: "INITIALIZE IDENTITY",
      desc: "Choose your callsign and secure your communication link.",
      children: [
        // Mode indicator
        TerminalInfoBox(
          title: isOffline ? "👻 GHOST MODE" : "🌐 CLOUD MODE",
          content: isOffline
              ? "Offline operation, mesh network, legalization later when internet is available."
              : "Full synchronization, cloud storage, immediate identity verification.",
          icon: isOffline ? Icons.wifi_off : Icons.cloud_done,
          color: isOffline ? AppColors.stealthOrange : AppColors.cloudGreen,
        ),
        const SizedBox(height: 24),

        // Username
        _buildGhostInput(
          controller: _usernameGhost,
          hint: "Tactical Callsign (Username)",
          icon: Icons.person_outline,
          suffix: _buildUsernameIndicator(),
          onTap: () => _showKeyboard(_usernameGhost, "CALLSIGN"),
        ),
        if (_usernameError != null) ...[
          const SizedBox(height: 4),
          TerminalText(_usernameError!, color: Colors.redAccent, fontSize: 11),
        ],
        const SizedBox(height: 16),

        // Email
        _buildGhostInput(
          controller: _emailGhost,
          hint: "Email (For future legalization)",
          icon: Icons.alternate_email,
          onTap: () => _showKeyboard(_emailGhost, "SECURE EMAIL"),
        ),
        if (_emailError != null) ...[
          const SizedBox(height: 4),
          TerminalText(_emailError!, color: Colors.redAccent, fontSize: 11),
        ],
        const SizedBox(height: 16),

        // Password
        _buildGhostInput(
          controller: _passwordGhost,
          hint: "Security Cipher (Password)",
          icon: Icons.lock_outline,
          isPassword: true,
          onTap: () => _showKeyboard(_passwordGhost, "CIPHER"),
        ),
        if (_passwordError != null) ...[
          const SizedBox(height: 4),
          TerminalText(_passwordError!, color: Colors.redAccent, fontSize: 11),
        ],
        if (_passwordStrength != null && _passwordGhost.value.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              TerminalText(
                "Strength: ",
                color: Colors.white54,
                fontSize: 11,
              ),
              TerminalText(
                _passwordStrength!,
                color: ValidationHelper.getPasswordStrengthColor(
                    _passwordGhost.value),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ],
          ),
        ],
      ],
      onNext: () {
        // Validate all fields
        _usernameError =
            ValidationHelper.validateUsername(_usernameGhost.value);
        _emailError = ValidationHelper.validateEmail(_emailGhost.value);
        _passwordError =
            ValidationHelper.validatePassword(_passwordGhost.value);

        setState(() {});

        if (_usernameError != null ||
            _emailError != null ||
            _passwordError != null) {
          _showError("Please fix the errors above");
          return;
        }

        _pageController.nextPage(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut);
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
      onNext: () => _pageController.nextPage(
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut),
    );
  }

  Widget _buildStep3() {
    final bool isOffline = NetworkMonitor().currentRole == MeshRole.GHOST;

    return _buildPageWrapper(
      title: "FINALIZE",
      desc: "Your data will be encrypted and stored in the local grid.",
      isLast: true,
      children: [
        if (_isLoading && _registrationStep == 3) ...[
          // Progress indicator during registration
          TerminalProgressBar(
            currentStep: _registrationStep,
            totalSteps: 3,
            stepLabels: [
              "Initializing mesh network...",
              "Creating identity...",
              "Synchronizing...",
            ],
          ),
          const SizedBox(height: 24),
          const TerminalLoadingIndicator(
            message: "Processing",
            color: Colors.greenAccent,
          ),
        ] else ...[
          Center(
            child: Pulse(
              infinite: true,
              child: Container(
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.gridCyan.withOpacity(0.2), width: 2),
                ),
                child: const Icon(Icons.shield_outlined,
                    color: AppColors.gridCyan, size: 50),
              ),
            ),
          ),
          const SizedBox(height: 30),
          TerminalInfoBox(
            title: isOffline ? "GHOST MODE" : "CLOUD MODE",
            content: isOffline
                ? "You're registering offline. Your identity will be created locally. You can legalize it later when internet is available."
                : "You're registering with cloud sync. Your identity will be synced to the cloud.",
            icon: isOffline ? Icons.wifi_off : Icons.cloud_done,
            color: isOffline ? AppColors.stealthOrange : AppColors.cloudGreen,
          ),
        ],
      ],
      onNext: _handleFinalStep,
    );
  }

  // --- ВСПОМОГАТЕЛЬНЫЕ КОМПОНЕНТЫ ---

  Widget _buildPageWrapper(
      {required String title,
      required String desc,
      required List<Widget> children,
      required VoidCallback onNext,
      bool isLast = false}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          FadeInDown(
            child: TerminalTitle(title),
          ),
          const SizedBox(height: 8),
          FadeInDown(
            delay: const Duration(milliseconds: 100),
            child: TerminalSubtitle(desc),
          ),
          const SizedBox(height: 40),
          ...children,
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
          const SizedBox(height: 40),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : onNext,
            child: _isLoading
                ? const TerminalLoadingIndicator(
                    message: "Processing",
                    color: Colors.black,
                  )
                : TerminalText(
                    isLast ? "START" : "CONTINUE",
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGhostInput(
      {required GhostController controller,
      required String hint,
      required IconData icon,
      bool isPassword = false,
      Widget? suffix,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.white05)),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textDim, size: 20),
            const SizedBox(width: 15),
            Expanded(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Text(
                  controller.value.isEmpty
                      ? hint
                      : (isPassword ? controller.masked : controller.value),
                  style: TextStyle(
                      color: controller.value.isEmpty
                          ? AppColors.textDim
                          : Colors.white,
                      fontSize: 14),
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
          color: isOffline
              ? AppColors.stealthOrange.withOpacity(0.1)
              : AppColors.cloudGreen.withOpacity(0.1),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isOffline ? Icons.wifi_off : Icons.cloud_done,
                  size: 12,
                  color: isOffline
                      ? AppColors.stealthOrange
                      : AppColors.cloudGreen),
              const SizedBox(width: 8),
              Text(
                isOffline
                    ? "GHOST PROTOCOL ACTIVE (OFFLINE)"
                    : "CLOUD UPLINK SECURED",
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isOffline
                      ? AppColors.stealthOrange
                      : AppColors.cloudGreen,
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
      color:
          _isUsernameAvailable! ? AppColors.cloudGreen : AppColors.warningRed,
      size: 18,
    );
  }

  void _showKeyboard(GhostController controller, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GhostKeyboard(
          controller: controller, onSend: () => Navigator.pop(context)),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: TerminalText(msg, color: Colors.white),
        backgroundColor: AppColors.warningRed,
      ),
    );
  }

  // Заглушка для проверки (реализуй в ApiService)
  Future<bool> _apiService_CheckUsername(String username) async {
    return await locator<ApiService>().checkUsernameAvailable(username);
  }
}
