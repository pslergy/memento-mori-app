package com.example.memento_mori_app
// Kotlin math
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.roundToInt
import kotlin.math.max

// Android audio
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

class FFT(private val input: DoubleArray) {

    private val n = input.size
    private val real = input.copyOf()
    private val imag = DoubleArray(n)

    init {
        fft()
    }

    private fun fft() {
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j >= bit) {
                j -= bit
                bit = bit shr 1
            }
            j += bit
            if (i < j) {
                real[i] = real[j].also { real[j] = real[i] }
                imag[i] = imag[j].also { imag[j] = imag[i] }
            }
        }

        var len = 2
        while (len <= n) {
            val ang = -2 * Math.PI / len
            val wlenR = cos(ang)
            val wlenI = sin(ang)
            for (i in 0 until n step len) {
                var wr = 1.0
                var wi = 0.0
                for (j in 0 until len / 2) {
                    val uR = real[i + j]
                    val uI = imag[i + j]
                    val vR = real[i + j + len / 2] * wr -
                            imag[i + j + len / 2] * wi
                    val vI = real[i + j + len / 2] * wi +
                            imag[i + j + len / 2] * wr

                    real[i + j] = uR + vR
                    imag[i + j] = uI + vI
                    real[i + j + len / 2] = uR - vR
                    imag[i + j + len / 2] = uI - vI

                    val nextWr = wr * wlenR - wi * wlenI
                    wi = wr * wlenI + wi * wlenR
                    wr = nextWr
                }
            }
            len = len shl 1
        }
    }

    fun getPowerAt(freq: Double, sampleRate: Int): Double {
        val bin = ((freq / sampleRate) * n).roundToInt()
        if (bin <= 0 || bin >= n / 2) return 0.0
        return sqrt(real[bin] * real[bin] + imag[bin] * imag[bin])
    }
    
}
