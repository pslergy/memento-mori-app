import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Сервис для получения названия места по координатам
/// Использует reverse geocoding для преобразования координат в читаемое название
class LocationNameService {
  static final LocationNameService _instance = LocationNameService._internal();
  factory LocationNameService() => _instance;
  LocationNameService._internal();

  /// Кэш для названий мест (чтобы не делать лишние запросы)
  final Map<String, String> _locationCache = {};

  /// Получает название места по координатам
  /// Использует зону 1.1 км (округление до 2 знаков после запятой)
  /// 
  /// [lat] - широта
  /// [lon] - долгота
  /// 
  /// Возвращает название места или null, если не удалось определить
  Future<String?> getLocationName(double lat, double lon) async {
    // Огрубляем координаты до 1.1 км (2 знака после запятой)
    final double blurredLat = double.parse(lat.toStringAsFixed(2));
    final double blurredLon = double.parse(lon.toStringAsFixed(2));
    
    // Создаем ключ для кэша
    final String cacheKey = "${blurredLat}_${blurredLon}";
    
    // Проверяем кэш
    if (_locationCache.containsKey(cacheKey)) {
      return _locationCache[cacheKey];
    }

    try {
      // Используем reverse geocoding для получения названия места
      List<Placemark> placemarks = await placemarkFromCoordinates(
        blurredLat,
        blurredLon,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        
        // Формируем название места
        // Приоритет: улица > район > город > область
        String locationName;
        
        if (place.street != null && place.street!.isNotEmpty) {
          locationName = place.street!;
          if (place.subLocality != null && place.subLocality!.isNotEmpty) {
            locationName += ", ${place.subLocality}";
          }
        } else if (place.subLocality != null && place.subLocality!.isNotEmpty) {
          locationName = place.subLocality!;
        } else if (place.locality != null && place.locality!.isNotEmpty) {
          locationName = place.locality!;
        } else if (place.administrativeArea != null && place.administrativeArea!.isNotEmpty) {
          locationName = place.administrativeArea!;
        } else {
          locationName = "Неизвестная локация";
        }

        // Сохраняем в кэш
        _locationCache[cacheKey] = locationName;
        return locationName;
      }
    } catch (e) {
      print("⚠️ [LocationName] Failed to get location name: $e");
    }

    return null;
  }

  /// Получает название места по sectorId (формат: S_6412_3012)
  /// Извлекает координаты из sectorId и получает название
  Future<String?> getLocationNameFromSectorId(String sectorId) async {
    try {
      // Парсим sectorId: S_6412_3012 -> lat=64.12, lon=30.12
      final parts = sectorId.replaceFirst('S_', '').split('_');
      if (parts.length != 2) return null;

      // Восстанавливаем координаты из sectorId
      // sectorId хранит координаты без точки: 6412 -> 64.12
      final String latStr = parts[0];
      final String lonStr = parts[1];

      // Вставляем точку на правильное место
      // Координаты в sectorId хранятся как целые числа без точки
      // Например: 6412 -> 64.12, 3012 -> 30.12
      double lat;
      double lon;

      // Для широты: первые 2 цифры - целая часть, остальные - дробная
      if (latStr.length >= 4) {
        final intPart = latStr.substring(0, latStr.length - 2);
        final fracPart = latStr.substring(latStr.length - 2);
        lat = double.parse('$intPart.$fracPart');
      } else {
        return null;
      }

      // Для долготы: аналогично
      if (lonStr.length >= 4) {
        final intPart = lonStr.substring(0, lonStr.length - 2);
        final fracPart = lonStr.substring(lonStr.length - 2);
        lon = double.parse('$intPart.$fracPart');
      } else {
        return null;
      }

      return await getLocationName(lat, lon);
    } catch (e) {
      print("⚠️ [LocationName] Failed to parse sectorId: $e");
      return null;
    }
  }

  /// Очищает кэш (можно вызывать периодически)
  void clearCache() {
    _locationCache.clear();
  }
}
