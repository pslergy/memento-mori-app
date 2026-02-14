import 'dart:math';

/// Этап 1 защиты: рандомизация таймингов для снижения паттернов.
/// Возвращает длительность в диапазоне [base * (1 - fraction), base * (1 + fraction)].
Duration randomDuration(Duration base, {double fraction = 0.2}) {
  if (fraction <= 0 || fraction > 0.5) fraction = 0.2;
  final ms = base.inMilliseconds;
  final delta = (ms * fraction).round().clamp(0, 15000);
  final r = Random.secure();
  final jitter = r.nextInt(2 * delta + 1) - delta;
  return Duration(milliseconds: (ms + jitter).clamp(1000, 120000));
}

/// Случайная задержка в миллисекундах: [baseMs, baseMs + rangeMs].
int randomDelayMs(int baseMs, int rangeMs) {
  if (rangeMs <= 0) return baseMs;
  return baseMs + Random.secure().nextInt(rangeMs + 1);
}
