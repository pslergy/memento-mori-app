import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_core_engine.dart';
import 'package:memento_mori_app/core/native_mesh_service.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

/// Экран Share App: отправка или приём APK по Wi-Fi Direct.
/// Требует активного P2P соединения (The Chain).
class ShareAppScreen extends StatefulWidget {
  const ShareAppScreen({super.key});

  @override
  State<ShareAppScreen> createState() => _ShareAppScreenState();
}

class _ShareAppScreenState extends State<ShareAppScreen> {
  bool _isSending = false;
  bool _isReceiving = false;
  String? _statusMessage;
  String? _errorMessage;
  String? _receivedPath;
  /// Android 8+: разрешена ли установка APK из этого приложения; `null` — ещё не проверяли.
  bool? _canInstallApk;

  MeshCoreEngine get _mesh => locator<MeshCoreEngine>();

  bool get _isP2pConnected => _mesh.isP2pConnected;
  String get _peerIp => _mesh.lastKnownPeerIp;
  bool get _isGoRole => _mesh.isHost;

  @override
  void initState() {
    super.initState();
    _mesh.addListener(_onMeshChanged);
    unawaited(_refreshInstallPermission());
  }

  @override
  void dispose() {
    _mesh.removeListener(_onMeshChanged);
    super.dispose();
  }

  void _onMeshChanged() {
    if (mounted) setState(() {});
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
            _buildPlayBundleWarning(),
            const SizedBox(height: 16),
            if (_isP2pConnected) _buildStepsCard(),
            const SizedBox(height: 24),
            if (!_isP2pConnected) _buildNotConnectedView(),
            if (_isP2pConnected) ...[
              if (_isGoRole && _peerIp.isEmpty) _buildGoWaitingPeerCard(),
              const SizedBox(height: 16),
              _buildReceiveButton(),
              const SizedBox(height: 16),
              _buildShareButton(),
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
            'Send this app\'s APK to a nearby device over the mesh P2P link (TCP port 55557). '
            'Both devices must be connected via The Chain first.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
        ],
      ),
    );
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
              'If you installed from Play (App Bundle), the path to the app on disk may be a split/base APK — '
              'the other device might not install it. For reliable sharing, use a universal release APK '
              '(e.g. flutter build apk).',
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
          _stepRow('1', 'Receiving device: tap Receive app and wait (up to 2 min).'),
          const SizedBox(height: 6),
          _stepRow('2', 'Sending device: tap Share app → peer IP (after peer IP appears).'),
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

  Widget _buildShareButton() {
    final bool noPeerIp = _peerIp.isEmpty;
    return ElevatedButton.icon(
      onPressed: _isSending || noPeerIp ? null : () => _sendApk(),
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
          : Icon(Icons.send, color: noPeerIp ? Colors.grey : Colors.black),
      label: Text(
        _isSending
            ? 'Sending…'
            : noPeerIp
                ? 'No peer IP (wait for mesh client)'
                : 'Share app → $peerIpShort',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  String get peerIpShort {
    if (_peerIp.length <= 16) return _peerIp;
    return '${_peerIp.substring(0, 12)}…';
  }

  Widget _buildReceiveButton() {
    return OutlinedButton.icon(
      onPressed: _isReceiving ? null : () => _receiveApk(),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.gridCyan,
        side: const BorderSide(color: AppColors.gridCyan),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: _isReceiving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gridCyan),
            )
          : const Icon(Icons.download),
      label: Text(
        _isReceiving ? 'Waiting for APK… (up to 2 min)' : 'Receive app (start first)',
        style: const TextStyle(fontWeight: FontWeight.bold),
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
    if (!_isP2pConnected || _peerIp.isEmpty) return;
    setState(() {
      _isSending = true;
      _errorMessage = null;
      _statusMessage = null;
    });
    try {
      final apkPath = await NativeMeshService.getApkPath();
      if (apkPath == null) {
        setState(() {
          _errorMessage = 'Could not get APK path';
          _isSending = false;
        });
        return;
      }
      await NativeMeshService.sendApkFile(filePath: apkPath, host: _peerIp);
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
      _errorMessage = null;
      _statusMessage = null;
      _receivedPath = null;
    });
    try {
      final path = await NativeMeshService.startApkReceiveServer(
        timeoutSeconds: 120,
      );
      if (mounted) {
        setState(() {
          _receivedPath = path;
          _isReceiving = false;
          _statusMessage = 'APK received and saved';
        });
        await _refreshInstallPermission();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isReceiving = false;
        });
      }
    }
  }

  Future<void> _installReceivedApk() async {
    final path = _receivedPath;
    if (path == null) return;
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

