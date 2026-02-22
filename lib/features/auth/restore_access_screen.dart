import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import '../../ghost_input/ghost_controller.dart';
import '../../ghost_input/ghost_keyboard.dart';

class RestoreAccessScreen extends StatefulWidget {
  const RestoreAccessScreen({super.key});

  @override
  State<RestoreAccessScreen> createState() => _RestoreAccessScreenState();
}

class _RestoreAccessScreenState extends State<RestoreAccessScreen> {
  final _emailGhost = GhostController();
  final _phraseGhost = GhostController();
  final _passwordGhost = GhostController();

  bool _isLoading = false;

  void _showKeyboard(GhostController controller, String title) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GhostKeyboard(
        controller: controller,
        onSend: () => Navigator.pop(context),
      ),
    );
  }

  Future<void> _handleRestore() async {
    if (_emailGhost.value.isEmpty || _phraseGhost.value.isEmpty || _passwordGhost.value.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Fill all fields")));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final res = await ApiService().recoverAccount(
        email: _emailGhost.value,
        recoveryPhrase: _phraseGhost.value,
        newPassword: _passwordGhost.value,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Password updated! Please login."), backgroundColor: Colors.green)
        );
        Navigator.pop(context); // Возврат на экран логина
      }
    } catch (e) {
      if (mounted) {
        String error = e.toString().contains("Offline")
            ? "Syncing via Mesh... Protocol initiated."
            : "Restore failed. Check seed phrase.";

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("RESTORE ACCESS"), backgroundColor: Colors.black),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.history_edu, size: 60, color: Colors.redAccent),
            const SizedBox(height: 20),
            const Text(
              "Enter your 12-word seed phrase and email to set a new password.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 40),

            _buildField(label: "Email", controller: _emailGhost, hint: "your@email.com"),
            const SizedBox(height: 20),
            _buildField(label: "Seed Phrase", controller: _phraseGhost, hint: "12 words here...", isLong: true),
            const SizedBox(height: 20),
            _buildField(label: "New Password", controller: _passwordGhost, hint: "min 8 chars", isPass: true),

            const SizedBox(height: 40),

            ElevatedButton(
              onPressed: _isLoading ? null : _handleRestore,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isLoading
                  ? const CircularProgressIndicator(color: Colors.black)
                  : const Text("UPDATE PASSWORD", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField({required String label, required GhostController controller, required String hint, bool isPass = false, bool isLong = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _showKeyboard(controller, label.toUpperCase()),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            height: isLong ? 100 : 55,
            decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(12)),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Text(
                controller.value.isEmpty ? hint : (isPass ? controller.masked : controller.value),
                style: TextStyle(color: controller.value.isEmpty ? Colors.grey : Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}