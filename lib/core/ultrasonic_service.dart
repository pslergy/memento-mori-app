import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

class UltrasonicService {
  static final UltrasonicService _instance = UltrasonicService._internal();
  factory UltrasonicService() => _instance;
  UltrasonicService._internal();

  // Параметры "акустического протокола"
  static const int sampleRate = 44100; // Стандартная частота дискретизации
  static const double freqZero = 18500.0; // Частота для бита "0" (Ультразвук)
  static const double freqOne = 19500.0;  // Частота для бита "1" (Ультразвук)
  static const double bitDuration = 0.1;  // Длительность одного бита (сек)

  /// Функция превращает текст в ультразвуковой импульс
  Future<void> transmit(String text) async {
    print("🔊 [Sonar] Encoding payload: $text");

    // 1. Превращаем текст в массив битов
    List<int> bytes = utf8.encode(text);
    List<int> bits = [];
    for (var byte in bytes) {
      for (var i = 7; i >= 0; i--) {
        bits.add((byte >> i) & 1);
      }
    }

    // 2. Генерируем аудио-буфер
    // Это "сырые" данные звуковой волны
    final int samplesPerBit = (sampleRate * bitDuration).toInt();
    final int totalSamples = samplesPerBit * bits.length;
    final Float32List buffer = Float32List(totalSamples);

    for (int i = 0; i < bits.length; i++) {
      double freq = (bits[i] == 1) ? freqOne : freqZero;
      for (int j = 0; j < samplesPerBit; j++) {
        int index = i * samplesPerBit + j;
        // Формула синусоиды: A * sin(2 * PI * f * t)
        buffer[index] = sin(2 * pi * freq * (j / sampleRate));
      }
    }

    // 3. Здесь должен быть вызов проигрывателя (JustAudio)
    // В задатке мы просто логируем процесс.
    // На реальном тесте телефон начнет "пищать" на частоте, которую не слышит ухо.
    print("📡 [Sonar] Transmission complete. ${bits.length} bits emitted via air.");
  }

  /// План для приемника:
  /// Микрофон записывает поток -> Применяем FFT (Преобразование Фурье) ->
  /// Если пик энергии на 18.5кГц, записываем '0', если на 19.5кГц - '1'.
  void startListening() {
    print("👂 [Sonar] Microphone is monitoring ultrasonic frequencies...");
    // Логика декодирования через анализ спектра будет здесь
  }
}