// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get disclaimerTitle => 'Avant de commencer';

  @override
  String get disclaimerText =>
      'Cette application calcule une date de fin de vie approximative à partir de données statistiques, à des fins de divertissement et de motivation uniquement. Ce n\'est pas une prédiction médicale. Les créateurs ne sont pas responsables de votre état émotionnel, actions ou décisions. En continuant, vous confirmez avoir 18 ans ou plus.';

  @override
  String get iAgree => 'Je comprends et j\'accepte tout ce qui précède.';

  @override
  String get proceed => 'Entrer dans le décompte';

  @override
  String get timerYears => 'ans';

  @override
  String get timerDays => 'jours';

  @override
  String get disclaimerP1 =>
      'Cette application fournit un calcul de temps fictif basé sur des données statistiques publiques, à des fins de motivation et de divertissement uniquement.';

  @override
  String get disclaimerP2 =>
      'Ce n\'est PAS une prédiction médicale ou scientifique. Le résultat est arbitraire.';

  @override
  String get disclaimerP3 =>
      'Les créateurs ne sont pas responsables des effets psychologiques liés à l\'utilisation. Vous l\'utilisez à vos propres risques.';

  @override
  String get disclaimerP4 =>
      'En cochant la case et en continuant, vous confirmez que :';

  @override
  String get disclaimerPoint1 => 'Vous avez 18 ans ou plus.';

  @override
  String get disclaimerPoint2 =>
      'Vous comprenez le caractère fictif de cette application.';

  @override
  String get disclaimerPoint3 =>
      'Vous assumez l\'entière responsabilité de vos émotions et actes.';

  @override
  String get disclaimerPoint4 =>
      'Vous acceptez notre Politique de confidentialité et nos Conditions d\'utilisation.';

  @override
  String get daysLived => 'JOURS VÉCUS';

  @override
  String get totalDaysEstimated => 'TOTAL DE JOURS ESTIMÉ';

  @override
  String get odysseyComplete => 'de votre odyssée accomplie';
}
