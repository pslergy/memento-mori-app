// lib/core/user_provider.dart
import 'package:flutter/material.dart';

// Простой класс для хранения данных
class UserData {
  final String id;
  final String username;
  final DateTime deathDate;

  UserData({
    required this.id,
    required this.username,
    required this.deathDate,
  });

  // Фабричный конструктор для создания из JSON (который приходит с сервера)
  factory UserData.fromJson(Map<String, dynamic> json) {
    return UserData(
      id: json['id'],
      username: json['username'],
      deathDate: DateTime.parse(json['deathDate']), // Превращаем строку в DateTime
    );
  }
}

// Виджет-провайдер, который делает UserData доступным
class UserProvider extends InheritedWidget {
  final UserData? userData;

  const UserProvider({
    super.key,
    required this.userData,
    required super.child,
  });

  // Статический метод для удобного доступа к данным из любого места
  static UserProvider? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<UserProvider>();
  }

  @override
  bool updateShouldNotify(UserProvider oldWidget) {
    return userData != oldWidget.userData;
  }
}