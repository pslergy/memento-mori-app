// Экран однократной установки двух кодов доступа (основной + аварийный).
// После регистрации/входа: первый код — для обычного месса, второй — для принуждения.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/decoy/app_mode.dart';
import '../../core/decoy/gate_storage.dart';
import '../../core/decoy/mode_resolver.dart';
import '../../main_screen.dart';

class SetAccessCodesScreen extends StatefulWidget {
  final DateTime deathDate;
  final DateTime birthDate;

  const SetAccessCodesScreen({
    super.key,
    required this.deathDate,
    required this.birthDate,
  });

  @override
  State<SetAccessCodesScreen> createState() => _SetAccessCodesScreenState();
}

class _SetAccessCodesScreenState extends State<SetAccessCodesScreen> {
  final _code1Controller = TextEditingController();
  final _code2Controller = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _code1Controller.dispose();
    _code2Controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c1 = _code1Controller.text.trim();
    final c2 = _code2Controller.text.trim();
    if (c1.isEmpty || c2.isEmpty) {
      setState(() => _error = 'Введите оба кода');
      return;
    }
    if (c1 == c2) {
      setState(() => _error = 'Коды должны отличаться');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final primary = hashAccessCode(c1);
      final alternative = hashAccessCode(c2);
      await saveGateHashes(primary, alternative);
      await saveGateMode(AppMode.REAL);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainScreen(
            deathDate: widget.deathDate,
            birthDate: widget.birthDate,
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка сохранения');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Text(
                'Коды доступа с калькулятора',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Первый — для обычного входа. Второй — для ситуации принуждения (одинаковое поведение ввода).',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _code1Controller,
                obscureText: _obscure1,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Код 1 (основной)',
                  labelStyle: TextStyle(color: Colors.white54),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure1 ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                    onPressed: () => setState(() => _obscure1 = !_obscure1),
                  ),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code2Controller,
                obscureText: _obscure2,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Код 2 (аварийный)',
                  labelStyle: TextStyle(color: Colors.white54),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure2 ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                    onPressed: () => setState(() => _obscure2 = !_obscure2),
                  ),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.orange)),
              ],
              const Spacer(),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _saving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Сохранить', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
