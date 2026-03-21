// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

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
  String get disclaimerTitle => 'قبل أن تبدأ';

  @override
  String get disclaimerText =>
      'يحسب هذا التطبيق تاريخ نهاية تقريبيًا بناءً على بيانات إحصائية لأغراض الترفيه والتحفيز فقط. ليست تنبؤًا طبيًا. المطورون غير مسؤولين عن مشاعرك أو أفعالك. بالمتابعة تؤكد أنك تجاوزت 18 عامًا.';

  @override
  String get iAgree => 'أفهم وأقبل ما ورد أعلاه.';

  @override
  String get proceed => 'الدخول إلى العد التنازلي';

  @override
  String get timerYears => 'سنوات';

  @override
  String get timerDays => 'أيام';

  @override
  String get disclaimerP1 =>
      'يوفر هذا التطبيق حسابات وهمية بناءً على بيانات إحصائية عامة، لأغراض تحفيزية وترفيهية فقط.';

  @override
  String get disclaimerP2 =>
      'هذا ليس تنبؤًا طبيًا أو علميًا. النتيجة تعسفية ولا يجب الاعتماد عليها.';

  @override
  String get disclaimerP3 =>
      'مطورو التطبيق غير مسؤولين عن أي ضائقة نفسية قد تنتج عن الاستخدام. الاستخدام على مسؤوليتك.';

  @override
  String get disclaimerP4 => 'بتحديد المربع والمتابعة تؤكد أن:';

  @override
  String get disclaimerPoint1 => 'أنك تجاوزت 18 عامًا.';

  @override
  String get disclaimerPoint2 => 'أنك تدرك أن التطبيق وهمي.';

  @override
  String get disclaimerPoint3 =>
      'أنك تتحمل المسؤولية الكاملة عن مشاعرك وأفعالك.';

  @override
  String get disclaimerPoint4 => 'أنك توافق على سياسة الخصوصية وشروط الخدمة.';

  @override
  String get daysLived => 'الأيام المعاشة';

  @override
  String get totalDaysEstimated => 'إجمالي الأيام التقديري';

  @override
  String get odysseyComplete => 'من رحلتك مكتملة';

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
