// lib/core/utils/geo_privacy.dart

class GeoPrivacy {
  /// Превращает точные координаты в ID квадрата 1км x 1км
  static String getZoneId(double lat, double lon) {
    // Делим координаты на 0.01 (примерно 1.1 км)
    // Это создает "сетку" на всей планете.
    int latIdx = (lat / 0.01).floor();
    int lonIdx = (lon / 0.01).floor();
    return "ZONE_${latIdx}_${lonIdx}";
  }
}