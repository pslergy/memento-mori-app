import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/models/ad_packet.dart';

class TacticalBanner extends StatelessWidget {
  final AdPacket ad;
  final VoidCallback onClose;

  const TacticalBanner({
    super.key,
    required this.ad,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // Используем SafeArea, чтобы баннер не залезал на системные кнопки внизу
    return SafeArea(
      child: Container(
        // Ограничиваем ширину для красоты на планшетах
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          // Очень темный серый, почти черный
          color: const Color(0xFF0F0F0F),
          borderRadius: BorderRadius.circular(24),
          // Тонкая рамка янтарного цвета, как на военных мониторах
          border: Border.all(
            color: Colors.amberAccent.withOpacity(0.3),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 20,
              spreadRadius: 5,
            )
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            // MainAxisSize.min заставляет колонку сжиматься по контенту
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- ШАПКА БАННЕРА ---
              Row(
                children: [
                  const Icon(Icons.sensors_rounded, color: Colors.amberAccent, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    "LOCAL SIGNAL DETECTED",
                    style: GoogleFonts.russoOne(
                      color: Colors.amberAccent,
                      fontSize: 12,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const Spacer(),
                  // Кнопка закрытия
                  GestureDetector(
                    onTap: onClose,
                    child: const Icon(Icons.close, color: Colors.white24, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // --- ИЗОБРАЖЕНИЕ (если есть) ---
              if (ad.imageUrl != null && ad.imageUrl!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    ad.imageUrl!,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    // Обработка ошибки загрузки картинки
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 100,
                      color: Colors.white10,
                      child: const Icon(Icons.broken_image, color: Colors.white24),
                    ),
                  ),
                ),

              if (ad.imageUrl != null) const SizedBox(height: 20),

              // --- ТЕКСТ РЕКЛАМЫ ---
              Text(
                ad.title.toUpperCase(),
                textAlign: TextAlign.left,
                style: GoogleFonts.russoOne(
                  color: Colors.white,
                  fontSize: 20,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                ad.content,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 25),

              // --- КНОПКА ДЕЙСТВИЯ ---
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () {
                  // Здесь логика перехода по ссылке
                  print("🔗 Tactical link opened: ${ad.id}");
                },
                child: Text(
                  "ESTABLISH CONNECTION",
                  style: GoogleFonts.russoOne(fontSize: 14),
                ),
              ),
              const SizedBox(height: 10),

              // Подпись о типе сигнала
              const Text(
                "ENCRYPTED ADVERTISING PAYLOAD // ID-8892",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white10,
                  fontSize: 8,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}