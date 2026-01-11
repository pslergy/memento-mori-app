import 'package:flutter/material.dart';
import 'ghost_controller.dart';

class GhostInputField extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade800),
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, __) {
            return Text(
              controller.value.isEmpty ? hint : controller.masked,
              style: TextStyle(
                color: controller.value.isEmpty
                    ? Colors.grey
                    : Colors.white,
                fontSize: 16,
              ),
            );
          },
        ),
      ),
    );
  }
}
