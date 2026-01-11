import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:memento_mori_app/features/auth/auth_gate_screen.dart'; // 🔥 Обязательно импортируй это
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
  final _storage = const FlutterSecureStorage();

  // 🔥 МОДИФИЦИРОВАННАЯ ЛОГИКА ДОСТУПА
  Future<void> _handleAccess() async {
    // 1. Код Принуждения (Silent Wipe)
    if (_expression == '9111') {
      print("☢️ [GATE] Silent Wipe PIN triggered.");
      if (mounted) await PanicService.killSwitch(context);
      return;
    }

    // 2. Обычный вход (3301)
    if (_expression == '3301') {
      // Читаем всё через наш единый Vault
      final String? token = await Vault.read('auth_token');
      final String? deathStr = await Vault.read('user_deathDate');
      final String? birthStr = await Vault.read('user_birthDate');

      print("🕵️ [Gate-Debug] Vault Status -> Token: ${token != null}, Death: ${deathStr != null}, Birth: ${birthStr != null}");

      if (!mounted) return;

      // КРИТИЧЕСКИЙ ФИКС: Если токен есть - мы пускаем.
      // Даже если даты потерялись из-за бага Tecno, мы подставим фолбек.
      if (token != null) {
        final bool isGhost = token == 'GHOST_MODE_ACTIVE';
        print("🔓 [Access] ${isGhost ? 'Ghost Node' : 'Cloud Node'} identified. Unlocking...");

        // Парсим даты с защитой от null/error
        final DateTime death = DateTime.tryParse(deathStr ?? '')
            ?? DateTime.now().add(const Duration(days: 365 * 50));
        final DateTime birth = DateTime.tryParse(birthStr ?? '')
            ?? DateTime(2000, 1, 1);

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BioLockScreen(
              deathDate: death,
              birthDate: birth,
            ),
          ),
        );
      } else {
        // Если токена нет совсем - значит регистрации не было
        print("🔑 [Access] No identity found in Vault. To Auth Gate.");
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AuthGateScreen()),
        );
      }
      return;
    }

    // Обычная арифметика
    _calculate();
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_expression, style: GoogleFonts.robotoMono(fontSize: 32, color: Colors.grey)),
                  const SizedBox(height: 10),
                  Text(_result, style: GoogleFonts.robotoMono(fontSize: 64, color: Colors.white)),
                ],
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