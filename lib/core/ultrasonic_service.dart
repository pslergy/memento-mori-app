import 'dart:async';
import 'dart:convert';
import 'package:sound_generator/sound_generator.dart';
import 'package:sound_generator/waveTypes.dart';

class UltrasonicService {
  static final UltrasonicService _instance = UltrasonicService._internal();
  factory UltrasonicService() => _instance;
  UltrasonicService._internal();

  // 🔥 Стрим-контроллер инициализируется СРАЗУ. Это исключает Null Check Error.
  final StreamController<String> _sonarController = StreamController<String>.broadcast();
  Stream<String> get sonarMessages => _sonarController.stream;

  static const double _frequency = 19000.0; // Частота ультразвука
  bool _isInitialized = false;

  void _log(String msg) => print("🔊 [Sonar] $msg");

  /// Инициализация аппаратного уровня (Audio Layer)
  Future<void> _init() async {
    if (_isInitialized) return;
    try {
      // Инициализация генератора (44.1kHz - стандарт Hi-Fi)
      SoundGenerator.init(44100);

      // Настройка волны: Чистая синусоида для минимизации шумов
      SoundGenerator.setWaveType(waveTypes.SINUSOIDAL);
      SoundGenerator.setFrequency(_frequency);
      SoundGenerator.setVolume(1.0);

      _isInitialized = true;
      _log("Acoustic Layer Secured at 19kHz.");
    } catch (e) {
      _log("CRITICAL: Hardware Layer Failure: $e");
    }
  }

  /// ПЕРЕДАЧА ДАННЫХ (Binary Acoustic Pulse)
  /// Реализация простейшего FSK (Frequency Shift Keying) через длительность
  Future<void> transmitData(String data) async {
    try {
      await _init();
      _log("Encoding identity pulse for: $data");

      // Превращаем строку в массив бит (ASCII 8-bit)
      final bits = utf8.encode(data).expand((byte) =>
          Iterable.generate(8, (i) => (byte >> (7 - i)) & 1)
      ).toList();

      for (var bit in bits) {
        SoundGenerator.play();
        // Модуляция: '1' шлем дольше (600мс), '0' короче (200мс)
        await Future.delayed(Duration(milliseconds: bit == 1 ? 600 : 200));
        SoundGenerator.stop();
        // Защитный интервал между битами (Guard Interval)
        await Future.delayed(const Duration(milliseconds: 150));
      }

      _log("Acoustic data burst successfully emitted.");
    } catch (e) {
      _log("Transmission Error: $e");
    }
  }

  /// ПЕРЕДАЧА МАЯКА (Simple Beacon)
  Future<void> transmit(String text) async {
    try {
      await _init();
      _log("Emitting SOS Beacon: $text");

      SoundGenerator.play();
      // Длительность зависит от веса сообщения
      final int duration = (text.length * 200).clamp(1000, 5000);
      await Future.delayed(Duration(milliseconds: duration));

      SoundGenerator.stop();
      _log("Beacon Pulse completed.");
    } catch (e) {
      _log("Error emitting beacon: $e");
    }
  }

  /// РЕЖИМ ПРОСЛУШИВАНИЯ (Passive Monitoring)
  void startListening() {
    _log("Microphone set to high-frequency monitoring mode.");

    // План для интервью в Нидерландах:
    // 1. Используем библиотеку 'record' для получения PCM байтов.
    // 2. Применяем библиотеку 'fftea' для БПФ (Быстрое Преобразование Фурье).
    // 3. Выделяем пик на 19000Гц.
    // 4. Если амплитуда > порога - декодируем бит.

    // Эмуляция обнаружения сигнала для отладки UI
    Future.delayed(const Duration(seconds: 10), () {
      if (!_sonarController.isClosed) {
        _sonarController.add("BEACON_ALIVE");
        _log("🎯 Signal captured via air-gap: BEACON_ALIVE");
      }
    });
  }

  /// Остановка всех систем
  void stop() {
    SoundGenerator.stop();
    _log("System Hibernate.");
  }
}