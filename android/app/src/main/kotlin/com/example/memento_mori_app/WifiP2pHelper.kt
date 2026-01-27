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
    // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
    // ============================================================================
    
    /**
     * Генерирует уникальное имя для Wi-Fi Direct группы
     * Формат: MESH_<userId_short>_<timestamp_short>
     */
    private fun generateGroupName(): String {
        val timestamp = (System.currentTimeMillis() / 1000) % 10000 // Последние 4 цифры timestamp
        val random = (Math.random() * 1000).toInt()
        return "MESH_${timestamp}_$random"
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
        
        Log.d("P2P", "🔍 [GROUP] Проверяем существующую группу...")
        
        manager?.requestGroupInfo(channel) { group ->
            if (group != null) {
                val info = GroupInfo(
                    networkName = group.networkName,
                    passphrase = group.passphrase,
                    isGroupOwner = group.isGroupOwner,
                    ownerAddress = group.owner?.deviceAddress,
                    clientCount = group.clientList?.size ?: 0
                )
                Log.d("P2P", "✅ [GROUP] Найдена группа: ${info.networkName}")
                Log.d("P2P", "   📋 Владелец: ${if (info.isGroupOwner) "Мы" else info.ownerAddress}")
                Log.d("P2P", "   📋 Клиентов: ${info.clientCount}")
                Log.d("P2P", "   📋 Passphrase: ${info.passphrase?.take(4)}...")
                
                isGroupOwner = info.isGroupOwner
                currentGroupName = info.networkName
                callback(info)
            } else {
                Log.d("P2P", "ℹ️ [GROUP] Активная группа не найдена")
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
        
        Log.d("P2P", "🚀 [GROUP] Начинаем создание Wi-Fi Direct группы...")
        Log.d("P2P", "   📋 forceCreate: $forceCreate")
        
        // Сначала проверяем существующую группу
        checkExistingGroup { existingGroup ->
            if (existingGroup != null && !forceCreate) {
                // Группа уже есть и мы не хотим её пересоздавать
                Log.d("P2P", "✅ [GROUP] Используем существующую группу: ${existingGroup.networkName}")
                
                if (existingGroup.isGroupOwner) {
                    // Мы владелец - отлично!
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
                    Log.d("P2P", "ℹ️ [GROUP] Мы клиент в чужой группе, пропускаем создание")
                    callback(existingGroup)
                }
                return@checkExistingGroup
            }
            
            // Нужно создать новую группу
            if (existingGroup != null && forceCreate) {
                // Удаляем старую группу перед созданием новой
                Log.d("P2P", "🗑️ [GROUP] Удаляем существующую группу перед созданием новой...")
                removeGroup { removed ->
                    if (removed) {
                        // Небольшая задержка для стабилизации
                        scope.launch {
                            delay(500)
                            createNewGroup(callback)
                        }
                    } else {
                        Log.e("P2P", "❌ [GROUP] Не удалось удалить старую группу")
                        callback(null)
                    }
                }
            } else {
                // Создаем новую группу
                createNewGroup(callback)
            }
        }
    }
    
    /**
     * Внутренний метод создания новой группы
     */
    @SuppressLint("MissingPermission")
    private fun createNewGroup(callback: (GroupInfo?) -> Unit) {
        isGroupCreating = true
        val groupName = generateGroupName()
        
        Log.d("P2P", "📡 [GROUP] Создаем группу: $groupName")
        Log.d("P2P", "   📋 Устройство: ${deviceInfo.brand} ${deviceInfo.model}")
        
        // 🔥 ФИКС ДЛЯ КИТАЙСКИХ УСТРОЙСТВ: Захватываем locks перед созданием группы
        acquireMulticastLock()
        acquireWifiLock()
        
        manager?.createGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d("P2P", "✅ [GROUP] Команда создания группы успешна, ждем подтверждения...")
                
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
                            
                            Log.d("P2P", "✅ [GROUP] Группа создана успешно!")
                            Log.d("P2P", "   📋 SSID: ${info.networkName}")
                            Log.d("P2P", "   📋 Passphrase: ${info.passphrase}")
                            Log.d("P2P", "   📋 Владелец: ${info.ownerAddress}")
                            
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
                            Log.e("P2P", "❌ [GROUP] Группа создана, но информация не получена")
                            runOnMain {
                                methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                                    "error" to "GROUP_INFO_UNAVAILABLE",
                                    "message" to "Группа создана, но информация недоступна"
                                ))
                            }
                            callback(null)
                        }
                    }
                }
            }
            
            override fun onFailure(reason: Int) {
                isGroupCreating = false
                val errorMsg = when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct не поддерживается"
                    WifiP2pManager.BUSY -> "Wi-Fi P2P занят"
                    WifiP2pManager.ERROR -> "Внутренняя ошибка Wi-Fi P2P"
                    else -> "Неизвестная ошибка: $reason"
                }
                
                Log.e("P2P", "❌ [GROUP] Ошибка создания группы: $errorMsg (code: $reason)")
                
                // Retry логика для BUSY состояния
                if (reason == WifiP2pManager.BUSY && groupCreationRetries < MAX_GROUP_RETRIES) {
                    groupCreationRetries++
                    Log.d("P2P", "🔄 [GROUP] Повторная попытка ${groupCreationRetries}/$MAX_GROUP_RETRIES через 2 секунды...")
                    
                    scope.launch {
                        delay(2000)
                        createNewGroup(callback)
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
        })
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