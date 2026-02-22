// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get profileWriteDm => 'Написать в ЛС';

  @override
  String get profileAddFriend => 'Добавить в друзья';

  @override
  String get profileRemoveFriend => 'Удалить из друзей';

  @override
  String get profileRequestPending => 'Заявка в друзья ожидает ответа';

  @override
  String get profileThisIsYou => 'Это вы';

  @override
  String get profileOpenViaMenu => 'Откройте свой профиль через меню.';

  @override
  String get profileFriendRemoved => 'Удалён из друзей';

  @override
  String get profileRequestSent => 'Заявка отправлена';

  @override
  String get profileErrorPrefix => 'Ошибка: ';

  @override
  String get profileFriendRemovedLocal => 'Удалено локально. Ошибка API: ';

  @override
  String get beaconWarningTitle => 'THE BEACON';

  @override
  String get beaconWarningMessage =>
      'Чат привязан к стране. Неверный выбор вредит другим.';

  @override
  String get beaconUnderstood => 'Понятно';

  @override
  String get beaconHoldToChangeCountry => 'удержать — сменить страну';

  @override
  String get identityMaskingTitle => 'МАСКИРОВКА ОБРАЗА';

  @override
  String get identityMaskingSubtitle =>
      'Выберите другой образ на этом устройстве. Вход по-прежнему через камуфляж (например, код калькулятора).';

  @override
  String get identityMaskingNote =>
      'Примечание: для обновления иконки может потребоваться перезапуск приложения.';

  @override
  String get appNameCalculator => 'Калькулятор';

  @override
  String get appNameNotes => 'Заметки';

  @override
  String get appNameCalendar => 'Календарь';

  @override
  String get appNameClock => 'Часы';

  @override
  String get appNameGallery => 'Галерея';

  @override
  String get appNameFiles => 'Файлы';

  @override
  String get disclaimerTitle => 'Warning';

  @override
  String get disclaimerText =>
      'This application calculates an approximate end-of-life date based on statistical data for entertainment and motivational purposes only. This is not a medical prediction. The creators are not responsible for your emotional state, actions, or decisions made based on the information provided. By continuing, you confirm that you are over 18 years old and accept full responsibility.';

  @override
  String get iAgree => 'I have read and agree';

  @override
  String get proceed => 'Proceed';

  @override
  String get timerYears => 'years';

  @override
  String get timerDays => 'days';

  @override
  String get disclaimerP1 =>
      'This application provides a fictional time calculation based on public statistical data. It is intended solely for motivational, philosophical, and entertainment purposes.';

  @override
  String get disclaimerP2 =>
      'This is NOT a medical, scientific, or factual prediction. The result is arbitrary and should not be taken seriously or used for making any life decisions.';

  @override
  String get disclaimerP3 =>
      'The creators of this application are NOT responsible for any emotional distress, anxiety, depression, panic attacks, or any other psychological effects that may arise from using this application. You use it at your own risk.';

  @override
  String get disclaimerP4 =>
      'By checking the box and proceeding, you confirm that:';

  @override
  String get disclaimerPoint1 => 'You are 18 years of age or older.';

  @override
  String get disclaimerPoint2 =>
      'You are of sound mind and understand the fictional nature of this application.';

  @override
  String get disclaimerPoint3 =>
      'You take full and sole responsibility for your emotional state and actions while using and after using this application.';

  @override
  String get disclaimerPoint4 =>
      'You agree to our Privacy Policy and Terms of Service.';

  @override
  String get daysLived => 'DAYS LIVED';

  @override
  String get totalDaysEstimated => 'TOTAL DAYS ESTIMATED';

  @override
  String get odysseyComplete => 'of your Odyssey complete';

  @override
  String get donateAppBarTitle => 'ПОДДЕРЖАТЬ ПРОЕКТ';

  @override
  String get donateHeaderLine1 =>
      'Поддержка проекта. Крипто ниже — без посредников, без регистрации.';

  @override
  String get donateHeaderLine2 =>
      'Ваша анонимность и анонимность проекта сохраняются: перевод напрямую на кошелёк, никто не хранит ваши данные.';

  @override
  String get donateSectionCrypto => 'КРИПТО — БЕЗ ПОСРЕДНИКОВ';

  @override
  String get donateSectionOther => 'ДРУГОЕ (МЕНЕЕ АНОНИМНО)';

  @override
  String get donatePrivacyNote =>
      'Криптопожертвования: анонимно, без привязки к личности. Предпочтительный способ для сохранения приватности с обеих сторон.';

  @override
  String donateAddressCopied(Object label) {
    return '$label — адрес скопирован';
  }

  @override
  String get donateGitHubTitle => 'GitHub Sponsors';

  @override
  String get donateGitHubSubtitle =>
      'Опционально. Заявка на одобрение; для полной анонимности используйте крипто выше.';

  @override
  String get donateLabelBtc => 'BTC';

  @override
  String get donateLabelEth => 'ETH';

  @override
  String get donateLabelBnb => 'BNB Chain (BEP-20)';

  @override
  String get donateLabelUsdtTrx => 'USDT (TRC-20 / Tron)';

  @override
  String get donateLabelXmrSolana => 'XMR (Monero) в сети Solana';
}
