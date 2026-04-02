// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

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
  String get disclaimerTitle => 'Avant de commencer';

  @override
  String get disclaimerText =>
      'Cette application calcule une date de fin de vie approximative à partir de données statistiques, à des fins de divertissement et de motivation uniquement. Ce n\'est pas une prédiction médicale. Les créateurs ne sont pas responsables de votre état émotionnel, actions ou décisions. En continuant, vous confirmez avoir 18 ans ou plus.';

  @override
  String get iAgree => 'Je comprends et j\'accepte tout ce qui précède.';

  @override
  String get proceed => 'Entrer dans le décompte';

  @override
  String get timerYears => 'ans';

  @override
  String get timerDays => 'jours';

  @override
  String get disclaimerP1 =>
      'Cette application fournit un calcul de temps fictif basé sur des données statistiques publiques, à des fins de motivation et de divertissement uniquement.';

  @override
  String get disclaimerP2 =>
      'Ce n\'est PAS une prédiction médicale ou scientifique. Le résultat est arbitraire.';

  @override
  String get disclaimerP3 =>
      'Les créateurs ne sont pas responsables des effets psychologiques liés à l\'utilisation. Vous l\'utilisez à vos propres risques.';

  @override
  String get disclaimerP4 =>
      'En cochant la case et en continuant, vous confirmez que :';

  @override
  String get disclaimerPoint1 => 'Vous avez 18 ans ou plus.';

  @override
  String get disclaimerPoint2 =>
      'Vous comprenez le caractère fictif de cette application.';

  @override
  String get disclaimerPoint3 =>
      'Vous assumez l\'entière responsabilité de vos émotions et actes.';

  @override
  String get disclaimerPoint4 =>
      'Vous acceptez notre Politique de confidentialité et nos Conditions d\'utilisation.';

  @override
  String get daysLived => 'JOURS VÉCUS';

  @override
  String get totalDaysEstimated => 'TOTAL DE JOURS ESTIMÉ';

  @override
  String get odysseyComplete => 'de votre odyssée accomplie';

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
