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
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
class WifiP2pHelper(
    private val context: Context,
    private val activity: android.app.Activity,
    private val methodChannel: MethodChannel
) {
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private val intentFilter = IntentFilter()

    // Пул потоков для сетевых операций (Dutch Engineering Style: Resource Management)
    private val networkExecutor = Executors.newFixedThreadPool(4).asCoroutineDispatcher()
    private val scope = CoroutineScope(networkExecutor + SupervisorJob())

    private val addressMap = mutableMapOf<String, String>()
    private var wakeLock: PowerManager.WakeLock? = null
    private val MESH_PORT = 55555 // Смещаемся на более свободный порт

    init {
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        intentFilter.addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)

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
                                mapOf("id" to hashedMac, "name" to (it.deviceName ?: "Ghost Node"), "type" to "mesh", "metadata" to hashedMac)
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
                                        methodChannel.invokeMethod("onConnected", mapOf("isHost" to isHost, "hostAddress" to hostAddress))
                                    }
                                    startTcpServer(MESH_PORT)
                                }
                            }
                        } else {
                            stopTcpServer()
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
        stopTcpServer()
    }

    @SuppressLint("MissingPermission")
    fun startDiscovery() { manager?.discoverPeers(channel, null) }

    fun stopDiscovery() { manager?.stopPeerDiscovery(channel, null) }

    @SuppressLint("MissingPermission")
    fun connect(hashedAddress: String) {
        val realMac = addressMap[hashedAddress] ?: return
        val config = WifiP2pConfig().apply { deviceAddress = realMac; groupOwnerIntent = 15 }
        manager?.connect(channel, config, null)
    }

    // --- СЕКЦИЯ ТРАНСПОРТА (TCP) ---

    fun sendTcp(host: String, port: Int, message: String) {
        scope.launch {
            try {
                Socket().use { socket ->
                    socket.tcpNoDelay = true
                    socket.soTimeout = 5000
                    socket.connect(InetSocketAddress(host, port), 5000)

                    val outputStream = socket.getOutputStream()
                    // Используем UTF_8 явно (Dutch precision)
                    val bytes = (message + "\n").toByteArray(StandardCharsets.UTF_8)
                    outputStream.write(bytes)
                    outputStream.flush()
                    Log.d("P2P_NET", "Burst delivered to $host")
                }
            } catch (e: Exception) {
                Log.e("P2P_NET", "Send failure: ${e.message}")
            }
        }
    }

    private var serverJob: Job? = null
    private var serverSocket: ServerSocket? = null

    private fun stopTcpServer() {
        serverJob?.cancel()
        try { serverSocket?.close() } catch (e: Exception) {}
        serverSocket = null
    }

    private fun startTcpServer(port: Int) {
        serverJob?.cancel()
        serverJob = scope.launch {
            while (isActive) { // Авто-рестарт сервера при падении
                try {
                    serverSocket = ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress("0.0.0.0", port))
                    }
                    Log.d("P2P_NET", "✅ SERVER LIVE on $port")

                    while (isActive) {
                        val client = serverSocket?.accept() ?: break
                        val remoteIp = client.inetAddress.hostAddress

                        scope.launch {
                            try {
                                client.use { s ->
                                    val reader = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))
                                    val input = reader.readLine()
                                    if (!input.isNullOrEmpty()) {
                                        runOnMain {
                                            methodChannel.invokeMethod("onMessageReceived", mapOf(
                                                "message" to input,
                                                "senderIp" to remoteIp
                                            ))
                                        }
                                    }
                                }
                            } catch (e: Exception) { Log.e("P2P_NET", "Read Error") }
                        }
                    }
                } catch (e: Exception) {
                    Log.e("P2P_NET", "Server Error, retrying in 2s: ${e.message}")
                    delay(2000) // Пауза перед рестартом
                } finally {
                    try { serverSocket?.close() } catch (e: Exception) {}
                }
            }
        }
    }

    private fun runOnMain(block: () -> Unit) { activity.runOnUiThread { block() } }
}