package com.example.memento_mori_app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.nio.charset.StandardCharsets
import kotlin.math.PI
import kotlin.math.cos

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL_P2P = "memento/wifi_direct"
    private val CHANNEL_SECURITY = "memento/security"
    private val CHANNEL_SONAR = "memento/sonar"
    private val CHANNEL_GOOGLE = "google_play_services"

    private var p2pHelper: WifiP2pHelper? = null
    private var p2pChannel: MethodChannel? = null
    private var sonarChannel: MethodChannel? = null
    private var acousticReceiver: AcousticReceiver? = null

    // ПРИЕМНИК ИЗ BACKGROUND SERVICE (Mesh-сообщения)
    private val messageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val msg = intent.getStringExtra("message")
            val ip = intent.getStringExtra("senderIp")
            runOnUiThread {
                p2pChannel?.invokeMethod("onMessageReceived", mapOf("message" to msg, "senderIp" to ip))
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Регистрация системной шины для связи с фоновым сервисом
        val filter = IntentFilter("com.example.memento_mori_app.MESSAGE_RECEIVED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(messageReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(messageReceiver, filter)
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 1. ИНИЦИАЛИЗАЦИЯ КАНАЛОВ
        p2pChannel = MethodChannel(messenger, CHANNEL_P2P)
        sonarChannel = MethodChannel(messenger, CHANNEL_SONAR)
        val securityChannel = MethodChannel(messenger, CHANNEL_SECURITY)
        val googleChannel = MethodChannel(messenger, CHANNEL_GOOGLE)

        // 2. ПОДГОТОВКА ХЕЛПЕРОВ
        p2pHelper = WifiP2pHelper(this, this, p2pChannel!!)
        acousticReceiver = AcousticReceiver { msg ->
            // Этот код выполняется в фоновом потоке сонара,
            // поэтому переходим в UI-поток для работы с MethodChannel
            runOnUiThread {
                Log.d("SONAR", "Captured pulse: $msg")

                if (msg.startsWith("LNK:")) {
                    // 🔥 ТАКТИЧЕСКИЙ МАЯК (Auto-Link)
                    val targetId = msg.substring(4)
                    Log.d("SONAR", "🚨 Auto-Link Request from: $targetId")

                    // Вызываем специальный метод во Flutter
                    sonarChannel?.invokeMethod("onAutoLinkRequest", targetId)
                } else {
                    // Обычное сообщение
                    sonarChannel?.invokeMethod("onSignalDetected", msg)
                }
            }
        }

        // 3. ОБРАБОТКА P2P МЕТОДОВ
        p2pChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMeshService" -> {
                    val intent = Intent(this, MeshBackgroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                    else startService(intent)
                    result.success(true)
                }
                "stopMeshService" -> {
                    stopService(Intent(this, MeshBackgroundService::class.java))
                    result.success(true)
                }
                "forceReset" -> p2pHelper?.forceReset { result.success(true) }
                "startDiscovery" -> { p2pHelper?.startDiscovery(); result.success(true) }
                "connect" -> {
                    val addr = call.argument<String>("deviceAddress")
                    if (addr != null) { p2pHelper?.connect(addr); result.success(true) }
                    else result.error("ERR", "No address", null)
                }
                "sendTcp" -> {
                    val host = call.argument<String>("host") ?: "192.168.49.1"
                    val msg = call.argument<String>("message") ?: ""
                    p2pHelper?.sendTcp(host, 55555, msg)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 4. ОБРАБОТКА SONAR МЕТОДОВ
        sonarChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        acousticReceiver?.start()
                        result.success(true)
                    } else {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 101)
                        result.error("PERM_DENIED", "Mic permission needed", null)
                    }
                }
                "stopListening" -> {
                    acousticReceiver?.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 5. БЕЗОПАСНОСТЬ (SECURE MODE + APP ICON)
        securityChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureMode" -> { window.addFlags(WindowManager.LayoutParams.FLAG_SECURE); result.success(true) }
                "disableSecureMode" -> { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE); result.success(true) }
                "changeIcon" -> {
                    val target = call.argument<String>("targetIcon")
                    if (target != null) { changeAppIcon(target); result.success(true) }
                    else result.error("ERR", "Null icon", null)
                }
                else -> result.notImplemented()
            }
        }

        // 6. GOOGLE SERVICES CHECK
        googleChannel.setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                val api = GoogleApiAvailability.getInstance()
                val status = api.isGooglePlayServicesAvailable(this)
                result.success(status == ConnectionResult.SUCCESS)
            } else result.notImplemented()
        }
    }

    private fun changeAppIcon(target: String) {
        val pkg = packageName
        val clsCalc = "$pkg.MainActivityCalculator"
        val clsNotes = "$pkg.MainActivityNotes"
        val pm = packageManager
        val (enable, disable) = if (target == "Notes") clsNotes to clsCalc else clsCalc to clsNotes
        try {
            pm.setComponentEnabledSetting(ComponentName(pkg, disable), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, 0)
            pm.setComponentEnabledSetting(ComponentName(pkg, enable), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, 0)
        } catch (e: Exception) { Log.e("STEALTH", "Error: ${e.message}") }
    }

    override fun onResume() { super.onResume(); p2pHelper?.registerReceiver() }

    override fun onDestroy() {
        try { unregisterReceiver(messageReceiver) } catch (e: Exception) {}
        acousticReceiver?.stop()
        p2pHelper?.unregisterReceiver()
        super.onDestroy()
    }
}

// -----------------------------------------------------------------------------
// 🔥 ACOUSTIC MODEM ENGINE (BFSK + CRC-8 + FRAME SYNC)
// -----------------------------------------------------------------------------

class AcousticReceiver(private val onSignalDetected: (String) -> Unit) {
    private val sampleRate = 44100
    private val freq0 = 17800.0
    private val freq1 = 18300.0
    private val bitDurationMs = 200L
    private val windowSize = 1024

    @Volatile private var isListening = false

    private val PREAMBLE = listOf(1,0,1,0,1,1,0,0) // 0xAC
    private val syncBuffer = mutableListOf<Int>()
    private val bitBuffer = mutableListOf<Int>()
    private val byteBuffer = mutableListOf<Int>()
    private var synced = false
    private var expectedLen = -1
    private var lastBitTime = 0L

    fun start() {
        if (isListening) return
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(windowSize)
        val audioRecord = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
        } catch (e: Exception) { return }

        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) return
        audioRecord.startRecording()
        isListening = true

        Thread {
            val buffer = ShortArray(windowSize)
            var noiseFloor0 = 1.0
            var noiseFloor1 = 1.0

            while (isListening) {
                val read = audioRecord.read(buffer, 0, windowSize)
                if (read <= 0) continue

                val mag0 = goertzel(buffer, freq0)
                val mag1 = goertzel(buffer, freq1)

                noiseFloor0 = noiseFloor0 * 0.99 + mag0 * 0.01
                noiseFloor1 = noiseFloor1 * 0.99 + mag1 * 0.01

                val currentTime = System.currentTimeMillis()

                if (currentTime - lastBitTime > (bitDurationMs * 0.8)) {
                    val bit = when {
                        mag1 > noiseFloor1 * 5 && mag1 > mag0 * 2 -> 1
                        mag0 > noiseFloor0 * 5 && mag0 > mag1 * 2 -> 0
                        else -> null
                    }

                    if (bit != null) {
                        lastBitTime = currentTime
                        processBit(bit)
                    }
                }
            }
            try { audioRecord.stop(); audioRecord.release() } catch (e: Exception) {}
        }.start()
    }

    private fun processBit(bit: Int) {
        if (!synced) {
            syncBuffer.add(bit)
            if (syncBuffer.size > PREAMBLE.size) syncBuffer.removeAt(0)
            if (syncBuffer == PREAMBLE) {
                synced = true
                bitBuffer.clear()
                byteBuffer.clear()
                expectedLen = -1
                Log.d("SONAR", "🎯 FRAME SYNC ACQUIRED")
            }
            return
        }

        bitBuffer.add(bit)
        if (bitBuffer.size < 8) return

        val byte = bitBuffer.fold(0) { acc, b -> (acc shl 1) or b }
        bitBuffer.clear()
        byteBuffer.add(byte)

        if (expectedLen == -1) {
            expectedLen = byte
            Log.d("SONAR", "📦 Payload Len: $expectedLen bytes")
            return
        }

        if (byteBuffer.size == expectedLen + 2) {
            val data = byteBuffer.dropLast(1)
            val crcRx = byteBuffer.last()
            val crcCalc = crc8(data)

            if (crcRx == crcCalc) {
                val msg = data.map { it.toChar() }.joinToString("")

                // 🔥 НОВАЯ ЛОГИКА: Если поймали префикс LNK (Link)
                if (crcRx == crcCalc) {
                    val msg = data.map { it.toChar() }.joinToString("")
                    onSignalDetected(msg) // Просто отдаем строку наверх
                    Log.d("SONAR", "✅ VALID FRAME: $msg")
                }

            synced = false
            syncBuffer.clear()
        }
    }}

    private fun crc8(data: List<Int>): Int {
        var crc = 0x00
        for (b in data) {
            crc = crc xor b
            repeat(8) {
                crc = if ((crc and 0x80) != 0) ((crc shl 1) xor 0x07) else (crc shl 1)
                crc = crc and 0xFF
            }
        }
        return crc
    }

    fun stop() { isListening = false }

    private fun goertzel(samples: ShortArray, freq: Double): Double {
        val n = samples.size
        val k = (0.5 + (n * freq / sampleRate)).toInt()
        val w = 2.0 * Math.PI * k / n
        val cosine = Math.cos(w)
        val coeff = 2.0 * cosine
        var q0 = 0.0; var q1 = 0.0; var q2 = 0.0
        for (s in samples) {
            q0 = coeff * q1 - q2 + s.toDouble()
            q2 = q1; q1 = q0
        }
        return q1 * q1 + q2 * q2 - coeff * q1 * q2
    }
}