import 'dart:async';
import 'package:flutter/material.dart';
import 'ghost_controller.dart';

class GhostInputField extends StatefulWidget {
  final GhostController controller;
  final VoidCallback onTap;
  final String hint;

  const GhostInputField({
    super.key,
    required this.controller,
    required this.onTap,
    required this.hint,
  });

  @override
  State<GhostInputField> createState() => _GhostInputFieldState();
}

class _GhostInputFieldState extends State<GhostInputField> {
  bool _cursorVisible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
          (_) => setState(() => _cursorVisible = !_cursorVisible),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  InlineSpan _cursor() {
    if (!_cursorVisible) return const TextSpan(text: '');
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        width: 2,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        color: Colors.redAccent,
      ),
    );
  }

  TextSpan _buildText() {
    final text = widget.controller.value;
    final cursor = widget.controller.cursorPosition;

    if (text.isEmpty) {
      return TextSpan(children: [
        _cursor(),
        TextSpan(
          text: ' ${widget.hint}',
          style: const TextStyle(color: Colors.grey),
        ),
      ]);
    }

    return TextSpan(children: [
      TextSpan(
        text: text.substring(0, cursor),
        style: const TextStyle(color: Colors.white),
      ),
      _cursor(),
      TextSpan(
        text: text.substring(cursor),
        style: const TextStyle(color: Colors.white),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (_, __) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade800),
            ),
            child: RichText(
              text: _buildText(),
              textDirection: TextDirection.ltr,
            ),
          );
        },
      ),
    );
  }
}
