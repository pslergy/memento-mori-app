package com.example.memento_mori_app

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Доставка mesh TCP (Wi‑Fi Direct :55556) во Flutter, пока жив только [MethodChannel].
 * Раньше broadcast ловила [MainActivity] и снималась в onDestroy — пакеты терялись.
 * Очередь: если TCP пришёл до configureFlutterEngine, сообщения буферизуются и сливаются при attach.
 */
object MeshTcpFlutterBridge {
    private const val TAG = "MeshTcpFlutterBridge"
    private const val MAX_PENDING = 64

    private val lock = Any()
    private var channel: MethodChannel? = null
    private val pending = mutableListOf<Pair<String, String?>>()
    private val mainHandler = Handler(Looper.getMainLooper())

    @JvmStatic
    fun attach(ch: MethodChannel) {
        mainHandler.post {
            synchronized(lock) {
                channel = ch
                val toFlush = pending.toList()
                pending.clear()
                val c = channel
                if (c != null) {
                    for ((msg, ip) in toFlush) {
                        invokeUnsafe(c, msg, ip)
                    }
                    if (toFlush.isNotEmpty()) {
                        Log.d(TAG, "Flushed ${toFlush.size} pending mesh TCP message(s) to Flutter")
                    }
                }
            }
        }
    }

    /** Вызывать из [MainActivity.onDestroy], чтобы не держать мёртвый channel. */
    @JvmStatic
    fun detach() {
        mainHandler.post {
            synchronized(lock) {
                channel = null
            }
        }
    }

    /**
     * Вызывается из [Application] при broadcast [MeshBackgroundService.ACTION_MESSAGE_RECEIVED].
     * Всегда с main thread (post), т.к. [MethodChannel.invokeMethod] требует UI isolate.
     */
    @JvmStatic
    fun deliverMeshTcpMessage(message: String?, senderIp: String?) {
        if (message.isNullOrEmpty()) return
        mainHandler.post {
            synchronized(lock) {
                val c = channel
                if (c != null) {
                    invokeUnsafe(c, message, senderIp)
                } else {
                    if (pending.size >= MAX_PENDING) {
                        pending.removeAt(0)
                        Log.w(TAG, "Pending queue full — dropped oldest mesh TCP message")
                    }
                    pending.add(message to senderIp)
                    Log.w(TAG, "Flutter channel not ready — queued mesh TCP (${pending.size} pending)")
                }
            }
        }
    }

    private fun invokeUnsafe(ch: MethodChannel, message: String, senderIp: String?) {
        try {
            ch.invokeMethod(
                "onMessageReceived",
                mapOf("message" to message, "senderIp" to (senderIp ?: "")),
            )
        } catch (e: Exception) {
            Log.e(TAG, "invokeMethod onMessageReceived failed: ${e.message}")
        }
    }
}
