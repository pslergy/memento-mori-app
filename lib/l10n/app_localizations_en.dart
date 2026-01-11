// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get disclaimerTitle => 'Before You Begin';

  @override
  String get disclaimerText =>
      'This application calculates an approximate end-of-life date based on statistical data for entertainment and motivational purposes only. This is not a medical prediction. The creators are not responsible for your emotional state, actions, or decisions made based on the information provided. By continuing, you confirm that you are over 18 years old and accept full responsibility.';

  @override
  String get iAgree => 'I understand and accept all of the above.';

  @override
  String get proceed => 'Enter the Countdown';

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
}
