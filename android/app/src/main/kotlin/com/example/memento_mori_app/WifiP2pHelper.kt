package com.example.memento_mori_app

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

class WifiP2pHelper(
    private val context: Context,
    private val activity: android.app.Activity,
    private val methodChannel: MethodChannel
) {
    companion object {
        // 🔥 Статический логгер для MeshBackgroundService и других компонентов
        private var staticLogCallback: ((String, String) -> Unit)? = null
        
        /**
         * Отправляет лог в Flutter UI терминал (вызывается из любого места)
         * Если Activity не активна, лог пишется только в Logcat
         */
        fun sendLogToFlutter(tag: String, message: String) {
            Log.d(tag, message)
            staticLogCallback?.invoke(tag, message)
        }
        
        /**
         * Shorthand для логирования с тегом P2P
         */
        fun log(message: String) = sendLogToFlutter("P2P", message)
    }
    
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private val intentFilter = IntentFilter()

    private val networkExecutor = Executors.newFixedThreadPool(4).asCoroutineDispatcher()
    private val scope = CoroutineScope(networkExecutor + SupervisorJob())

    private val addressMap = mutableMapOf<String, String>()
    private var wakeLock: PowerManager.WakeLock? = null
    private var isP2pEnabled = false // Состояние Wi-Fi Direct
    
    // 🔥 ФИКСЫ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var heartbeatJob: Job? = null
    private val deviceInfo = DeviceDetector.detectDevice()
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    
    // Флаги для управления постоянными locks (не только во время discovery)
    private var isServiceActive = false // Приложение активно или Foreground Service работает
    
    // 🔥 АВТОМАТИЧЕСКОЕ СОЗДАНИЕ WI-FI DIRECT ГРУППЫ
    private var isGroupOwner = false      // Мы владелец группы?
    private var isGroupCreating = false   // Группа создается?
    private var currentGroupName: String? = null  // Имя текущей группы
    private var groupCreationRetries = 0  // Количество попыток создания группы
    private val MAX_GROUP_RETRIES = 3     // Максимум попыток
    /** Huawei/Honor: после сбоя createGroup не ретраить сразу (cooldown 60s). */
    private var lastGroupCreateFailureTimeMs: Long = 0

    init {
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)

        // 🔥 ФИКС ДЛЯ HUAWEI: Максимальный приоритет для перехвата P2P событий в фоне
        intentFilter.priority = 999

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Memento:MeshWakeLock")
        
        // 🔥 ИНИЦИАЛИЗАЦИЯ ФИКСОВ ДЛЯ КИТАЙСКИХ УСТРОЙСТВ
        initializeChineseDeviceFixes()
        
        // 🔥 АКТИВИРУЕМ ПОСТОЯННЫЕ LOCKS ДЛЯ КИТАЙСКИХ УСТРОЙСТВ
        // Это гарантирует работу P2P в фоне на Xiaomi/Poco/Tecno/Infinix
        activatePersistentLocks()
        
        // Проверяем начальное состояние Wi-Fi Direct
        checkP2pState()
        
        // 🔥 УСТАНАВЛИВАЕМ СТАТИЧЕСКИЙ ЛОГГЕР ДЛЯ ДОСТУПА ИЗ MeshBackgroundService
        staticLogCallback = { tag, message ->
            runOnMain {
                try {
                    methodChannel.invokeMethod("onNativeLog", mapOf(
                        "tag" to tag,
                        "message" to message
                    ))
                } catch (e: Exception) {
                    // Activity может быть не активна - игнорируем
                }
            }
        }
    }
    
    /**
     * Инициализация фиксов для китайских устройств
     */
    private fun initializeChineseDeviceFixes() {
        if (!DeviceDetector.isChineseDevice()) {
            Log.d("P2P", "ℹ️ Not a Chinese device, skipping special fixes")
            return
        }
        
        Log.d("P2P", "🔧 Initializing fixes for ${deviceInfo.brand} (${deviceInfo.firmware})")
        
        // Инициализация MulticastLock (если требуется)
        if (DeviceDetector.requiresMulticastLock() && wifiManager != null) {
            try {
                multicastLock = wifiManager.createMulticastLock("Memento:MulticastLock")
                multicastLock?.setReferenceCounted(false)
                Log.d("P2P", "✅ MulticastLock initialized")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to create MulticastLock: ${e.message}")
            }
        }
        
        // Инициализация Wi-Fi Lock (если требуется)
        if (DeviceDetector.requiresWifiLock() && wifiManager != null) {
            try {
                wifiLock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // Android 10+ (API 29+): WIFI_MODE_FULL_LOW_LATENCY
                    @Suppress("NewApi")
                    wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Memento:WifiLock")
                } else {
                    // Старые версии: WIFI_MODE_FULL_HIGH_PERF
                    @Suppress("DEPRECATION")
                    wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Memento:WifiLock")
                }
                wifiLock?.setReferenceCounted(false)
                Log.d("P2P", "✅ Wi-Fi Lock initialized")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to create Wi-Fi Lock: ${e.message}")
            }
        }
    }
    
    /**
     * Захватывает MulticastLock (для китайских устройств)
     * Вызывается при запуске discovery
     */
    private fun acquireMulticastLock() {
        if (DeviceDetector.requiresMulticastLock() && multicastLock != null) {
            try {
                if (!multicastLock!!.isHeld) {
                    multicastLock!!.acquire()
                    Log.d("P2P", "🔒 MulticastLock acquired")
                }
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to acquire MulticastLock: ${e.message}")
            }
        }
    }
    
    /**
     * Освобождает MulticastLock
     * Вызывается только при полной остановке или если discovery завершен и сервис не активен
     */
    private fun releaseMulticastLock() {
        // Освобождаем только если сервис не активен
        if (!isServiceActive && multicastLock != null && multicastLock!!.isHeld) {
            try {
                multicastLock!!.release()
                Log.d("P2P", "🔓 MulticastLock released")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to release MulticastLock: ${e.message}")
            }
        }
    }
    
    /**
     * Захватывает Wi-Fi Lock (для китайских устройств)
     * Должен удерживаться постоянно, пока приложение активно
     */
    private fun acquireWifiLock() {
        if (DeviceDetector.requiresWifiLock() && wifiLock != null) {
            try {
                if (!wifiLock!!.isHeld) {
                    wifiLock!!.acquire()
                    Log.d("P2P", "🔒 Wi-Fi Lock acquired (persistent)")
                }
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to acquire Wi-Fi Lock: ${e.message}")
            }
        }
    }
    
    /**
     * Освобождает Wi-Fi Lock
     * Вызывается только при полной остановке приложения
     */
    private fun releaseWifiLock() {
        // Освобождаем только если сервис не активен
        if (!isServiceActive && wifiLock != null && wifiLock!!.isHeld) {
            try {
                wifiLock!!.release()
                Log.d("P2P", "🔓 Wi-Fi Lock released")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to release Wi-Fi Lock: ${e.message}")
            }
        }
    }
    
    /**
     * Активирует постоянные locks для китайских устройств
     * Вызывается при старте приложения или Foreground Service
     */
    fun activatePersistentLocks() {
        if (!DeviceDetector.isChineseDevice()) return
        
        isServiceActive = true
        Log.d("P2P", "🔧 Activating persistent locks for ${deviceInfo.brand}")
        
        // Захватываем Wi-Fi Lock постоянно (для работы в фоне)
        acquireWifiLock()
        
        // Запускаем Heartbeat для Tecno/Infinix
        if (DeviceDetector.requiresHeartbeat()) {
            startPersistentHeartbeat()
        }
    }
    
    /**
     * Деактивирует постоянные locks
     * Вызывается при полной остановке приложения
     */
    fun deactivatePersistentLocks() {
        isServiceActive = false
        Log.d("P2P", "🔧 Deactivating persistent locks")
        
        // Останавливаем Heartbeat
        stopHeartbeat()
        
        // Освобождаем все locks
        if (multicastLock != null && multicastLock!!.isHeld) {
            try {
                multicastLock!!.release()
                Log.d("P2P", "🔓 MulticastLock released (deactivation)")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to release MulticastLock: ${e.message}")
            }
        }
        
        if (wifiLock != null && wifiLock!!.isHeld) {
            try {
                wifiLock!!.release()
                Log.d("P2P", "🔓 Wi-Fi Lock released (deactivation)")
            } catch (e: Exception) {
                Log.e("P2P", "❌ Failed to release Wi-Fi Lock: ${e.message}")
            }
        }
    }
    
    /**
     * Запускает Heartbeat для Tecno/Infinix (отправка пустых пакетов каждые 2-5 секунд)
     * Используется только во время discovery
     */
    private fun startHeartbeat() {
        if (!DeviceDetector.requiresHeartbeat()) return
        
        // Останавливаем предыдущий heartbeat, если есть
        stopHeartbeat()
        
        Log.d("P2P", "💓 Starting Heartbeat (discovery mode) for ${deviceInfo.brand}")
        
        heartbeatJob = scope.launch {
            while (isActive && _isDiscoveryActive) {
                delay(3000) // 3 секунды между heartbeat пакетами
                
                // Отправляем пустой heartbeat пакет через P2P
                // Это помогает поддерживать соединение активным на Tecno/Infinix
                try {
                    if (manager != null && channel != null && isP2pEnabled) {
                        // Просто проверяем состояние соединения - это достаточно для heartbeat
                        manager?.requestConnectionInfo(channel) { info ->
                            if (info != null) {
                                Log.v("P2P", "💓 Heartbeat: Connection active")
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w("P2P", "⚠️ Heartbeat error: ${e.message}")
                }
            }
        }
    }
    
    /**
     * Запускает постоянный Heartbeat для Tecno/Infinix
     * Работает пока приложение активно или Foreground Service живет
     */
    private fun startPersistentHeartbeat() {
        if (!DeviceDetector.requiresHeartbeat()) return
        
        // Останавливаем предыдущий heartbeat, если есть
        stopHeartbeat()
        
        Log.d("P2P", "💓 Starting Persistent Heartbeat for ${deviceInfo.brand}")
        
        heartbeatJob = scope.launch {
            while (isActive && isServiceActive) {
                delay(4000) // 4 секунды между heartbeat пакетами (чуть реже для экономии батареи)
                
                // Отправляем пустой heartbeat пакет через P2P
                // Это помогает поддерживать соединение активным на Tecno/Infinix
                try {
                    if (manager != null && channel != null && isP2pEnabled) {
                        // Просто проверяем состояние соединения - это достаточно для heartbeat
                        manager?.requestConnectionInfo(channel) { info ->
                            if (info != null) {
                                Log.v("P2P", "💓 Persistent Heartbeat: Connection active")
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w("P2P", "⚠️ Persistent Heartbeat error: ${e.message}")
                }
            }
        }
    }
    
    /**
     * Останавливает Heartbeat
     */
    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        Log.d("P2P", "💓 Heartbeat stopped")
    }

    private fun anonymize(address: String): String {
        return try {
            val salt = "memento_mori_stealth_v2"
            val md = MessageDigest.getInstance("SHA-256")
            val digest = md.digest((address + salt).toByteArray())
            digest.fold("") { str, it -> str + "%02x".format(it) }.substring(0, 16)
        } catch (e: Exception) { address.takeLast(8) }
    }

    private fun ensureP2pInitialized(): Boolean {
        if (manager != null && channel != null) return true
        return try {
            val m = context.applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            val c = m?.initialize(context.applicationContext, context.mainLooper, null)
            manager = m
            channel = c
            m != null && c != null
        } catch (e: Exception) { false }
    }

    /// Проверяет состояние Wi-Fi Direct (вызывается при инициализации)
    /// Реальное состояние обновляется через WIFI_P2P_STATE_CHANGED_ACTION
    private fun checkP2pState() {
        // По умолчанию считаем, что Wi-Fi Direct включен
        // Если он отключен, событие WIFI_P2P_STATE_CHANGED_ACTION обновит isP2pEnabled
        isP2pEnabled = true
    }

    fun registerReceiver() {
        if (receiver != null || !ensureP2pInitialized()) return
        receiver = object : BroadcastReceiver() {
            @SuppressLint("MissingPermission")
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        // 🔥 КРИТИЧНО: Обрабатываем изменение состояния Wi-Fi Direct
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        isP2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
                        
                        if (isP2pEnabled) {
                            Log.d("P2P", "✅ Wi-Fi Direct ENABLED")
                            runOnMain { 
                                methodChannel.invokeMethod("onP2pStateChanged", mapOf("enabled" to true))
                            }
                        } else {
                            Log.w("P2P", "⚠️ Wi-Fi Direct DISABLED - User needs to enable it")
                            runOnMain { 
                                methodChannel.invokeMethod("onP2pStateChanged", mapOf("enabled" to false))
                            }
                        }
                    }
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        manager?.requestPeers(channel) { peers ->
                            val deviceList = peers?.deviceList?.map {
                                val hashedMac = anonymize(it.deviceAddress)
                                addressMap[hashedMac] = it.deviceAddress
                                mapOf(
                                    "id" to hashedMac,
                                    "name" to (it.deviceName ?: "Ghost Node"),
                                    "type" to "mesh",
                                    "metadata" to hashedMac
                                )
                            } ?: emptyList()
                            // Логируем в UI терминал
                            if (deviceList.isNotEmpty()) {
                                logP2P("📡 [PEERS] Found ${deviceList.size} device(s)")
                            }
                            runOnMain { methodChannel.invokeMethod("onPeersFound", deviceList) }
                        }
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val networkInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO, NetworkInfo::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO)
                        }

                        logP2P("🔗 [CONNECTION] State: ${networkInfo?.state}, Connected: ${networkInfo?.isConnected}")

                        if (networkInfo?.isConnected == true) {
                            // 🔥 КРИТИЧНО: Проверяем, что P2P инициализирован перед запросом информации
                            if (!ensureP2pInitialized()) {
                                Log.e("P2P", "❌ [CONNECTION_CHANGED] P2P not initialized, cannot get connection info")
                                return@onReceive
                            }
                            
                            manager?.requestConnectionInfo(channel) { info ->
                                if (info == null) {
                                    Log.w("P2P", "⚠️ [CONNECTION_CHANGED] Connection info is null")
                                    return@requestConnectionInfo
                                }
                                
                                logP2P("📋 [CONNECTION] Info received")
                                logP2P("   - Group formed: ${info.groupFormed}")
                                logP2P("   - Is group owner: ${info.isGroupOwner}")
                                logP2P("   - GO address: ${info.groupOwnerAddress?.hostAddress}")
                                
                                if (info.groupFormed && info.groupOwnerAddress != null) {
                                    val isHost = info.isGroupOwner
                                    val hostAddress = info.groupOwnerAddress.hostAddress
                                    
                                    logP2P("✅ [CONNECTION] Established!")
                                    logP2P("   - Role: ${if (isHost) "HOST (GO)" else "CLIENT"}")
                                    logP2P("   - Host IP: $hostAddress")
                                    
                                    if (wakeLock?.isHeld == false) {
                                        wakeLock?.acquire(10 * 60 * 1000L)
                                        Log.d("P2P", "🔒 WakeLock acquired")
                                    }

                                    runOnMain {
                                        methodChannel.invokeMethod("onConnected", mapOf(
                                            "isHost" to isHost,
                                            "hostAddress" to hostAddress
                                        ))
                                    }
                                } else {
                                    Log.w("P2P", "⚠️ [CONNECTION_CHANGED] Network connected but group not formed or address missing")
                                    Log.w("P2P", "   - Group formed: ${info.groupFormed}")
                                    Log.w("P2P", "   - Group owner address: ${info.groupOwnerAddress?.hostAddress}")
                                    
                                    // Возможно, подключение еще устанавливается, ждем немного
                                    scope.launch {
                                        delay(2000) // Ждем 2 секунды
                                        manager?.requestConnectionInfo(channel) { retryInfo ->
                                            if (retryInfo != null && retryInfo.groupFormed && retryInfo.groupOwnerAddress != null) {
                                                val isHost = retryInfo.isGroupOwner
                                                val hostAddress = retryInfo.groupOwnerAddress.hostAddress
                                                
                                                logP2P("✅ [CONNECTION] Established after retry!")
                                                
                                                if (wakeLock?.isHeld == false) {
                                                    wakeLock?.acquire(10 * 60 * 1000L)
                                                }
                                                
                                                runOnMain {
                                                    methodChannel.invokeMethod("onConnected", mapOf(
                                                        "isHost" to isHost,
                                                        "hostAddress" to hostAddress
                                                    ))
                                                }
                                            } else {
                                                Log.e("P2P", "❌ [CONNECTION_CHANGED] Connection failed after retry")
                                                runOnMain {
                                                    methodChannel.invokeMethod("onConnectionFailed", mapOf(
                                                        "error" to "GROUP_NOT_FORMED",
                                                        "message" to "Группа не сформирована после подключения"
                                                    ))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            logP2P("🔌 [CONNECTION] Disconnected")
                            if (wakeLock?.isHeld == true) {
                                wakeLock?.release()
                                Log.d("P2P", "🔓 WakeLock released")
                            }
                            runOnMain { methodChannel.invokeMethod("onDisconnected", null) }
                        }
                    }
                }
            }
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Context.RECEIVER_EXPORTED else 0
        context.registerReceiver(receiver, intentFilter, flags)
    }

    fun unregisterReceiver() {
        receiver?.let { try { context.unregisterReceiver(it) } catch (e: Exception) { } }
        receiver = null
    }

    /// Проверяет, включен ли Wi-Fi Direct
    fun isP2pEnabled(): Boolean {
        return isP2pEnabled && ensureP2pInitialized()
    }

    /// Запрашивает активацию Wi-Fi Direct (открывает настройки)
    fun requestP2pActivation() {
        try {
            val intent = Intent(android.provider.Settings.ACTION_WIRELESS_SETTINGS)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            activity.startActivity(intent)
            Log.d("P2P", "📱 Opening Wi-Fi settings for user to enable Wi-Fi Direct")
        } catch (e: Exception) {
            Log.e("P2P", "Failed to open settings: ${e.message}")
        }
    }

    private var _isDiscoveryActive = false
    
    @SuppressLint("MissingPermission")
    fun startDiscovery(): Boolean {
        if (!ensureP2pInitialized()) {
            Log.e("P2P", "❌ P2P not initialized")
            return false
        }
        
        if (!isP2pEnabled) {
            Log.w("P2P", "⚠️ Wi-Fi Direct is DISABLED. Cannot start discovery.")
            runOnMain {
                methodChannel.invokeMethod("onP2pStateChanged", mapOf("enabled" to false))
            }
            return false
        }
        
        // Если discovery уже активен, не запускаем повторно (ошибка 0 = ERROR обычно означает что уже запущен)
        if (_isDiscoveryActive) {
            Log.d("P2P", "ℹ️ Discovery already active, skipping duplicate start")
            return true
        }
        
        // 🔥 ФИКС ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Захватываем locks перед запуском discovery
        acquireMulticastLock()
        acquireWifiLock()
        
        _isDiscoveryActive = true
        
        // 🔥 ФИКС ДЛЯ TECNO/INFINIX: Запускаем Heartbeat
        startHeartbeat()
        
        manager?.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                logP2P("✅ [SCAN] Discovery started")
                // Discovery автоматически останавливается через ~10 секунд, сбрасываем флаг
                scope.launch {
                    delay(12000) // Немного больше чем стандартный таймаут
                    _isDiscoveryActive = false
                    // Освобождаем только MulticastLock (он нужен только для discovery)
                    // Wi-Fi Lock остается активным (он постоянный для китайских устройств)
                    releaseMulticastLock()
                    // Останавливаем discovery heartbeat, но постоянный heartbeat продолжает работать
                    stopHeartbeat()
                    // Если требуется постоянный heartbeat, он уже запущен через activatePersistentLocks()
                    if (DeviceDetector.requiresHeartbeat() && isServiceActive) {
                        startPersistentHeartbeat()
                    }
                }
            }
            override fun onFailure(reason: Int) {
                _isDiscoveryActive = false
                // Освобождаем только MulticastLock при ошибке
                // Wi-Fi Lock остается активным
                releaseMulticastLock()
                stopHeartbeat()
                
                logP2P("❌ [SCAN] Discovery failed: $reason")
                // Коды ошибок:
                // P2P_UNSUPPORTED = 1
                // BUSY = 2
                // ERROR = 0 (обычно означает что discovery уже запущен или система занята)
                when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> {
                        logP2P("❌ Device not support Wi-Fi Direct")
                    }
                    WifiP2pManager.BUSY -> {
                        logP2P("⚠️ P2P busy, retry later")
                    }
                    0 -> {
                        // ERROR = 0 часто означает что discovery уже активен или система занята
                        // В этом случае считаем discovery активным (Android может не дать запустить повторно)
                        _isDiscoveryActive = true
                        logP2P("ℹ️ [SCAN] Error 0 - likely already active")
                        // Сбрасываем флаг через 12 секунд (стандартный таймаут discovery)
                        scope.launch {
                            delay(12000)
                            _isDiscoveryActive = false
                            releaseMulticastLock()
                            stopHeartbeat()
                            // Если требуется постоянный heartbeat, он уже запущен через activatePersistentLocks()
                            if (DeviceDetector.requiresHeartbeat() && isServiceActive) {
                                startPersistentHeartbeat()
                            }
                        }
                    }
                    else -> {
                        Log.e("P2P", "Unknown error: $reason")
                    }
                }
            }
        })
        return true
    }

    fun stopDiscovery() { 
        _isDiscoveryActive = false
        
        // 🔥 ФИКС ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Освобождаем только MulticastLock
        // Wi-Fi Lock остается активным (он постоянный для китайских устройств)
        releaseMulticastLock()
        stopHeartbeat()
        
        // Если требуется постоянный heartbeat, запускаем его
        if (DeviceDetector.requiresHeartbeat() && isServiceActive) {
            startPersistentHeartbeat()
        }
        
        if (ensureP2pInitialized()) {
            manager?.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d("P2P", "Discovery stopped")
                }
                override fun onFailure(reason: Int) {
                    Log.e("P2P", "Failed to stop discovery: $reason")
                }
            })
        }
    }
    
    fun isDiscoveryActive(): Boolean {
        return _isDiscoveryActive
    }

    @SuppressLint("MissingPermission")
    fun connect(hashedAddress: String, networkName: String? = null, passphrase: String? = null) {
        if (!ensureP2pInitialized()) {
            Log.e("P2P", "❌ [CONNECT] P2P not initialized")
            runOnMain {
                methodChannel.invokeMethod("onConnectionFailed", mapOf(
                    "error" to "P2P_NOT_INITIALIZED",
                    "message" to "Wi-Fi P2P не инициализирован"
                ))
            }
            return
        }
        
        if (!isP2pEnabled) {
            Log.w("P2P", "⚠️ [CONNECT] Wi-Fi Direct is DISABLED")
            runOnMain {
                methodChannel.invokeMethod("onConnectionFailed", mapOf(
                    "error" to "P2P_DISABLED",
                    "message" to "Wi-Fi Direct выключен. Включите в настройках."
                ))
            }
            return
        }
        
        val realMac = addressMap[hashedAddress]
        if (realMac == null) {
            Log.e("P2P", "❌ [CONNECT] Device address not found for hashed: $hashedAddress")
            runOnMain {
                methodChannel.invokeMethod("onConnectionFailed", mapOf(
                    "error" to "DEVICE_NOT_FOUND",
                    "message" to "Адрес устройства не найден"
                ))
            }
            return
        }
        
        Log.d("P2P", "🔗 [CONNECT] Attempting connection to device: ${anonymize(realMac)}")
        if (passphrase != null && passphrase.isNotEmpty()) {
            logP2P("   📋 Using passphrase for Wi-Fi Direct (GHOST will connect without dialog)")
        }

        val config = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && passphrase != null && passphrase.isNotEmpty()) {
            // API 29+: Используем Builder с passphrase — GHOST подключается без диалога ввода пароля
            val builder = android.net.wifi.p2p.WifiP2pConfig.Builder()
            builder.setDeviceAddress(android.net.MacAddress.fromString(realMac))
            networkName?.let { builder.setNetworkName(it) }
            builder.setPassphrase(passphrase)
            builder.build()
        } else {
            WifiP2pConfig().apply {
                deviceAddress = realMac
                groupOwnerIntent = 15
            }
        }

        manager?.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d("P2P", "✅ [CONNECT] Connection request sent successfully")
                // Подключение будет обработано через WIFI_P2P_CONNECTION_CHANGED_ACTION
            }
            
            override fun onFailure(reason: Int) {
                val errorMsg = when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct не поддерживается"
                    WifiP2pManager.BUSY -> "Wi-Fi P2P занят, попробуйте позже"
                    WifiP2pManager.ERROR -> "Ошибка подключения"
                    else -> "Неизвестная ошибка: $reason"
                }
                
                Log.e("P2P", "❌ [CONNECT] Connection failed: $errorMsg (code: $reason)")
                
                runOnMain {
                    methodChannel.invokeMethod("onConnectionFailed", mapOf(
                        "error" to "CONNECT_FAILED",
                        "code" to reason,
                        "message" to errorMsg
                    ))
                }
            }
        })
    }

    fun sendTcp(host: String, port: Int, message: String) {
        scope.launch {
            try {
                // 🔥 КРИТИЧЕСКИЙ ФИКС #3: Используем SocketFactory из Wi-Fi Direct Network (Android 10+)
                // Без этого сокеты могут идти через мобильную сеть вместо Wi-Fi Direct
                val network = getWifiDirectNetwork()
                
                val socket = if (network != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    // Используем SocketFactory из Network для гарантии использования Wi-Fi Direct
                    try {
                        network.socketFactory.createSocket()
                    } catch (e: Exception) {
                        Log.w("P2P_NET", "⚠️ Failed to create socket from network, using default: ${e.message}")
                        Socket()
                    }
                } else {
                    Socket()
                }
                
                socket.use { s ->
                    s.tcpNoDelay = true
                    s.soTimeout = 5000
                    s.connect(InetSocketAddress(host, port), 5000)
                    val out = s.getOutputStream()
                    val bytes = (message + "\n").toByteArray(StandardCharsets.UTF_8)
                    out.write(bytes)
                    out.flush()
                    Log.d("P2P_NET", "🚀 Burst delivered via P2P to $host (network: ${network != null})")
                }
            } catch (e: Exception) {
                Log.e("P2P_NET", "Send Error: ${e.message}")
            }
        }
    }
    
    /**
     * 🔥 КРИТИЧЕСКИЙ ФИКС #3: Получает Network для Wi-Fi Direct
     * Используется для создания сокетов через правильную сеть
     */
    private fun getWifiDirectNetwork(): Network? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }
        
        return try {
            val connectivityManager = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (connectivityManager == null) {
                Log.w("P2P", "⚠️ ConnectivityManager not available")
                return null
            }
            
            val networks = connectivityManager.allNetworks
            for (network in networks) {
                val capabilities = connectivityManager.getNetworkCapabilities(network)
                if (capabilities != null) {
                    // 🔥 FIX: TRANSPORT_WIFI_DIRECT не существует в API
                    // Wi-Fi Direct сети определяем по наличию Wi-Fi транспорта
                    // Приоритет: Wi-Fi без интернета (вероятно Wi-Fi Direct) > Wi-Fi с интернетом
                    val hasWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    
                    if (hasWifi) {
                        // Предпочитаем Wi-Fi без интернета (вероятно Wi-Fi Direct)
                        if (!hasInternet) {
                            Log.d("P2P", "✅ Found Wi-Fi network without Internet (likely Wi-Fi Direct) for socket factory")
                            return network
                        }
                    }
                }
            }
            
            // Fallback: ищем любой Wi-Fi сеть
            for (network in networks) {
                val capabilities = connectivityManager.getNetworkCapabilities(network)
                if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                    Log.d("P2P", "✅ Found Wi-Fi network (fallback) for socket factory")
                    return network
                }
            }
            
            Log.w("P2P", "⚠️ Wi-Fi Direct network not found")
            null
        } catch (e: Exception) {
            Log.e("P2P", "❌ Error getting Wi-Fi Direct network: ${e.message}")
            null
        }
    }

    fun forceReset(callback: () -> Unit) {
        if (manager == null || channel == null) return

        // 1. Останавливаем текущий поиск
        manager?.stopPeerDiscovery(channel, null)

        // 2. Принудительно удаляем старую группу (даже если её нет)
        manager?.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d("P2P_NET", "☢️ P2P Group Purged Successfully")
                callback()
            }
            override fun onFailure(reason: Int) {
                // Даже если нечего удалять, мы идем дальше
                Log.d("P2P_NET", "☢️ No P2P Group to purge (Reason: $reason)")
                callback()
            }
        })
    }

    private fun runOnMain(block: () -> Unit) {
        activity.runOnUiThread { block() }
    }
    
    // ============================================================================
    // 🔥 ОТПРАВКА ЛОГОВ В FLUTTER UI (ТЕРМИНАЛ ПРИЛОЖЕНИЯ)
    // ============================================================================
    
    /**
     * Отправляет лог в Flutter терминал приложения.
     * Вызывайте эту функцию вместо Log.d() где нужно видеть логи в UI.
     * 
     * @param tag Тег для логирования (также записывается в Android Logcat)
     * @param msg Сообщение для отображения
     * @param alsoLogcat Если true, дублирует в Logcat (по умолчанию true)
     */
    fun logToFlutter(tag: String, msg: String, alsoLogcat: Boolean = true) {
        if (alsoLogcat) {
            Log.d(tag, msg)
        }
        runOnMain {
            try {
                methodChannel.invokeMethod("onNativeLog", mapOf(
                    "tag" to tag,
                    "message" to msg
                ))
            } catch (e: Exception) {
                Log.e("P2P", "Failed to send log to Flutter: ${e.message}")
            }
        }
    }
    
    /**
     * Shorthand для логирования с тегом P2P
     */
    fun logP2P(msg: String) = logToFlutter("P2P", msg)
    
    // ============================================================================
    // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
    // ============================================================================
    
    /**
     * Генерирует уникальное имя для Wi-Fi Direct группы.
     * На API 29+ Android требует префикс DIRECT-xy (Wi‑Fi Direct spec).
     * Формат: DIRECT-<2 hex>_<short id>, например DIRECT-a1_7924.
     */
    private fun generateGroupName(): String {
        val hex = "0123456789abcdef"
        val c1 = hex[(Math.random() * 16).toInt()]
        val c2 = hex[(Math.random() * 16).toInt()]
        val id = (System.currentTimeMillis() / 1000) % 10000
        return "DIRECT-${c1}${c2}_$id"
    }

    /** Генерирует парольную фразу для группы (8–63 символа, WPA2). На API 29+ обязательна в Builder. */
    private fun generateGroupPassphrase(): String {
        val chars = "0123456789abcdefghijklmnopqrstuvwxyz"
        return (1..12).map { chars[(Math.random() * chars.length).toInt()] }.joinToString("")
    }
    
    /**
     * Проверяет, есть ли существующая Wi-Fi Direct группа
     * @param callback Вызывается с информацией о группе (или null если группы нет)
     */
    @SuppressLint("MissingPermission")
    fun checkExistingGroup(callback: (GroupInfo?) -> Unit) {
        if (!ensureP2pInitialized()) {
            Log.e("P2P", "❌ [GROUP] P2P не инициализирован")
            callback(null)
            return
        }
        
        Log.d("P2P", "🔍 [GROUP] Checking existing group...")
        
        manager?.requestGroupInfo(channel) { group ->
            if (group != null) {
                val info = GroupInfo(
                    networkName = group.networkName,
                    passphrase = group.passphrase,
                    isGroupOwner = group.isGroupOwner,
                    ownerAddress = group.owner?.deviceAddress,
                    clientCount = group.clientList?.size ?: 0
                )
                Log.d("P2P", "✅ [GROUP] Found group: ${info.networkName}")
                Log.d("P2P", "   📋 Owner: ${if (info.isGroupOwner) "Us" else anonymize(info.ownerAddress ?: "")}")
                Log.d("P2P", "   📋 Clients: ${info.clientCount}")
                Log.d("P2P", "   📋 Passphrase: ${info.passphrase?.take(4)}...")
                
                isGroupOwner = info.isGroupOwner
                currentGroupName = info.networkName
                callback(info)
            } else {
                Log.d("P2P", "ℹ️ [GROUP] No active group found")
                isGroupOwner = false
                currentGroupName = null
                callback(null)
            }
        }
    }
    
    /**
     * Создает Wi-Fi Direct группу автоматически
     * ВАЖНО: Проверяет существующую группу перед созданием
     * 
     * @param forceCreate Если true - удалит существующую группу и создаст новую
     * @param callback Вызывается с результатом (GroupInfo или null при ошибке)
     */
    @SuppressLint("MissingPermission")
    fun createGroup(forceCreate: Boolean = false, callback: (GroupInfo?) -> Unit) {
        if (!ensureP2pInitialized()) {
            Log.e("P2P", "❌ [GROUP] P2P не инициализирован для создания группы")
            runOnMain {
                methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                    "error" to "P2P_NOT_INITIALIZED",
                    "message" to "Wi-Fi P2P не инициализирован"
                ))
            }
            callback(null)
            return
        }
        
        if (!isP2pEnabled) {
            Log.w("P2P", "⚠️ [GROUP] Wi-Fi Direct выключен")
            runOnMain {
                methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                    "error" to "P2P_DISABLED",
                    "message" to "Wi-Fi Direct выключен. Включите в настройках."
                ))
            }
            callback(null)
            return
        }
        
        if (isGroupCreating) {
            Log.w("P2P", "⚠️ [GROUP] Создание группы уже в процессе")
            callback(null)
            return
        }
        
        Log.d("P2P", "🚀 [GROUP] Starting Wi-Fi Direct group creation...")
        Log.d("P2P", "   📋 forceCreate: $forceCreate")
        
        // Сначала проверяем существующую группу
        checkExistingGroup { existingGroup ->
            if (existingGroup != null && !forceCreate) {
                // Группа уже есть и мы не хотим её пересоздавать
                Log.d("P2P", "✅ [GROUP] Using existing group: ${existingGroup.networkName}")
                
                if (existingGroup.isGroupOwner) {
                    // We are owner - OK
                    runOnMain {
                        methodChannel.invokeMethod("onGroupCreated", mapOf(
                            "networkName" to existingGroup.networkName,
                            "passphrase" to existingGroup.passphrase,
                            "isGroupOwner" to existingGroup.isGroupOwner,
                            "clientCount" to existingGroup.clientCount,
                            "reused" to true
                        ))
                    }
                    callback(existingGroup)
                } else {
                    // Мы клиент в чужой группе - возможно нужно создать свою
                    Log.d("P2P", "ℹ️ [GROUP] We are client in another group, skipping creation")
                    callback(existingGroup)
                }
                return@checkExistingGroup
            }
            
            // Нужно создать новую группу
            if (existingGroup != null && forceCreate) {
                // Удаляем старую группу перед созданием новой
                Log.d("P2P", "🗑️ [GROUP] Removing existing group before creating new one...")
                removeGroup { removed ->
                    if (removed) {
                        // Небольшая задержка для стабилизации
                        scope.launch {
                            delay(500)
                            createNewGroup(callback)
                        }
                    } else {
                        Log.e("P2P", "❌ [GROUP] Failed to remove old group")
                        callback(null)
                    }
                }
            } else {
                // Создаем новую группу не сразу из onGroupInfoAvailable — откладываем 300–500 ms
                // чтобы P2P стек успел стабилизироваться (особенно Huawei).
                scope.launch {
                    delay(400)
                    createNewGroup(callback)
                }
            }
        }
    }
    
    /**
     * Внутренний метод создания новой группы.
     * @param try5GhzFirst На API 29+: сначала 5 GHz, при неудаче — fallback на 2.4 GHz (не все устройства поддерживают 5 GHz).
     */
    @SuppressLint("MissingPermission")
    private fun createNewGroup(callback: (GroupInfo?) -> Unit, try5GhzFirst: Boolean = true) {
        // Huawei/Honor: одна попытка за раз, после сбоя cooldown 60 s
        val isHuaweiOrHonor = deviceInfo.brand == DeviceDetector.DeviceBrand.HUAWEI || deviceInfo.brand == DeviceDetector.DeviceBrand.HONOR
        if (isHuaweiOrHonor && (System.currentTimeMillis() - lastGroupCreateFailureTimeMs) < 60_000L) {
            Log.w("P2P", "⚠️ [GROUP] Huawei cooldown: skipping create (60s after last failure)")
            callback(null)
            return
        }
        isGroupCreating = true
        var groupName = generateGroupName().trim()
        if (groupName.isEmpty() || !groupName.startsWith("DIRECT-")) {
            val h = "0123456789abcdef"
            groupName = "DIRECT-${h[(Math.random() * 16).toInt()]}${h[(Math.random() * 16).toInt()]}_${System.currentTimeMillis() % 10000}"
        }
        logP2P("📡 [GROUP] Creating: $groupName")
        Log.d("P2P", "   📋 Device: ${deviceInfo.brand} ${deviceInfo.model}")
        
        // 🔥 ФИКС ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Захватываем locks перед созданием группы
        acquireMulticastLock()
        acquireWifiLock()
        
        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                logP2P("✅ [GROUP] Create cmd OK, waiting...")
                
                // Группа создается асинхронно, ждем обновления через колбек
                // Проверяем информацию о группе через небольшую задержку
                scope.launch {
                    delay(1000) // Даем время на создание группы
                    
                    manager?.requestGroupInfo(channel) { group ->
                        isGroupCreating = false
                        groupCreationRetries = 0
                        
                        if (group != null) {
                            val info = GroupInfo(
                                networkName = group.networkName,
                                passphrase = group.passphrase,
                                isGroupOwner = group.isGroupOwner,
                                ownerAddress = group.owner?.deviceAddress,
                                clientCount = group.clientList?.size ?: 0
                            )
                            
                            isGroupOwner = true
                            currentGroupName = info.networkName
                            
                            logP2P("✅ [GROUP] Created!")
                            logP2P("   📋 SSID: ${info.networkName}")
                            logP2P("   📋 Pass: ${info.passphrase?.take(4)}...")
                            Log.d("P2P", "   📋 Owner: ${anonymize(info.ownerAddress ?: "")}")
                            
                            runOnMain {
                                methodChannel.invokeMethod("onGroupCreated", mapOf(
                                    "networkName" to info.networkName,
                                    "passphrase" to info.passphrase,
                                    "isGroupOwner" to info.isGroupOwner,
                                    "clientCount" to info.clientCount,
                                    "reused" to false
                                ))
                            }
                            callback(info)
                        } else {
                            Log.e("P2P", "❌ [GROUP] Group created but info not received")
                            runOnMain {
                                methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                                    "error" to "GROUP_INFO_UNAVAILABLE",
                                    "message" to "Group created but info unavailable"
                                ))
                            }
                            callback(null)
                        }
                    }
                }
            }
            
            override fun onFailure(reason: Int) {
                isGroupCreating = false
                lastGroupCreateFailureTimeMs = System.currentTimeMillis()
                val errorMsg = when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct не поддерживается"
                    WifiP2pManager.BUSY -> "Wi-Fi P2P занят"
                    WifiP2pManager.ERROR -> "Внутренняя ошибка Wi-Fi P2P"
                    else -> "Неизвестная ошибка: $reason"
                }
                
                Log.e("P2P", "❌ [GROUP] Ошибка создания группы: $errorMsg (code: $reason)")
                
                // 📡 Fallback: 5 GHz не поддерживается на части устройств — повтор с 2.4 GHz (API 29+)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && try5GhzFirst) {
                    logP2P("   📡 Fallback: retrying on 2.4 GHz...")
                    scope.launch {
                        delay(1500)
                        createNewGroup(callback, try5GhzFirst = false)
                    }
                    return
                }
                
                // Retry логика для BUSY состояния (повтор с той же полосой)
                if (reason == WifiP2pManager.BUSY && groupCreationRetries < MAX_GROUP_RETRIES) {
                    groupCreationRetries++
                    Log.d("P2P", "🔄 [GROUP] Повторная попытка ${groupCreationRetries}/$MAX_GROUP_RETRIES через 2 секунды...")
                    
                    scope.launch {
                        delay(2000)
                        createNewGroup(callback, try5GhzFirst)
                    }
                    return
                }
                
                groupCreationRetries = 0
                releaseMulticastLock()
                
                runOnMain {
                    methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                        "error" to "CREATE_FAILED",
                        "code" to reason,
                        "message" to errorMsg
                    ))
                }
                callback(null)
            }
        }
        val ch = channel
        val ssid = groupName.trim()
        if (ssid.isEmpty() || !ssid.startsWith("DIRECT-")) {
            Log.e("P2P", "❌ [GROUP] Refusing to create: network name must be non-empty and start with DIRECT-xy")
            isGroupCreating = false
            callback(null)
            return
        }
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && ch != null -> {
                val band = if (try5GhzFirst) android.net.wifi.p2p.WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
                    else android.net.wifi.p2p.WifiP2pConfig.GROUP_OWNER_BAND_2GHZ
                val passphrase = generateGroupPassphrase()
                val config = android.net.wifi.p2p.WifiP2pConfig.Builder()
                    .setNetworkName(ssid)
                    .setPassphrase(passphrase)
                    .setGroupOperatingBand(band)
                    .build()
                logP2P(if (try5GhzFirst) "   📡 Using 5 GHz band (API 29+)" else "   📡 Using 2.4 GHz band (fallback)")
                manager?.createGroup(ch, config, listener)
            }
            ch != null -> manager?.createGroup(ch, listener)
            else -> {
                isGroupCreating = false
                Log.e("P2P", "❌ [GROUP] Channel is null, cannot create group")
                callback(null)
            }
        }
    }
    
    /**
     * Удаляет текущую Wi-Fi Direct группу
     */
    @SuppressLint("MissingPermission")
    fun removeGroup(callback: (Boolean) -> Unit) {
        if (!ensureP2pInitialized()) {
            Log.e("P2P", "❌ [GROUP] P2P не инициализирован для удаления группы")
            callback(false)
            return
        }
        
        Log.d("P2P", "🗑️ [GROUP] Удаляем Wi-Fi Direct группу...")
        
        manager?.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d("P2P", "✅ [GROUP] Группа удалена")
                isGroupOwner = false
                currentGroupName = null
                
                runOnMain {
                    methodChannel.invokeMethod("onGroupRemoved", mapOf("success" to true))
                }
                callback(true)
            }
            
            override fun onFailure(reason: Int) {
                // Если ошибка = "нет группы для удаления" - это нормально
                val errorMsg = when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct не поддерживается"
                    WifiP2pManager.BUSY -> "Wi-Fi P2P занят"
                    WifiP2pManager.ERROR -> "Группа не найдена или уже удалена"
                    else -> "Неизвестная ошибка: $reason"
                }
                
                Log.w("P2P", "⚠️ [GROUP] Ошибка удаления группы: $errorMsg")
                isGroupOwner = false
                currentGroupName = null
                
                // Считаем успехом если группы нет (ERROR = 0 обычно означает "нечего удалять")
                val success = reason == WifiP2pManager.ERROR || reason == 0
                callback(success)
            }
        })
    }
    
    /**
     * Получает информацию о текущей группе
     */
    @SuppressLint("MissingPermission")
    fun getGroupInfo(callback: (GroupInfo?) -> Unit) {
        checkExistingGroup(callback)
    }
    
    /**
     * Автоматически создает группу если её нет
     * Идеально для автоматического mesh-режима
     */
    fun ensureGroupExists(callback: (GroupInfo?) -> Unit) {
        createGroup(forceCreate = false, callback = callback)
    }
    
    /**
     * Проверяет, является ли устройство владельцем группы
     */
    fun isCurrentlyGroupOwner(): Boolean {
        return isGroupOwner
    }
    
    /**
     * Получает имя текущей группы
     */
    fun getCurrentGroupName(): String? {
        return currentGroupName
    }
    
    /**
     * Данные о Wi-Fi Direct группе
     */
    data class GroupInfo(
        val networkName: String?,
        val passphrase: String?,
        val isGroupOwner: Boolean,
        val ownerAddress: String?,
        val clientCount: Int
    )
    
    /**
     * Очистка ресурсов при уничтожении
     * Вызывается из MainActivity.onDestroy()
     */
    fun cleanup() {
        deactivatePersistentLocks()
        unregisterReceiver()
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        scope.cancel()
    }
}
