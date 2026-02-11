package com.example.memento_mori_app

import android.app.*
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket // 🔥 Обязательно для работы с клиентами
import java.nio.charset.StandardCharsets

class MeshBackgroundService : Service() {
    // Используем SupervisorJob, чтобы падение одного сокета не убивало весь сервис
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var serverSocket: ServerSocket? = null
    private var serviceJob: Job? = null // Переменная для управления циклом сервера
    private var temporaryServerJob: Job? = null // Для временного сервера
    private var temporaryServerSocket: ServerSocket? = null // Сокет временного сервера
    // 🔥 Единый порт 55556: и постоянный, и временный сервер (на Huawei часто поднимается только временный — клиент подключается к 55556)
    private val MESH_PORT = 55556
    private val BRIDGE_PULL_PORT = 55556 // Тот же порт для временного BRIDGE сервера
    private var dbHelper: BridgeQueueDbHelper? = null

    companion object {
        const val ACTION_MESSAGE_RECEIVED = "com.example.memento_mori_app.MESSAGE_RECEIVED"
        private var instance: MeshBackgroundService? = null

        fun startTemporaryServer(context: Context, durationSeconds: Int) {
            val intent = Intent(context, MeshBackgroundService::class.java).apply {
                putExtra("temporary", true)
                putExtra("duration", durationSeconds)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopTemporaryServer(context: Context) {
            instance?.stopTemporaryServerInternal()
        }

        fun getQueuedMessages(context: Context): List<Map<String, Any>> {
            return instance?.getQueuedMessagesInternal() ?: emptyList()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        dbHelper = BridgeQueueDbHelper(this)

        createNotificationChannel()

        // Создаем системное уведомление для работы в Foreground
        val notification = NotificationCompat.Builder(this, "MementoMoriMesh")
            .setContentTitle("Memento Mori: Mesh Active")
            .setContentText("Protecting your communication grid in the background...")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock) // Можно заменить на свою иконку
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        // Запуск сервиса в режиме "бессмертия"
        startForeground(1, notification)

        // 🔥 КРИТИЧЕСКИЙ ФИКС #1: Проверка GO и запуск TCP сервера — асинхронно
        // requestGroupInfo callback вызывается на Main Looper; runBlocking на Main приводил к дедлоку.
        val isTemporary = intent?.getBooleanExtra("temporary", false) ?: false
        val duration = intent?.getIntExtra("duration", 20) ?: 20

        serviceScope.launch(Dispatchers.Default) {
            val isGroupOwner = checkIfGroupOwnerAsync()
            if (!isGroupOwner) {
                Log.w("P2P_BG", "⚠️ Not Group Owner - TCP server not started (only GO can be server)")
                Log.w("P2P_BG", "   💡 This device is a client - will connect to GO's TCP server")
                return@launch
            }
            Log.d("P2P_BG", "✅ Device is Group Owner - TCP server can be started")
            bindToWifiDirectNetwork()
            if (!DeviceDetector.canStartTcpServer(this@MeshBackgroundService)) {
                Log.w("P2P_BG", "🚫 TCP server disabled - using BLE GATT instead")
                return@launch
            }
            withContext(Dispatchers.Main) {
                if (isTemporary) {
                    startTemporaryTcpServer(duration)
                } else {
                    startTcpServer()
                }
            }
        }

        return START_STICKY
    }

    private fun startTcpServer() {
        // GO уже проверен в onStartCommand (checkIfGroupOwnerAsync) перед вызовом с Main
        bindToWifiDirectNetwork()
        
        // 1. Убиваем старую задачу, если она жива
        serviceJob?.cancel()

        serviceJob = serviceScope.launch(Dispatchers.IO) {
            while (isActive) {
                var ss: ServerSocket? = null
                try {
                    // 2. Явно пытаемся закрыть старый серверный сокет, если он остался в памяти
                    serverSocket?.close()

                    ss = ServerSocket()
                    ss.reuseAddress = true // Позволяет занимать порт сразу после закрытия

                    // Пытаемся привязаться к порту
                    ss.bind(InetSocketAddress("0.0.0.0", MESH_PORT))
                    serverSocket = ss

                    Log.d("P2P_BG", "🛡️ SERVER REBORN on port $MESH_PORT (Group Owner confirmed)")
                    WifiP2pHelper.sendLogToFlutter("TCP", "🛡️ Server ACTIVE on port $MESH_PORT")

                    while (isActive) {
                        val client = try {
                            ss.accept()
                        } catch (e: Exception) {
                            null
                        } ?: break

                        val remoteIp = client.inetAddress.hostAddress
                        serviceScope.launch(Dispatchers.IO) {
                            handleClientSecurely(client, remoteIp)
                        }
                    }
                } catch (e: Exception) {
                    Log.e("P2P_BG", "🚨 Bind failed (Port $MESH_PORT): ${e.message}")

                    // 🔥 КРИТИЧЕСКИЙ ФИКС: Если сервер упал с первого раза - отмечаем краш
                    // При следующем запуске будет использоваться BLE GATT
                    DeviceDetector.markTcpServerCrashed(this@MeshBackgroundService)
                    
                    // 🔥 КРИТИЧЕСКИЙ ФИКС: Пауза перед рестартом.
                    // Без неё цикл крутится со скоростью процессора, забивая логи и вешая телефон.
                    delay(5000)
                } finally {
                    try { ss?.close() } catch (e: Exception) {}
                }
            }
        }
    }

    private suspend fun handleClientSecurely(socket: Socket, remoteIp: String?) {
        try {
            Log.d("P2P_BG", "🔌 [BRIDGE] New client connected from $remoteIp")
            WifiP2pHelper.sendLogToFlutter("TCP", "🔌 Client connected: $remoteIp")
            socket.soTimeout = 10000 // Таймаут на чтение — 10 секунд (для batch)
            val reader = socket.getInputStream().bufferedReader(StandardCharsets.UTF_8)
            val input = reader.readLine()
            Log.d("P2P_BG", "📥 [BRIDGE] Received data from $remoteIp: ${input?.take(100)}...")

            if (!input.isNullOrEmpty()) {
                try {
                    val json = JSONObject(input)
                    val type = json.optString("type")

                    when (type) {
                        "GHOST_UPLOAD" -> {
                            // Обработка batch загрузки от GHOST
                            handleGhostUpload(socket, json, remoteIp)
                        }
                        else -> {
                            // Стандартная обработка (для обратной совместимости)
                            Log.d("P2P_BG", "📦 Packet captured from $remoteIp")
                            WifiP2pHelper.sendLogToFlutter("TCP", "📦 Packet from $remoteIp type=$type")
                            val broadcastIntent = Intent(ACTION_MESSAGE_RECEIVED).apply {
                                setPackage(packageName)
                                putExtra("message", input)
                                putExtra("senderIp", remoteIp)
                            }
                            sendBroadcast(broadcastIntent)
                        }
                    }
                } catch (e: Exception) {
                    Log.e("P2P_BG", "JSON parse error: ${e.message}")
                    // Fallback на старую обработку
                    val broadcastIntent = Intent(ACTION_MESSAGE_RECEIVED).apply {
                        setPackage(packageName)
                        putExtra("message", input)
                        putExtra("senderIp", remoteIp)
                    }
                    sendBroadcast(broadcastIntent)
                }
            }
        } catch (e: Exception) {
            Log.e("P2P_BG", "Read error from $remoteIp: ${e.message}")
        } finally {
            // 🔥 РУЧНОЕ БЕЗОПАСНОЕ ЗАКРЫТИЕ (Защита от Fatal Signal 6 / fdsan)
            try {
                if (!socket.isClosed) {
                    socket.shutdownInput() // Сигнализируем о завершении чтения
                    socket.close() // Освобождаем дескриптор файла
                }
            } catch (e: Exception) {
                Log.e("P2P_BG", "Socket cleanup error: ${e.message}")
            }
        }
    }

    private suspend fun handleGhostUpload(socket: Socket, json: JSONObject, remoteIp: String?) {
        try {
            val token = json.optString("token")
            val batchId = json.optString("batchId")
            val senderId = json.optString("senderId")
            val messages = json.getJSONArray("messages")
            val count = json.optInt("count", 0)

            Log.d("P2P_BG", "📦 GHOST_UPLOAD from $senderId: $count messages (batch: $batchId)")
            WifiP2pHelper.sendLogToFlutter("TCP", "📦 UPLOAD: $count msg from GHOST")

            // Сохраняем в SQLite очередь
            dbHelper?.let { db ->
                val dbWritable = db.writableDatabase
                for (i in 0 until messages.length()) {
                    val msg = messages.getJSONObject(i)
                    val content = dbWritable.compileStatement(
                        "INSERT INTO bridge_queue (sender_id, batch_id, message_json, received_at, processed) VALUES (?, ?, ?, ?, 0)"
                    )
                    content.bindString(1, senderId)
                    content.bindString(2, batchId)
                    content.bindString(3, msg.toString())
                    content.bindLong(4, System.currentTimeMillis())
                    content.executeInsert()
                    content.close()
                }
            }

            // Отправляем ACK
            val ack = JSONObject().apply {
                put("type", "UPLOAD_ACK")
                put("batchId", batchId)
                put("received", count)
                put("status", "OK")
                put("processed", true)
            }

            val out = socket.getOutputStream()
            out.write((ack.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
            out.flush()

            Log.d("P2P_BG", "✅ ACK sent for batch $batchId")
        } catch (e: Exception) {
            Log.e("P2P_BG", "GHOST_UPLOAD error: ${e.message}")
            // Отправляем ошибку
            try {
                val errorAck = JSONObject().apply {
                    put("type", "UPLOAD_ACK")
                    put("status", "ERROR")
                    put("error", e.message)
                }
                val out = socket.getOutputStream()
                out.write((errorAck.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
                out.flush()
            } catch (e2: Exception) {
                Log.e("P2P_BG", "Failed to send error ACK: ${e2.message}")
            }
        }
    }

    private fun startTemporaryTcpServer(durationSeconds: Int) {
        // GO уже проверен в onStartCommand (checkIfGroupOwnerAsync) перед вызовом с Main
        bindToWifiDirectNetwork()
        // Закрываем предыдущий временный сервер, если он есть
        temporaryServerJob?.cancel()
        temporaryServerSocket?.close()
        temporaryServerSocket = null
        
        temporaryServerJob = serviceScope.launch(Dispatchers.IO) {
            var ss: ServerSocket? = null
            try {
                ss = ServerSocket()
                ss.reuseAddress = true
                ss.bind(InetSocketAddress("0.0.0.0", BRIDGE_PULL_PORT)) // Используем отдельный порт для временного сервера
                temporaryServerSocket = ss // Сохраняем ссылку для возможности закрытия извне
                // Не перезаписываем serverSocket, чтобы основной сервер продолжал работать

                Log.d("P2P_BG", "🛡️ TEMPORARY BRIDGE SERVER started on port $BRIDGE_PULL_PORT for ${durationSeconds}s")

                // Таймер для автоматического закрытия
                val timeoutJob = launch {
                    delay(durationSeconds * 1000L)
                    if (!ss.isClosed) {
                        Log.d("P2P_BG", "⏰ Temporary server timeout after ${durationSeconds}s, closing...")
                        try {
                            ss.close()
                        } catch (e: Exception) {
                            Log.e("P2P_BG", "Error closing server: ${e.message}")
                        }
                    }
                }

                while (ss != null && !ss.isClosed && isActive) {
                    val client = try {
                        Log.d("P2P_BG", "👂 [BRIDGE] Waiting for connections on port $BRIDGE_PULL_PORT...")
                        ss.accept()
                    } catch (e: Exception) {
                        // Различаем нормальное закрытие от ошибок
                        if (ss == null || ss.isClosed) {
                            Log.d("P2P_BG", "ℹ️ [BRIDGE] Server closed normally (timeout or stop requested)")
                        } else {
                            Log.e("P2P_BG", "❌ [BRIDGE] Accept error (server still open): ${e.message}")
                        }
                        break
                    }

                    val remoteIp = client.inetAddress.hostAddress
                    Log.d("P2P_BG", "✅ [BRIDGE] Client accepted from $remoteIp")
                    serviceScope.launch(Dispatchers.IO) {
                        handleClientSecurely(client, remoteIp)
                    }
                }

                timeoutJob.cancel()
            } catch (e: Exception) {
                Log.e("P2P_BG", "Temporary server error: ${e.message}")
                
                // 🔥 КРИТИЧЕСКИЙ ФИКС: Если временный сервер упал - отмечаем краш
                DeviceDetector.markTcpServerCrashed(this@MeshBackgroundService)
            } finally {
                // Очищаем ссылку на сокет
                if (temporaryServerSocket == ss) {
                    temporaryServerSocket = null
                }
                ss?.close()
                Log.d("P2P_BG", "🧹 [BRIDGE] Temporary server socket cleaned up")
            }
        }
    }

    private fun stopTemporaryServerInternal() {
        Log.d("P2P_BG", "🛑 [BRIDGE] Stopping temporary server...")
        temporaryServerJob?.cancel()
        try {
            // Закрываем временный серверный сокет, а не основной serverSocket
            temporaryServerSocket?.close()
            temporaryServerSocket = null
        } catch (e: Exception) {
            Log.e("P2P_BG", "Stop temporary server error: ${e.message}")
        }
        Log.d("P2P_BG", "✅ [BRIDGE] Temporary server stop requested")
    }

    private fun getQueuedMessagesInternal(): List<Map<String, Any>> {
        val messages = mutableListOf<Map<String, Any>>()
        dbHelper?.let { db ->
            val dbReadable = db.readableDatabase
            val cursor = dbReadable.rawQuery(
                "SELECT id, sender_id, batch_id, message_json, received_at FROM bridge_queue WHERE processed = 0 ORDER BY received_at ASC LIMIT 100",
                null
            )
            while (cursor.moveToNext()) {
                messages.add(mapOf(
                    "id" to cursor.getLong(0),
                    "senderId" to cursor.getString(1),
                    "batchId" to cursor.getString(2),
                    "message" to cursor.getString(3),
                    "receivedAt" to cursor.getLong(4)
                ))
            }
            cursor.close()
        }
        return messages
    }

    override fun onDestroy() {
        Log.d("P2P_BG", "🔌 Shutting down Mesh service...")
        instance = null
        try { serverSocket?.close() } catch (e: Exception) {}
        serviceJob?.cancel()
        temporaryServerJob?.cancel()
        serviceScope.cancel()
        dbHelper?.close()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Асинхронная проверка GO для использования из корутины (Default dispatcher).
     * Не блокирует Main — callback requestGroupInfo может выполниться на Main Looper.
     */
    private suspend fun checkIfGroupOwnerAsync(): Boolean {
        return try {
            val wifiP2pManager = getSystemService(Context.WIFI_P2P_SERVICE) as? android.net.wifi.p2p.WifiP2pManager
                ?: run {
                Log.w("P2P_BG", "⚠️ WifiP2pManager not available")
                return false
            }
            val channel = wifiP2pManager.initialize(applicationContext, Looper.getMainLooper(), null)
                ?: run {
                Log.w("P2P_BG", "⚠️ Failed to initialize WifiP2pManager channel")
                return false
            }

            val deferred = CompletableDeferred<Boolean>()
            var retryCount = 0
            val maxRetries = 8

            fun checkGroupInfo() {
                wifiP2pManager.requestGroupInfo(channel) { group ->
                    if (group != null && group.isGroupOwner) {
                        Log.d("P2P_BG", "📋 Group info (requestGroupInfo): isGroupOwner=true, networkName=${group.networkName}")
                        deferred.complete(true)
                    } else {
                        if (group != null) {
                            Log.d("P2P_BG", "📋 Group info (requestGroupInfo): group exists but we are not owner")
                            deferred.complete(false)
                        } else if (retryCount < maxRetries) {
                            retryCount++
                            Log.d("P2P_BG", "📋 No group yet, retry $retryCount/$maxRetries in 1.2s...")
                            Handler(Looper.getMainLooper()).postDelayed({ checkGroupInfo() }, 1200)
                        } else {
                            Log.d("P2P_BG", "📋 No active group found after $maxRetries retries")
                            deferred.complete(false)
                        }
                    }
                }
            }

            // Запускаем запрос на Main Looper; await на текущем (Default) — Main свободен для callback
            withContext(Dispatchers.Main.immediate) { checkGroupInfo() }
            deferred.awaitWithTimeout(15000) ?: false
        } catch (e: Exception) {
            Log.e("P2P_BG", "❌ Error checking Group Owner status: ${e.message}")
            false
        }
    }

    
    /**
     * 🔥 КРИТИЧЕСКИЙ ФИКС #3: Привязывает процесс к Wi-Fi Direct сети (Android 10+)
     * Без этого сокеты могут идти через мобильную сеть вместо Wi-Fi Direct
     */
    private fun bindToWifiDirectNetwork() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            Log.d("P2P_BG", "ℹ️ Android < 6.0 - network binding not required")
            return
        }
        
        try {
            val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (connectivityManager == null) {
                Log.w("P2P_BG", "⚠️ ConnectivityManager not available")
                return
            }
            
            val networks = connectivityManager.allNetworks
            var wifiDirectNetwork: Network? = null
            
            for (network in networks) {
                val capabilities = connectivityManager.getNetworkCapabilities(network)
                if (capabilities != null) {
                    // 🔥 FIX: TRANSPORT_WIFI_DIRECT не существует в API
                    // Wi-Fi Direct сети определяем по:
                    // 1. Wi-Fi транспорт
                    // 2. Отсутствие интернета (Wi-Fi Direct обычно не имеет интернета)
                    // 3. Или наличие Wi-Fi с локальным IP (192.168.49.x)
                    val hasWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    
                    // Wi-Fi Direct обычно не имеет интернета, но имеет Wi-Fi транспорт
                    // Также проверяем наличие Wi-Fi транспорта (может быть Wi-Fi Direct или обычный Wi-Fi)
                    if (hasWifi) {
                        wifiDirectNetwork = network
                        Log.d("P2P_BG", "✅ Found Wi-Fi network (Wi-Fi Direct or regular Wi-Fi): ${network}")
                        Log.d("P2P_BG", "   📋 Has Internet: $hasInternet")
                        break
                    }
                }
            }
            
            if (wifiDirectNetwork != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // Привязываем процесс к Wi-Fi Direct сети
                val success = connectivityManager.bindProcessToNetwork(wifiDirectNetwork)
                if (success) {
                    Log.d("P2P_BG", "✅ Process bound to Wi-Fi Direct network")
                } else {
                    Log.w("P2P_BG", "⚠️ Failed to bind process to network")
                }
            } else {
                Log.w("P2P_BG", "⚠️ Wi-Fi Direct network not found - sockets may use mobile network")
            }
        } catch (e: Exception) {
            Log.e("P2P_BG", "❌ Failed to bind to Wi-Fi Direct network: ${e.message}")
        }
    }
    
    /**
     * Extension для CompletableDeferred с таймаутом
     */
    private suspend fun <T> CompletableDeferred<T>.awaitWithTimeout(timeoutMs: Long): T? {
        return try {
            withTimeout(timeoutMs) {
                await()
            }
        } catch (e: TimeoutCancellationException) {
            null
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "MementoMoriMesh",
                "Mesh Network Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Handles background mesh communication and data relaying."
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}

// SQLite Helper для очереди сообщений на BRIDGE
class BridgeQueueDbHelper(context: Context) : SQLiteOpenHelper(context, "bridge_queue.db", null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE bridge_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sender_id TEXT NOT NULL,
                batch_id TEXT NOT NULL,
                message_json TEXT NOT NULL,
                received_at INTEGER NOT NULL,
                processed INTEGER DEFAULT 0,
                uploaded_at INTEGER
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX idx_processed ON bridge_queue(processed)")
        db.execSQL("CREATE INDEX idx_received_at ON bridge_queue(received_at)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS bridge_queue")
        onCreate(db)
    }
}