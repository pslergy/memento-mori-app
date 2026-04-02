import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ghost_controller.dart';

enum KeyboardMode { letters, symbols, emojis }
enum KeyboardLang { en, ru }

/// Кастомная клавиатура в стиле приложения: тёмная панель, красные акценты, крупные зоны нажатия.
class GhostKeyboard extends StatefulWidget {
  final GhostController controller;
  final VoidCallback onSend;

  const GhostKeyboard({
    super.key,
    required this.controller,
    required this.onSend,
  });

  @override
  State<GhostKeyboard> createState() => _GhostKeyboardState();
}

class _GhostKeyboardState extends State<GhostKeyboard>
    with WidgetsBindingObserver {
  static const Color _panel = Color(0xFF0A0A0A);
  static const Color _panelElevated = Color(0xFF141414);
  static const Color _keyFill = Color(0xFF1C1C1E);
  static const Color _keyFillSecondary = Color(0xFF2C2C2E);
  static const Color _keyBorder = Color(0xFF3A3A3C);
  static const Color _accent = Color(0xFFFF3B30);
  static const Color _accentDim = Color(0x66FF3B30);
  static const Color _labelPrimary = Color(0xFFF2F2F7);
  static const Color _labelMuted = Color(0xFF8E8E93);

  KeyboardMode _mode = KeyboardMode.letters;
  KeyboardLang _lang = KeyboardLang.en;

  final enLetters = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];

  final ruLetters = [
    ['й', 'ц', 'у', 'к', 'е', 'н', 'г', 'ш', 'щ', 'з', 'х', 'ъ'],
    ['ф', 'ы', 'в', 'а', 'п', 'р', 'о', 'л', 'д', 'ж', 'э'],
    ['я', 'ч', 'с', 'м', 'и', 'т', 'ь', 'б', 'ю'],
  ];

  final symbols = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['@', '#', r'$', '%', '&', '-', '+', '(', ')', '/'],
    ['.', ',', '_', '=', ';', ':', '!', '?', '"', '\''],
  ];

  final List<List<String>> emojiPages = [
    ['😂', '❤️', '👍', '🙌', '😍', '🤔', '😊', '🔥', '😭', '✨'],
    ['🚀', '💀', '💯', '🙏', '🤡', '👀', '⚡️', '📍', '🛡️', '🔑'],
    ['🔓', '💊', '🚬', '💣', '🔫', '📞', '💻', '⌛', '📢', '❌'],
  ];

  int _emojiPage = 0;

  /// Пока панель открыта: периодически дергаем контроллер + кадр, чтобы не залипал hit-test после долгого AFK.
  Timer? _idleKeepAlive;

  static const Duration _keepAlivePeriod = Duration(seconds: 90);

  void _haptic() => HapticFeedback.lightImpact();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _idleKeepAlive = Timer.periodic(_keepAlivePeriod, (_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      widget.controller.touchKeepAlive();
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        widget.controller.touchKeepAlive(minInterval: Duration.zero);
        WidgetsBinding.instance.scheduleFrame();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleKeepAlive?.cancel();
    super.dispose();
  }

  /// Huawei/EMUI: GestureDetector + opaque — надёжнее InkWell.
  Widget _keyCap(
    String label,
    VoidCallback onTap, {
    int flex = 1,
    Color? fill,
    Color? borderColor,
    Color? textColor,
    bool active = false,
    double height = 48,
    FontWeight weight = FontWeight.w500,
    double fontSize = 16,
    VoidCallback? onLongPress,
  }) {
    final bg = active
        ? _accent
        : (fill ?? _keyFill);
    final fg = active
        ? Colors.black
        : (textColor ?? _labelPrimary);
    final border = borderColor ??
        (active ? _accent : _keyBorder);

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _haptic();
            onTap();
          },
          onLongPress: onLongPress == null
              ? null
              : () {
                  _haptic();
                  onLongPress();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            height: height,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border.withValues(alpha: 0.9), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: fontSize,
                fontWeight: weight,
                letterSpacing: label.length > 2 ? 0.8 : 0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLetterRows() {
    final letters = _lang == KeyboardLang.en ? enLetters : ruLetters;
    return [
      Row(
        children: letters[0]
            .map((l) => _keyCap(
                  widget.controller.isUpperCase ? l.toUpperCase() : l,
                  () => widget.controller.add(l),
                ))
            .toList(),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: letters[1]
              .map((l) => _keyCap(
                    widget.controller.isUpperCase ? l.toUpperCase() : l,
                    () => widget.controller.add(l),
                  ))
              .toList(),
        ),
      ),
      Row(
        children: [
          _keyCap(
            '⇧',
            () => setState(() => widget.controller.toggleCase()),
            flex: 2,
            fill: _keyFillSecondary,
            active: widget.controller.isUpperCase,
            fontSize: 18,
          ),
          ...letters[2].map(
            (l) => _keyCap(
              widget.controller.isUpperCase ? l.toUpperCase() : l,
              () => widget.controller.add(l),
            ),
          ),
          _keyCap(
            '⌫',
            () => widget.controller.backspace(),
            flex: 2,
            fill: _keyFillSecondary,
            textColor: _labelMuted,
            fontSize: 18,
            onLongPress: () {
              while (widget.controller.cursorPosition > 0 &&
                  widget.controller
                          .value[widget.controller.cursorPosition - 1] !=
                      ' ') {
                widget.controller.backspace();
              }
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildSymbolRows() {
    return symbols
        .map(
          (row) => Row(
            children: row
                .map((s) => _keyCap(s, () => widget.controller.add(s)))
                .toList(),
          ),
        )
        .toList();
  }

  Widget _buildModeStrip() {
    Widget chip({
      required String label,
      required IconData icon,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _haptic();
              onTap();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? _accent.withValues(alpha: 0.22) : _keyFill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? _accent : _keyBorder,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? _accent : _labelMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? _labelPrimary : _labelMuted,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(
          label: 'ABC',
          icon: Icons.text_fields_rounded,
          selected: _mode == KeyboardMode.letters,
          onTap: () => setState(() => _mode = KeyboardMode.letters),
        ),
        chip(
          label: '123',
          icon: Icons.dialpad_rounded,
          selected: _mode == KeyboardMode.symbols,
          onTap: () => setState(() => _mode = KeyboardMode.symbols),
        ),
        chip(
          label: 'Emoji',
          icon: Icons.emoji_emotions_outlined,
          selected: _mode == KeyboardMode.emojis,
          onTap: () => setState(() => _mode = KeyboardMode.emojis),
        ),
      ],
    );
  }

  Widget _buildEmojiGrid() {
    final emojis = emojiPages[_emojiPage];
    return Column(
      children: [
        SizedBox(
          height: 148,
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: emojis.length,
            itemBuilder: (context, index) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _haptic();
                  widget.controller.add(emojis[index]);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _keyFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _keyBorder),
                  ),
                  child: Center(
                    child: Text(
                      emojis[index],
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(emojiPages.length, (i) {
            final on = i == _emojiPage;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _haptic();
                setState(() => _emojiPage = i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.symmetric(horizontal: 5),
                width: on ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: on ? _accent : _labelMuted.withValues(alpha: 0.35),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildLangRow() {
    Widget spaceKey() {
      return Expanded(
        flex: 5,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _haptic();
              widget.controller.add(' ');
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: _keyFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _keyBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.space_bar_rounded,
                color: _labelMuted,
                size: 28,
              ),
            ),
          ),
        ),
      );
    }

    Widget sendKey() {
      return Expanded(
        flex: 2,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _haptic();
              widget.onSend();
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF453A), Color(0xFFC62828)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _accent.withValues(alpha: 0.85)),
                boxShadow: [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.send_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        _keyCap(
          _lang == KeyboardLang.en ? 'EN' : 'RU',
          () => setState(
            () => _lang =
                _lang == KeyboardLang.en ? KeyboardLang.ru : KeyboardLang.en,
          ),
          flex: 2,
          fill: _keyFillSecondary,
          textColor: _accent,
          weight: FontWeight.w700,
        ),
        spaceKey(),
        sendKey(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return Material(
          color: Colors.transparent,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: _panel,
              border: Border(
                top: BorderSide(color: _accentDim, width: 1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: ClipRRect(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 3,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [_accentDim, Colors.transparent],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(10, 10, 10, bottomInset + 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _panelElevated,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _keyBorder.withValues(alpha: 0.6)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildModeStrip(),
                          const SizedBox(height: 10),
                          if (_mode == KeyboardMode.letters) ..._buildLetterRows(),
                          if (_mode == KeyboardMode.symbols) ..._buildSymbolRows(),
                          if (_mode == KeyboardMode.emojis) _buildEmojiGrid(),
                          const SizedBox(height: 10),
                          Row(
                            children: ['.', ',', '@', '_', '-', '/']
                                .map(
                                  (s) => _keyCap(
                                    s,
                                    () => widget.controller.add(s),
                                    flex: 1,
                                    height: 40,
                                    fontSize: 15,
                                    fill: _keyFillSecondary,
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 8),
                          _buildLangRow(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
