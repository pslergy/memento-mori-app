import 'dart:async';
import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';


import 'features/theme/app_colors.dart';

class TimerScreen extends StatefulWidget {
  final DateTime birthDate;
  final DateTime deathDate;
  const TimerScreen({super.key, required this.birthDate, required this.deathDate});

  @override
  State<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen> {
  late Timer _fastTimer;
  Duration _remainingTime = Duration.zero;
  double _sessionSecondsLost = 0;
  DateTime _sessionStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _fastTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!mounted) return;
      setState(() {
        _remainingTime = widget.deathDate.difference(DateTime.now());
        _sessionSecondsLost = DateTime.now().difference(_sessionStart).inMilliseconds / 1000;
      });
    });
  }

  @override
  void dispose() { _fastTimer.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final totalLifeMs = widget.deathDate.difference(widget.birthDate).inMilliseconds;
    final progress = (_remainingTime.inMilliseconds / totalLifeMs).clamp(0.0, 1.0);
    final double percentLeft = progress * 100;
    String fullStr = percentLeft.toStringAsFixed(10);
    List<String> parts = fullStr.split('.');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container( // 🔥 ГАРАНТИЯ ЦЕНТРА
        width: double.infinity,
        height: double.infinity,
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "TEMPORAL EROSION",
                style: TextStyle(
                  color: AppColors.warningRed,
                  fontSize: 10,
                  letterSpacing: 5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 40),

              // ТАЙМЕР
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 260, height: 260,
                    child: CircularProgressIndicator(value: progress, strokeWidth: 1, color: progress > 0.2 ? AppColors.gridCyan : AppColors.warningRed, backgroundColor: AppColors.white10),
                  ),
                  Column(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            parts[0],
                            style: const TextStyle(fontSize: 50, color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            ".",
                            style: TextStyle(fontSize: 30, color: AppColors.warningRed, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            parts[1].substring(0, 5),
                            style: const TextStyle(fontSize: 16, color: Colors.white70),
                          ),
                        ],
                      ),
                      const Text(
                        "PERCENT REMAINING",
                        style: TextStyle(fontSize: 8, color: AppColors.textDim, letterSpacing: 1.5),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 50),

              // МАНИФЕСТ
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: const Text(
                  "Every millisecond is a tactical loss. Reach out. Synchronize. Survive.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // СТАТИСТИКА
              Text(
                "${_remainingTime.inSeconds}s",
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w300),
              ),
              Text(
                "SESSION LOSS: ${_sessionSecondsLost.toStringAsFixed(3)}s",
                style: TextStyle(
                  color: AppColors.warningRed.withOpacity(0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}