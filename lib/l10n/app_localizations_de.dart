// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get disclaimerTitle => 'Bevor Sie beginnen';

  @override
  String get disclaimerText =>
      'Diese App berechnet ein ungefähres Lebensenddatum basierend auf statistischen Daten, nur zu Unterhaltungs- und Motivationszwecken. Es ist keine medizinische Vorhersage. Die Entwickler sind nicht verantwortlich für Ihre Gefühle, Handlungen oder Entscheidungen. Durch Fortfahren bestätigen Sie, dass Sie mindestens 18 Jahre alt sind.';

  @override
  String get iAgree => 'Ich verstehe und akzeptiere das oben Gesagte.';

  @override
  String get proceed => 'Countdown starten';

  @override
  String get timerYears => 'Jahre';

  @override
  String get timerDays => 'Tage';

  @override
  String get disclaimerP1 =>
      'Diese App bietet eine fiktive Zeitberechnung basierend auf öffentlichen Statistiken, nur zu Motivations- und Unterhaltungszwecken.';

  @override
  String get disclaimerP2 =>
      'Dies ist keine medizinische oder wissenschaftliche Vorhersage. Das Ergebnis ist willkürlich.';

  @override
  String get disclaimerP3 =>
      'Die Entwickler sind nicht verantwortlich für psychische Auswirkungen durch die Nutzung. Nutzung auf eigenes Risiko.';

  @override
  String get disclaimerP4 => 'Mit dem Ankreuzen bestätigen Sie:';

  @override
  String get disclaimerPoint1 => 'Sie sind mindestens 18 Jahre alt.';

  @override
  String get disclaimerPoint2 =>
      'Sie verstehen den fiktiven Charakter der App.';

  @override
  String get disclaimerPoint3 =>
      'Sie übernehmen die volle Verantwortung für Ihre Gefühle und Handlungen.';

  @override
  String get disclaimerPoint4 =>
      'Sie stimmen der Datenschutzrichtlinie und den AGB zu.';

  @override
  String get daysLived => 'Gelebte Tage';

  @override
  String get totalDaysEstimated => 'Geschätzte Gesamttage';

  @override
  String get odysseyComplete => 'Ihrer Reise abgeschlossen';
}
