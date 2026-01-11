// lib/features/auth/auth_gate_screen.dart
import 'package:flutter/material.dart';
import 'login_screen.dart';
import 'registration_screen.dart'; // Наш старый экран

class AuthGateScreen extends StatelessWidget {
  const AuthGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        // TODO: Сделать красивый дизайн с лого
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
              child: const Text('Войти'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegistrationScreen())),
              child: const Text('Создать аккаунт'),
            ),
          ],
        ),
      ),
    );
  }
}