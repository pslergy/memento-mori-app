// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

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
  String get disclaimerTitle => 'Antes de começar';

  @override
  String get disclaimerText =>
      'Este aplicativo calcula uma data aproximada de fim de vida com base em dados estatísticos, apenas para entretenimento e motivação. Não é uma previsão médica. Os criadores não são responsáveis pelo seu estado emocional, ações ou decisões. Ao continuar, você confirma que tem 18 anos ou mais.';

  @override
  String get iAgree => 'Entendo e aceito tudo o que foi dito acima.';

  @override
  String get proceed => 'Entrar na contagem';

  @override
  String get timerYears => 'anos';

  @override
  String get timerDays => 'dias';

  @override
  String get disclaimerP1 =>
      'Este aplicativo fornece um cálculo de tempo fictício baseado em dados estatísticos públicos, apenas para fins motivacionais e de entretenimento.';

  @override
  String get disclaimerP2 =>
      'NÃO é uma previsão médica ou científica. O resultado é arbitrário.';

  @override
  String get disclaimerP3 =>
      'Os criadores não são responsáveis por quaisquer efeitos psicológicos decorrentes do uso. Você o utiliza por sua conta e risco.';

  @override
  String get disclaimerP4 =>
      'Ao marcar a caixa e continuar, você confirma que:';

  @override
  String get disclaimerPoint1 => 'Você tem 18 anos ou mais.';

  @override
  String get disclaimerPoint2 =>
      'Você entende o caráter fictício deste aplicativo.';

  @override
  String get disclaimerPoint3 =>
      'Você assume total responsabilidade por suas emoções e ações.';

  @override
  String get disclaimerPoint4 =>
      'Você concorda com nossa Política de Privacidade e Termos de Serviço.';

  @override
  String get daysLived => 'DIAS VIVIDOS';

  @override
  String get totalDaysEstimated => 'TOTAL DE DIAS ESTIMADO';

  @override
  String get odysseyComplete => 'da sua odisseia concluída';

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
