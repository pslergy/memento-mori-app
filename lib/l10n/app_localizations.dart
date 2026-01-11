import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru')
  ];

  /// No description provided for @disclaimerTitle.
  ///
  /// In en, this message translates to:
  /// **'Before You Begin'**
  String get disclaimerTitle;

  /// No description provided for @disclaimerText.
  ///
  /// In en, this message translates to:
  /// **'This application calculates an approximate end-of-life date based on statistical data for entertainment and motivational purposes only. This is not a medical prediction. The creators are not responsible for your emotional state, actions, or decisions made based on the information provided. By continuing, you confirm that you are over 18 years old and accept full responsibility.'**
  String get disclaimerText;

  /// No description provided for @iAgree.
  ///
  /// In en, this message translates to:
  /// **'I understand and accept all of the above.'**
  String get iAgree;

  /// No description provided for @proceed.
  ///
  /// In en, this message translates to:
  /// **'Enter the Countdown'**
  String get proceed;

  /// No description provided for @timerYears.
  ///
  /// In en, this message translates to:
  /// **'years'**
  String get timerYears;

  /// No description provided for @timerDays.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get timerDays;

  /// No description provided for @disclaimerP1.
  ///
  /// In en, this message translates to:
  /// **'This application provides a fictional time calculation based on public statistical data. It is intended solely for motivational, philosophical, and entertainment purposes.'**
  String get disclaimerP1;

  /// No description provided for @disclaimerP2.
  ///
  /// In en, this message translates to:
  /// **'This is NOT a medical, scientific, or factual prediction. The result is arbitrary and should not be taken seriously or used for making any life decisions.'**
  String get disclaimerP2;

  /// No description provided for @disclaimerP3.
  ///
  /// In en, this message translates to:
  /// **'The creators of this application are NOT responsible for any emotional distress, anxiety, depression, panic attacks, or any other psychological effects that may arise from using this application. You use it at your own risk.'**
  String get disclaimerP3;

  /// No description provided for @disclaimerP4.
  ///
  /// In en, this message translates to:
  /// **'By checking the box and proceeding, you confirm that:'**
  String get disclaimerP4;

  /// No description provided for @disclaimerPoint1.
  ///
  /// In en, this message translates to:
  /// **'You are 18 years of age or older.'**
  String get disclaimerPoint1;

  /// No description provided for @disclaimerPoint2.
  ///
  /// In en, this message translates to:
  /// **'You are of sound mind and understand the fictional nature of this application.'**
  String get disclaimerPoint2;

  /// No description provided for @disclaimerPoint3.
  ///
  /// In en, this message translates to:
  /// **'You take full and sole responsibility for your emotional state and actions while using and after using this application.'**
  String get disclaimerPoint3;

  /// No description provided for @disclaimerPoint4.
  ///
  /// In en, this message translates to:
  /// **'You agree to our Privacy Policy and Terms of Service.'**
  String get disclaimerPoint4;

  /// No description provided for @daysLived.
  ///
  /// In en, this message translates to:
  /// **'DAYS LIVED'**
  String get daysLived;

  /// No description provided for @totalDaysEstimated.
  ///
  /// In en, this message translates to:
  /// **'TOTAL DAYS ESTIMATED'**
  String get totalDaysEstimated;

  /// No description provided for @odysseyComplete.
  ///
  /// In en, this message translates to:
  /// **'of your Odyssey complete'**
  String get odysseyComplete;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
