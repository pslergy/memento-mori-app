import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:memento_mori_app/features/theme/app_colors.dart';

/// Экран поддержки проекта: крипто-адреса (без посредников) и опциональная ссылка.
/// Стиль — тактический, в духе приложения.
class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  /// Замените на реальные адреса или подгружайте из конфига/remote config.
  static const String _btcAddress = 'bc1q...PLACEHOLDER'; // TODO: подставить реальный BTC
  static const String _ethAddress = '0x...PLACEHOLDER';   // TODO: подставить реальный ETH
  static const String _usdtAddress = '0x...PLACEHOLDER';  // TODO: подставить реальный USDT (ERC-20)
  /// Ссылка на страницу с донатами (GitHub Sponsors, Ko-fi, Patreon и т.д.)
  static const String _moreOptionsUrl = 'https://github.com'; // TODO: подставить реальную ссылку

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'SUPPORT THE GRID',
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
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSectionTitle('CRYPTO — NO MIDDLEMAN'),
          const SizedBox(height: 8),
          _buildCryptoCard(context, 'BTC', _btcAddress, Colors.orangeAccent),
          const SizedBox(height: 8),
          _buildCryptoCard(context, 'ETH', _ethAddress, Colors.blueAccent),
          const SizedBox(height: 8),
          _buildCryptoCard(context, 'USDT (ERC-20)', _usdtAddress, Colors.greenAccent),
          const SizedBox(height: 24),
          _buildSectionTitle('MORE OPTIONS'),
          const SizedBox(height: 8),
          _buildLinkCard(context),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sonarPurple.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sonarPurple.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.volunteer_activism, color: AppColors.sonarPurple, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Support development of the tactical mesh. Crypto or link below.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
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

  Widget _buildCryptoCard(
    BuildContext context,
    String label,
    String address,
    Color accent,
  ) {
    return Container(
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
        subtitle: Text(
          address,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: Icon(Icons.copy, color: accent, size: 20),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: address));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$label address copied'),
                backgroundColor: Colors.grey[900],
                duration: const Duration(seconds: 2),
              ),
            );
          },
          tooltip: 'Copy',
        ),
      ),
    );
  }

  Widget _buildLinkCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.gridCyan.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gridCyan.withOpacity(0.25)),
      ),
      child: ListTile(
        leading: Icon(Icons.link, color: AppColors.gridCyan, size: 24),
        title: const Text(
          'Donation page (GitHub / Ko-fi / etc.)',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          _moreOptionsUrl,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
        ),
        trailing: IconButton(
          icon: Icon(Icons.copy, color: AppColors.gridCyan, size: 20),
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: _moreOptionsUrl));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Link copied — open in browser'),
                backgroundColor: Colors.black87,
                duration: Duration(seconds: 2),
              ),
            );
          },
          tooltip: 'Copy link',
        ),
      ),
    );
  }
}
