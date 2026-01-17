package com.example.memento_mori_app

import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pManager
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
import android.media.*
import kotlin.math.PI
import kotlin.math.cos

class MainActivity : FlutterFragmentActivity() {

    // --- Константы каналов ---
    private val CHANNEL_P2P = "memento/p2p"
    private val CHANNEL_WIFI_DIRECT = "memento/wifi_direct"
    private val CHANNEL_SECURITY = "memento/security"
    private val CHANNEL_SONAR = "memento/sonar"
    private val CHANNEL_GOOGLE = "google_play_services"
    private val CHANNEL_ULTRASONIC = "ultrasonic"

    // --- Системные объекты ---
    private var p2pHelper: WifiP2pHelper? = null
    private var wifiManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null

    // --- Flutter MethodChannels ---
    private var p2pMethodChannel: MethodChannel? = null
    private var sonarMethodChannel: MethodChannel? = null
    private var meshMethodChannel: MethodChannel? = null

    private var acousticReceiver: AcousticReceiver? = null

    // Приемник сообщений из фонового сервиса Mesh
    private val messageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val msg = intent.getStringExtra("message")
            val ip = intent.getStringExtra("senderIp")
            runOnUiThread {
                p2pMethodChannel?.invokeMethod(
                    "onMessageReceived",
                    mapOf("message" to msg, "senderIp" to ip)
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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

        // 1. Инициализация системного Wi-Fi P2P менеджера
        val manager = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
        wifiManager = manager
        wifiP2pChannel = manager.initialize(this, mainLooper, null)

        // 2. Создание MethodChannels
        meshMethodChannel = MethodChannel(messenger, CHANNEL_WIFI_DIRECT)
        p2pMethodChannel = MethodChannel(messenger, CHANNEL_P2P)
        val securityChannel = MethodChannel(messenger, CHANNEL_SECURITY)
        val googleChannel = MethodChannel(messenger, CHANNEL_GOOGLE)
        sonarMethodChannel = MethodChannel(messenger, CHANNEL_SONAR)

        // 3. Инициализация хелпера (связываем его с p2pMethodChannel)
        p2pHelper = WifiP2pHelper(this, this, p2pMethodChannel!!)

        // 4. Привязка NativeMeshService к mesh-каналу (решение проблемы stopDiscovery)
        meshMethodChannel?.setMethodCallHandler(NativeMeshService(manager, wifiP2pChannel!!, p2pHelper))

        // 5. Обработчик Акустического приемника (Sonar)
        acousticReceiver = AcousticReceiver { msg ->
            runOnUiThread {
                Log.d("SONAR", "Captured pulse: $msg")
                if (msg.startsWith("LNK:")) {
                    // Сигнал авто-подключения пробрасываем в mesh-канал
                    meshMethodChannel?.invokeMethod("onAutoLinkRequest", msg.substring(4))
                } else {
                    // Обычные данные в канал сонара
                    sonarMethodChannel?.invokeMethod("onSignalDetected", msg)
                }
            }
        }

        // 6. Хендлеры P2P (Wi-Fi Direct)
        p2pMethodChannel?.setMethodCallHandler { call, result ->
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
                "startDiscovery" -> {
                    p2pHelper?.startDiscovery()
                    result.success(true)
                }
                "stopDiscovery" -> {
                    manager.stopPeerDiscovery(wifiP2pChannel!!, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { result.success(true) }
                        override fun onFailure(reason: Int) { result.error("P2P_ERR", "Stop failed", null) }
                    })
                }
                "connect" -> {
                    val addr = call.argument<String>("deviceAddress")
                    if (addr != null) {
                        p2pHelper?.connect(addr)
                        result.success(true)
                    } else result.error("ERR", "No address", null)
                }
                "sendTcp" -> {
                    val host = call.argument<String>("host") ?: "192.168.49.1"
                    val msg = call.argument<String>("message") ?: ""
                    p2pHelper?.sendTcp(host, 55555, msg)
                    result.success(true)
                }
                "forceReset" -> {
                    p2pHelper?.forceReset { result.success(true) }
                }
                else -> result.notImplemented()
            }
        }

        // 7. Хендлеры SONAR (Listening & Sweep)
        sonarMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        acousticReceiver?.start()
                        result.success(true)
                    } else {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 101)
                        result.error("PERM_DENIED", "Mic needed", null)
                    }
                }
                "stopListening" -> {
                    acousticReceiver?.stop()
                    result.success(true)
                }
                "runFrequencySweep" -> {
                    Thread {
                        try {
                            val spectrum = UltrasonicCalibrator.runSweep()
                            runOnUiThread { result.success(spectrum) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("FFT_ERROR", e.message, null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // 8. Хендлеры SECURITY (Защита экрана и Camouflage)
        securityChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureMode" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(true)
                }
                "disableSecureMode" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(true)
                }
                "changeIcon" -> {
                    val target = call.argument<String>("targetIcon")
                    if (target != null) {
                        changeAppIcon(target)
                        result.success(true)
                    } else result.error("ERR", "Null icon", null)
                }
                else -> result.notImplemented()
            }
        }

        // 9. Хендлеры GOOGLE (Play Services)
        googleChannel.setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                val api = GoogleApiAvailability.getInstance()
                result.success(api.isGooglePlayServicesAvailable(this) == ConnectionResult.SUCCESS)
            } else result.notImplemented()
        }
    }

    private fun changeAppIcon(target: String) {
        val pkg = packageName
        val clsCalc = "$pkg.MainActivityCalculator"
        val clsNotes = "$pkg.MainActivityNotes"
        val enable: String
        val disable: String
        if (target == "Notes") {
            enable = clsNotes
            disable = clsCalc
        } else {
            enable = clsCalc
            disable = clsNotes
        }
        try {
            packageManager.setComponentEnabledSetting(
                ComponentName(pkg, disable),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, 0
            )
            packageManager.setComponentEnabledSetting(
                ComponentName(pkg, enable),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED, 0
            )
        } catch (e: Exception) {
            Log.e("ICON", "Failed to change icon: ${e.message}")
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(messageReceiver) } catch (e: Exception) { }
        acousticReceiver?.stop()
        super.onDestroy()
    }
}

// -----------------------------------------------------------------------------
// 🔊 Acoustic Receiver + Goertzel (Твоя оригинальная логика)
// -----------------------------------------------------------------------------
class AcousticReceiver(private val onSignalDetected: (String) -> Unit) {
    private val sampleRate = 44100
    private val freq0 = 17800.0
    private val freq1 = 18300.0
    private val bitDurationMs = 120L
    private val windowSize = 1024

    private var audioRecord: AudioRecord? = null
    @Volatile private var isListening = false

    private val PREAMBLE_BYTE = 0xAC
    private val syncBuffer = mutableListOf<Int>()
    private val bitBuffer = mutableListOf<Int>()
    private val byteBuffer = mutableListOf<Int>()
    private var synced = false
    private var expectedLen = -1
    private var lastBitTime = 0L

    fun start() {
        if (isListening) return
        val bufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(windowSize)

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )
        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) return
        audioRecord?.startRecording()
        isListening = true

        Thread {
            val buffer = ShortArray(windowSize)
            var nFloor0 = 1.0
            var nFloor1 = 1.0

            while (isListening) {
                val read = audioRecord?.read(buffer, 0, windowSize) ?: -1
                if (read <= 0) continue

                val mag0 = goertzel(buffer, freq0)
                val mag1 = goertzel(buffer, freq1)

                nFloor0 = nFloor0 * 0.99 + mag0 * 0.01
                nFloor1 = nFloor1 * 0.99 + mag1 * 0.01

                val now = System.currentTimeMillis()
                if (now - lastBitTime > (bitDurationMs * 0.8)) {
                    val bit = when {
                        mag1 > nFloor1 * 4 && mag1 > mag0 * 1.5 -> 1
                        mag0 > nFloor0 * 4 && mag0 > mag1 * 1.5 -> 0
                        else -> null
                    }
                    if (bit != null) { lastBitTime = now; processBit(bit) }
                }
            }
        }.start()
    }

    private fun processBit(bit: Int) {
        if (!synced) {
            syncBuffer.add(bit)
            if (syncBuffer.size > 8) syncBuffer.removeAt(0)
            if (syncBuffer.fold(0) { acc, b -> (acc shl 1) or b } == PREAMBLE_BYTE) {
                synced = true
                bitBuffer.clear()
                byteBuffer.clear()
                expectedLen = -1
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
            return
        }

        if (byteBuffer.size == expectedLen + 1) {
            val data = byteBuffer.dropLast(1)
            if (crc8(data) == byteBuffer.last()) {
                onSignalDetected(data.map { it.toChar() }.joinToString(""))
            }
            synced = false
            syncBuffer.clear()
        }
    }

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

    fun stop() {
        isListening = false
        audioRecord?.let { if (it.state == AudioRecord.STATE_INITIALIZED) { it.stop(); it.release() } }
        audioRecord = null
    }

    private fun goertzel(samples: ShortArray, freq: Double): Double {
        val n = samples.size
        val k = (0.5 + (n * freq / sampleRate)).toInt()
        val w = 2.0 * PI * k / n
        val coeff = 2.0 * cos(w)
        var q0 = 0.0
        var q1 = 0.0
        var q2 = 0.0
        for (s in samples) {
            q0 = coeff * q1 - q2 + s.toDouble()
            q2 = q1
            q1 = q0
        }
        return q1 * q1 + q2 * q2 - coeff * q1 * q2
    }
}