import 'package:flutter/material.dart';

/// Единые формулировки: приватность и **относительная** анонимность (не абсолютная).
/// Шифрование есть; mesh-метаданные, радиослед и публичные каналы ограничивают степень анонимности.
class MessengerExpectationsInfo {
  MessengerExpectationsInfo._();

  static const String expansionTitle = 'Что ожидать от чата';

  /// Полный текст для раскрывающегося блока и карточки THE CHAIN.
  static const String bodyRu = '''• Содержимое сообщений шифруется (E2EE для своих чатов). Публичные маяки и «рядом» используют общий ключ канала — сообщения могут прочитать все, кто в этом канале.

• Анонимность относительная: mesh (BLE / Wi‑Fi / Sonar) оставляет технический след — факт обмена, близость, тайминги. Текст в своих чатах для посторонних без ключа недоступен, но «полной невидимости в эфире» нет.

• История на экране — локальная копия: в группах у разных телефонов списки могут отличаться, пока не пройдёт синхронизация.

• Синхронизация с соседями не непрерывная: в режиме GHOST при необходимости откройте THE CHAIN и нажмите «Синхронизировать» (нужны видимый сосед и свободный Bluetooth).

• Режим BRIDGE: при доступе в интернет часть доставки идёт через облако по правилам приложения — это не «только офлайн-эфир».''';

  static const String onboardingTitle = 'ПРИВАТНОСТЬ И ОЖИДАНИЯ';

  static const String onboardingBody = '''Сообщения шифруются. Анонимность здесь относительная: в mesh виден факт радиообмена; в публичных маяках текст доступен всем участникам канала.

Мы не обещаем абсолютную анонимность или невидимость в эфире — у специализированных инструментов для этого другая модель и другая цена по удобству.

English: Encrypted content; anonymity is relative — mesh metadata and public channels still leave traces.''';

  /// Компактная карточка под заголовком (THE CHAIN).
  static Widget buildChainCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: Colors.amber.shade200),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Ожидания от мессенджера',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            bodyRu,
            style: TextStyle(
              fontSize: 9,
              height: 1.4,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  /// Раскрывающийся блок под статусом модулей в чате.
  static Widget buildConversationExpansion() {
    return Material(
      color: Colors.transparent,
      child: Theme(
        data: ThemeData.dark().copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.cyanAccent.withValues(alpha: 0.08),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          childrenPadding: EdgeInsets.zero,
          iconColor: Colors.cyanAccent,
          collapsedIconColor: Colors.cyanAccent.withValues(alpha: 0.75),
          title: const Text(
            expansionTitle,
            style: TextStyle(
              fontSize: 12,
              color: Colors.cyanAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: SelectableText(
                bodyRu,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
