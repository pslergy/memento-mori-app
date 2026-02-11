// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

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
}
