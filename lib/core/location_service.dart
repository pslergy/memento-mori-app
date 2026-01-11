import 'dart:math';

class GeoPrivacyService {
  /// Заблюривает координату, оставляя только 2 знака после запятой.
  /// Это дает точность около 1.1 км — достаточно для поиска "своих" рядом,
  /// но бесполезно для наведения артиллерии или точного слежения.
  static double blur(double coordinate) {
    // 64.123456 -> 64.12
    return double.parse(coordinate.toStringAsFixed(2));
  }

  /// Добавляет случайное смещение (джиттер) в пределах 500 метров.
  /// Это создает "облако неопределенности" вокруг пользователя.
  static double addJitter(double coordinate) {
    final Random random = Random();
    // Генерируем случайное смещение +- 0.005 градуса
    double offset = (random.nextDouble() - 0.5) / 100;
    return coordinate + offset;
  }
}