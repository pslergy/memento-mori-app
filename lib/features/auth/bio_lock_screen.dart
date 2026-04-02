import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:memento_mori_app/core/decoy/gate_storage.dart';
import 'package:memento_mori_app/core/panic_service.dart';
import 'package:memento_mori_app/features/auth/set_access_codes_screen.dart';
import 'package:memento_mori_app/main_screen.dart';
import 'package:local_auth_android/local_auth_android.dart';

class BioLockScreen extends StatefulWidget {
  final DateTime deathDate;
  final DateTime birthDate;
  final bool requireBiometric; // Если true - биометрия обязательна (паник-протокол)

  const BioLockScreen({
    super.key, 
    required this.deathDate, 
    required this.birthDate,
    this.requireBiometric = false,
  });

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
      final bool canCheckBiometrics = await auth.canCheckBiometrics;
      final bool isDeviceSupported = await auth.isDeviceSupported();

      // 🔥 ПАНИК-ПРОТОКОЛ: Если биометрия обязательна, но недоступна - блокируем вход
      if (widget.requireBiometric && (!canCheckBiometrics || !isDeviceSupported)) {
        print("🚫 [PANIC] Biometric required but not available. Access denied.");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('BIOMETRIC AUTHENTICATION REQUIRED'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      // Если биометрия не обязательна и недоступна - пропускаем
      if (!canCheckBiometrics || !isDeviceSupported) {
        _onSuccess();
        return;
      }

      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'IDENTITY VERIFICATION',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
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
      print("❌ [Bio] Error: $e");
      if (e.toString().contains("NotAvailable") || e.toString().contains("LockedOut")) {
        _onSuccess(); // Фолбек для девайсов без биометрии
      } else {
        PanicService.killSwitch(context);
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

  void _onSuccess() async {
    if (widget.requireBiometric) {
      await PanicService.resetPanicFlag();
    }
    if (!mounted) return;
    final needCodes = !(await hasGateHashes());
    if (needCodes) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SetAccessCodesScreen(
            deathDate: widget.deathDate,
            birthDate: widget.birthDate,
          ),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainScreen(
            deathDate: widget.deathDate,
            birthDate: widget.birthDate,
          ),
        ),
      );
    }
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