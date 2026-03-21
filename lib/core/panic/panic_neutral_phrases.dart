// lib/core/panic/panic_neutral_phrases.dart
//
// Нейтральные фразы для подмены контента в режиме паники.
// Проверяющий видит «живую» переписку без чувствительных данных.

/// Пул нейтральных фраз для подмены реального контента сообщений.
const List<String> kPanicNeutralPhrases = [
  'OK',
  'Sure',
  'Thanks',
  '👍',
  'See you',
  'Got it',
  'Will do',
  'Let me check',
  'Sounds good',
  'Понятно',
  'Договорились',
  'Хорошо',
  'До завтра',
  'Спасибо',
  'Давай',
  'Ок',
  'Принято',
  'Угу',
  'Напишу',
  'Позже',
];

/// Возвращает нейтральную фразу для messageId (детерминированно).
String neutralPhraseForId(String messageId) {
  final idx = messageId.hashCode % kPanicNeutralPhrases.length;
  return kPanicNeutralPhrases[idx.abs()];
}
