import 'package:flutter/foundation.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GhostController extends ChangeNotifier {
  String _value = '';
  int _cursorPosition = 0; // 🔥 ПОЗИЦИЯ КУРСОРA
  bool _isUpperCase = false;

  String get value => _value;
  int get cursorPosition => _cursorPosition;
  bool get isUpperCase => _isUpperCase;

  String get masked => List.filled(_value.length, '•').join();

  // Добавление в позицию курсора
  void add(String char) {
    String formattedChar = RegExp(r'[a-zA-Zа-яА-Я]').hasMatch(char)
        ? (_isUpperCase ? char.toUpperCase() : char.toLowerCase())
        : char;

    _value = _value.substring(0, _cursorPosition) +
        formattedChar +
        _value.substring(_cursorPosition);
    _cursorPosition++;
    notifyListeners();
  }

  void backspace() {
    if (_value.isNotEmpty && _cursorPosition > 0) {
      _value = _value.substring(0, _cursorPosition - 1) +
          _value.substring(_cursorPosition);
      _cursorPosition--;
      notifyListeners();
    }
  }
  void moveLeft() { if (_cursorPosition > 0) { _cursorPosition--; notifyListeners(); } }
  void moveRight() { if (_cursorPosition < _value.length) { _cursorPosition++; notifyListeners(); } }

  // 🔥 БУФЕР ОБМЕНА (PASTE)
  Future<void> paste() async {
    ClipboardData? data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      for (var i = 0; i < data!.text!.length; i++) {
        add(data.text![i]);
      }
    }
  }

  void clear() { _value = ''; _cursorPosition = 0; notifyListeners(); }



  void toggleCase() {
    _isUpperCase = !_isUpperCase;
    notifyListeners();
  }
  void addSpace() {
    _value += ' ';
    notifyListeners();
  }

}

