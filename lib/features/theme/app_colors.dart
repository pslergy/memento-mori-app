import 'package:flutter/material.dart';

class AppColors {
  // Основные фоны
  static const Color background = Color(0xFF050505);
  static const Color surface = Color(0xFF0D0D0D);
  static const Color cardBackground = Color(0xFF111111);

  // Тактические акценты
  static const Color gridCyan = Colors.cyanAccent;
  static const Color cloudGreen = Colors.greenAccent;
  static const Color warningRed = Colors.redAccent;
  static const Color sonarPurple = Colors.purpleAccent;
  static const Color stealthOrange = Colors.orangeAccent;

  // Прозрачные слои (решение твоей ошибки)
  static final Color white05 = Colors.white.withOpacity(0.05);
  static final Color white10 = Colors.white.withOpacity(0.1);
  static final Color white24 = Colors.white24;

  // Тексты
  static const Color textMain = Colors.white;
  static const Color textDim = Colors.white38;
  static final Color textMuted = Colors.white.withOpacity(0.1);
}