import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ghost_controller.dart';

enum KeyboardMode { letters, symbols, emojis }
enum KeyboardLang { en, ru }

class GhostKeyboard extends StatefulWidget {
  final GhostController controller;
  final VoidCallback onSend;

  const GhostKeyboard({super.key, required this.controller, required this.onSend});

  @override
  State<GhostKeyboard> createState() => _GhostKeyboardState();
}

class _GhostKeyboardState extends State<GhostKeyboard> {
  KeyboardMode _mode = KeyboardMode.letters;
  KeyboardLang _lang = KeyboardLang.en;

  // --- Раскладки букв ---
  final enRow1 = ['q','w','e','r','t','y','u','i','o','p'];
  final enRow2 = ['a','s','d','f','g','h','j','k','l'];
  final enRow3 = ['z','x','c','v','b','n','m'];

  final ruRow1 = ['й','ц','у','к','е','н','г','ш','щ','з','х','ъ'];
  final ruRow2 = ['ф','ы','в','а','п','р','о','л','д','ж','э'];
  final ruRow3 = ['я','ч','с','м','и','т','ь','б','ю'];

  // --- Символы ---
  final symRow1 = ['1','2','3','4','5','6','7','8','9','0'];
  final symRow2 = ['@','#','\$','%','&','-','+','(',')','/'];
  final symRow3 = ['*','"','\'',':',';','!','?','_','=','\\'];

  // --- Смайлы ---
  final emojis = [
    '😂','❤️','👍','🙌','😍','🤔','😊','🔥','😭','✨',
    '🚀','💀','💯','🙏','🤡','👀','⚡️','📍','🛡️','🔑',
    '🔓','💊','🚬','💣','🔫','📞','💻','⌛','📢','❌'
  ];

  Widget _key(String label, VoidCallback onTap, {int flex = 1, Color? color, bool isActive = false, VoidCallback? onLongPress}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.lightImpact(); // 🔥 Вибрация при нажатии
              onTap();
            },
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(6),
            child: Ink(
              height: 46,
              decoration: BoxDecoration(
                color: isActive ? Colors.redAccent : (color ?? const Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  if (!isActive) BoxShadow(color: Colors.black.withOpacity(0.3), offset: const Offset(0, 1), blurRadius: 1)
                ],
              ),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                      color: isActive ? Colors.black : Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Сборка букв с лонг-прессом на удаление ---
  List<Widget> _buildAlphaRows() {
    final bool isEn = _lang == KeyboardLang.en;
    final r1 = isEn ? enRow1 : ruRow1;
    final r2 = isEn ? enRow2 : ruRow2;
    final r3 = isEn ? enRow3 : ruRow3;

    return [
      Row(children: r1.map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList()),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: isEn ? 15 : 5),
        child: Row(children: r2.map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList()),
      ),
      Row(children: [
        _key('⇧', () => widget.controller.toggleCase(), isActive: widget.controller.isUpperCase),
        ...r3.map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList(),
        // 🔥 Кнопка Backspace с LongPress очисткой
        _key('⌫',
                () => widget.controller.backspace(),
            onLongPress: () => widget.controller.clear(), // Очистить всё поле
            color: const Color(0xFF444444)),
      ]),
    ];
  }

  // --- Сборка символов с лонг-прессом ---
  List<Widget> _buildSymbolRows() {
    return [
      Row(children: symRow1.map((s) => _key(s, () => widget.controller.add(s))).toList()),
      Row(children: symRow2.map((s) => _key(s, () => widget.controller.add(s))).toList()),
      Row(children: [
        _key('.', () => widget.controller.add('.')),
        ...symRow3.map((s) => _key(s, () => widget.controller.add(s))).toList(),
        // 🔥 Тут тоже лонг-пресс
        _key('⌫',
                () => widget.controller.backspace(),
            onLongPress: () => widget.controller.clear(),
            color: const Color(0xFF444444)),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return Container(
          color: const Color(0xFF0D0D0D),
          padding: EdgeInsets.fromLTRB(2, 8, 2, MediaQuery.of(context).padding.bottom + 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Основные ряды (Буквы/Символы/Смайлы)
              if (_mode == KeyboardMode.letters) ..._buildAlphaRows(),
              if (_mode == KeyboardMode.symbols) ..._buildSymbolRows(),
              if (_mode == KeyboardMode.emojis) _buildEmojiGrid(),

              const SizedBox(height: 8),

              // 🔥 НОВЫЙ РЯД: УПРАВЛЕНИЕ КУРСОРОМ И ВСТАВКА
              Row(
                children: [
                  _key('⬅️', () => widget.controller.moveLeft(), color: const Color(0xFF333333)),
                  _key('PASTE', () => widget.controller.paste(), flex: 2, color: const Color(0xFF333333)),
                  _key('➡️', () => widget.controller.moveRight(), color: const Color(0xFF333333)),
                ],
              ),

              const SizedBox(height: 4),

              // 2. НИЖНИЙ РЯД УПРАВЛЕНИЯ
              Row(
                children: [
                  // Смена языка
                  _key(_lang == KeyboardLang.en ? 'EN' : 'RU',
                          () => setState(() => _lang = _lang == KeyboardLang.en ? KeyboardLang.ru : KeyboardLang.en),
                      color: const Color(0xFF3A3A3A), flex: 2
                  ),
                  // Смена режима
                  _key(_mode == KeyboardMode.letters ? '?123' : 'ABC',
                          () => setState(() => _mode = _mode == KeyboardMode.symbols ? KeyboardMode.letters : KeyboardMode.symbols),
                      color: const Color(0xFF444444), flex: 2
                  ),
                  // Пробел
                  _key('SPACE', () => widget.controller.add(' '), flex: 4),
                  // Смайлы
                  _key(_mode == KeyboardMode.emojis ? 'ABC' : '😊',
                          () => setState(() => _mode = _mode == KeyboardMode.emojis ? KeyboardMode.letters : KeyboardMode.emojis),
                      color: const Color(0xFF444444), flex: 2
                  ),
                  // Отправить / ОК
                  _key('OK', widget.onSend, color: Colors.redAccent, flex: 2),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Сборка буквенных рядов ---


  // --- Сетка смайлов ---
  Widget _buildEmojiGrid() {
    return SizedBox(
      height: 140,
      child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: emojis.length,
        itemBuilder: (context, index) {
          return InkWell(
            onTap: () => widget.controller.add(emojis[index]),
            child: Container(
              alignment: Alignment.center,
              child: Text(emojis[index], style: const TextStyle(fontSize: 24)),
            ),
          );
        },
      ),
    );
  }
}