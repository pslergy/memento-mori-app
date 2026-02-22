// Глобальный ключ навигатора и время ухода в фон для вызова комуфляжа при долгой неактивности.

import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

DateTime? lastBackgroundTime;
const inactivityThreshold = Duration(minutes: 5);
