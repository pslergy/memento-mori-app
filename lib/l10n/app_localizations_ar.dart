// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

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
}
