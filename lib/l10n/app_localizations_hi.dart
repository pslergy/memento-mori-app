// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hindi (`hi`).
class AppLocalizationsHi extends AppLocalizations {
  AppLocalizationsHi([String locale = 'hi']) : super(locale);

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
