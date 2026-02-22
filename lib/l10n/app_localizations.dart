import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_bn.dart';
import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_hi.dart';
import 'app_localizations_id.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_pt.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

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
    Locale('ar'),
    Locale('bn'),
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('hi'),
    Locale('id'),
    Locale('ja'),
    Locale('ko'),
    Locale('pt'),
    Locale('ru'),
    Locale('zh')
  ];

  /// No description provided for @profileWriteDm.
  ///
  /// In en, this message translates to:
  /// **'Write in DM'**
  String get profileWriteDm;

  /// No description provided for @profileAddFriend.
  ///
  /// In en, this message translates to:
  /// **'Add friend'**
  String get profileAddFriend;

  /// No description provided for @profileRemoveFriend.
  ///
  /// In en, this message translates to:
  /// **'Remove from friends'**
  String get profileRemoveFriend;

  /// No description provided for @profileRequestPending.
  ///
  /// In en, this message translates to:
  /// **'Friend request pending'**
  String get profileRequestPending;

  /// No description provided for @profileThisIsYou.
  ///
  /// In en, this message translates to:
  /// **'This is you'**
  String get profileThisIsYou;

  /// No description provided for @profileOpenViaMenu.
  ///
  /// In en, this message translates to:
  /// **'Open your profile via menu.'**
  String get profileOpenViaMenu;

  /// No description provided for @profileFriendRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed from friends'**
  String get profileFriendRemoved;

  /// No description provided for @profileRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Request sent'**
  String get profileRequestSent;

  /// No description provided for @profileErrorPrefix.
  ///
  /// In en, this message translates to:
  /// **'Error: '**
  String get profileErrorPrefix;

  /// No description provided for @profileFriendRemovedLocal.
  ///
  /// In en, this message translates to:
  /// **'Removed locally. API error: '**
  String get profileFriendRemovedLocal;

  /// No description provided for @beaconWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'THE BEACON'**
  String get beaconWarningTitle;

  /// No description provided for @beaconWarningMessage.
  ///
  /// In en, this message translates to:
  /// **'Chat is tied to country. Wrong choice harms others.'**
  String get beaconWarningMessage;

  /// No description provided for @beaconUnderstood.
  ///
  /// In en, this message translates to:
  /// **'Understood'**
  String get beaconUnderstood;

  /// No description provided for @beaconHoldToChangeCountry.
  ///
  /// In en, this message translates to:
  /// **'hold — change country'**
  String get beaconHoldToChangeCountry;

  /// No description provided for @identityMaskingTitle.
  ///
  /// In en, this message translates to:
  /// **'IDENTITY MASKING'**
  String get identityMaskingTitle;

  /// No description provided for @identityMaskingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select an alternate identity to show on this device. Entry remains via camouflage (e.g. calculator code).'**
  String get identityMaskingSubtitle;

  /// No description provided for @identityMaskingNote.
  ///
  /// In en, this message translates to:
  /// **'Note: The app may need to be reopened for the launcher icon to update.'**
  String get identityMaskingNote;

  /// No description provided for @appNameCalculator.
  ///
  /// In en, this message translates to:
  /// **'Calculator'**
  String get appNameCalculator;

  /// No description provided for @appNameNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get appNameNotes;

  /// No description provided for @appNameCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get appNameCalendar;

  /// No description provided for @appNameClock.
  ///
  /// In en, this message translates to:
  /// **'Clock'**
  String get appNameClock;

  /// No description provided for @appNameGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get appNameGallery;

  /// No description provided for @appNameFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get appNameFiles;

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

  /// No description provided for @donateAppBarTitle.
  ///
  /// In en, this message translates to:
  /// **'SUPPORT THE GRID'**
  String get donateAppBarTitle;

  /// No description provided for @donateHeaderLine1.
  ///
  /// In en, this message translates to:
  /// **'Support the project. Crypto below — no middleman, no signup.'**
  String get donateHeaderLine1;

  /// No description provided for @donateHeaderLine2.
  ///
  /// In en, this message translates to:
  /// **'Your anonymity and the project\'s anonymity are preserved: direct transfer to wallet, no one stores your data.'**
  String get donateHeaderLine2;

  /// No description provided for @donateSectionCrypto.
  ///
  /// In en, this message translates to:
  /// **'CRYPTO — NO MIDDLEMAN'**
  String get donateSectionCrypto;

  /// No description provided for @donateSectionOther.
  ///
  /// In en, this message translates to:
  /// **'OTHER (LESS ANONYMOUS)'**
  String get donateSectionOther;

  /// No description provided for @donatePrivacyNote.
  ///
  /// In en, this message translates to:
  /// **'Crypto donations: anonymous, no link to identity. Preferred way to preserve privacy on both sides.'**
  String get donatePrivacyNote;

  /// No description provided for @donateAddressCopied.
  ///
  /// In en, this message translates to:
  /// **'{label} — address copied'**
  String donateAddressCopied(Object label);

  /// No description provided for @donateGitHubTitle.
  ///
  /// In en, this message translates to:
  /// **'GitHub Sponsors'**
  String get donateGitHubTitle;

  /// No description provided for @donateGitHubSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Optional. Application pending; for full anonymity use crypto above.'**
  String get donateGitHubSubtitle;

  /// No description provided for @donateLabelBtc.
  ///
  /// In en, this message translates to:
  /// **'BTC'**
  String get donateLabelBtc;

  /// No description provided for @donateLabelEth.
  ///
  /// In en, this message translates to:
  /// **'ETH'**
  String get donateLabelEth;

  /// No description provided for @donateLabelBnb.
  ///
  /// In en, this message translates to:
  /// **'BNB Chain (BEP-20)'**
  String get donateLabelBnb;

  /// No description provided for @donateLabelUsdtTrx.
  ///
  /// In en, this message translates to:
  /// **'USDT (TRC-20 / Tron)'**
  String get donateLabelUsdtTrx;

  /// No description provided for @donateLabelXmrSolana.
  ///
  /// In en, this message translates to:
  /// **'XMR (Monero) on Solana'**
  String get donateLabelXmrSolana;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
        'ar',
        'bn',
        'de',
        'en',
        'es',
        'fr',
        'hi',
        'id',
        'ja',
        'ko',
        'pt',
        'ru',
        'zh'
      ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'bn':
      return AppLocalizationsBn();
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'hi':
      return AppLocalizationsHi();
    case 'id':
      return AppLocalizationsId();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'pt':
      return AppLocalizationsPt();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
