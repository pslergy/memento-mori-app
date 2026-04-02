import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';

import '../theme/app_colors.dart';
import 'login_screen.dart';
import 'registration_screen.dart';

class AuthGateScreen extends StatelessWidget {
  const AuthGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FadeInDown(
              child: Icon(Icons.shield_outlined, size: 80, color: AppColors.gridCyan),
            ),
            const SizedBox(height: 30),
            const Text(
              "GRID ACCESS",
              style: TextStyle(
                fontSize: 22,
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 5,
              ),
            ),
            const SizedBox(height: 10),
            Text("Authorization required to establish uplink.",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 60),

            // КНОПКА: ВОЙТИ
            FadeInLeft(
              child: _AuthButton(
                label: "RESTORE ACCESS",
                desc: "I already have an identity",
                color: Colors.white,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
              ),
            ),
            const SizedBox(height: 20),

            // КНОПКА: СОЗДАТЬ
            FadeInRight(
              child: _AuthButton(
                label: "CREATE IDENTITY",
                desc: "Generate new Nomad profile",
                color: AppColors.gridCyan,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegistrationScreen())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  final String label;
  final String desc;
  final Color color;
  final VoidCallback onTap;

  const _AuthButton({required this.label, required this.desc, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  border: Border.all(color: color.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(15),
                  color: color.withOpacity(0.05)
              ),
              child: Column(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    desc,
                    style: const TextStyle(color: AppColors.textDim, fontSize: 8),
                  ),
                ],
              ),
            ),
    );
  }
}