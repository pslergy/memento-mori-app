import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:memento_mori_app/features/theme/app_colors.dart';
import 'package:memento_mori_app/l10n/app_localizations.dart';

/// Экран поддержки проекта: крипто-адреса (без посредников), анонимность донора и проекта.
/// Стиль — тактический, в духе приложения.
class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  static const String _btcAddress = 'bc1q7308mnt0yarq5s9ngvjvurp3juggn9jy9yh53p';
  static const String _ethAddress = '0xd642d38532FE3c2B5Fa0547556fff2d9388621E6';
  static const String _bnbAddress = '0xd642d38532FE3c2B5Fa0547556fff2d9388621E6'; // BNB Chain (BEP-20)
  static const String _usdtTrxAddress = 'TBXUd9XyFYfZE9m3BdJ76659As5dm8DdKD'; // USDT в сети TRX (Tron)
  static const String _xmrSolanaAddress = '8wTydu2jav9uKjUatC5i4PBuXT5EJkSQ9yvva21aK3GA'; // Monero (XMR) в сети Solana
  /// GitHub Sponsors — опционально; крипто предпочтительнее для анонимности.
  static const String _githubSponsorsUrl = 'https://github.com/sponsors/pslergy';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          l.donateAppBarTitle,
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _buildHeader(context),
          const SizedBox(height: 20),
          _buildSectionTitle(context, l.donateSectionCrypto),
          const SizedBox(height: 8),
          _buildCryptoCard(context, l.donateLabelBtc, _btcAddress, Colors.orangeAccent),
          const SizedBox(height: 8),
          _buildCryptoCard(context, l.donateLabelEth, _ethAddress, Colors.blueAccent),
          const SizedBox(height: 8),
          _buildCryptoCard(context, l.donateLabelBnb, _bnbAddress, Colors.amber),
          const SizedBox(height: 8),
          _buildCryptoCard(context, l.donateLabelUsdtTrx, _usdtTrxAddress, Colors.greenAccent),
          const SizedBox(height: 8),
          _buildCryptoCard(context, l.donateLabelXmrSolana, _xmrSolanaAddress, Color(0xFFFF6600)),
          const SizedBox(height: 12),
          _buildPrivacyNote(context),
          const SizedBox(height: 24),
          _buildSectionTitle(context, l.donateSectionOther),
          const SizedBox(height: 8),
          _buildGitHubSponsorsCard(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sonarPurple.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sonarPurple.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.volunteer_activism, color: AppColors.sonarPurple, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.donateHeaderLine1,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l.donateHeaderLine2,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 10,
              height: 1.35,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyNote(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: Colors.white24, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.donatePrivacyNote,
              style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white24,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  void _copyAddressAndSnackbar(BuildContext context, String label, String address) {
    final l = AppLocalizations.of(context)!;
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.donateAddressCopied(label)),
        backgroundColor: Colors.grey[900],
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildCryptoCard(
    BuildContext context,
    String label,
    String address,
    Color accent,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copyAddressAndSnackbar(context, label, address),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accent.withOpacity(0.12), Colors.transparent],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withOpacity(0.3)),
          ),
          child: ListTile(
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                label.split(' ').first.substring(0, 1),
                style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            title: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                address,
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Icon(Icons.copy, color: accent.withOpacity(0.9), size: 20),
          ),
        ),
      ),
    );
  }

  Widget _buildGitHubSponsorsCard(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.gridCyan.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gridCyan.withOpacity(0.25)),
      ),
      child: ListTile(
        leading: Icon(Icons.volunteer_activism, color: AppColors.gridCyan, size: 24),
        title: Text(
          l.donateGitHubTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          l.donateGitHubSubtitle,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
          ),
        ),
        trailing: IconButton(
          icon: Icon(Icons.open_in_new, color: AppColors.gridCyan, size: 20),
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: _githubSponsorsUrl));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Link copied — open in browser when available'),
                backgroundColor: Colors.grey[900],
                duration: const Duration(seconds: 2),
              ),
            );
          },
          tooltip: 'Copy link',
        ),
      ),
    );
  }
}
