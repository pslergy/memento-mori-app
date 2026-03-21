import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'decoy/app_bootstrap.dart';
import 'decoy/app_mode.dart';
import 'locator.dart';
import 'mesh_core_engine.dart';

/// После [SecureLocalPurge] нужно заново зарегистрировать GetIt **и** пересоздать
/// [Provider&lt;MeshCoreEngine&gt;], иначе в дереве останется старый экземпляр.
class DiRestartScope extends StatefulWidget {
  const DiRestartScope({
    super.key,
    required this.initialMode,
    required this.child,
  });

  final AppMode initialMode;
  final Widget child;

  @override
  State<DiRestartScope> createState() => DiRestartScopeState();
}

class DiRestartScopeState extends State<DiRestartScope> {
  static DiRestartScopeState? _instance;

  late AppMode _mode;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _instance = this;
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    super.dispose();
  }

  /// Сброс GetIt и пересборка mesh-провайдера (вызывать после стирания REAL).
  Future<void> rebindAfterPurge() async {
    final mode = await resolveAppMode();
    if (!mounted) return;
    if (mode == AppMode.INVALID) return;
    locator.reset();
    setupCoreLocator(mode);
    setupSessionLocator(mode);
    setState(() {
      _mode = mode;
      _epoch++;
    });
  }

  AppMode get currentMode => _mode;

  /// Для вызова из статического [PanicService] без [BuildContext] scope.
  static Future<void> rebindAfterPurgeFromStatic() async {
    final i = _instance;
    if (i != null) {
      await i.rebindAfterPurge();
      return;
    }
    final mode = await resolveAppMode();
    if (mode == AppMode.INVALID) return;
    locator.reset();
    setupCoreLocator(mode);
    setupSessionLocator(mode);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<MeshCoreEngine>(
          key: ValueKey(_epoch),
          create: (_) => locator<MeshCoreEngine>(),
        ),
      ],
      child: RestartedAppModeScope(
        mode: _mode,
        child: widget.child,
      ),
    );
  }
}

/// Актуальный режим после [DiRestartScopeState.rebindAfterPurge] (для [PermissionGate] / [MyApp]).
class RestartedAppModeScope extends InheritedWidget {
  const RestartedAppModeScope({
    super.key,
    required this.mode,
    required super.child,
  });

  final AppMode mode;

  static AppMode of(BuildContext context) {
    final w =
        context.dependOnInheritedWidgetOfExactType<RestartedAppModeScope>();
    assert(w != null, 'RestartedAppModeScope not found');
    return w!.mode;
  }

  @override
  bool updateShouldNotify(RestartedAppModeScope oldWidget) =>
      oldWidget.mode != mode;
}
