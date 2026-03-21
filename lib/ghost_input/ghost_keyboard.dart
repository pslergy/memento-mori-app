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

  // --- Буквы ---
  final enLetters = [
    ['q','w','e','r','t','y','u','i','o','p'],
    ['a','s','d','f','g','h','j','k','l'],
    ['z','x','c','v','b','n','m']
  ];

  final ruLetters = [
    ['й','ц','у','к','е','н','г','ш','щ','з','х','ъ'],
    ['ф','ы','в','а','п','р','о','л','д','ж','э'],
    ['я','ч','с','м','и','т','ь','б','ю']
  ];

  // --- Символы и цифры ---
  final symbols = [
    ['1','2','3','4','5','6','7','8','9','0'],
    ['@','#','\$','%','&','-','+','(',')','/'],
    ['.',',','_','=',';',':','!','?','"','\'']
  ];

  // --- Смайлы ---
  final List<List<String>> emojiPages = [
    ['😂','❤️','👍','🙌','😍','🤔','😊','🔥','😭','✨'],
    ['🚀','💀','💯','🙏','🤡','👀','⚡️','📍','🛡️','🔑'],
    ['🔓','💊','🚬','💣','🔫','📞','💻','⌛','📢','❌']
  ];

  int _emojiPage = 0;

  Widget _key(String label, VoidCallback onTap,
      {int flex = 1, Color? color, bool isActive = false, VoidCallback? onLongPress}) {
    // GestureDetector + opaque hit target: на части прошивок (Huawei/EMUI) после resume
    // InkWell перестаёт получать касания; Samsung обычно не страдает.
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          onLongPress: onLongPress,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: isActive ? Colors.redAccent : (color ?? const Color(0xFF2A2A2A)),
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                if (!isActive)
                  BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      offset: const Offset(0, 1),
                      blurRadius: 1)
              ],
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                    color: isActive ? Colors.black : Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Ряды букв ---
  List<Widget> _buildLetterRows() {
    final letters = _lang == KeyboardLang.en ? enLetters : ruLetters;
    return [
      Row(children: letters[0].map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Row(children: letters[1].map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList()),
      ),
      Row(children: [
        _key('⇧', () => setState(() => widget.controller.toggleCase()), isActive: widget.controller.isUpperCase),
        ...letters[2].map((l) => _key(widget.controller.isUpperCase ? l.toUpperCase() : l, () => widget.controller.add(l))).toList(),
        _key('⌫', () => widget.controller.backspace(),
            onLongPress: () {
              // Удаляем слово
              while(widget.controller.cursorPosition > 0 && widget.controller.value[widget.controller.cursorPosition-1] != ' ') {
                widget.controller.backspace();
              }
            },
            color: const Color(0xFF444444)),
      ]),
    ];
  }

  // --- Ряды символов ---
  List<Widget> _buildSymbolRows() {
    return symbols.map((row) {
      return Row(children: row.map((s) => _key(s, () => widget.controller.add(s))).toList());
    }).toList();
  }

  // --- Emoji Grid ---
  Widget _buildEmojiGrid() {
    final emojis = emojiPages[_emojiPage];
    return Column(
      children: [
        SizedBox(
          height: 140,
          child: GridView.builder(
            padding: const EdgeInsets.all(4),
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1,
            ),
            itemCount: emojis.length,
            itemBuilder: (context, index) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.lightImpact();
                  widget.controller.add(emojis[index]);
                },
                child: Center(child: Text(emojis[index], style: const TextStyle(fontSize: 28))),
              );
            },
          ),
        ),
        // Page selector
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(emojiPages.length, (i) => GestureDetector(
            onTap: () => setState(() => _emojiPage = i),
            child: Container(
              margin: const EdgeInsets.all(2),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == _emojiPage ? Colors.redAccent : Colors.grey,
              ),
            ),
          )),
        )
      ],
    );
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
              // Основные ряды
              if (_mode == KeyboardMode.letters) ..._buildLetterRows(),
              if (_mode == KeyboardMode.symbols) ..._buildSymbolRows(),
              if (_mode == KeyboardMode.emojis) _buildEmojiGrid(),

              const SizedBox(height: 8),

              // Быстрая вставка символов
              Row(
                children: ['.', ',', '@', '_', '-', '/']
                    .map((s) => _key(s, () => widget.controller.add(s), flex: 1))
                    .toList(),
              ),

              const SizedBox(height: 4),

              // Нижний ряд управления
              Row(
                children: [
                  _key(_lang == KeyboardLang.en ? 'EN' : 'RU',
                          () => setState(() => _lang = _lang == KeyboardLang.en ? KeyboardLang.ru : KeyboardLang.en),
                      color: const Color(0xFF3A3A3A), flex: 2),
                  _key(_mode == KeyboardMode.letters ? '?123' : 'ABC',
                          () => setState(() {
                        _mode = _mode == KeyboardMode.symbols ? KeyboardMode.letters : KeyboardMode.symbols;
                      }),
                      color: const Color(0xFF444444), flex: 2),
                  _key('SPACE', () => widget.controller.add(' '), flex: 4),
                  _key(_mode == KeyboardMode.emojis ? 'ABC' : '😊',
                          () => setState(() => _mode = _mode == KeyboardMode.emojis ? KeyboardMode.letters : KeyboardMode.emojis),
                      color: const Color(0xFF444444), flex: 2),
                  _key('OK', widget.onSend, color: Colors.redAccent, flex: 2),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
