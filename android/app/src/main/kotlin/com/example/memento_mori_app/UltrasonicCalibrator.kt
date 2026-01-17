package com.example.memento_mori_app

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlin.math.*

object UltrasonicCalibrator {

    private const val SAMPLE_RATE = 44100
    private const val FFT_SIZE = 4096

    private const val START_FREQ = 17000.0
    private const val END_FREQ = 19500.0
    private const val STEP = 100.0

    fun runSweep(): Map<String, Double> {
        // 🔥 Очистка перед стартом
        System.gc()
        Thread.sleep(100)

        val recorder = try {
            createRecorder()
        } catch (e: Exception) {
            // Если совсем всё плохо — бросаем ошибку, Flutter её поймает и уйдет в fallback
            throw Exception("HAL_LOCKED")
        }

        val buffer = ShortArray(FFT_SIZE)
        val spectrum = mutableMapOf<String, Double>()

        try {
            recorder.startRecording()
            // Даем AGC время на адаптацию к фоновому шуму
            Thread.sleep(500)

            recorder.read(buffer, 0, FFT_SIZE)
            recorder.stop()
            recorder.release()

            val windowed = DoubleArray(FFT_SIZE) { i ->
                val w = 0.5 * (1 - cos(2.0 * PI * i / (FFT_SIZE - 1)))
                buffer[i] * w
            }

            val fft = FFT(windowed)
            var f = START_FREQ
            while (f <= END_FREQ) {
                spectrum[f.toInt().toString()] = fft.getPowerAt(f, SAMPLE_RATE)
                f += STEP
            }
            return spectrum
        } catch (e: Exception) {
            try { recorder.release() } catch (ex: Exception) {}
            throw e
        }
    }

    private fun createRecorder(): AudioRecord {
        // 🔥 Пробуем две самые популярные частоты
        val sampleRates = intArrayOf(44100, 48000)
        val sources = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,// Оптимально для FFT
            MediaRecorder.AudioSource.VOICE_COMMUNICATION, // Обходит VoIP блокировки
            MediaRecorder.AudioSource.UNPROCESSED,

        )

        for (rate in sampleRates) {
            for (source in sources) {
                try {
                    val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                    if (minBuf == AudioRecord.ERROR_BAD_VALUE) continue

                    val recorder = AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(minBuf, 4096 * 2))

                    if (recorder.state == AudioRecord.STATE_INITIALIZED) {
                        Log.d("SONAR", "✅ SECURED: Source=$source, Rate=$rate")
                        return recorder
                    }
                    recorder.release()
                } catch (e: Exception) { continue }
            }
        }
        throw Exception("HARDWARE_LOCKED: AudioFlinger refused all configurations. Check if another app is using MIC.")
    }

    private fun applyHann(input: ShortArray): DoubleArray {
        val out = DoubleArray(input.size)
        val n = input.size
        for (i in 0 until n) {
            // Окно Хэнна снижает спектральные утечки (Spectral Leakage)
            val w = 0.5 * (1 - cos(2.0 * PI * i / (n - 1)))
            out[i] = input[i] * w
        }
        return out
    }
}