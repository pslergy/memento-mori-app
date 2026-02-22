// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

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
