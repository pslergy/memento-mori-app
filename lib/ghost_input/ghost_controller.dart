import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GhostController extends ChangeNotifier {
  final List<String> _chars = [];
  int _cursorPosition = 0;
  bool _isUpperCase = false;

  // ================================
  // GETTERS
  // ================================
  String get value => _chars.join();
  int get cursorPosition => _cursorPosition;
  bool get isUpperCase => _isUpperCase;

  String get masked => '•' * _chars.length;

  // ================================
  // TEXT EDITING
  // ================================
  void add(String char) {
    String formattedChar = RegExp(r'[a-zA-Zа-яА-Я]').hasMatch(char)
        ? (_isUpperCase ? char.toUpperCase() : char.toLowerCase())
        : char;

    _chars.insert(_cursorPosition, formattedChar);
    _cursorPosition++;
    notifyListeners();
  }

  void backspace() {
    if (_chars.isNotEmpty && _cursorPosition > 0) {
      _chars.removeAt(_cursorPosition - 1);
      _cursorPosition--;
      notifyListeners();
    }
  }

  void addSpace() {
    _chars.insert(_cursorPosition, ' ');
    _cursorPosition++;
    notifyListeners();
  }

  void clear() {
    _chars.clear();
    _cursorPosition = 0;
    notifyListeners();
  }

  // ================================
  // CURSOR CONTROL
  // ================================
  void moveLeft() {
    if (_cursorPosition > 0) {
      _cursorPosition--;
      notifyListeners();
    }
  }

  void moveRight() {
    if (_cursorPosition < _chars.length) {
      _cursorPosition++;
      notifyListeners();
    }
  }

  void setCursor(int position) {
    _cursorPosition = position.clamp(0, _chars.length);
    notifyListeners();
  }

  // ================================
  // CASE TOGGLE
  // ================================
  void toggleCase() {
    _isUpperCase = !_isUpperCase;
    notifyListeners();
  }

  // ================================
  // PASTE SUPPORT
  // ================================
  Future<void> paste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.isNotEmpty) {
      final text = data.text!;
      _chars.insertAll(_cursorPosition, text.split(''));
      _cursorPosition += text.length;
      notifyListeners();
    }
  }
}
