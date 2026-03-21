// Смена кодов доступа из профиля.
// Первый код — для обычного входа, второй — для фейк/аварийного аккаунта.
// Связано с gate_storage, mode_resolver, CalculatorGate.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/decoy/app_mode.dart';
import '../../core/decoy/gate_storage.dart';
import '../../core/decoy/mode_resolver.dart';
import '../theme/app_colors.dart';

class ChangeAccessCodesScreen extends StatefulWidget {
  const ChangeAccessCodesScreen({super.key});

  @override
  State<ChangeAccessCodesScreen> createState() => _ChangeAccessCodesScreenState();
}

class _ChangeAccessCodesScreenState extends State<ChangeAccessCodesScreen> {
  final _currentController = TextEditingController();
  final _primaryController = TextEditingController();
  final _alternativeController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscurePrimary = true;
  bool _obscureAlt = true;
  String? _error;
  bool _saving = false;
  bool _needsVerification = true;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _checkVerificationNeeded();
  }

  Future<void> _checkVerificationNeeded() async {
    final hashes = await getGateHashes();
    if (!mounted) return;
    setState(() {
      _needsVerification = hashes != null;
      if (!_needsVerification) _verified = true;
    });
  }

  @override
  void dispose() {
    _currentController.dispose();
    _primaryController.dispose();
    _alternativeController.dispose();
    super.dispose();
  }

  Future<bool> _verifyCurrent() async {
    final code = _currentController.text.trim();
    if (code.isEmpty) return false;
    final hashes = await getGateHashes();
    if (hashes == null) return true;
    final inputHash = hashAccessCode(code);
    final resolved = resolveMode(
      inputHash: inputHash,
      primaryAccessHash: hashes.primary,
      alternativeAccessHash: hashes.alternative,
    );
    return resolved != AppMode.INVALID;
  }

  Future<void> _onVerify() async {
    setState(() => _error = null);
    final ok = await _verifyCurrent();
    if (!mounted) return;
    if (ok) {
      setState(() => _verified = true);
    } else {
      setState(() => _error = 'Неверный текущий код');
    }
  }

  Future<void> _save() async {
    final primary = _primaryController.text.trim();
    final alt = _alternativeController.text.trim();
    if (primary.isEmpty || alt.isEmpty) {
      setState(() => _error = 'Введите оба новых кода');
      return;
    }
    if (primary == alt) {
      setState(() => _error = 'Коды должны отличаться');
      return;
    }
    if (primary.length < 4 || alt.length < 4) {
      setState(() => _error = 'Код минимум 4 цифры');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final primaryHash = hashAccessCode(primary);
      final alternativeHash = hashAccessCode(alt);
      await saveGateHashes(primaryHash, alternativeHash);
      await saveGateMode(AppMode.REAL);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Коды сохранены'),
          backgroundColor: AppColors.cloudGreen,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка сохранения');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Коды доступа',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        backgroundColor: AppColors.surface,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Первый код открывает основное приложение. Второй — аварийный/фейк аккаунт.',
              style: TextStyle(
                color: AppColors.textDim,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 24),

            if (_needsVerification && !_verified) ...[
              Text(
                'Текущий код (подтверждение)',
                style: TextStyle(
                  color: AppColors.textDim,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _currentController,
                obscureText: _obscureCurrent,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '••••',
                  hintStyle: TextStyle(color: Colors.white24),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureCurrent ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.textDim,
                    ),
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _onVerify,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gridCyan,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Подтвердить'),
                ),
              ),
              const SizedBox(height: 32),
            ],

            if (_verified) ...[
              Text(
                'Новый код для основного входа',
                style: TextStyle(
                  color: AppColors.textDim,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _primaryController,
                obscureText: _obscurePrimary,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '4–12 цифр',
                  hintStyle: TextStyle(color: Colors.white24),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePrimary ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.textDim,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePrimary = !_obscurePrimary),
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Новый код для фейк-аккаунта',
                style: TextStyle(
                  color: AppColors.textDim,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _alternativeController,
                obscureText: _obscureAlt,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '4–12 цифр',
                  hintStyle: TextStyle(color: Colors.white24),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureAlt ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.textDim,
                    ),
                    onPressed: () =>
                        setState(() => _obscureAlt = !_obscureAlt),
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.warningRed),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gridCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text(
                          'Сохранить коды',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
