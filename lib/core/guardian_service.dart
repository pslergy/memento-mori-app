// lib/core/guardian_service.dart
import 'dart:ui'; // Для Locale
import 'package:memento_mori_app/core/api_service.dart';

class GuardianService {
  static final GuardianService _instance = GuardianService._internal();
  factory GuardianService() => _instance;
  GuardianService._internal();

  final ApiService _apiService = ApiService();
  Map<String, dynamic> _dictionary = {};

  // Пороговое значение риска. Можем тоже получать его с сервера в будущем.
  final double _riskThreshold = 10.0;

  Future<void> initialize() async {
    try {
      _dictionary = await _apiService.getGuardianDictionary();
      print("--- [Guardian] Dictionary version ${_dictionary['version']} loaded. ---");
    } catch (e) {
      print("--- [Guardian] Failed to load dictionary: $e ---");
    }
  }

  // Главный метод: теперь он возвращает true/false
  bool checkForFlags(String text) {
    if (_dictionary.isEmpty) return false;

    // Определяем язык пользователя (очень упрощенно, лучше брать из настроек)
    final lang = window.locale.languageCode; // 'ru', 'en', etc.

    final riskScore = _calculateMessageRisk(text, lang);

    return riskScore >= _riskThreshold;
  }

  // --- ТВОЯ ЛОГИКА, ПЕРЕВЕДЕННАЯ НА DART ---
  double _calculateMessageRisk(String message, String mainLang) {
    final keywordsData = _dictionary['keywords'] as Map<String, dynamic>?;
    if (keywordsData == null) return 0.0;

    final lowerCaseMessage = message.toLowerCase();
    double totalScore = 0.0;
    final foundPhrases = <String>{};

    // Функция, которая ищет по конкретному языку
    void checkLang(String lang) {
      if (keywordsData[lang] == null) return;

      final langKeywords = keywordsData[lang] as Map<String, dynamic>;
      langKeywords.forEach((category, items) {
        final phraseList = items as List<dynamic>;
        for (final item in phraseList) {
          final phrase = (item['phrase'] as String).toLowerCase();
          final score = item['score'];
          if (lowerCaseMessage.contains(phrase) && !foundPhrases.contains(phrase)) {
            print("--- [Guardian] Flag found in '$lang' dictionary: '$phrase', score: $score");
            totalScore += (score ?? 0).toDouble();
            foundPhrases.add(phrase);
          }
        }
      });
    }

    // 1. Сначала проверяем основной язык системы
    checkLang(mainLang);

    // 2. Затем проходимся по ВСЕМ словарям
    keywordsData.keys.forEach((langKey) {
      if (langKey != mainLang) { // Пропускаем тот, что уже проверили
        checkLang(langKey);
      }
    });

    if (totalScore > 0) {
      print("--- [Guardian] Total risk score for message: $totalScore");
    }
    return totalScore;
  }}