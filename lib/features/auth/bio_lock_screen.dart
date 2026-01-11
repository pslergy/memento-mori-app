import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart'; // Для красивых текстов на Android
import 'package:memento_mori_app/core/panic_service.dart';
import 'package:memento_mori_app/main_screen.dart';

class BioLockScreen extends StatefulWidget {
  final DateTime deathDate;
  final DateTime birthDate;

  const BioLockScreen({super.key, required this.deathDate, required this.birthDate});

  @override
  State<BioLockScreen> createState() => _BioLockScreenState();
}

class _BioLockScreenState extends State<BioLockScreen> {
  final LocalAuthentication auth = LocalAuthentication();
  int _failedAttempts = 0;

  @override
  void initState() {
    super.initState();
    // 🔥 TECNO FIX: Увеличиваем задержку до 1 секунды.
    // Китайским прошивкам нужно время, чтобы подготовить биометрический контекст.
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) _authenticate();
    });
  }

  Future<void> _authenticate() async {
    try {
      // 1. Проверяем возможности железа
      final bool canCheckBiometrics = await auth.canCheckBiometrics;
      final bool isDeviceSupported = await auth.isDeviceSupported();
      final List<BiometricType> availableBiometrics = await auth.getAvailableBiometrics();

      // Если сканера нет или в системе не добавлено ни одного пальца
      if (!canCheckBiometrics || !isDeviceSupported || availableBiometrics.isEmpty) {
        print("⚠️ Биометрия недоступна или не настроена. Пропускаем.");
        _onSuccess();
        return;
      }

      // 2. Вызываем системное окно (ИСПРАВЛЕННЫЙ СИНТАКСИС)
      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'IDENTITY VERIFICATION',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true, // Только палец, запрещаем ПИН телефона
          useErrorDialogs: true,
        ),
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'SECURE LINK',
            biometricHint: 'Verify your pulse',
            cancelButton: 'ABORT',
          ),
        ],
      );

      if (didAuthenticate) {
        _onSuccess();
      } else {
        _onFailure();
      }
    } catch (e) {
      print("❌ [Bio] Critical Error: $e");

      // 🔥 ПРОТОКОЛ ПАНИКА: Если в системе Android был добавлен/удален палец
      // Библиотека выдаст KeyPermanentlyInvalidatedException.
      // В этом случае мы стираем данные, так как база отпечатков скомпрометирована.
      if (e.toString().contains("KeyPermanentlyInvalidatedException") ||
          e.toString().contains("LockedOut")) {
        print("☢️ [SECURITY] Biometric database changed or locked. Wiping...");
        PanicService.killSwitch(context);
      } else {
        _onFailure();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.fingerprint, size: 80, color: Colors.white10),
            const SizedBox(height: 40),
            const Text("SECURE ACCESS ONLY", style: TextStyle(color: Colors.white38, letterSpacing: 2)),
            const SizedBox(height: 60),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white12),
              onPressed: _authenticate,
              child: const Text("TAP TO SCAN", style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  void _onSuccess() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MainScreen(
        deathDate: widget.deathDate,
        birthDate: widget.birthDate,
      )),
    );
  }

  void _onFailure() {
    setState(() => _failedAttempts++);

    // 🔥 ТАКТИЧЕСКАЯ ЛОВУШКА
    if (_failedAttempts >= 3) {
      print("☢️ [BIO-TRAP] 3 failed scans. Compromise suspected. Wiping...");
      PanicService.killSwitch(context);
    }
  }

}