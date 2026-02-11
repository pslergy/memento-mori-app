import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sound_generator/sound_generator.dart';
import 'package:sound_generator/waveTypes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'native_mesh_service.dart';

/// 🔒 КОНТРАКТ SONAR: орган чувств сети, не транспорт.
///
/// Sonar используется для:
/// • обнаружения соседних узлов (beacon = «узел рядом»);
/// • bootstrap / hint для BLE и Wi‑Fi (сигнал может подсказать «кто-то здесь», не более);
/// • экстренных коротких сигналов (SOS, очень короткие сообщения в sendAuto / cascade).
///
/// Sonar не является надёжным транспортом:
/// • может быть потерян или искажён;
/// • не гарантирует доставку;
/// • любой принятый Sonar-сигнал = намёк (hint), а не факт доставки.
///
/// Sonar не используется для gossip или bulk-доставки. Не подключать к PeerCache
/// как success/failure доставки; допускаются только observation / presence.
class UltrasonicService {
  static final UltrasonicService _instance = UltrasonicService._internal();
  factory UltrasonicService() => _instance;
  UltrasonicService._internal() {
    _setupNativeReceiver();
  }

  static const MethodChannel _channel = MethodChannel('ultrasonic');

  final StreamController<String> _sonarController = StreamController<String>.broadcast();
  Stream<String> get sonarMessages => _sonarController.stream;

  // 🔥 ТАКТИЧЕСКИЙ СТЕЛС: Частоты выше 19.5 кГц
  double _freq0 = 19800.0;
  double _freq1 = 20400.0;

  bool _isTransmitting = false;
  bool _isInitialized = false;
  bool _isCalibrating = false;

  bool get isTransmitting => _isTransmitting;

  static const _bitDurationMs = 120;
  static const _interFrameGapMs = 400;
  static const _preamble = [0xAA, 0xAA, 0xAC];

  void _log(String m) => print("🔊 [Sonar] $m");

  /// Инициализация аппаратного микшера.
  /// 🔥 ВАЖНО: Методы SoundGenerator возвращают void, убираем await.
  Future<void> _initHardware() async {
    if (_isInitialized) return;
    try {
      SoundGenerator.init(44100);
      SoundGenerator.setWaveType(waveTypes.SINUSOIDAL);
      SoundGenerator.setVolume(0.3);
      _isInitialized = true;
      _log("Hardware Ready. Frequencies: $_freq0 / $_freq1 Hz");
    } catch (e) {
      _log("🚨 Audio HAL Lock: $e");
    }
  }

  /// Авто-калибровка спектра
  Future<void> autoCalibrateIfNeeded({bool force = false}) async {
    if (_isCalibrating) return;
    _isCalibrating = true;
    final prefs = await SharedPreferences.getInstance();

    if (!force) {
      final savedF0 = prefs.getDouble('ultra_freq0');
      if (savedF0 != null) {
        _freq0 = savedF0;
        _freq1 = savedF0 + 600.0;
        _isCalibrating = false;
        return;
      }
    }

    try {
      _log("🧪 Scanning spectral environment...");
      final dynamic raw = await _channel.invokeMethod('runFrequencySweep');
      final Map<double, double> spectrum = {};

      if (raw is Map) {
        raw.forEach((k, v) {
          final key = double.tryParse(k.toString());
          final value = double.tryParse(v.toString());
          if (key != null && value != null) spectrum[key] = value;
        });
      }

      if (spectrum.isNotEmpty) {
        final sorted = spectrum.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
        _freq0 = sorted.first.key;
        _freq1 = _freq0 + 600.0;
        await prefs.setDouble('ultra_freq0', _freq0);
        _log("✅ Optimal window found: $_freq0 Hz");
      }
    } catch (e) {
      _log("⚠️ FFT Scan failed, using stealth defaults.");
      _freq0 = 19800.0;
      _freq1 = 20400.0;
    } finally {
      _isCalibrating = false;
    }
  }

  /// Передача кадра данных
  Future<void> transmitFrame(String payload) async {
    if (_isTransmitting) return;
    _isTransmitting = true;

    try {
      await _initHardware();

      // 🛡️ MUTEX: Останавливаем прослушку
      await NativeMeshService.stopSonarListening();
      await Future.delayed(const Duration(milliseconds: 300));

      final data = utf8.encode(payload);
      final frame = [..._preamble, data.length, ...data, _crc8(data)];
      final bits = frame.expand((b) => List.generate(8, (i) => (b >> (7 - i)) & 1)).toList();

      _log("🚀 Emitting Acoustic Frame (${data.length} bytes)...");

      SoundGenerator.play();
      final sw = Stopwatch()..start();
      int lastBitTime = 0;

      for (final bit in bits) {
        SoundGenerator.setFrequency(bit == 1 ? _freq1 : _freq0);
        final wait = lastBitTime + _bitDurationMs - sw.elapsedMilliseconds;
        if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
        lastBitTime = sw.elapsedMilliseconds;
      }

      await Future.delayed(Duration(milliseconds: _bitDurationMs));
      SoundGenerator.stop();
      _log("✅ Frame delivered.");

    } catch (e) {
      _log("❌ Acoustic TX fault: $e");
    } finally {
      _isTransmitting = false;
      Future.delayed(const Duration(milliseconds: 500), () {
        NativeMeshService.startSonarListening();
      });
    }
  }

  /// Ультразвуковой маяк (presence: «узел рядом»).
  /// Не передаёт данных. При приёме на другой стороне — только намёк на присутствие;
  /// не должен вызывать sendAuto, cascade или relay (см. контракт Sonar).
  Future<void> transmitBeacon() async {
    if (_isTransmitting) return;
    _isTransmitting = true;
    try {
      await _initHardware();
      await NativeMeshService.stopSonarListening();

      _log("🔊 Pulsing stealth beacon...");
      SoundGenerator.setFrequency(_freq1);
      SoundGenerator.play();
      await Future.delayed(const Duration(milliseconds: 800));
      SoundGenerator.stop();
    } finally {
      _isTransmitting = false;
      Future.delayed(const Duration(milliseconds: 300), () {
        NativeMeshService.startSonarListening();
      });
    }
  }

  int _crc8(List<int> data) {
    var crc = 0x00;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) : (crc << 1);
        crc &= 0xFF;
      }
    }
    return crc;
  }

  void handleInboundSignal(String signal) {
    if (signal.trim().isEmpty) return;
    _log("🎯 Captured signal: $signal");
    _sonarController.add(signal);
  }

  void _setupNativeReceiver() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSignalDetected') {
        final msg = call.arguments.toString();
        handleInboundSignal(msg);
      }
    });
  }

  Future<void> startListening() async {
    await _initHardware();
    await autoCalibrateIfNeeded(force: false);
    await NativeMeshService.startSonarListening();
  }

  Future<void> stopListening() async {
    await NativeMeshService.stopSonarListening();
  }

  void stop() {
    SoundGenerator.stop();
    _isTransmitting = false;
  }
}