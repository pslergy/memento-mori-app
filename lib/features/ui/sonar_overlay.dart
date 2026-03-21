import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';

import 'package:memento_mori_app/core/native_mesh_service.dart';

import '../theme/app_colors.dart';

class SonarOverlay {
  static void show(BuildContext context, String senderId) {
    HapticFeedback.heavyImpact();

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.95), // Глубокий черный фон
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (ctx, anim1, anim2) => Center(
        child: Material( // Чтобы текстовые стили работали корректно
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Визуальный эффект "Волн"
              Pulse(
                infinite: true,
                child: Container(
                  padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.sonarPurple.withOpacity(0.5), width: 2),
                  ),
                  child: const Icon(Icons.record_voice_over, color: AppColors.sonarPurple, size: 60),
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                "ACOUSTIC SIGNAL CAPTURED",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "IDENT: Nomad #${senderId.substring(0, 6)}",
                style: const TextStyle(
                  color: AppColors.sonarPurple,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 60),

              // Кнопки управления
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _TacticalBtn(
                      label: "ABORT",
                      color: AppColors.warningRed,
                      onTap: () => Navigator.pop(ctx)
                  ),
                  const SizedBox(width: 20),
                  _TacticalBtn(
                      label: "ESTABLISH LINK",
                      color: AppColors.gridCyan,
                      onTap: () {
                        Navigator.pop(ctx);
                        NativeMeshService.connect(senderId);
                      }
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

// Вспомогательный тактический виджет кнопки
class _TacticalBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TacticalBtn({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(10),
          color: color.withOpacity(0.05),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}