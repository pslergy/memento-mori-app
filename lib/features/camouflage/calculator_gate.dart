import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:memento_mori_app/features/auth/auth_gate_screen.dart';
import '../../core/decoy/app_mode.dart';
import '../../core/decoy/gate_storage.dart';
import '../../core/decoy/mode_resolver.dart';
import '../../core/decoy/session_teardown.dart';
import '../../core/locator.dart';
import '../../core/panic_service.dart';
import '../../core/storage_service.dart';
import '../auth/bio_lock_screen.dart';

class CalculatorGate extends StatefulWidget {
  const CalculatorGate({super.key});

  @override
  State<CalculatorGate> createState() => _CalculatorGateState();
}

class _CalculatorGateState extends State<CalculatorGate> {
  String _expression = '';
  String _result = '0';

  /// Общий переход: разблокировка в выбранном режиме. Одинаковое поведение для REAL и DECOY (без логов режима).
  /// Если auth_token нет, но есть user_id — считаем Ghost (на Huawei scoped может не вернуть токен).
  Future<void> _unlockWithVault(BuildContext context, AppMode mode) async {
    final String? token = await Vault.read('auth_token');
    final String? userId = await Vault.read('user_id');
    final String? deathStr = await Vault.read('user_deathDate');
    final String? birthStr = await Vault.read('user_birthDate');
    if (kDebugMode) {
      debugPrint('[GATE] 3301 unlock: token=${token != null ? "***" : "null"}, userId=${userId != null ? "***" : "null"}, death=${deathStr != null}, birth=${birthStr != null}');
    }
    if (!mounted) return;
    final bool hasIdentity = token != null && token.isNotEmpty;
    final bool hasGhostIdentity = !hasIdentity &&
        userId != null &&
        userId.isNotEmpty &&
        (deathStr != null || birthStr != null);
    if (hasIdentity || hasGhostIdentity) {
      if (hasGhostIdentity) {
        await Vault.write('auth_token', 'GHOST_MODE_ACTIVE');
      }
      final DateTime death = DateTime.tryParse(deathStr ?? '')
          ?? DateTime.now().add(const Duration(days: 365 * 50));
      final DateTime birth = DateTime.tryParse(birthStr ?? '')
          ?? DateTime(2000, 1, 1);
      final bool isPanicActivated = await PanicService.isPanicProtocolActivated();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BioLockScreen(
            deathDate: death,
            birthDate: birth,
            requireBiometric: isPanicActivated,
          ),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthGateScreen()),
      );
    }
  }

  Future<void> _handleAccess() async {
    if (_expression == '9111') {
      if (kDebugMode) debugPrint('[GATE] Silent Wipe PIN triggered.');
      if (mounted) await PanicService.killSwitch(context);
      return;
    }

    final hashes = await getGateHashes();
    if (hashes == null) {
      if (_expression == '3301') {
        final String? token = await Vault.read('auth_token');
        final String? userId = await Vault.read('user_id');
        final String? deathStr = await Vault.read('user_deathDate');
        final String? birthStr = await Vault.read('user_birthDate');
        if (!mounted) return;
        final bool hasIdentity = token != null && token.isNotEmpty;
        final bool hasGhostIdentity = !hasIdentity &&
            userId != null &&
            userId.isNotEmpty &&
            (deathStr != null || birthStr != null);
        if (hasIdentity || hasGhostIdentity) {
          if (hasGhostIdentity) {
            await Vault.write('auth_token', 'GHOST_MODE_ACTIVE');
          }
          final DateTime death = DateTime.tryParse(deathStr ?? '')
              ?? DateTime.now().add(const Duration(days: 365 * 50));
          final DateTime birth = DateTime.tryParse(birthStr ?? '')
              ?? DateTime(2000, 1, 1);
          final bool isPanicActivated = await PanicService.isPanicProtocolActivated();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => BioLockScreen(
                deathDate: death,
                birthDate: birth,
                requireBiometric: isPanicActivated,
              ),
            ),
          );
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const AuthGateScreen()),
          );
        }
      } else {
        _calculate();
      }
      return;
    }

    final inputHash = hashAccessCode(_expression);
    final resolved = resolveMode(
      inputHash: inputHash,
      primaryAccessHash: hashes.primary,
      alternativeAccessHash: hashes.alternative,
    );
    if (resolved == AppMode.INVALID) {
      _calculate();
      return;
    }

    final currentMode = await getGateMode();
    if (currentMode != resolved) {
      await teardownSession();
      ensureCoreLocator(resolved);
      if (!isMeshReady) setupSessionLocator(resolved);
      await saveGateMode(resolved);
    }
    if (!mounted) return;
    await _unlockWithVault(context, resolved);
  }

  void _calculate() {
    try {
      Parser p = Parser();
      Expression exp = p.parse(_expression.replaceAll('×', '*').replaceAll('÷', '/'));
      ContextModel cm = ContextModel();
      double eval = exp.evaluate(EvaluationType.REAL, cm);
      String res = eval.toString();
      if (res.endsWith('.0')) res = res.substring(0, res.length - 2);
      setState(() => _result = res);
    } catch (e) {
      setState(() => _result = 'Error');
    }
  }

  void _onPressed(String text) {
    setState(() {
      if (text == 'AC') {
        _expression = '';
        _result = '0';
      } else if (text == '⌫') {
        if (_expression.isNotEmpty) {
          _expression = _expression.substring(0, _expression.length - 1);
        }
      } else if (text == '=') {
        _handleAccess();
      } else {
        _expression += text;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(24),
              alignment: Alignment.bottomRight,
              child: FittedBox(
                alignment: Alignment.bottomRight,
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _expression,
                      style: const TextStyle(
                        fontSize: 32,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      // Плейсхолдер результата, реальное значение уже в _result
                      "",
                      style: TextStyle(
                        fontSize: 64,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _result,
                      style: const TextStyle(
                        fontSize: 48,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  _buildRow(['AC', '⌫', '%', '÷'], Colors.orange),
                  _buildRow(['7', '8', '9', '×'], Colors.grey[800]!),
                  _buildRow(['4', '5', '6', '-'], Colors.grey[800]!),
                  _buildRow(['1', '2', '3', '+'], Colors.grey[800]!),
                  _buildRow(['00', '0', '.', '='], Colors.grey[800]!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(List<String> buttons, Color color) {
    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: buttons.map((text) {
          final isOperator = ['÷', '×', '-', '+', '='].contains(text);
          final isAction = ['AC', '⌫', '%'].contains(text);
          final btnColor = isOperator ? Colors.orange : (isAction ? Colors.grey : Colors.grey[900]);
          final txtColor = isAction ? Colors.black : Colors.white;

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: btnColor,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: () => _onPressed(text),
                child: Text(text, style: TextStyle(fontSize: 24, color: txtColor)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}