// lib/timer_screen.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animate_do/animate_do.dart'; // Нам понадобится для красивого появления

class TimerScreen extends StatefulWidget {
  final DateTime birthDate;
  final DateTime deathDate;

  const TimerScreen({
    super.key,
    required this.birthDate,
    required this.deathDate,
  });

  @override
  State<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen> with SingleTickerProviderStateMixin {
  late Timer _mainTimer;
  late Timer _sloganTimer; // <-- Таймер для слоганов
  Duration _remainingTime = Duration.zero;
  Duration _livedTime = Duration.zero;

  late AnimationController _animationController;
  bool _showDayPrice = false;

  // --- Пул слоганов ---
  final List<String> _slogans = [
    "Don't waste time. Appreciate every second.",
    "The future is not promised. Act now.",
    "Every tick is a choice.",
    "This moment will never come again.",
    "What will you do with this gift?",
    "Make it count.",
  ];
  String _currentSlogan = "";
  bool _showSlogan = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();

    _updateTime();
    _mainTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
    });

    // --- Логика для слоганов ---
    _sloganTimer = Timer.periodic(const Duration(seconds: 17), (timer) {
      _showNewSlogan();
    });
  }

  void _showNewSlogan() {
    final random = Random();
    // Показываем новый случайный слоган
    setState(() {
      _currentSlogan = _slogans[random.nextInt(_slogans.length)];
      _showSlogan = true;
    });

    // Через 5 секунд прячем его
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _showSlogan = false;
        });
      }
    });
  }

  void _updateTime() {
    if (mounted) {
      final now = DateTime.now();
      setState(() {
        _remainingTime = widget.deathDate.difference(now);
        _livedTime = now.difference(widget.birthDate);
      });
    }
  }

  @override
  void dispose() {
    _mainTimer.cancel();
    _sloganTimer.cancel(); // <-- Не забываем отменять
    _animationController.dispose();
    super.dispose();
  }

  // ... (остальные функции _formatRemainingTime, buildDayPriceWidget, buildRemainingTimeWidget без изменений) ...
  String _formatRemainingTime(Duration duration) {
    if (duration.isNegative) return "0 DAYS 00:00:00";
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final days = duration.inDays % 365;
    final hours = twoDigits(duration.inHours % 24);
    final minutes = twoDigits(duration.inMinutes % 60);
    final seconds = twoDigits(duration.inSeconds % 60);
    return "${days} DAYS ${hours}:${minutes}:${seconds}";
  }

  @override
  Widget build(BuildContext context) {
    final remainingYears = _remainingTime.inDays ~/ 365;
    final remainingDaysTotal = _remainingTime.inDays > 0 ? _remainingTime.inDays : 1;
    final dayPrice = (1 / remainingDaysTotal) * 100;
    final totalYears = widget.deathDate.difference(widget.birthDate).inDays / 365;
    final crystalBrightness = 1.0 - (remainingYears / totalYears);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: GestureDetector(
        onTap: () {
          setState(() => _showDayPrice = true);
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) setState(() => _showDayPrice = false);
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // --- Основной контент ---
            // ИСПРАВЛЕНИЕ: Оборачиваем Column в SizedBox, чтобы он занял всю ширину
            SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                // ИСПРАВЛЕНИЕ: Явно указываем выравнивание по центру
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),
                  Text('LIVED: ${_livedTime.inDays} DAYS', style: GoogleFonts.robotoMono(fontSize: 12, color: Colors.white38)),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 200, height: 200,
                    child: AnimatedBuilder(
                      animation: _animationController,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: _animationController.value * 2 * pi,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const RadialGradient(colors: [Colors.black, Colors.transparent]),
                              boxShadow: [
                                BoxShadow(color: Colors.cyan.withOpacity(max(0.1, crystalBrightness * 0.7)), blurRadius: 50, spreadRadius: 10),
                              ],
                            ),
                            child: Icon(Icons.hourglass_bottom, size: 80, color: Colors.cyan.withOpacity(max(0.3, crystalBrightness))),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 30),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                    child: _showDayPrice ? _buildDayPriceWidget(dayPrice) : _buildRemainingTimeWidget(remainingYears),
                  ),
                  const Spacer(flex: 3),
                ],
              ),
            ),

            // --- СЛОЙ СО СЛОГАНОМ (остается без изменений) ---
            AnimatedOpacity(
              opacity: _showSlogan ? 1.0 : 0.0,
              duration: const Duration(seconds: 1),
              child: FadeInUp(
                animate: _showSlogan,
                child: Text(
                  _currentSlogan,
                  style: GoogleFonts.lato(
                    fontSize: 16,
                    fontStyle: FontStyle.italic,
                    color: Colors.white.withOpacity(0.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Виджеты _buildDayPriceWidget и _buildRemainingTimeWidget остаются без изменений
  Widget _buildDayPriceWidget(double dayPrice) {
    return Column(
      key: const ValueKey('dayPrice'),
      children: [
        Text('${dayPrice.toStringAsFixed(4)}%', style: GoogleFonts.russoOne(fontSize: 48, color: Colors.redAccent)),
        const SizedBox(height: 10),
        Text('OF YOUR REMAINING ESSENCE', style: TextStyle(fontFamily: 'Orbitron',fontSize: 14, color: Colors.redAccent.withOpacity(0.7), letterSpacing: 2)),
      ],
    );
  }

  Widget _buildRemainingTimeWidget(int remainingYears) {
    return Column(
      key: const ValueKey('remainingTime'),
      children: [
        Text(remainingYears.toString(), style: GoogleFonts.russoOne(fontSize: 80, color: Colors.white, height: 1.0)),
        Text(_formatRemainingTime(_remainingTime), style: GoogleFonts.robotoMono(fontSize: 18, color: Colors.white70)),
        const SizedBox(height: 10),
        Text('YEARS OF POTENTIAL', style: TextStyle(fontFamily: 'Orbitron',fontSize: 14, color: Colors.cyan.withOpacity(0.7), letterSpacing: 2)),
      ],
    );
  }
}