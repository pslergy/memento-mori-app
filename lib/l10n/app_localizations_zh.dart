// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get disclaimerTitle => '开始之前';

  @override
  String get disclaimerText =>
      '本应用根据统计数据计算近似寿命，仅供娱乐与激励，非医学预测。开发者不对您的情绪、行为或据此做出的决定负责。继续即表示您年满18岁并承担全部责任。';

  @override
  String get iAgree => '我理解并接受以上全部内容。';

  @override
  String get proceed => '进入倒计时';

  @override
  String get timerYears => '年';

  @override
  String get timerDays => '天';

  @override
  String get disclaimerP1 => '本应用基于公开统计数据提供虚构时间计算，仅用于激励、哲学与娱乐目的。';

  @override
  String get disclaimerP2 => '这不是医学、科学或事实预测。结果仅供参考，请勿用于人生决策。';

  @override
  String get disclaimerP3 => '应用开发者不对使用本应用可能产生的情绪困扰、焦虑、抑郁、恐慌等心理影响负责。使用风险自负。';

  @override
  String get disclaimerP4 => '勾选并继续即表示您确认：';

  @override
  String get disclaimerPoint1 => '您年满18周岁。';

  @override
  String get disclaimerPoint2 => '您心智健全并理解本应用的虚构性质。';

  @override
  String get disclaimerPoint3 => '您对使用本应用期间及之后的情绪与行为负全部责任。';

  @override
  String get disclaimerPoint4 => '您同意我们的隐私政策与服务条款。';

  @override
  String get daysLived => '已活天数';

  @override
  String get totalDaysEstimated => '预估总天数';

  @override
  String get odysseyComplete => '人生旅程完成度';
}
