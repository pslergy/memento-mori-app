// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

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
  String get disclaimerTitle => '시작하기 전에';

  @override
  String get disclaimerText =>
      '이 앱은 오락 및 동기 부여 목적으로만 통계 데이터를 바탕으로 대략적인 생애 종료 시점을 계산합니다. 의료적 예측이 아닙니다. 제작자는 귀하의 감정, 행동 또는 결정에 대해 책임지지 않습니다. 계속하면 18세 이상임을 확인한 것으로 간주됩니다.';

  @override
  String get iAgree => '위 내용을 이해하고 모두 동의합니다.';

  @override
  String get proceed => '카운트다운 시작';

  @override
  String get timerYears => '년';

  @override
  String get timerDays => '일';

  @override
  String get disclaimerP1 =>
      '이 앱은 공개 통계 데이터를 기반으로 한 가상의 시간 계산을 제공하며, 동기 부여 및 오락 목적으로만 사용됩니다.';

  @override
  String get disclaimerP2 => '의료 또는 과학적 예측이 아닙니다. 결과는 임의적입니다.';

  @override
  String get disclaimerP3 =>
      '제작자는 앱 사용으로 인한 정신적 영향에 대해 책임지지 않습니다. 사용은 귀하의 책임입니다.';

  @override
  String get disclaimerP4 => '체크하고 계속하면 다음을 확인한 것입니다:';

  @override
  String get disclaimerPoint1 => '18세 이상입니다.';

  @override
  String get disclaimerPoint2 => '이 앱이 가상임을 이해했습니다.';

  @override
  String get disclaimerPoint3 => '감정과 행동에 대한 전적인 책임을 집니다.';

  @override
  String get disclaimerPoint4 => '개인정보 보호정책 및 이용약관에 동의합니다.';

  @override
  String get daysLived => '살아온 날';

  @override
  String get totalDaysEstimated => '예상 총 일수';

  @override
  String get odysseyComplete => '여정 완료';

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
