// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Bengali Bangla (`bn`).
class AppLocalizationsBn extends AppLocalizations {
  AppLocalizationsBn([String locale = 'bn']) : super(locale);

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
  String get disclaimerTitle => 'শুরু করার আগে';

  @override
  String get disclaimerText =>
      'এই অ্যাপটি শুধুমাত্র বিনোদন ও অনুপ্রেরণার জন্য পরিসংখ্যানের ভিত্তিতে আনুমানিক জীবনকাল দেখায়। এটি চিকিৎসা পূর্বাভাস নয়। নির্মাতারা আপনার আবেগ, কাজ বা সিদ্ধান্তের জন্য দায়ী নন। চালিয়ে যাওয়ার মাধ্যমে আপনি নিশ্চিত করেন যে আপনার বয়স ১৮ বছরের বেশি।';

  @override
  String get iAgree => 'আমি উপরের সব কিছু বুঝে সম্মত।';

  @override
  String get proceed => 'কাউন্টডাউনে প্রবেশ';

  @override
  String get timerYears => 'বছর';

  @override
  String get timerDays => 'দিন';

  @override
  String get disclaimerP1 =>
      'এই অ্যাপটি জনসাধারণের পরিসংখ্যানের ভিত্তিতে একটি কাল্পনিক গণনা দেয়, শুধুমাত্র অনুপ্রেরণা ও বিনোদনের জন্য।';

  @override
  String get disclaimerP2 =>
      'এটি চিকিৎসা বা বৈজ্ঞানিক পূর্বাভাস নয়। ফলাফল নির্বিচারে।';

  @override
  String get disclaimerP3 =>
      'অ্যাপ ব্যবহারের ফলে কোনো মানসিক প্রভাবের জন্য নির্মাতারা দায়ী নন। আপনি নিজের দায়িত্বে ব্যবহার করছেন।';

  @override
  String get disclaimerP4 =>
      'বক্স টিক দিয়ে চালিয়ে যাওয়ার মাধ্যমে আপনি নিশ্চিত করেন:';

  @override
  String get disclaimerPoint1 => 'আপনার বয়স ১৮ বছরের বেশি।';

  @override
  String get disclaimerPoint2 => 'আপনি বুঝেছেন যে এই অ্যাপটি কাল্পনিক।';

  @override
  String get disclaimerPoint3 =>
      'আপনি আপনার আবেগ ও কাজের সম্পূর্ণ দায়িত্ব নিচ্ছেন।';

  @override
  String get disclaimerPoint4 =>
      'আপনি গোপনীয়তা নীতি ও সেবার শর্তাবলীতে সম্মত।';

  @override
  String get daysLived => 'বাঁচা দিন';

  @override
  String get totalDaysEstimated => 'আনুমানিক মোট দিন';

  @override
  String get odysseyComplete => 'আপনার যাত্রা সম্পূর্ণ';

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
