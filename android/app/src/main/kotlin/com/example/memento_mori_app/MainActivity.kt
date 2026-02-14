package com.example.memento_mori_app

import android.Manifest
import android.app.*
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.*
import android.provider.Settings
import android.content.pm.PackageManager
import android.media.*
import android.net.wifi.p2p.WifiP2pManager
import android.os.*
import android.util.Log
import android.view.WindowManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.*
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.*
import android.media.AudioManager

private const val MAX_EVENTS = 120

class MainActivity : FlutterFragmentActivity() {

    // --- Константы каналов ---
    private val CHANNEL_P2P = "memento/p2p"
    private val CHANNEL_WIFI_DIRECT = "memento/wifi_direct"
    private val CHANNEL_SECURITY = "memento/security"
    private val CHANNEL_SONAR = "memento/sonar"
    private val CHANNEL_GOOGLE = "google_play_services"
    private val CHANNEL_HARDWARE_GUARD = "memento/hardware_guard"
    private val CHANNEL_ROUTER = "memento/router"

    // --- Системные объекты ---
    private var p2pHelper: WifiP2pHelper? = null
    private var wifiManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null
    private var acousticReceiver: AcousticReceiver? = null
    private lateinit var hardwareGuardChannel: MethodChannel
    private var p2pMethodChannel: MethodChannel? = null
    private var meshMethodChannel: MethodChannel? = null
    private var sonarMethodChannel: MethodChannel? = null
    private var routerMethodChannel: MethodChannel? = null
    private var routerHelper: RouterHelper? = null
    private var gattServerHelper: GattServerHelper? = null
    private var gattMethodChannel: MethodChannel? = null
    
    // 🔥 Native BLE Advertiser для Huawei/Honor
    private var nativeBleAdvertiser: NativeBleAdvertiser? = null
    private var nativeAdvMethodChannel: MethodChannel? = null

    // --- Состояние микрофона и аналитика ---
    private var micMutex: AudioRecord? = null
    private var audioCallback: AudioManager.AudioRecordingCallback? = null
    private val timeline = CopyOnWriteArrayList<MicEvent>()
    private var lastScore = 0.0
    private var lastPattern = MicPattern.NORMAL

    // --- Внутренние модели для форензики ---
    enum class MicType { CALL, VOIP, RECORDER, UNKNOWN }
    enum class MicPattern { NORMAL, VOIP_CALL, BACKGROUND_REC, SPY_RECORDING }
    data class MicEvent(val ts: Long, val type: MicType, val hidden: Boolean)

    // Приемник сообщений из Mesh-сервиса
    // WIFI_DIRECT_AUDIT: TCP-приём должен идти на memento/wifi_direct, т.к. Dart слушает только там
    private val messageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val msg = intent.getStringExtra("message")
            val ip = intent.getStringExtra("senderIp")
            runOnUiThread {
                meshMethodChannel?.invokeMethod("onMessageReceived", mapOf("message" to msg, "senderIp" to ip))
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
        
        // 🔥 ПРОВЕРКА AUTOSTART ДЛЯ КИТАЙСКИХ УСТРОЙСТВ (Xiaomi/Poco)
        checkAutostartIfNeeded()
    }
    
    /**
     * Проверяет и показывает диалог Autostart, если требуется
     */
    private fun checkAutostartIfNeeded() {
        if (!AutostartHelper.requiresAutostartCheck()) {
            return
        }
        
        // Проверяем, показывали ли уже диалог (можно использовать SharedPreferences)
        val prefs = getSharedPreferences("memento_prefs", Context.MODE_PRIVATE)
        val autostartDialogShown = prefs.getBoolean("autostart_dialog_shown", false)
        
        if (!autostartDialogShown) {
            // Показываем диалог только один раз
            runOnUiThread {
                AutostartHelper.showAutostartDialog(this) {
                    AutostartHelper.openAutostartSettings(this)
                    prefs.edit().putBoolean("autostart_dialog_shown", true).apply()
                }
            }
        }
    }

    override fun configureFlutterEngine(@NonNull engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger

        // 1. Инициализация менеджера P2P
        val manager = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
        wifiManager = manager
        wifiP2pChannel = manager.initialize(this, mainLooper, null)

        // 2. Инициализация всех Method Channels
        meshMethodChannel = MethodChannel(messenger, CHANNEL_WIFI_DIRECT)
        p2pMethodChannel = MethodChannel(messenger, CHANNEL_P2P)
        sonarMethodChannel = MethodChannel(messenger, "memento/sonar")
        hardwareGuardChannel = MethodChannel(messenger, CHANNEL_HARDWARE_GUARD)
        routerMethodChannel = MethodChannel(messenger, CHANNEL_ROUTER)
        gattMethodChannel = MethodChannel(messenger, "memento/gatt_server")
        val securityChannel = MethodChannel(messenger, CHANNEL_SECURITY)
        val googleChannel = MethodChannel(messenger, CHANNEL_GOOGLE)

        // Инициализация RouterHelper
        routerHelper = RouterHelper(this)

        // Инициализация GATT Server Helper
        gattServerHelper = GattServerHelper(this, gattMethodChannel)

        // 3. Привязка нативного сервиса Mesh к каналу Wi-Fi Direct
        // WIFI_DIRECT_AUDIT: P2P-колбэки (onConnected, onPeersFound, onGroupCreated и т.д.) должны идти на memento/wifi_direct
        p2pHelper = WifiP2pHelper(this, this, meshMethodChannel!!)
        // 🔥 КРИТИЧНО: Регистрируем receiver для обработки Wi-Fi Direct событий
        p2pHelper?.registerReceiver()
        val nativeMeshService = NativeMeshService(this, manager, wifiP2pChannel!!, p2pHelper)
        nativeMeshService.setGattServerHelper(gattServerHelper)
        meshMethodChannel?.setMethodCallHandler(nativeMeshService)
        
        // GATT Server Method Channel
        gattMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startGattServer" -> {
                    val success = gattServerHelper?.startGattServer() ?: false
                    val gen = gattServerHelper?.getGattServerGeneration() ?: 0
                    result.success(mapOf("success" to success, "generation" to gen))
                }
                "stopGattServer" -> {
                    gattServerHelper?.stopGattServer()
                    result.success(true)
                }
                "isGattServerRunning" -> {
                    val isRunning = gattServerHelper?.isRunning() ?: false
                    result.success(isRunning)
                }
                "getConnectedDevicesCount" -> {
                    val count = gattServerHelper?.getConnectedDevicesCount() ?: 0
                    result.success(count)
                }
                "getGattServerStatus" -> {
                    // 🔥 DIAGNOSTIC: Get detailed GATT server status
                    val status = gattServerHelper?.getDetailedStatus() ?: mapOf(
                        "isRunning" to false,
                        "error" to "gattServerHelper is null"
                    )
                    gattServerHelper?.logStatus() // Also log to Android logcat
                    result.success(status)
                }
                "sendAppAck" -> {
                    // 🔥 APP-LEVEL ACK: Отправляем подтверждение обработки сообщения на GHOST
                    val deviceAddress = call.argument<String>("deviceAddress") ?: ""
                    val messageId = call.argument<String>("messageId") ?: ""
                    val timestamp = call.argument<Long>("timestamp") ?: System.currentTimeMillis()
                    
                    Log.d("GATT_SERVER", "📤 [ACK] Sending app-level ACK to $deviceAddress for message $messageId")
                    
                    // Отправляем ACK через GATT notify (если устройство ещё подключено)
                    val success = gattServerHelper?.sendAppAck(deviceAddress, messageId, timestamp) ?: false
                    result.success(success)
                }
                "sendMessageToClient" -> {
                    // 🔥 SEND MESSAGE: Отправляем сообщение подключенному GATT клиенту
                    val deviceAddress = call.argument<String>("deviceAddress") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    
                    Log.d("GATT_SERVER", "📤 [MESSAGE] Sending message to client: $deviceAddress")
                    Log.d("GATT_SERVER", "   📋 Message length: ${message.length} bytes")
                    
                    val success = gattServerHelper?.sendMessageToClient(deviceAddress, message) ?: false
                    result.success(success)
                }
                "getLocalBluetoothAddress" -> {
                    // Tie-breaker: lower MAC = PERIPHERAL, higher MAC = CENTRAL
                    // Android 10+ may return "02:00:00:00:00:00" (masked MAC) — use stable ID fallback
                    try {
                        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                        val adapter: BluetoothAdapter? = manager?.adapter
                        var address = adapter?.address?.trim() ?: ""
                        if (address.isEmpty() || address.equals("02:00:00:00:00:00", ignoreCase = true)) {
                            val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
                            address = if (androidId.isNotEmpty()) "S:$androidId" else ""
                        }
                        result.success(if (address.isNotEmpty()) address else null)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        // 🔥 Native BLE Advertiser для Huawei/Honor
        nativeAdvMethodChannel = MethodChannel(messenger, "memento/native_ble_advertiser")
        nativeBleAdvertiser = NativeBleAdvertiser(this, nativeAdvMethodChannel)
        
        // 🔒 SECURITY FIX #4: Pass GattServerHelper to NativeBleAdvertiser
        // This allows advertiser to check for connected GATT clients before cycling strategies
        nativeBleAdvertiser?.setGattServerHelper(gattServerHelper)
        
        nativeAdvMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertising" -> {
                    val localName = call.argument<String>("localName") ?: ""
                    val manufacturerData = call.argument<ByteArray>("manufacturerData") ?: byteArrayOf()
                    val singleStrategyOnly = call.argument<Boolean>("singleStrategyOnly") ?: false
                    val success = nativeBleAdvertiser?.startAdvertising(localName, manufacturerData, singleStrategyOnly) ?: false
                    result.success(success)
                }
                "stopAdvertising" -> {
                    nativeBleAdvertiser?.stopAdvertising()
                    result.success(true)
                }
                "isAdvertising" -> {
                    val isActive = nativeBleAdvertiser?.isAdvertising() ?: false
                    result.success(isActive)
                }
                "requiresNativeAdvertising" -> {
                    // Проверяем, требуется ли native advertising для этого устройства
                    val requires = DeviceDetector.requiresNativeBleAdvertising()
                    result.success(requires)
                }
                "getDeviceInfo" -> {
                    val info = DeviceDetector.detectDevice()
                    result.success(mapOf(
                        "brand" to info.brand.name,
                        "firmware" to info.firmware.name,
                        "manufacturer" to info.manufacturer,
                        "model" to info.model,
                        "requiresNativeAdvertising" to DeviceDetector.requiresNativeBleAdvertising(),
                        "requiresMinimalAdvertising" to DeviceDetector.requiresMinimalAdvertising()
                    ))
                }
                else -> result.notImplemented()
            }
        }

        // 4. Запуск форензик-систем (Mic Detection & Anti-Hook)
        startMicDetection()
        antiHookCheck()

        // --- HARDWARE GUARD: Мониторинг сенсоров и Опознаватель ---
        hardwareGuardChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSensorsState" -> {
                    val state = HashMap<String, Any?>()
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager

                    // 🛡️ РЕФЛЕКСИЯ: Проверка активности микрофона (Android 9+)
                    var micInUse = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        try {
                            val method = am.javaClass.getMethod("isMicrophoneActive")
                            micInUse = method.invoke(am) as Boolean
                        } catch (e: Exception) { micInUse = false }
                    }

                    state["micActive"] = micInUse
                    state["isScreenOn"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                        pm.isInteractive
                    } else {
                        @Suppress("DEPRECATION")
                        pm.isScreenOn
                    }
                    state["foregroundApp"] = getForegroundApp()
                    result.success(state)
                }
                "engageHardwareLock" -> {
                    engageMicMutex()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // --- P2P HANDLERS: Управление Wi-Fi Direct ---
        p2pMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDiscovery" -> {
                    // Проверяем состояние Wi-Fi Direct перед запуском
                    val p2pHelper = p2pHelper
                    if (p2pHelper?.isP2pEnabled() != true) {
                        Log.w("P2P", "⚠️ Wi-Fi Direct is disabled. Requesting activation...")
                        result.error("P2P_DISABLED", "Wi-Fi Direct is disabled. Please enable it in settings.", null)
                        // Открываем настройки для пользователя
                        p2pHelper?.requestP2pActivation()
                        return@setMethodCallHandler
                    }
                    
                    // Используем нативный менеджер напрямую для надежности
                    manager.discoverPeers(wifiP2pChannel, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            Log.d("P2P", "✅ Discovery started")
                            result.success(true)
                        }
                        override fun onFailure(reason: Int) {
                            Log.e("P2P", "❌ Discovery failed: $reason")
                            result.error("P2P_ERR", "Failed to start discovery", reason)
                        }
                    })
                }
            "checkP2pState" -> {
                val isEnabled = p2pHelper?.isP2pEnabled() ?: false
                result.success(mapOf("enabled" to isEnabled))
            }
            "checkDiscoveryState" -> {
                val isActive = p2pHelper?.isDiscoveryActive() ?: false
                result.success(mapOf("active" to isActive))
            }
            "requestP2pActivation" -> {
                p2pHelper?.requestP2pActivation()
                result.success(true)
            }
                "stopDiscovery" -> {
                    manager.stopPeerDiscovery(wifiP2pChannel, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { result.success(true) }
                        override fun onFailure(reason: Int) { result.error("P2P_ERR", "Stop failed", reason) }
                    })
                }

                "forceReset" -> {
                    p2pHelper?.forceReset { result.success(true) }
                }
                "getHardwareCapabilities" -> {
                    val pm = packageManager
                    val caps = HashMap<String, Any?>()
                    caps["hasAware"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        pm.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
                    } else false
                    caps["hasDirect"] = pm.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
                    caps["androidVersion"] = Build.VERSION.SDK_INT
                    result.success(caps)
                }
                else -> result.notImplemented()
            }
        }

        // --- SONAR HANDLERS: Управление Акустикой ---
        sonarMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        acousticReceiver?.start()
                        result.success(true)
                    } else {
                        result.error("PERM_DENIED", "Mic permission required", null)
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

        // --- SECURITY HANDLERS: Защита и Камуфляж ---
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
                    } else result.error("ERR", "Null icon target", null)
                }
                else -> result.notImplemented()
            }
        }

        // --- ROUTER CAPTURE PROTOCOL: Управление Wi-Fi роутерами ---
        routerMethodChannel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "scanWifiNetworks" -> {
                        val networks = routerHelper?.scanWifiNetworks() ?: emptyList()
                        result.success(networks)
                    }
                    "connectToRouter" -> {
                        val ssid = call.argument<String>("ssid") ?: ""
                        val password = call.argument<String>("password")
                        val success = routerHelper?.connectToRouter(ssid, password) ?: false
                        result.success(success)
                    }
                    "disconnectFromRouter" -> {
                        val success = routerHelper?.disconnectFromRouter() ?: false
                        result.success(success)
                    }
                    "getLocalIpAddress" -> {
                        val ip = routerHelper?.getLocalIpAddress()
                        result.success(ip)
                    }
                    "checkInternetViaRouter" -> {
                        val hasInternet = routerHelper?.checkInternetViaRouter() ?: false
                        result.success(hasInternet)
                    }
                    "getConnectedRouterInfo" -> {
                        val info = routerHelper?.getConnectedRouterInfo()
                        result.success(info)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            } catch (e: Exception) {
                Log.e("RouterHelper", "Error handling method call: ${e.message}")
                result.error("ROUTER_ERROR", e.message, null)
            }
        }

        // --- GOOGLE API: Проверка сервисов ---
        googleChannel.setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                val api = GoogleApiAvailability.getInstance()
                result.success(api.isGooglePlayServicesAvailable(this) == ConnectionResult.SUCCESS)
            } else result.notImplemented()
        }
    }

    // ================= MIC FORENSICS LOGIC =================

    private fun startMicDetection() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioCallback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                val active = configs.isNotEmpty()
                if (active) {
                    val event = MicEvent(ts = System.currentTimeMillis(), type = classifyMic(am), hidden = micMutex == null)
                    pushEvent(event)
                    analyze()
                }
            }
        }
        am.registerAudioRecordingCallback(audioCallback!!, Handler(Looper.getMainLooper()))
    }

    private fun classifyMic(am: AudioManager): MicType = when (am.mode) {
        AudioManager.MODE_IN_CALL -> MicType.CALL
        AudioManager.MODE_IN_COMMUNICATION -> MicType.VOIP
        else -> MicType.RECORDER
    }

    private fun analyze() {
        if (timeline.size < 10) return
        val window = timeline.takeLast(40)
        val n = window.size.toDouble()
        val types = window.groupingBy { it.type }.eachCount()
        val ent = types.values.sumOf { val p = it / n; -p * ln(p) }
        val hiddenRate = window.count { it.hidden }.toDouble() / n
        val burst = window.zipWithNext().count { it.second.ts - it.first.ts < 300 }

        var score = (ent.coerceIn(0.0, 1.5) / 1.5 + hiddenRate * 1.2 + min(1.0, burst / 10.0)) / 3.0
        score = score.coerceIn(0.0, 1.0)

        val pattern = when {
            score > 0.75 && hiddenRate > 0.4 -> MicPattern.SPY_RECORDING
            hiddenRate > 0.3 -> MicPattern.BACKGROUND_REC
            window.any { it.type == MicType.VOIP } -> MicPattern.VOIP_CALL
            else -> MicPattern.NORMAL
        }

        if (abs(score - lastScore) > 0.15 || pattern != lastPattern) {
            runOnUiThread { dispatch(pattern, score) }
            if (pattern == MicPattern.SPY_RECORDING && score > 0.8) engageMicMutex()
        }
        lastScore = score; lastPattern = pattern
    }

    private fun pushEvent(e: MicEvent) {
        timeline.add(e)
        if (timeline.size > MAX_EVENTS) timeline.removeAt(0)
    }

    private fun engageMicMutex() {
        if (micMutex != null) return
        try {
            val buf = AudioRecord.getMinBufferSize(44100, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                micMutex = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, 44100, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, buf)
                micMutex?.startRecording()
                Log.w("GUARD", "Hardware Mutex Engaged")
            }
        } catch (e: Exception) { Log.e("GUARD", "Mutex failed: ${e.message}") }
    }

    private fun dispatch(pattern: MicPattern, score: Double) {
        hardwareGuardChannel.invokeMethod("onMicAnalysis", mapOf("pattern" to pattern.name, "score" to score, "timestamp" to System.currentTimeMillis()))
    }

    private fun getForegroundApp(): String {
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val time = System.currentTimeMillis()
            val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 1000 * 10, time)
            if (stats != null && stats.isNotEmpty()) {
                stats.maxByOrNull { it.lastTimeUsed }?.packageName ?: "unknown"
            } else "unknown"
        } catch (e: Exception) { "unknown" }
    }

    private fun antiHookCheck() {
        Thread {
            if (detectHook()) {
                runOnUiThread { hardwareGuardChannel.invokeMethod("onSecurityAlert", "HOOK_DETECTED") }
            }
        }.start()
    }

    private fun detectHook(): Boolean {
        return try {
            Class.forName("de.robv.android.xposed.XposedBridge")
            true
        } catch (_: Exception) {
            try {
                File("/proc/self/maps").readText().run { contains("frida") || contains("gum-js-loop") }
            } catch (_: Exception) { false }
        }
    }

    private fun changeAppIcon(target: String) {
        val pkg = packageName
        val clsCalc = "$pkg.MainActivityCalculator"
        val clsNotes = "$pkg.MainActivityNotes"
        val enable = if (target == "Notes") clsNotes else clsCalc
        val disable = if (target == "Notes") clsCalc else clsNotes
        try {
            packageManager.setComponentEnabledSetting(ComponentName(pkg, disable), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, 0)
            packageManager.setComponentEnabledSetting(ComponentName(pkg, enable), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, 0)
        } catch (e: Exception) { Log.e("ICON", "Error: ${e.message}") }
    }

    override fun onDestroy() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioCallback?.let { am.unregisterAudioRecordingCallback(it) }
        try { unregisterReceiver(messageReceiver) } catch (_: Exception) {}
        micMutex?.let { try { it.stop(); it.release() } catch (_: Exception) {} }
        
        // 🔥 ОЧИСТКА P2P РЕСУРСОВ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ
        p2pHelper?.cleanup()
        
        // 🔥 ОЧИСТКА NATIVE BLE ADVERTISER
        nativeBleAdvertiser?.cleanup()
        
        super.onDestroy()
    }
}

// -----------------------------------------------------------------------------
// 🔊 Acoustic Receiver + Goertzel (Logic Preserved)
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