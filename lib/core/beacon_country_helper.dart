import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Код страны для чата The Beacon по странам (THE_BEACON_XX).
/// Сначала проверяется ручной выбор пользователя, иначе — локаль устройства.
class BeaconCountryHelper {
  BeaconCountryHelper._();

  static const String _prefKey = 'beacon_country_override';
  static String? _countryOverride;

  /// Загрузить сохранённый выбор страны (вызвать при старте приложения).
  static Future<void> loadOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefKey);
      _countryOverride = v; // null, '' (Global), or 'BY', 'RU', ...
    } catch (_) {
      _countryOverride = null;
    }
  }

  /// Установить страну для The Beacon вручную.
  /// [code] == null — по системе (локаль); '' — принудительно Global; 'BY', 'RU' и т.д. — страна.
  static Future<void> setCountryOverride(String? code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (code == null) {
        await prefs.remove(_prefKey);
        _countryOverride = null;
      } else if (code.isEmpty) {
        await prefs.setString(_prefKey, '');
        _countryOverride = '';
      } else {
        final cc = code.toUpperCase();
        if (cc.length == 2 && _isAlpha2(cc)) {
          await prefs.setString(_prefKey, cc);
          _countryOverride = cc;
        }
      }
    } catch (_) {}
  }

  /// Текущий выбранный вручную код страны (null = по системе, '' = принудительно Global).
  static String? get countryOverride => _countryOverride;

  /// Двухбуквенный ISO код страны: ручной выбор → локаль устройства → пусто (Global).
  static String getBeaconCountryCode() {
    if (_countryOverride != null) return _countryOverride!;
    try {
      final locale = WidgetsBinding.instance.platformDispatcher.locale;
      final cc = (locale.countryCode ?? '').toUpperCase();
      if (cc.length == 2 && _isAlpha2(cc)) return cc;
    } catch (_) {}
    return '';
  }

  static bool _isAlpha2(String s) {
    return s.codeUnits.every((c) => (c >= 65 && c <= 90));
  }

  /// chatId для The Beacon: THE_BEACON_<CC> или THE_BEACON_GLOBAL.
  static String beaconChatIdForCountry() {
    final cc = getBeaconCountryCode();
    return cc.isEmpty ? 'THE_BEACON_GLOBAL' : 'THE_BEACON_$cc';
  }

  /// Является ли [chatId] комнатой The Beacon (глобальной или по стране).
  static bool isBeaconChat(String? chatId) {
    if (chatId == null || chatId.isEmpty) return false;
    if (chatId == 'THE_BEACON_GLOBAL' || chatId == 'GLOBAL') return true;
    if (chatId.startsWith('THE_BEACON_') && chatId.length == 13) {
      final cc = chatId.substring(11);
      return _isAlpha2(cc);
    }
    return false;
  }

  /// Код страны из chatId (THE_BEACON_RU → RU), или пусто для глобального.
  static String countryCodeFromBeaconChatId(String? chatId) {
    if (chatId == null || chatId.isEmpty) return '';
    if (chatId != 'THE_BEACON_GLOBAL' && chatId != 'GLOBAL' &&
        chatId.startsWith('THE_BEACON_') && chatId.length == 13) {
      final cc = chatId.substring(11);
      return _isAlpha2(cc) ? cc : '';
    }
    return '';
  }

  /// Отображаемое название страны для UI (RU → Russia, US → United States, …).
  static const Map<String, String> _countryNames = {
    'RU': 'Russia', 'US': 'United States', 'GB': 'United Kingdom', 'DE': 'Germany',
    'FR': 'France', 'UA': 'Ukraine', 'BY': 'Belarus', 'KZ': 'Kazakhstan',
    'PL': 'Poland', 'IT': 'Italy', 'ES': 'Spain', 'TR': 'Turkey', 'CN': 'China',
    'IN': 'India', 'BR': 'Brazil', 'JP': 'Japan', 'KR': 'South Korea', 'CA': 'Canada',
    'AU': 'Australia', 'NL': 'Netherlands', 'SE': 'Sweden', 'NO': 'Norway', 'FI': 'Finland',
    'AT': 'Austria', 'BE': 'Belgium', 'CH': 'Switzerland', 'CZ': 'Czech Republic',
    'GR': 'Greece', 'HU': 'Hungary', 'PT': 'Portugal', 'RO': 'Romania', 'RS': 'Serbia',
    'SK': 'Slovakia', 'BG': 'Bulgaria', 'HR': 'Croatia', 'SI': 'Slovenia', 'LT': 'Lithuania',
    'LV': 'Latvia', 'EE': 'Estonia', 'MD': 'Moldova', 'GE': 'Georgia', 'AM': 'Armenia',
    'AZ': 'Azerbaijan', 'UZ': 'Uzbekistan', 'TM': 'Turkmenistan', 'TJ': 'Tajikistan', 'KG': 'Kyrgyzstan',
    'MN': 'Mongolia', 'IL': 'Israel', 'SA': 'Saudi Arabia', 'AE': 'United Arab Emirates', 'EG': 'Egypt',
    'ZA': 'South Africa', 'NG': 'Nigeria', 'KE': 'Kenya', 'MA': 'Morocco', 'AR': 'Argentina',
    'MX': 'Mexico', 'CO': 'Colombia', 'CL': 'Chile', 'PE': 'Peru', 'ID': 'Indonesia',
    'TH': 'Thailand', 'VN': 'Vietnam', 'MY': 'Malaysia', 'PH': 'Philippines', 'SG': 'Singapore',
    'NZ': 'New Zealand', 'IE': 'Ireland', 'DK': 'Denmark', 'LU': 'Luxembourg', 'IS': 'Iceland',
    'CY': 'Cyprus', 'MT': 'Malta', 'AL': 'Albania', 'MK': 'North Macedonia', 'BA': 'Bosnia and Herzegovina',
    'ME': 'Montenegro', 'XK': 'Kosovo', 'PK': 'Pakistan', 'BD': 'Bangladesh', 'LK': 'Sri Lanka',
    'NP': 'Nepal', 'IR': 'Iran', 'IQ': 'Iraq', 'SY': 'Syria', 'JO': 'Jordan', 'LB': 'Lebanon',
    'QA': 'Qatar', 'KW': 'Kuwait', 'BH': 'Bahrain', 'OM': 'Oman', 'YE': 'Yemen',
    'ET': 'Ethiopia', 'GH': 'Ghana', 'TZ': 'Tanzania', 'UG': 'Uganda', 'DZ': 'Algeria',
    'TN': 'Tunisia', 'LY': 'Libya', 'SD': 'Sudan', 'EC': 'Ecuador', 'VE': 'Venezuela',
    'BO': 'Bolivia', 'PY': 'Paraguay', 'UY': 'Uruguay', 'CR': 'Costa Rica', 'PA': 'Panama',
    'GT': 'Guatemala', 'CU': 'Cuba', 'DO': 'Dominican Republic', 'JM': 'Jamaica', 'HT': 'Haiti',
    'TW': 'Taiwan', 'HK': 'Hong Kong', 'AF': 'Afghanistan', 'MM': 'Myanmar', 'KH': 'Cambodia',
    'LA': 'Laos',
  };

  /// Название страны для отображения в The Beacon (по chatId или по коду).
  static String beaconCountryDisplayName(String? chatId) {
    final cc = chatId != null && chatId.startsWith('THE_BEACON_') && chatId.length == 13
        ? chatId.substring(11).toUpperCase()
        : getBeaconCountryCode();
    if (cc.isEmpty) return 'Global';
    return _countryNames[cc] ?? cc;
  }

  /// Список вариантов для выбора страны: [('', 'Global'), ('BY', 'Belarus'), ...].
  static List<MapEntry<String, String>> get countryChoicesForPicker {
    final list = <MapEntry<String, String>>[const MapEntry('', 'Global')];
    list.addAll(_countryNames.entries.map((e) => MapEntry(e.key, e.value)));
    return list;
  }
}
