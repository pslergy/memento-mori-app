// lib/core/models/ad_packet.dart

class AdPacket {
  final String id;
  final String title;
  final String content;
  final String? imageUrl;    // 🔥 Добавлено
  final int priority;
  final bool isInterstitial; // 🔥 Добавлено (флаг баннера)
  final DateTime expiresAt;

  AdPacket({
    required this.id,
    required this.title,
    required this.content,
    this.imageUrl,
    this.priority = 1,
    this.isInterstitial = false,
    required this.expiresAt,
  });

  // Превращаем JSON (из API или SQLite) в объект Dart
  factory AdPacket.fromJson(Map<String, dynamic> json) {
    return AdPacket(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? 'Signal',
      content: json['content'] ?? '',
      imageUrl: json['imageUrl'],
      priority: json['priority'] ?? 1,
      // В SQLite bool хранится как 1 или 0
      isInterstitial: json['isInterstitial'] == 1 || json['isInterstitial'] == true,
      expiresAt: DateTime.parse(json['expiresAt'] ?? DateTime.now().toIso8601String()),
    );
  }

  // Превращаем объект Dart в Map для сохранения в SQLite
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'imageUrl': imageUrl,
    'priority': priority,
    // Сохраняем как число для SQLite
    'isInterstitial': isInterstitial ? 1 : 0,
    'expiresAt': expiresAt.toIso8601String(),
  };
}