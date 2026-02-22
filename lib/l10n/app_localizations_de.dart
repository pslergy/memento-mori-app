// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get profileWriteDm => 'Write in DM';

  @override
  String get profileAddFriend => 'Add friend';

  @override
  String get profileRemoveFriend => 'Remove from friends';

  @override
  String get profileRequestPending => 'Friend request pending';

  @override
  String get profileThisIsYou => 'This is you';

  @override
  String get profileOpenViaMenu => 'Open your profile via menu.';

  @override
  String get profileFriendRemoved => 'Removed from friends';

  @override
  String get profileRequestSent => 'Request sent';

  @override
  String get profileErrorPrefix => 'Error: ';

  @override
  String get profileFriendRemovedLocal => 'Removed locally. API error: ';

  @override
  String get beaconWarningTitle => 'THE BEACON';

  @override
  String get beaconWarningMessage =>
      'Chat is tied to country. Wrong choice harms others.';

  @override
  String get beaconUnderstood => 'Understood';

  @override
  String get beaconHoldToChangeCountry => 'hold — change country';

  @override
  String get identityMaskingTitle => 'IDENTITY MASKING';

  @override
  String get identityMaskingSubtitle =>
      'Select an alternate identity to show on this device. Entry remains via camouflage (e.g. calculator code).';

  @override
  String get identityMaskingNote =>
      'Note: The app may need to be reopened for the launcher icon to update.';

  @override
  String get appNameCalculator => 'Calculator';

  @override
  String get appNameNotes => 'Notes';

  @override
  String get appNameCalendar => 'Calendar';

  @override
  String get appNameClock => 'Clock';

  @override
  String get appNameGallery => 'Gallery';

  @override
  String get appNameFiles => 'Files';

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

  @override
  String get donateAppBarTitle => 'SUPPORT THE GRID';

  @override
  String get donateHeaderLine1 =>
      'Support the project. Crypto below — no middleman, no signup.';

  @override
  String get donateHeaderLine2 =>
      'Your anonymity and the project\'s anonymity are preserved: direct transfer to wallet, no one stores your data.';

  @override
  String get donateSectionCrypto => 'CRYPTO — NO MIDDLEMAN';

  @override
  String get donateSectionOther => 'OTHER (LESS ANONYMOUS)';

  @override
  String get donatePrivacyNote =>
      'Crypto donations: anonymous, no link to identity. Preferred way to preserve privacy on both sides.';

  @override
  String donateAddressCopied(Object label) {
    return '$label — address copied';
  }

  @override
  String get donateGitHubTitle => 'GitHub Sponsors';

  @override
  String get donateGitHubSubtitle =>
      'Optional. Application pending; for full anonymity use crypto above.';

  @override
  String get donateLabelBtc => 'BTC';

  @override
  String get donateLabelEth => 'ETH';

  @override
  String get donateLabelBnb => 'BNB Chain (BEP-20)';

  @override
  String get donateLabelUsdtTrx => 'USDT (TRC-20 / Tron)';

  @override
  String get donateLabelXmrSolana => 'XMR (Monero) on Solana';
}
