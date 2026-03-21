// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

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
  String get disclaimerTitle => 'Antes de comenzar';

  @override
  String get disclaimerText =>
      'Esta aplicación calcula una fecha aproximada de fin de vida basada en datos estadísticos solo para entretenimiento y motivación. No es una predicción médica. Los creadores no son responsables de su estado emocional, acciones o decisiones. Al continuar, confirma que es mayor de 18 años.';

  @override
  String get iAgree => 'Entiendo y acepto todo lo anterior.';

  @override
  String get proceed => 'Entrar al conteo';

  @override
  String get timerYears => 'años';

  @override
  String get timerDays => 'días';

  @override
  String get disclaimerP1 =>
      'Esta aplicación ofrece un cálculo de tiempo ficticio basado en datos estadísticos públicos, solo con fines motivacionales y de entretenimiento.';

  @override
  String get disclaimerP2 =>
      'NO es una predicción médica o científica. El resultado es arbitrario.';

  @override
  String get disclaimerP3 =>
      'Los creadores no son responsables de ningún efecto psicológico derivado del uso. Usted usa la aplicación bajo su propio riesgo.';

  @override
  String get disclaimerP4 => 'Al marcar la casilla y continuar, confirma que:';

  @override
  String get disclaimerPoint1 => 'Usted tiene 18 años o más.';

  @override
  String get disclaimerPoint2 =>
      'Comprende el carácter ficticio de esta aplicación.';

  @override
  String get disclaimerPoint3 =>
      'Asume toda la responsabilidad de sus emociones y acciones.';

  @override
  String get disclaimerPoint4 =>
      'Acepta nuestra Política de Privacidad y Términos de Servicio.';

  @override
  String get daysLived => 'DÍAS VIVIDOS';

  @override
  String get totalDaysEstimated => 'TOTAL DE DÍAS ESTIMADOS';

  @override
  String get odysseyComplete => 'de tu odisea completada';

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
