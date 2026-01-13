package com.example.memento_mori_app

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
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

    init {
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)

        // 🔥 ФИКС ДЛЯ HUAWEI: Максимальный приоритет для перехвата P2P событий в фоне
        intentFilter.priority = 999

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Memento:MeshWakeLock")
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

    fun registerReceiver() {
        if (receiver != null || !ensureP2pInitialized()) return
        receiver = object : BroadcastReceiver() {
            @SuppressLint("MissingPermission")
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
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

    @SuppressLint("MissingPermission")
    fun startDiscovery() { if (ensureP2pInitialized()) manager?.discoverPeers(channel, null) }

    fun stopDiscovery() { if (ensureP2pInitialized()) manager?.stopPeerDiscovery(channel, null) }

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
}