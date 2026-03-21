import 'package:flutter/material.dart';
import 'dart:async';

/// 🖥️ Terminal Style Widgets
/// Unified terminal-style UI components for auth and onboarding screens

class TerminalText extends StatelessWidget {
  final String text;
  final Color color;
  final double fontSize;
  final FontWeight? fontWeight;
  final TextAlign? textAlign;

  const TerminalText(
    this.text, {
    super.key,
    this.color = Colors.greenAccent,
    this.fontSize = 14,
    this.fontWeight,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'RobotoMono',
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: 0.5,
      ),
      textAlign: textAlign,
    );
  }
}

class TerminalTitle extends StatelessWidget {
  final String text;
  final Color color;

  const TerminalTitle(
    this.text, {
    super.key,
    this.color = Colors.greenAccent,
  });

  @override
  Widget build(BuildContext context) {
    return TerminalText(
      text,
      color: color,
      fontSize: 20,
      fontWeight: FontWeight.bold,
    );
  }
}

class TerminalSubtitle extends StatelessWidget {
  final String text;
  final Color color;

  const TerminalSubtitle(
    this.text, {
    super.key,
    this.color = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    return TerminalText(
      text,
      color: color,
      fontSize: 12,
    );
  }
}

class TerminalLoadingIndicator extends StatefulWidget {
  final String message;
  final Color color;

  const TerminalLoadingIndicator({
    super.key,
    this.message = "Loading...",
    this.color = Colors.greenAccent,
  });

  @override
  State<TerminalLoadingIndicator> createState() =>
      _TerminalLoadingIndicatorState();
}

class _TerminalLoadingIndicatorState extends State<TerminalLoadingIndicator> {
  int _dotCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      setState(() {
        _dotCount = (_dotCount + 1) % 4;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * _dotCount;
    return TerminalText(
      '${widget.message}$dots',
      color: widget.color,
    );
  }
}

class TerminalProgressBar extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  final List<String> stepLabels;

  const TerminalProgressBar({
    super.key,
    required this.currentStep,
    required this.totalSteps,
    required this.stepLabels,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < totalSteps; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                TerminalText(
                  i < currentStep
                      ? '[OK]'
                      : (i == currentStep ? '[...]' : '[  ]'),
                  color: i < currentStep
                      ? Colors.greenAccent
                      : (i == currentStep
                          ? Colors.yellowAccent
                          : Colors.white38),
                  fontSize: 12,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TerminalText(
                    stepLabels[i],
                    color: i <= currentStep ? Colors.white70 : Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class TerminalErrorDialog extends StatelessWidget {
  final String title;
  final String message;
  final String? solution;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  const TerminalErrorDialog({
    super.key,
    required this.title,
    required this.message,
    this.solution,
    this.onRetry,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D0D),
      title: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TerminalTitle(title, color: Colors.redAccent),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TerminalText(message, color: Colors.white70),
            if (solution != null) ...[
              const SizedBox(height: 16),
              TerminalText('Solution:',
                  color: Colors.greenAccent, fontWeight: FontWeight.bold),
              const SizedBox(height: 4),
              TerminalText(solution!, color: Colors.white70),
            ],
          ],
        ),
      ),
      actions: [
        if (onDismiss != null)
          TextButton(
            onPressed: onDismiss,
            child: const TerminalText('Dismiss', color: Colors.white54),
          ),
        if (onRetry != null)
          ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
            ),
            child: const TerminalText('Retry',
                color: Colors.black, fontWeight: FontWeight.bold),
          ),
      ],
    );
  }
}

class TerminalInfoBox extends StatelessWidget {
  final String title;
  final String content;
  final IconData icon;
  final Color color;

  const TerminalInfoBox({
    super.key,
    required this.title,
    required this.content,
    this.icon = Icons.info_outline,
    this.color = Colors.cyanAccent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: TerminalText(title,
                    color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TerminalText(content, color: Colors.white70),
        ],
      ),
    );
  }
}
