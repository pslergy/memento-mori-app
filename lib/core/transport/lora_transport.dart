// lib/core/transport/lora_transport.dart
//
// LoRa transport skeleton: implements TransportInterface, start/stop/send/onPacket.
// No real hardware (no UART/SPI), no external libs. Mock receive via receiveMock().
// Not activated by default (enableLoRa = false in TransportConfig).

import 'dart:convert';

import 'transport_interface.dart';

/// LoRa transport skeleton. EU868 typical max payload; fragmentation not implemented.
class LoRaTransport implements TransportInterface {
  LoRaTransport._();
  static final LoRaTransport _instance = LoRaTransport._();
  factory LoRaTransport() => _instance;

  bool _isRunning = false;
  OnPacketCallback? _onPacket;

  /// EU868 typical max payload (bytes). Exceeding triggers log only; no fragmentation yet.
  static const int maxPayloadBytes = 220;

  /// Mock latency for simulated receive delay. Not used for real radio.
  Duration mockLatency = Duration.zero;

  @override
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _log('LoRa transport started');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    _log('LoRa transport stopped');
  }

  @override
  void onPacket(OnPacketCallback callback) {
    _onPacket = callback;
  }

  @override
  Future<void> send(TransportPacket packet) async {
    final serialized = utf8.encode(jsonEncode(packet));
    final size = serialized.length;
    if (size > maxPayloadBytes) {
      _log('send: fragmentation required (payload $size bytes > $maxPayloadBytes); not implemented');
    }
    _log('send: payload size=$size bytes');
    // No real radio: nothing to transmit
  }

  @override
  bool isAvailable() => _isRunning;

  @override
  TransportType getTransportType() => TransportType.LORA;

  /// Inject a mock packet (e.g. from tests). Delivers to onPacket callback if set.
  void receiveMock(TransportPacket packet) {
    if (_onPacket != null) {
      if (mockLatency > Duration.zero) {
        Future.delayed(mockLatency, () => _onPacket!(packet));
      } else {
        _onPacket!(packet);
      }
    }
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().split('T').last.substring(0, 8);
    print('[$ts] [LoRaTransport] $message');
  }

  // ——— Future (TODOs) ———
  // TODO: fragmentation layer for payloads > maxPayloadBytes
  // TODO: duty cycle compliance (EU868 1% etc.)
  // TODO: AES payload encryption reuse (mesh encryption service)
  // TODO: ADR support (adaptive data rate)
  // TODO: store-and-forward queue when radio busy or offline
}
