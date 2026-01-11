// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get disclaimerTitle => 'Прежде чем начать';

  @override
  String get disclaimerText =>
      'Это приложение рассчитывает примерную дату окончания жизни на основе статистических данных исключительно в развлекательных и мотивационных целях. Это не является медицинским прогнозом. Создатели не несут ответственности за ваше эмоциональное состояние, действия или решения, принятые на основе предоставленной информации. Продолжая, вы подтверждаете, что вам больше 18 лет и принимаете на себя полную ответственность.';

  @override
  String get iAgree => 'Я понимаю и принимаю все вышеизложенное.';

  @override
  String get proceed => 'Начать отсчет';

  @override
  String get timerYears => 'лет';

  @override
  String get timerDays => 'дней';

  @override
  String get disclaimerP1 =>
      'Это приложение предоставляет вымышленный расчет времени, основанный на общедоступных статистических данных. Оно предназначено исключительно для мотивационных, философских и развлекательных целей.';

  @override
  String get disclaimerP2 =>
      'Это НЕ является медицинским, научным или фактическим прогнозом. Результат является произвольным, его не следует воспринимать всерьез или использовать для принятия каких-либо жизненных решений.';

  @override
  String get disclaimerP3 =>
      'Создатели этого приложения НЕ несут ответственности за любые эмоциональные расстройства, тревогу, депрессию, панические атаки или любые другие психологические эффекты, которые могут возникнуть в результате использования этого приложения. Вы используете его на свой страх и риск.';

  @override
  String get disclaimerP4 =>
      'Устанавливая флажок и продолжая, вы подтверждаете, что:';

  @override
  String get disclaimerPoint1 => 'Вам 18 лет или больше.';

  @override
  String get disclaimerPoint2 =>
      'Вы находитесь в здравом уме и понимаете вымышленную природу этого приложения.';

  @override
  String get disclaimerPoint3 =>
      'Вы принимаете на себя полную и единоличную ответственность за свое эмоциональное состояние и действия во время и после использования этого приложения.';

  @override
  String get disclaimerPoint4 =>
      'Вы соглашаетесь с нашей Политикой конфиденциальности и Условиями использования.';

  @override
  String get daysLived => 'ДНЕЙ ПРОЖИТО';

  @override
  String get totalDaysEstimated => 'ДНЕЙ ПРЕДПОЛОЖИТЕЛЬНО';

  @override
  String get odysseyComplete => 'вашей Одиссеи пройдено';
}
