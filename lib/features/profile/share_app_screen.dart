import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh/mesh_constants.dart'
    show kMeshHotspotShareEnabled, kMeshHotspotShareHttpPort, kMeshP2pRendezvousEnabled;
import 'package:memento_mori_app/core/mesh_core_engine.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

/// Экран Share App: приём/отправка APK по Wi-Fi Direct (The Chain)
/// и офлайн-отправка через системное меню (Bluetooth и др.) без месса на втором телефоне.
class ShareAppScreen extends StatefulWidget {
  const ShareAppScreen({super.key});

  @override
  State<ShareAppScreen> createState() => _ShareAppScreenState();
}

class _ShareAppScreenState extends State<ShareAppScreen> {
  bool _isSending = false;
  bool _isReceiving = false;
  /// Натив подтвердил bind :55557 (до accept) — показываем «LISTENING».
  bool _apkListeningReady = false;
  StreamSubscription<int>? _apkListenSub;
  String? _statusMessage;
  String? _errorMessage;
  String? _receivedPath;
  /// Android 8+: разрешена ли установка APK из этого приложения; `null` — ещё не проверяли.
  bool? _canInstallApk;
  bool _p2pDiagLoading = false;
  String? _p2pDiagSummary;
  bool _offlineShareBusy = false;
  /// Краткий вывод `hotspotShareGetStatus` (заготовка натива).
  String? _hotspotStatusSummary;
  bool _hotspotStatusLoading = false;
  /// Локальный IPv4 на интерфейсе Wi‑Fi Direct (из нативной диагностики) — показываем отправителю.
  String? _receiverLocalP2pIp;
  bool _refreshingLocalP2pIp = false;
  bool? _prevP2pConnected;
  /// Ручной IP получателя (если mesh не выдал `lastKnownPeerIp`, напр. GO до mesh TCP).
  final TextEditingController _manualHostController = TextEditingController();

  MeshCoreEngine get _mesh => locator<MeshCoreEngine>();

  bool get _isP2pConnected => _mesh.isP2pConnected;
  String get _peerIp => _mesh.lastKnownPeerIp;
  bool get _isGoRole => _mesh.isHost;

  /// Куда слать TCP: поле ввода имеет приоритет над IP из mesh.
  String get _effectiveSendHost {
    final m = _manualHostController.text.trim();
    if (m.isNotEmpty) return m;
    return _peerIp;
  }

  bool get _canSendApk => _isP2pConnected && _effectiveSendHost.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _apkListenSub = NativeMeshService.apkReceiveListenPortStream.listen((port) {
      if (!mounted || !_isReceiving) return;
      setState(() {
        _apkListeningReady = true;
        _statusMessage =
            'LISTENING on TCP $port — other phone can tap «Connect to server & send APK» now.';
      });
    });
    _mesh.addListener(_onMeshChanged);
    _manualHostController.addListener(_onMeshChanged);
    unawaited(_refreshInstallPermission());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isP2pConnected) {
        unawaited(_silentRefreshLocalP2pIp());
      }
    });
  }

  @override
  void dispose() {
    _apkListenSub?.cancel();
    _mesh.removeListener(_onMeshChanged);
    _manualHostController.removeListener(_onMeshChanged);
    _manualHostController.dispose();
    super.dispose();
  }

  void _onMeshChanged() {
    final c = _isP2pConnected;
    final prev = _prevP2pConnected;
    if (prev != c) {
      if (prev == true && !c) {
        _receiverLocalP2pIp = null;
      }
      if (c) {
        unawaited(_silentRefreshLocalP2pIp());
      }
      _prevP2pConnected = c;
    }
    if (mounted) setState(() {});
  }

  void _applyLocalIpFromDiagnosticsMap(Map<String, dynamic> m) {
    final has = m['hasP2pNetwork'] == true;
    if (!has) {
      _receiverLocalP2pIp = null;
      return;
    }
    final addr = m['localP2pBindAddress']?.toString().trim();
    _receiverLocalP2pIp =
        (addr != null && addr.isNotEmpty) ? addr : null;
  }

  /// Обновить локальный P2P IP (лёгкий вызов натива; без сброса P2P/BLE).
  Future<void> _silentRefreshLocalP2pIp() async {
    if (!mounted || _refreshingLocalP2pIp) return;
    _refreshingLocalP2pIp = true;
    try {
      final m = await NativeMeshService.getApkP2pLinkDiagnostics();
      if (!mounted) return;
      setState(() => _applyLocalIpFromDiagnosticsMap(m));
    } catch (_) {
      // ignore
    } finally {
      _refreshingLocalP2pIp = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshInstallPermission() async {
    final ok = await NativeMeshService.canRequestApkInstall();
    if (mounted) setState(() => _canInstallApk = ok);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'SHARE APP',
          style: TextStyle(
            letterSpacing: 2,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHintCard(),
            const SizedBox(height: 16),
            _buildOfflineShareCard(),
            const SizedBox(height: 16),
            _buildPlayBundleWarning(),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const SizedBox(height: 16),
              _buildHotspotFoundationCard(),
            ],
            const SizedBox(height: 16),
            if (_isP2pConnected) ...[
              _buildStepsCard(),
              const SizedBox(height: 20),
            ],
            if (!_isP2pConnected) _buildNotConnectedView(),
            if (_isP2pConnected) ...[
              if (_isGoRole && _peerIp.isEmpty) _buildGoWaitingPeerCard(),
              if (_isGoRole && _peerIp.isEmpty) const SizedBox(height: 16),
              _buildReceiverServerCard(),
              const SizedBox(height: 16),
              _buildSenderConnectCard(),
            ],
            if (_statusMessage != null) ...[
              const SizedBox(height: 20),
              _buildStatusCard(_statusMessage!, isError: false),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 20),
              _buildStatusCard(_errorMessage!, isError: true),
            ],
            if (_receivedPath != null) ...[
              const SizedBox(height: 20),
              _buildInstallPrompt(),
            ],
            const SizedBox(height: 24),
            _buildP2pApkDiagnosticsCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildHintCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering, color: AppColors.gridCyan, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Wi-Fi Direct Share',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Two ways: (A) Offline sharing below — system sheet (Bluetooth / Nearby / …), other phone does not need this app. '
            '(B) Wi‑Fi Direct: The Chain brings up P2P; the APK goes over TCP (port ${NativeMeshService.apkTransferPort}) — '
            'receiver starts the transfer server, sender connects and uploads. '
            'Troubleshooting at the bottom is read-only OS status — it does not move the file.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  /// Офлайн: системный ACTION_SEND — Bluetooth / Nearby и т.д.; второй телефон без месса.
  Widget _buildOfflineShareCard() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.textDim.withValues(alpha: 0.25)),
        ),
        child: Text(
          'System share (Bluetooth / offline) is available on Android only.',
          style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.35),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cloudGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.share, color: AppColors.cloudGreen, size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Offline / no internet',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Use when the other person does not have this messenger installed, or there is no internet. '
            'No Wi‑Fi Direct or The Chain required on this path.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 12),
          _offlineInstructionRow(
            '1',
            'Optional: pair both phones in system Bluetooth settings if you plan to use Bluetooth file transfer.',
          ),
          const SizedBox(height: 6),
          _offlineInstructionRow(
            '2',
            'Tap the button below. Android opens the share sheet — choose Bluetooth, Nearby Share (if available), or another app.',
          ),
          const SizedBox(height: 6),
          _offlineInstructionRow(
            '3',
            'On the other phone, accept the file, then open the APK. They may need to allow installing apps from unknown sources / that sender app.',
          ),
          const SizedBox(height: 6),
          _offlineInstructionRow(
            '4',
            'Prefer a universal release APK built on a PC (flutter build apk --release). Play / split installs may not install on the other device.',
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _offlineShareBusy ? null : () => unawaited(_shareApkViaSystem()),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.cloudGreen,
              side: const BorderSide(color: AppColors.cloudGreen),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _offlineShareBusy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.cloudGreen,
                    ),
                  )
                : Icon(Icons.bluetooth, color: AppColors.cloudGreen, size: 22),
            label: Text(
              _offlineShareBusy ? 'Preparing…' : 'Share installer via system…',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _offlineInstructionRow(String n, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            n,
            style: TextStyle(
              color: AppColors.cloudGreen,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
          ),
        ),
      ],
    );
  }

  Future<void> _shareApkViaSystem() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    setState(() {
      _offlineShareBusy = true;
      _errorMessage = null;
    });
    try {
      await NativeMeshService.shareApkViaSystem();
      if (mounted) {
        setState(() {
          _statusMessage =
              'Share sheet opened — pick Bluetooth, Nearby, or another app. No internet required.';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? e.code;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _offlineShareBusy = false);
    }
  }

  /// Заготовка Hotspot + HTTP: нативный статус и константы для следующего этапа.
  Widget _buildHotspotFoundationCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.textDim.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering_error_rounded,
                  color: AppColors.textDim.withValues(alpha: 0.9), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Hotspot file relay (foundation)',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Planned: turn on a portable hotspot (or local-only Wi‑Fi), serve the APK over HTTP on port '
            '$kMeshHotspotShareHttpPort so the other phone can download in a browser — no internet, no mesh on their side. '
            'Native API hooks exist; tethering + HTTP server are not started yet.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
          ),
          if (!kMeshHotspotShareEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Feature flag kMeshHotspotShareEnabled is false — UI extensions stay minimal until implementation lands.',
                style: TextStyle(
                  color: AppColors.stealthOrange.withValues(alpha: 0.9),
                  fontSize: 10,
                  height: 1.3,
                ),
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _hotspotStatusLoading ? null : () => unawaited(_refreshHotspotNativeStatus()),
            icon: _hotspotStatusLoading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textDim,
                    ),
                  )
                : Icon(Icons.info_outline, size: 18, color: AppColors.textDim),
            label: const Text('Query native hotspot stub status'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textDim,
              side: BorderSide(color: AppColors.textDim.withValues(alpha: 0.45)),
            ),
          ),
          if (_hotspotStatusSummary != null && _hotspotStatusSummary!.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              _hotspotStatusSummary!,
              style: TextStyle(
                color: AppColors.textDim.withValues(alpha: 0.95),
                fontSize: 10,
                height: 1.35,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _refreshHotspotNativeStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    setState(() {
      _hotspotStatusLoading = true;
      _hotspotStatusSummary = null;
    });
    try {
      final m = await NativeMeshService.hotspotShareGetStatus();
      final buf = StringBuffer()
        ..writeln('implemented: ${m['implemented']}')
        ..writeln('ready: ${m['ready']}')
        ..writeln('plannedHttpPort: ${m['plannedHttpPort']}')
        ..writeln('apiLevel: ${m['apiLevel']}')
        ..write('hint: ${m['hint']}');
      if (mounted) {
        setState(() => _hotspotStatusSummary = buf.toString());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hotspotStatusSummary = 'Error: $e');
      }
    } finally {
      if (mounted) setState(() => _hotspotStatusLoading = false);
    }
  }

  /// После успешного приёма по P2P — системный шаг установки.
  Future<void> _showP2pReceiveInstallDialog(
    String path, {
    required bool needInstallSettings,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(
            children: [
              Icon(Icons.install_mobile, color: AppColors.cloudGreen, size: 26),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'APK received',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The file is saved. Open the Android package installer now?',
                  style: TextStyle(color: AppColors.textDim, fontSize: 14, height: 1.35),
                ),
                if (needInstallSettings) ...[
                  const SizedBox(height: 12),
                  Text(
                    'If install is blocked, tap «App settings» first and allow installing unknown apps for this app, then use Install on this screen again.',
                    style: TextStyle(
                      color: AppColors.stealthOrange.withValues(alpha: 0.95),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Later', style: TextStyle(color: AppColors.textDim)),
            ),
            if (needInstallSettings)
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  try {
                    await NativeMeshService.openApkInstallSettings();
                  } catch (e) {
                    if (mounted) {
                      setState(() => _errorMessage = 'Could not open settings: $e');
                    }
                  }
                },
                child: Text(
                  'App settings',
                  style: TextStyle(color: AppColors.stealthOrange),
                ),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.cloudGreen,
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _installReceivedApkForPath(path);
              },
              child: const Text('Install'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildP2pApkDiagnosticsCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Troubleshooting (optional)',
            style: TextStyle(
              color: AppColors.gridCyan,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Read-only: what ConnectivityManager reports about Wi‑Fi Direct. '
            'Does not start the transfer server, does not connect, does not send the APK. '
            'Does not remove the P2P group or stop BLE — use if the address is missing or transfer fails.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.3),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _p2pDiagLoading ? null : _runP2pApkDiagnostics,
            icon: _p2pDiagLoading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.gridCyan,
                    ),
                  )
                : Icon(Icons.troubleshoot, color: AppColors.gridCyan, size: 20),
            label: Text(
              _p2pDiagLoading ? 'Checking…' : 'Wi‑Fi Direct status (read-only)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.gridCyan,
              side: BorderSide(color: AppColors.gridCyan.withValues(alpha: 0.85)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          if (_p2pDiagSummary != null) ...[
            const SizedBox(height: 12),
            Text(
              _p2pDiagSummary!,
              style: TextStyle(
                color: AppColors.textDim,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runP2pApkDiagnostics() async {
    setState(() {
      _p2pDiagLoading = true;
      _errorMessage = null;
    });
    try {
      final m = await NativeMeshService.getApkP2pLinkDiagnostics();
      final hint = m['hint']?.toString() ?? '';
      final has = m['hasP2pNetwork'] == true;
      final addr = m['localP2pBindAddress']?.toString();
      final onSubnet = m['onP2pSubnet'] == true;
      final chain = _isP2pConnected ? 'connected' : 'not connected';
      final peer = _peerIp.isEmpty ? '—' : _peerIp;
      final lines = <String>[
        hint,
        'The Chain (app): $chain · mesh peer IP: $peer',
        'OS sees P2P: ${has ? 'yes' : 'no'}'
            '${addr != null && addr.isNotEmpty ? ' · local $addr${onSubnet ? ' (GO/client subnet)' : ''}' : ''}',
      ];
      if (mounted) {
        setState(() {
          _applyLocalIpFromDiagnosticsMap(m);
          _p2pDiagSummary = lines.where((s) => s.isNotEmpty).join('\n');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _p2pDiagLoading = false);
    }
  }

  Widget _buildPlayBundleWarning() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.stealthOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.stealthOrange.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: AppColors.stealthOrange, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You do not build the APK on the phone: Share uses the installed app package. '
              'We copy it to app cache so TCP can read it reliably. '
              'If you installed from Play (App Bundle / splits), the copied file may still not install on the other phone — '
              'for reliable offline sharing, sideload a universal release APK built on your PC (e.g. flutter build apk --release).',
              style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Order',
            style: TextStyle(
              color: AppColors.gridCyan,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          _stepRow(
            '1',
            'Receiver: tap «Start transfer server» first — this phone listens on TCP ${NativeMeshService.apkTransferPort} and waits.',
          ),
          const SizedBox(height: 6),
          _stepRow(
            '2',
            'Sender: tap «Connect to server & send APK» while the receiver is waiting — '
            'that opens TCP and uploads the file. Use mesh IP or the address shown on the receiver.',
          ),
        ],
      ),
    );
  }

  Widget _stepRow(String n, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            n,
            style: TextStyle(
              color: AppColors.gridCyan,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.3),
          ),
        ),
      ],
    );
  }

  Widget _buildGoWaitingPeerCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.router, color: AppColors.gridCyan, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'You are Group Owner: peer IP appears after the other device joins mesh TCP. '
              'Wait until Share shows a destination IP, or use the device in client role to send.',
              style: TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotConnectedView() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.stealthOrange.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Icon(Icons.link_off, color: AppColors.stealthOrange, size: 40),
          const SizedBox(height: 12),
          Text(
            'Connect via The Chain first',
            style: TextStyle(
              color: AppColors.stealthOrange,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Open "The Chain (Mesh Net)" from Operations and establish a P2P connection with the other device before sharing.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiverLocalP2pAddressBlock() {
    final port = NativeMeshService.apkTransferPort;
    final ip = _receiverLocalP2pIp;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Address for the sender (this phone)',
                style: TextStyle(
                  color: AppColors.gridCyan.withValues(alpha: 0.95),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: (_refreshingLocalP2pIp || !_isP2pConnected)
                  ? null
                  : () => unawaited(_silentRefreshLocalP2pIp()),
              child: Text(_refreshingLocalP2pIp ? '…' : 'Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (ip == null || ip.isEmpty)
          Text(
            'Not reported by the OS yet. Tap Refresh, or use Troubleshooting → Wi‑Fi Direct status below.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.gridCyan.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    '$ip:$port',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.2,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy host:port',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: '$ip:$port'));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Copied host:port for sender'),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: Icon(Icons.copy, color: AppColors.gridCyan, size: 22),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildReceiverServerCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.dns, color: AppColors.gridCyan, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Receiver — start here',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'This phone opens a TCP server on port ${NativeMeshService.apkTransferPort}. '
            'After you tap the button, wait for the green «LISTENING» line — then the other phone sends.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 12),
          if (_isReceiving && _apkListeningReady) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D2818),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF4ADE80), width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.sensors, color: const Color(0xFF4ADE80), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'LISTENING — waiting for incoming APK (up to 2 min)',
                      style: TextStyle(
                        color: const Color(0xFF4ADE80),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _buildReceiverLocalP2pAddressBlock(),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _isReceiving ? null : () => _receiveApk(),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.gridCyan,
              side: const BorderSide(color: AppColors.gridCyan),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _isReceiving
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _apkListeningReady
                          ? const Color(0xFF4ADE80)
                          : AppColors.gridCyan,
                    ),
                  )
                : const Icon(Icons.cloud_download_outlined),
            label: Text(
              !_isReceiving
                  ? 'Start transfer server'
                  : _apkListeningReady
                      ? 'Listening — waiting for file…'
                      : 'Starting server…',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSenderConnectCard() {
    final bool canSend = _canSendApk;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.upload_file, color: AppColors.gridCyan, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sender — after receiver started the server',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Opens TCP to the receiver’s server, then uploads the APK. '
            'Only works while the other phone is already waiting with «Start transfer server». '
            'Host = mesh peer IP below, or paste the address from the receiver’s screen.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 10),
          Text(
            'Mesh peer IP: ${_peerIp.isEmpty ? "— (not from mesh yet)" : _peerIp}',
            style: TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _manualHostController,
            keyboardType: TextInputType.text,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Override host (e.g. 192.168.49.1)',
              hintStyle: TextStyle(color: AppColors.textDim.withValues(alpha: 0.85)),
              filled: true,
              fillColor: AppColors.background.withValues(alpha: 0.5),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppColors.gridCyan.withValues(alpha: 0.35)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.gridCyan),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: _isSending || !canSend ? null : () => _sendApk(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gridCyan,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _isSending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : Icon(Icons.link, color: canSend ? Colors.black : Colors.grey),
            label: Text(
              _isSending
                  ? 'Sending APK…'
                  : !canSend
                      ? 'Need The Chain + host (mesh or manual)'
                      : 'Connect to server & send APK → ${_effectiveSendHost.length > 18 ? "${_effectiveSendHost.substring(0, 14)}…" : _effectiveSendHost}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(String message, {required bool isError}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError
            ? AppColors.warningRed.withValues(alpha: 0.2)
            : AppColors.cloudGreen.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? AppColors.warningRed : AppColors.cloudGreen,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: isError ? AppColors.warningRed : AppColors.cloudGreen,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isError ? AppColors.warningRed : AppColors.cloudGreen,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstallPrompt() {
    final needSettings = _canInstallApk == false;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cloudGreen.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cloudGreen),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'APK received',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.cloudGreen,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          if (needSettings) ...[
            const SizedBox(height: 10),
            Text(
              'Android requires "Install unknown apps" for this app. Open settings, allow installs, then tap Install again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.3),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                try {
                  await NativeMeshService.openApkInstallSettings();
                } catch (e) {
                  if (mounted) {
                    setState(() => _errorMessage = 'Could not open settings: $e');
                  }
                }
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.cloudGreen,
                side: const BorderSide(color: AppColors.cloudGreen),
              ),
              child: const Text('Open install permission settings'),
            ),
          ],
          Builder(
            builder: (context) {
              final p = _receivedPath;
              if (p == null || p.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Saved path (app private storage)',
                style: TextStyle(
                  color: AppColors.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Not the public Downloads gallery on some phones — usually under Android/data/…/files/Download/. '
              'Use Install below, or copy the path for a PC/USB file manager.',
              style: TextStyle(color: AppColors.textDim.withValues(alpha: 0.9), fontSize: 10, height: 1.35),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.gridCyan.withValues(alpha: 0.25)),
              ),
              child: SelectableText(
                p,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  height: 1.25,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: p));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Path copied'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.gridCyan,
                side: BorderSide(color: AppColors.gridCyan.withValues(alpha: 0.6)),
              ),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy full path'),
            ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () => _installReceivedApk(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.cloudGreen,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Install'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendApk() async {
    if (!_canSendApk) return;
    final host = _effectiveSendHost;
    setState(() {
      _isSending = true;
      _errorMessage = null;
      _statusMessage = null;
    });
    try {
      final prepared = await NativeMeshService.prepareApkForShare();
      if (prepared == null) {
        setState(() {
          _errorMessage =
              'Could not prepare APK for send (no read access to installed package). '
              'Try reinstalling, or share a universal APK built with flutter build apk --release.';
          _isSending = false;
        });
        return;
      }
      final apkPath = prepared.path;
      if (prepared.isSplitInstall && mounted) {
        setState(() {
          _statusMessage =
              'Split-install app: the file may not install on the other device. Prefer a universal release APK.';
        });
      }
      if (kMeshP2pRendezvousEnabled) {
        if (mounted) {
          setState(() => _statusMessage = 'BLE hint: waiting for peer (P2P_RENDEZVOUS)…');
        }
        await _mesh.emitP2pRendezvousForApkShare();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (mounted) {
        setState(() => _statusMessage = 'Connecting to $host:${NativeMeshService.apkTransferPort}…');
      }
      await NativeMeshService.sendApkFile(filePath: apkPath, host: host);
      if (mounted) {
        setState(() {
          _statusMessage = 'APK sent successfully';
          _isSending = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isSending = false;
        });
      }
    }
  }

  Future<void> _receiveApk() async {
    if (!_isP2pConnected) return;
    setState(() {
      _isReceiving = true;
      _apkListeningReady = false;
      _errorMessage = null;
      _statusMessage =
          'Opening receive server (up to ~5 s) — then LISTENING will appear…';
      _receivedPath = null;
    });
    // Дать отрисовать «Starting…» до долгого native receive (accept может висеть минуты).
    await WidgetsBinding.instance.endOfFrame;
    try {
      final path = await NativeMeshService.startApkReceiveServer(
        timeoutSeconds: 120,
        p2pPrepareWaitMs: 15000,
      );
      if (mounted) {
        setState(() {
          _receivedPath = path;
          _isReceiving = false;
          _apkListeningReady = false;
          _statusMessage = 'APK received and saved';
        });
        await _refreshInstallPermission();
        final needSettings = _canInstallApk == false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_showP2pReceiveInstallDialog(path, needInstallSettings: needSettings));
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isReceiving = false;
          _apkListeningReady = false;
        });
      }
    }
  }

  Future<void> _installReceivedApk() async {
    final path = _receivedPath;
    if (path == null || path.isEmpty) return;
    await _installReceivedApkForPath(path);
  }

  Future<void> _installReceivedApkForPath(String path) async {
    if (path.isEmpty) return;
    setState(() => _errorMessage = null);
    try {
      await NativeMeshService.installApk(path);
      if (mounted) await _refreshInstallPermission();
    } on PlatformException catch (e) {
      if (e.code == 'INSTALL_PERMISSION_REQUIRED') {
        if (mounted) {
          setState(() {
            _canInstallApk = false;
            _errorMessage =
                e.message ?? 'Allow installation from this app in Android settings, then try again.';
          });
        }
        if (mounted) {
          unawaited(_showP2pReceiveInstallDialog(path, needInstallSettings: true));
        }
      } else {
        if (mounted) {
          setState(() => _errorMessage = 'Install failed: ${e.message ?? e.code}');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Install failed: $e');
      }
    }
  }
}

