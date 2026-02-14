// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get disclaimerTitle => 'Sebelum Memulai';

  @override
  String get disclaimerText =>
      'Aplikasi ini menghitung perkiraan tanggal akhir hidup berdasarkan data statistik hanya untuk hiburan dan motivasi. Bukan prediksi medis. Pembuat tidak bertanggung jawab atas keadaan emosional, tindakan, atau keputusan Anda. Dengan melanjutkan, Anda mengonfirmasi berusia 18 tahun ke atas.';

  @override
  String get iAgree => 'Saya memahami dan menerima semua hal di atas.';

  @override
  String get proceed => 'Masuk ke Hitungan Mundur';

  @override
  String get timerYears => 'tahun';

  @override
  String get timerDays => 'hari';

  @override
  String get disclaimerP1 =>
      'Aplikasi ini menyediakan perhitungan waktu fiksi berdasarkan data statistik publik, hanya untuk tujuan motivasi dan hiburan.';

  @override
  String get disclaimerP2 =>
      'Ini BUKAN prediksi medis atau ilmiah. Hasilnya arbitrer.';

  @override
  String get disclaimerP3 =>
      'Pembuat tidak bertanggung jawab atas efek psikologis akibat penggunaan. Anda menggunakannya dengan risiko sendiri.';

  @override
  String get disclaimerP4 =>
      'Dengan mencentang kotak dan melanjutkan, Anda mengonfirmasi bahwa:';

  @override
  String get disclaimerPoint1 => 'Anda berusia 18 tahun ke atas.';

  @override
  String get disclaimerPoint2 => 'Anda memahami sifat fiksi aplikasi ini.';

  @override
  String get disclaimerPoint3 =>
      'Anda bertanggung jawab penuh atas emosi dan tindakan Anda.';

  @override
  String get disclaimerPoint4 =>
      'Anda setuju dengan Kebijakan Privasi dan Ketentuan Layanan kami.';

  @override
  String get daysLived => 'HARI HIDUP';

  @override
  String get totalDaysEstimated => 'TOTAL HARI PERKIRAAN';

  @override
  String get odysseyComplete => 'dari perjalanan Anda selesai';

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
