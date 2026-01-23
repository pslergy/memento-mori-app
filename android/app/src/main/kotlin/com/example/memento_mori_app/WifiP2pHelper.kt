package com.example.memento_mori_app

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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

                        if (networkInfo?.isConnected == true) {
                            manager?.requestConnectionInfo(channel) { info ->
                                if (info != null && info.groupFormed && info.groupOwnerAddress != null) {
                                    val isHost = info.isGroupOwner
                                    val hostAddress = info.groupOwnerAddress.hostAddress
                                    if (wakeLock?.isHeld == false) wakeLock?.acquire(10 * 60 * 1000L)

                                    runOnMain {
                                        methodChannel.invokeMethod("onConnected", mapOf(
                                            "isHost" to isHost,
                                            "hostAddress" to hostAddress
                                        ))
                                    }
                                }
                            }
                        } else {
                            if (wakeLock?.isHeld == true) wakeLock?.release()
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
                Log.d("P2P", "✅ Discovery started successfully")
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
                
                Log.e("P2P", "❌ Discovery failed: $reason")
                // Коды ошибок:
                // P2P_UNSUPPORTED = 1
                // BUSY = 2
                // ERROR = 0 (обычно означает что discovery уже запущен или система занята)
                when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> {
                        Log.e("P2P", "Device does not support Wi-Fi Direct")
                    }
                    WifiP2pManager.BUSY -> {
                        Log.w("P2P", "P2P is busy, will retry later")
                    }
                    0 -> {
                        // ERROR = 0 часто означает что discovery уже активен или система занята
                        // В этом случае считаем discovery активным (Android может не дать запустить повторно)
                        _isDiscoveryActive = true
                        Log.d("P2P", "ℹ️ Discovery error 0 (likely already active or system busy) - marking as active")
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
    fun connect(hashedAddress: String) {
        val realMac = addressMap[hashedAddress] ?: return
        val config = WifiP2pConfig().apply {
            deviceAddress = realMac
            groupOwnerIntent = 15 // Форсируем роль владельца для стабильности моста
        }
        manager?.connect(channel, config, null)
    }

    fun sendTcp(host: String, port: Int, message: String) {
        scope.launch {
            try {
                Socket().use { socket ->
                    socket.tcpNoDelay = true
                    socket.soTimeout = 5000
                    socket.connect(InetSocketAddress(host, port), 5000)
                    val out = socket.getOutputStream()
                    val bytes = (message + "\n").toByteArray(StandardCharsets.UTF_8)
                    out.write(bytes)
                    out.flush()
                    Log.d("P2P_NET", "🚀 Burst delivered via P2P to $host")
                }
            } catch (e: Exception) {
                Log.e("P2P_NET", "Send Error: ${e.message}")
            }
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