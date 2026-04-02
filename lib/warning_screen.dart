// lib/warning_screen.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:memento_mori_app/l10n/app_localizations.dart';
import 'package:memento_mori_app/main_screen.dart';
// import 'package:url_launcher/url_launcher.dart'; // Для ссылок на Политику/Условия

class WarningScreen extends StatefulWidget {
  final DateTime deathDate;
  final DateTime birthDate;
  const WarningScreen({
    super.key,
    required this.deathDate,
    required this.birthDate, // <-- Делаем обязательным
  });

  @override
  State<WarningScreen> createState() => _WarningScreenState();
}

class _WarningScreenState extends State<WarningScreen> {
  bool _isAgreed = false;
  final ScrollController _scrollController = ScrollController();
  bool _isScrollCompleted = false; // Флаг, что пользователь доскроллил до конца

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      // Если доскроллили до самого низа
      if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
        if (!_isScrollCompleted) {
          setState(() {
            _isScrollCompleted = true;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // Вспомогательный виджет для пунктов списка
  Widget _buildDisclaimerPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, left: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(color: Colors.white70, fontSize: 16)),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.4))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!; // Сокращение для удобства

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.disclaimerTitle,
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.disclaimerP1, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5)),
                      const SizedBox(height: 15),
                      Text(l.disclaimerP2, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5)),
                      const SizedBox(height: 15),
                      Container( // Выделяем самый важный пункт
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(l.disclaimerP3, style: TextStyle(color: Colors.redAccent, fontSize: 16, height: 1.5, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 15),
                      Text(l.disclaimerP4, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5)),
                      const SizedBox(height: 10),
                      _buildDisclaimerPoint(l.disclaimerPoint1),
                      _buildDisclaimerPoint(l.disclaimerPoint2),
                      _buildDisclaimerPoint(l.disclaimerPoint3),
                      _buildDisclaimerPoint(l.disclaimerPoint4), // Пункт со ссылками
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Галочка становится активной только после прокрутки
              Row(
                children: [
                  Checkbox(
                    value: _isAgreed,
                    onChanged: _isScrollCompleted
                        ? (value) => setState(() => _isAgreed = value ?? false)
                        : null, // Неактивна, пока не доскроллят
                    checkColor: Colors.black,
                    activeColor: Colors.white,
                    side: BorderSide(color: _isScrollCompleted ? Colors.white : Colors.grey[700]!),
                  ),
                  Expanded(
                    child: Text(
                      l.iAgree,
                      style: TextStyle(color: _isScrollCompleted ? Colors.white : Colors.grey[700]!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isAgreed && _isScrollCompleted)
                      ? () {
                    Navigator.of(context).pushReplacement( // <-- ДОБАВЛЯЕМ ЭТО
                      MaterialPageRoute(
                        builder: (context) => MainScreen(
                          deathDate: widget.deathDate,
                          birthDate: widget.birthDate,
                        ),
                      ),
                    ); // <-- И ЗАКРЫВАЮЩУЮ СКОБКУ
                  }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (_isAgreed && _isScrollCompleted) ? Colors.white : Colors.grey[800],
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(l.proceed),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}