// lib/features/settings/panic_reveal_code_screen.dart
//
// Настройка кода для показа реальных сообщений после паники.
// Открывается по 10 тапам на версию в HUD.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/panic/panic_display_service.dart';
import '../../core/panic_service.dart';
import '../theme/app_colors.dart';

class PanicRevealCodeScreen extends StatefulWidget {
  const PanicRevealCodeScreen({super.key});

  @override
  State<PanicRevealCodeScreen> createState() => _PanicRevealCodeScreenState();
}

class _PanicRevealCodeScreenState extends State<PanicRevealCodeScreen> {
  final _codeController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _codeController.text.trim();
    final confirm = _confirmController.text.trim();
    setState(() => _error = null);
    if (code.isEmpty) {
      setState(() => _error = 'Введите код');
      return;
    }
    if (code != confirm) {
      setState(() => _error = 'Коды не совпадают');
      return;
    }
    if (code.length < 4) {
      setState(() => _error = 'Минимум 4 символа');
      return;
    }
    await PanicDisplayService.setRevealCode(code);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Код сохранён'),
          backgroundColor: AppColors.gridCyan,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Код показа реальных', style: TextStyle(fontSize: 14)),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDim,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'После паники сообщения показываются нейтральными. Этот код позволит увидеть реальный контент.',
              style: TextStyle(color: AppColors.textDim, fontSize: 12),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _codeController,
              obscureText: _obscure,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 8,
              decoration: InputDecoration(
                labelText: 'Код',
                errorText: _error,
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmController,
              obscureText: _obscure,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 8,
              decoration: const InputDecoration(labelText: 'Подтверждение'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gridCyan,
                foregroundColor: Colors.black,
              ),
              child: const Text('Сохранить'),
            ),
            const SizedBox(height: 32),
            TextButton(
              onPressed: _confirmFullLocalWipe,
              child: Text(
                'Стереть локальные данные REAL на устройстве…',
                style: TextStyle(
                  color: AppColors.warningRed.withOpacity(0.85),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmFullLocalWipe() async {
    final ok1 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Полный сброс REAL'),
        content: const Text(
          'Будут удалены база REAL, ключи сессии и резервы Ghost из настроек. '
          'Режим DECOY и коды калькулятора (отдельное хранилище) не затрагиваются. '
          'Продолжить?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Стереть', style: TextStyle(color: AppColors.warningRed)),
          ),
        ],
      ),
    );
    if (ok1 != true || !mounted) return;
    final confirmCtrl = TextEditingController();
    bool? ok2;
    try {
      ok2 = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Подтверждение'),
          content: TextField(
            controller: confirmCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Введите: УДАЛИТЬ',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                if (confirmCtrl.text.trim() == 'УДАЛИТЬ') {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      );
    } finally {
      confirmCtrl.dispose();
    }
    if (ok2 != true || !mounted) return;
    await PanicService.hardPurgeRealData();
  }
}
