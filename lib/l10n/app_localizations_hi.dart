// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hindi (`hi`).
class AppLocalizationsHi extends AppLocalizations {
  AppLocalizationsHi([String locale = 'hi']) : super(locale);

  @override
  String get disclaimerTitle => 'शुरू करने से पहले';

  @override
  String get disclaimerText =>
      'यह ऐप केवल मनोरंजन और प्रेरणा के लिए सांख्यिकीय डेटा के आधार पर अनुमानित जीवन तिथि दिखाता है। यह चिकित्सा भविष्यवाणी नहीं है। निर्माता आपकी भावनाओं, कार्यों या इस जानकारी पर आधारित निर्णयों के लिए जिम्मेदार नहीं हैं। जारी रखकर आप पुष्टि करते हैं कि आप 18 वर्ष से अधिक हैं।';

  @override
  String get iAgree => 'मैं उपरोक्त सभी से सहमत हूं।';

  @override
  String get proceed => 'काउंटडाउन में प्रवेश';

  @override
  String get timerYears => 'वर्ष';

  @override
  String get timerDays => 'दिन';

  @override
  String get disclaimerP1 =>
      'यह ऐप सार्वजनिक आंकड़ों पर आधारित एक काल्पनिक गणना प्रदान करता है, केवल प्रेरणा और मनोरंजन के लिए।';

  @override
  String get disclaimerP2 =>
      'यह चिकित्सा या वैज्ञानिक भविष्यवाणी नहीं है। परिणाम मनमाना है।';

  @override
  String get disclaimerP3 =>
      'निर्माता इस ऐप के उपयोग से उत्पन्न किसी भी मनोवैज्ञानिक प्रभाव के लिए जिम्मेदार नहीं हैं।';

  @override
  String get disclaimerP4 => 'बॉक्स चेक करके आप पुष्टि करते हैं:';

  @override
  String get disclaimerPoint1 => 'आप 18 वर्ष से अधिक हैं।';

  @override
  String get disclaimerPoint2 => 'आप समझते हैं कि यह ऐप काल्पनिक है।';

  @override
  String get disclaimerPoint3 =>
      'आप अपनी भावनाओं और कार्यों की पूरी जिम्मेदारी लेते हैं।';

  @override
  String get disclaimerPoint4 =>
      'आप गोपनीयता नीति और सेवा की शर्तों से सहमत हैं।';

  @override
  String get daysLived => 'जीते गए दिन';

  @override
  String get totalDaysEstimated => 'अनुमानित कुल दिन';

  @override
  String get odysseyComplete => 'आपकी यात्रा पूर्ण';
}
