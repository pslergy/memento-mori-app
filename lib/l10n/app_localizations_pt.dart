// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

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
}
