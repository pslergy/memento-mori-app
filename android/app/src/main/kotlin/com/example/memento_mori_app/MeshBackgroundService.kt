package com.example.memento_mori_app

import android.app.*
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import android.util.Log
import kotlinx.coroutines.*
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets

class MeshBackgroundService : Service() {
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var serverSocket: ServerSocket? = null
    private val MESH_PORT = 55555

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "MementoMoriMesh"
        // Создаем уведомление (обязательно для Foreground)
        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Memento Mori: Active")
            .setContentText("Mesh Link is alive in background")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .build()

        startForeground(1, notification)

        // 🔥 ЗАПУСКАЕМ СЕРВЕР В СЕРВИСЕ (а не в Activity)
        startTcpServer()

        return START_STICKY
    }

    private fun startTcpServer() {
        serviceScope.launch {
            try {
                serverSocket = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress("0.0.0.0", MESH_PORT))
                }
                while (isActive) {
                    val client = serverSocket?.accept() ?: break
                    serviceScope.launch {
                        client.use { s ->
                            val input = s.getInputStream().bufferedReader(StandardCharsets.UTF_8).readLine()
                            if (!input.isNullOrEmpty()) {
                                // Шлем данные во Flutter через Broadcast или статический доступ
                                // Для теста просто логируем
                                Log.d("P2P_NET", "📩 Background Packet: $input")

                                // Отправляем интент в MainActivity, чтобы Flutter проснулся
                                val intent = Intent("com.example.memento_mori_app.MESSAGE_RECEIVED")
                                intent.putExtra("message", input)
                                intent.putExtra("senderIp", client.inetAddress.hostAddress)
                                sendBroadcast(intent)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("P2P_NET", "Background Server Error: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        serverSocket?.close()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}