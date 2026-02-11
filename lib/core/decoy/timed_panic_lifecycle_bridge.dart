// lib/core/decoy/timed_panic_lifecycle_bridge.dart
//
// Передаёт AppLifecycle в TimedPanicController и запускает его при первом resumed.
// При долгой неактивности (свёрнуто/в фоне > 5 мин) показывает калькулятор для повторного ввода кода.

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../app_navigator_key.dart';
import '../locator.dart';
import '../../features/camouflage/calculator_gate.dart';
import 'timed_panic_controller.dart';

class TimedPanicLifecycleBridge extends StatefulWidget {
  const TimedPanicLifecycleBridge({super.key, required this.child});

  final Widget child;

  @override
  State<TimedPanicLifecycleBridge> createState() =>
      _TimedPanicLifecycleBridgeState();
}

class _TimedPanicLifecycleBridgeState extends State<TimedPanicLifecycleBridge>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      lastBackgroundTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = lastBackgroundTime;
      if (at != null &&
          DateTime.now().difference(at) >= inactivityThreshold) {
        lastBackgroundTime = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          appNavigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const CalculatorGate()),
            (_) => false,
          );
        });
      }
      if (locator.isRegistered<TimedPanicController>()) {
        locator<TimedPanicController>().onAppLifecycleChanged(state);
      }
    } else if (locator.isRegistered<TimedPanicController>()) {
      locator<TimedPanicController>().onAppLifecycleChanged(state);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Запуск Timed Panic только после успешного входа (вызывать из MainScreen).
void startTimedPanicAfterLogin() {
  if (!locator.isRegistered<TimedPanicController>()) return;
  locator<TimedPanicController>().start();
}
