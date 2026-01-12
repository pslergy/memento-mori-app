package com.example.memento_mori_app

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import android.util.Log
import kotlinx.coroutines.*
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket // 🔥 Обязательно для работы с клиентами
import java.nio.charset.StandardCharsets

class MeshBackgroundService : Service() {
    // Используем SupervisorJob, чтобы падение одного сокета не убивало весь сервис
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var serverSocket: ServerSocket? = null
    private var serviceJob: Job? = null // Переменная для управления циклом сервера
    private val MESH_PORT = 55555

    companion object {
        const val ACTION_MESSAGE_RECEIVED = "com.example.memento_mori_app.MESSAGE_RECEIVED"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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

        // Запуск TCP сервера
        startTcpServer()

        return START_STICKY
    }

    private fun startTcpServer() {
        serviceJob?.cancel() // Убиваем старый цикл, если он был
        serviceJob = serviceScope.launch {
            while (isActive) {
                var ss: ServerSocket? = null
                try {
                    // Биндимся на 0.0.0.0, чтобы слушать ВСЕ интерфейсы (4G + WiFi P2P)
                    ss = ServerSocket()
                    ss.reuseAddress = true
                    ss.bind(InetSocketAddress("0.0.0.0", MESH_PORT))
                    serverSocket = ss

                    Log.d("P2P_BG", "🛡️ Background Server Secured: Listening on $MESH_PORT")

                    while (isActive) {
                        // Ожидаем подключения
                        val client = try {
                            ss.accept()
                        } catch (e: Exception) {
                            null
                        } ?: break // Выход из цикла, если сокет закрыт извне

                        val remoteIp = client.inetAddress.hostAddress
                        Log.d("P2P_BG", "🔥 Signal detected from $remoteIp")

                        // Обработка клиента в отдельной корутине
                        serviceScope.launch {
                            handleClientSecurely(client, remoteIp)
                        }
                    }
                } catch (e: Exception) {
                    Log.e("P2P_BG", "Server Error: ${e.message}")
                    delay(3000) // Пауза перед автоматическим рестартом
                } finally {
                    try { ss?.close() } catch (e: Exception) {}
                }
            }
        }
    }

    private suspend fun handleClientSecurely(socket: Socket, remoteIp: String?) {
        try {
            socket.soTimeout = 5000 // Таймаут на чтение — 5 секунд
            val reader = socket.getInputStream().bufferedReader(StandardCharsets.UTF_8)
            val input = reader.readLine()

            if (!input.isNullOrEmpty()) {
                Log.d("P2P_BG", "📦 Packet captured from $remoteIp")

                // Отправляем Broadcast в MainActivity
                val broadcastIntent = Intent(ACTION_MESSAGE_RECEIVED).apply {
                    setPackage(packageName) // Для безопасности шлем только своему приложению
                    putExtra("message", input)
                    putExtra("senderIp", remoteIp)
                }
                sendBroadcast(broadcastIntent)
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

    override fun onDestroy() {
        Log.d("P2P_BG", "🔌 Shutting down Mesh service...")
        try { serverSocket?.close() } catch (e: Exception) {}
        serviceJob?.cancel()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

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