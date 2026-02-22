import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/features/auth/survival_guide_screen.dart';

class RecoveryPhraseScreen extends StatelessWidget {
  final String phrase; // Строка из 12 слов через пробел
  final bool isFlow; // 🔥 Добавлено


  const RecoveryPhraseScreen({super.key, required this.phrase, this.isFlow = false});

  @override
  Widget build(BuildContext context) {
    final words = phrase.split(' ');

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.security, size: 60, color: Colors.redAccent),
              const SizedBox(height: 20),
              const Text(
                "SECRET RECOVERY KEY",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 15),
              const Text(
                "Write these words down in order. If you lose your password, this is the ONLY way to recover your account.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 30),

              // Сетка слов
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, // Сделал 2 колонки для лучшей читаемости на мобилках
                    childAspectRatio: 3.5,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: words.length,
                  itemBuilder: (context, index) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D0D0D),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        children: [
                          Text(
                            "${index + 1}.",
                            style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              words[index],
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // Кнопка копирования
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: phrase));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Copied to clipboard (Unsafe! Write it down!)"),
                      backgroundColor: Colors.orange,
                    ),
                  );
                },
                icon: const Icon(Icons.copy, color: Colors.white, size: 18),
                label: const Text("COPY TO CLIPBOARD", style: TextStyle(color: Colors.white, fontSize: 12)),
              ),

              const SizedBox(height: 16),

              // Кнопка "Я записал"
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (isFlow) {
                    // 🔥 ШАГ 4: Переход к тактической инструкции
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const SurvivalGuideScreen()),
                    );
                  } else {
                    // Если это просто просмотр из настроек — возвращаемся назад
                    Navigator.of(context).pop();
                  }
                },
                child: const Text(
                    "I HAVE SECURELY SAVED IT",
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}