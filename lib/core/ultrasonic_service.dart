import 'dart:async';
import 'dart:convert';
import 'package:sound_generator/sound_generator.dart';
import 'package:sound_generator/waveTypes.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'native_mesh_service.dart';

class UltrasonicService {
  // ---------------- SINGLETON ----------------
  static final UltrasonicService _instance = UltrasonicService._internal();
  factory UltrasonicService() => _instance;
  UltrasonicService._internal();

  // ---------------- STREAM (RX) ----------------
  final StreamController<String> _sonarController =
  StreamController<String>.broadcast();
  Stream<String> get sonarMessages => _sonarController.stream;

  // ---------------- FSK CONFIG ----------------
  static const double _freq0 = 17800.0; // Частота для бита 0
  static const double _freq1 = 18300.0; // Частота для бита 1
  static const int _bitDurationMs = 200; // Длительность бита (согласовано с Kotlin)
  static const int _preambleByte = 0xAC; // 10101100

  bool _isInitialized = false;
  bool _isTransmitting = false;

  // ---------------- LOG ----------------
  void _log(String msg) => print("🔊 [Sonar] $msg");

  // ---------------- INIT ----------------
  Future<void> _init() async {
    if (_isInitialized) return;
    // Инициализация генератора звука (44.1 кГц)
    SoundGenerator.init(44100);
    SoundGenerator.setWaveType(waveTypes.SINUSOIDAL);
    SoundGenerator.setVolume(1.0);
    _isInitialized = true;
    _log("Acoustic FSK layer secured.");
  }

  // ============================================================
  // 🔥 FRAME PROTOCOL L2 (TX)
  // ============================================================

  /// Вычисление контрольной суммы CRC-8 (полином 0x07)
  int crc8(List<int> data) {
    int crc = 0x00;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) : (crc << 1);
        crc &= 0xFF;
      }
    }
    return crc;
  }

  /// Сборка фрейма: [PREAMBLE] [LEN] [DATA] [CRC]
  List<int> _buildFrameBits(String payload) {
    final dataBytes = utf8.encode(payload);
    final len = dataBytes.length;
    final crc = crc8(dataBytes);

    // Собираем байты кадра
    final frameBytes = <int>[_preambleByte, len, ...dataBytes, crc];

    // Разворачиваем байты в битовый поток (MSB first)
    return frameBytes.expand(
          (b) => List.generate(8, (i) => (b >> (7 - i)) & 1),
    ).toList();
  }

  /// Передача защищенного фрейма через звук
  Future<void> transmitFrame(String payload) async {
    if (_isTransmitting) return;
    _isTransmitting = true;

    try {
      await _init();
      final mesh = locator<MeshService>();
      final bits = _buildFrameBits(payload);

      mesh.logSonarEvent("TX FRAME: \"$payload\" (${bits.length} bits)");

      // 1. Включаем несущую частоту
      SoundGenerator.play();

      // 2. Передаем биты методом FSK
      for (final bit in bits) {
        SoundGenerator.setFrequency(bit == 1 ? _freq1 : _freq0);
        await Future.delayed(const Duration(milliseconds: _bitDurationMs));
      }

      // 3. Выключаем звук
      SoundGenerator.stop();
      mesh.logSonarEvent("✅ Frame transmitted via air-gap.");

    } catch (e) {
      locator<MeshService>().logSonarEvent("TX failed: $e", isError: true);
    } finally {
      _isTransmitting = false;
    }
  }

  // ============================================================
  // 🔊 LEGACY & UTILS
  // ============================================================

  /// Облегченная версия отправки (для обратной совместимости)
  Future<void> transmitData(String data) async => await transmitFrame(data);

  /// Отправка одиночного маяка (Discovery)
  Future<void> transmitBeacon() async {
    await _init();
    if (_isTransmitting) return;
    _log("Emitting SOS beacon pulse...");
    SoundGenerator.setFrequency(_freq1);
    SoundGenerator.play();
    await Future.delayed(const Duration(milliseconds: 1000));
    SoundGenerator.stop();
  }

  // ============================================================
  // 🔊 RX INTEGRATION (СВЯЗЬ С KOTLIN)
  // ============================================================

  /// Метод вызывается из NativeMeshService при успешной валидации CRC в Kotlin
  void handleInboundSignal(String signal) {
    if (!_sonarController.isClosed) {
      _sonarController.add(signal);
      _log("🎯 [RX-VALID] Captured message: $signal");
    }
  }

  Future<void> startListening() async {
    _log("Activating acoustic monitoring...");
    await NativeMeshService.startSonarListening();
  }

  Future<void> stopListening() async {
    await NativeMeshService.stopSonarListening();
    _log("Monitoring halted.");
  }

  void stop() {
    SoundGenerator.stop();
    _isTransmitting = false;
    _log("Acoustic emergency stop triggered.");
  }
}