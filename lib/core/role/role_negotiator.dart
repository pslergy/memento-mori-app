// lib/core/role/role_negotiator.dart
// Bridge role negotiation: backend assigns role via POST /mesh/hello.
// Without a valid lease, node MUST NOT behave as BRIDGE.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../storage_service.dart';
import '../security_config.dart';

/// Response from POST /mesh/hello. role is 'GHOST'|'CLIENT'|'BRIDGE'.
class HelloResponse {
  final String role;
  final String? leaseId;
  final DateTime? expiresAt;

  HelloResponse({required this.role, this.leaseId, this.expiresAt});
}

void _noopLeaseLost() {}

/// Negotiates role with backend. Stores lease; heartbeat on failure or expiry → calls [onLeaseLost].
class RoleNegotiator {
  RoleNegotiator({void Function()? onLeaseLost}) : _onLeaseLost = onLeaseLost ?? _noopLeaseLost;

  static String get _baseUrl => SecurityConfig.backendBaseUrl;
  static const String _helloEndpoint = '/mesh/hello';
  static const Duration heartbeatInterval = Duration(seconds: 60);
  static const Duration leaseGraceMs = Duration(seconds: 30);

  final void Function() _onLeaseLost;
  String? _leaseId;
  DateTime? _expiresAt;
  Timer? _heartbeatTimer;
  bool _heartbeatRunning = false;

  String? get leaseId => _leaseId;
  DateTime? get expiresAt => _expiresAt;

  /// True only when we have an active BRIDGE lease not yet expired.
  bool get hasValidLease {
    if (_leaseId == null || _expiresAt == null) return false;
    return DateTime.now().isBefore(_expiresAt!.add(leaseGraceMs));
  }

  http.Client _createClient() {
    final ioc = createSecureHttpClient();
    ioc.connectionTimeout = const Duration(seconds: 8);
    return IOClient(ioc);
  }

  /// Call when internet is available (ONLINE_UNCONFIRMED). Returns assigned role.
  Future<HelloResponse> hello() async {
    final client = _createClient();
    try {
      final token = await Vault.read('auth_token');
      if (token == null || token == 'GHOST_MODE_ACTIVE') {
        _log('[ROLE] hello skipped: no auth token');
        return HelloResponse(role: 'CLIENT');
      }
      final url = Uri.parse('$_baseUrl$_helloEndpoint');
      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
      ).timeout(const Duration(seconds: 8));

      client.close();

      if (response.statusCode != 200) {
        _log('[ROLE] hello failed: ${response.statusCode}');
        return HelloResponse(role: 'CLIENT');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>?;
      if (data == null) return HelloResponse(role: 'CLIENT');

      String roleStr = (data['role'] as String?) ?? 'CLIENT';
      if (roleStr != 'BRIDGE' && roleStr != 'GHOST') roleStr = 'CLIENT';

      final lid = data['leaseId'] as String?;
      final exp = data['expiresAt'];
      DateTime? expiresAt;
      if (exp != null) {
        if (exp is int) expiresAt = DateTime.fromMillisecondsSinceEpoch(exp);
        else if (exp is num) expiresAt = DateTime.fromMillisecondsSinceEpoch(exp.toInt());
      }

      if (roleStr == 'BRIDGE' && (lid == null || lid.isEmpty || expiresAt == null)) {
        _log('[ROLE] BRIDGE rejected: missing leaseId or expiresAt');
        roleStr = 'CLIENT';
      }

      if (roleStr == 'BRIDGE') {
        _leaseId = lid;
        _expiresAt = expiresAt;
        _log('[ROLE] Lease assigned: leaseId=$lid expiresAt=$expiresAt');
        _startHeartbeat();
      } else {
        _clearLease();
        _stopHeartbeat();
      }

      return HelloResponse(role: roleStr, leaseId: _leaseId, expiresAt: _expiresAt);
    } catch (e) {
      _log('[ROLE] hello error: $e');
      client.close();
      return HelloResponse(role: 'CLIENT');
    }
  }

  /// Heartbeat: same endpoint or dedicated. On failure or expiry → downgrade.
  Future<void> _heartbeat() async {
    if (!_heartbeatRunning || _leaseId == null) return;
    if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
      _log('[ROLE] Lease expired: expiresAt=$_expiresAt');
      _downgradeToClient();
      return;
    }
    final client = _createClient();
    try {
      final token = await Vault.read('auth_token');
      final url = Uri.parse('$_baseUrl$_helloEndpoint');
      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'leaseId': _leaseId, 'ts': DateTime.now().millisecondsSinceEpoch}),
      ).timeout(const Duration(seconds: 8));
      client.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        if (data != null && data['expiresAt'] != null) {
          final exp = data['expiresAt'];
          if (exp is int) _expiresAt = DateTime.fromMillisecondsSinceEpoch(exp);
          else if (exp is num) _expiresAt = DateTime.fromMillisecondsSinceEpoch(exp.toInt());
        }
        return;
      }
      _log('[ROLE] Heartbeat failed: ${response.statusCode}');
      _downgradeToClient();
    } catch (e) {
      _log('[ROLE] Heartbeat error: $e');
      client.close();
      _downgradeToClient();
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatRunning = true;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _heartbeat());
  }

  void _stopHeartbeat() {
    _heartbeatRunning = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _clearLease() {
    _leaseId = null;
    _expiresAt = null;
  }

  void _downgradeToClient() {
    _clearLease();
    _stopHeartbeat();
    _log('[ROLE] Lease lost or heartbeat failure — downgrading');
    _onLeaseLost();
  }

  void dispose() {
    _stopHeartbeat();
    _clearLease();
  }

  void _log(String msg) => print(msg);
}
