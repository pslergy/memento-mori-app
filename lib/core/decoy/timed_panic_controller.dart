// lib/core/decoy/timed_panic_controller.dart
//
// Timed Panic v2: автоматический мягкий выход из REAL при подозрительном бездействии.
// Не рвёт BLE/Wi‑Fi, не меняет тайминги mesh. Exit только после drain или по таймауту.
//
// Инварианты: UI ≠ транспорт; первый meaningful touch отменяет QUIET; таймер только
// при REAL + foreground + screen on + нет активности > N мин + нет активного drain.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api_service.dart';
import '../ghost_transfer_manager.dart';
import '../locator.dart';
import 'mode_exit_service.dart';

enum PanicPhase {
  normal,
  quietReal,
  draining,
}

/// Smart Drain (PROMPT #8): пороги для решения о выходе. Решения по сообщениям, время по hoops.
const int _smallHoopsThreshold = 2;
const double _fastDrainRate = 2.0; // hoops per second
const int _drainExtensionSeconds = 5;

/// Отдельный сервис; не часть UI, не часть ModeExitService, не часть Mesh FSM.
/// Наблюдает состояние, управляет фазой; никогда напрямую не управляет транспортом.
class TimedPanicController with ChangeNotifier {
  TimedPanicController({
    this.idleMinutes = 5,
    this.quietSeconds = 30,
    this.maxDrainTimeSeconds = 15,
    bool? armed,
  }) : _armed = armed ?? !kDebugMode;

  final int idleMinutes;
  final int quietSeconds;
  final int maxDrainTimeSeconds;
  final bool _armed;

  PanicPhase _phase = PanicPhase.normal;
  PanicPhase get phase => _phase;

  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;
  bool _screenOn = true;
  DateTime? _lastActivity;
  Timer? _idleTimer;
  Timer? _quietTimer;
  Timer? _drainCheckTimer;
  Timer? _drainExtensionTimer;
  DateTime? _drainStartedAt;
  int? _lastQueueLength;
  bool _gtmListenerAdded = false;
  bool _drainExtensionScheduled = false;

  void _onGtmChanged() {
    if (_phase != PanicPhase.normal) return;
    if (!locator.isRegistered<GhostTransferManager>()) return;
    try {
      final len = locator<GhostTransferManager>().totalQueueLength;
      if (_lastQueueLength != null && len < _lastQueueLength!) recordActivity();
      _lastQueueLength = len;
    } catch (_) {}
  }

  bool get _isForeground => _appLifecycle == AppLifecycleState.resumed;
  bool get _timerConditionsMet =>
      _isForeground &&
      _screenOn &&
      _phase == PanicPhase.normal &&
      _lastActivity != null;

  void onAppLifecycleChanged(AppLifecycleState state) {
    _appLifecycle = state;
    if (!_isForeground) {
      _cancelIdleTimer();
      _cancelQuietTimer();
    } else if (_phase == PanicPhase.normal) {
      _scheduleIdleTimer();
    }
    notifyListeners();
  }

  void setScreenOn(bool on) {
    _screenOn = on;
    if (!on) _cancelIdleTimer();
    notifyListeners();
  }

  /// Вызов при любом meaningful activity (send, receive, scroll, tap, queue decrease).
  /// В QUIET_REAL первый вызов отменяет панику и возвращает NORMAL.
  void recordActivity() {
    if (_phase == PanicPhase.quietReal) {
      _phase = PanicPhase.normal;
      _cancelQuietTimer();
      _scheduleIdleTimer();
      if (kDebugMode)
        debugPrint('[TimedPanic] QUIET cancelled by activity → NORMAL');
      notifyListeners();
      return;
    }
    if (_phase == PanicPhase.draining) return;
    _lastActivity = DateTime.now();
    _scheduleIdleTimer();
    notifyListeners();
  }

  void start() {
    if (_phase != PanicPhase.normal) return;
    _lastActivity = DateTime.now();
    if (locator.isRegistered<GhostTransferManager>()) {
      try {
        final gtm = locator<GhostTransferManager>();
        _lastQueueLength = gtm.totalQueueLength;
        if (!_gtmListenerAdded) {
          gtm.addListener(_onGtmChanged);
          _gtmListenerAdded = true;
        }
      } catch (_) {}
    }
    _scheduleIdleTimer();
  }

  void _scheduleIdleTimer() {
    _cancelIdleTimer();
    if (!_timerConditionsMet) return;
    _idleTimer = Timer(Duration(minutes: idleMinutes), _onIdleExpired);
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _onIdleExpired() {
    _cancelIdleTimer();
    if (_phase != PanicPhase.normal || !_isForeground) return;
    _phase = PanicPhase.quietReal;
    if (kDebugMode) debugPrint('[TimedPanic] Idle expired → QUIET_REAL');
    notifyListeners();
    _quietTimer?.cancel();
    _quietTimer = Timer(Duration(seconds: quietSeconds), _onQuietExpired);
  }

  void _cancelQuietTimer() {
    _quietTimer?.cancel();
    _quietTimer = null;
  }

  void _onQuietExpired() {
    _cancelQuietTimer();
    if (_phase != PanicPhase.quietReal) return;
    _phase = PanicPhase.draining;
    if (kDebugMode) debugPrint('[TimedPanic] QUIET expired → DRAINING');
    _drainStartedAt = DateTime.now();
    if (locator.isRegistered<GhostTransferManager>()) {
      try {
        locator<GhostTransferManager>().setDrainOnly(true);
      } catch (_) {}
    }
    notifyListeners();
    _drainCheckTimer?.cancel();
    _drainCheckTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkDrainDone());
  }

  void _checkDrainDone() {
    if (_phase != PanicPhase.draining) {
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      return;
    }
    if (!locator.isRegistered<GhostTransferManager>()) {
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      _triggerExit();
      return;
    }
    final gtm = locator<GhostTransferManager>();
    final metrics = gtm.outboxMetrics;
    final pendingMessages = metrics.pendingMessages;
    final pendingHoops = metrics.pendingHoops;
    final hoopsPerSecond = metrics.hoopsPerSecond;
    final drainTimeout = _drainStartedAt != null &&
        DateTime.now().difference(_drainStartedAt!).inSeconds >=
            maxDrainTimeSeconds;

    if (!_armed) {
      debugPrint(
          '[TimedPanic] SmartDrain pendingMessages=$pendingMessages pendingHoops=$pendingHoops hoopsPerSecond=$hoopsPerSecond');
    }

    // Очередь пуста → exit сразу
    if (pendingMessages == 0) {
      if (!_armed)
        debugPrint('[TimedPanic] SmartDrain decision: exit (queue empty)');
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      _drainExtensionTimer?.cancel();
      _triggerExit();
      return;
    }

    // Таймаут drain → exit
    if (drainTimeout) {
      if (!_armed)
        debugPrint('[TimedPanic] SmartDrain decision: exit (drain timeout)');
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      _drainExtensionTimer?.cancel();
      _triggerExit();
      return;
    }

    // > 3 сообщений → exit без ожидания
    if (pendingMessages > 3) {
      if (!_armed)
        debugPrint(
            '[TimedPanic] SmartDrain decision: exit (pendingMessages > 3)');
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      _drainExtensionTimer?.cancel();
      _triggerExit();
      return;
    }

    // 1 сообщение: короткое расширение при малых hoops или быстрой доставке
    if (pendingMessages == 1) {
      if (pendingHoops <= _smallHoopsThreshold ||
          hoopsPerSecond >= _fastDrainRate) {
        if (!_drainExtensionScheduled) {
          _drainExtensionScheduled = true;
          _drainExtensionTimer?.cancel();
          _drainExtensionTimer =
              Timer(Duration(seconds: _drainExtensionSeconds), () {
            _drainExtensionTimer = null;
            if (!_armed)
              debugPrint(
                  '[TimedPanic] SmartDrain decision: exit (after extension)');
            _triggerExit();
          });
          if (!_armed)
            debugPrint(
                '[TimedPanic] SmartDrain decision: wait extension $_drainExtensionSeconds s');
        }
        return;
      }
      if (!_armed)
        debugPrint('[TimedPanic] SmartDrain decision: exit (1 msg, slow)');
      _drainCheckTimer?.cancel();
      _drainCheckTimer = null;
      _drainExtensionTimer?.cancel();
      _triggerExit();
      return;
    }

    // 2–3 сообщения: продолжаем проверять по таймеру (drainTimeout или пусто обработаются выше)
  }

  void _triggerExit() {
    if (!_armed) {
      if (kDebugMode) debugPrint('[TimedPanic] Exit skipped (not armed)');
      return;
    }
    if (locator.isRegistered<ApiService>()) {
      try {
        locator<ApiService>().logout();
      } catch (_) {}
    }
    try {
      ModeExitService.performExit();
    } catch (_) {}
  }
}
