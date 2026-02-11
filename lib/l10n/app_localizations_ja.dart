// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get disclaimerTitle => '開始する前に';

  @override
  String get disclaimerText =>
      '本アプリは娯楽・モチベーション目的のみで統計データに基づくおおよその寿命を計算します。医療的な予測ではありません。制作者は利用者の感情・行動・判断について責任を負いません。続行により18歳以上であることを確認したものとみなします。';

  @override
  String get iAgree => '上記の内容を理解し、同意します。';

  @override
  String get proceed => 'カウントダウンへ';

  @override
  String get timerYears => '年';

  @override
  String get timerDays => '日';

  @override
  String get disclaimerP1 => '本アプリは公的統計に基づく架空の時間計算を提供し、モチベーション・娯楽目的のみに使用されます。';

  @override
  String get disclaimerP2 => '医学的・科学的な予測ではありません。結果は任意であり、人生の判断に用いるべきではありません。';

  @override
  String get disclaimerP3 =>
      '制作者は本アプリの利用により生じる精神的影響について責任を負いません。ご自身の責任でご利用ください。';

  @override
  String get disclaimerP4 => 'チェックして続行することで、以下を確認したものとみなします：';

  @override
  String get disclaimerPoint1 => '18歳以上であること。';

  @override
  String get disclaimerPoint2 => '本アプリが架空のものであることを理解していること。';

  @override
  String get disclaimerPoint3 => '利用中・利用後の感情・行動について一切の責任を負うこと。';

  @override
  String get disclaimerPoint4 => 'プライバシーポリシーと利用規約に同意すること。';

  @override
  String get daysLived => '生きた日数';

  @override
  String get totalDaysEstimated => '推定総日数';

  @override
  String get odysseyComplete => 'あなたの旅の完了度';
}
