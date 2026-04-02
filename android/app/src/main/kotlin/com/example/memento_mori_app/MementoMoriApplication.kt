package com.example.memento_mori_app

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log

/**
 * Регистрирует приём mesh TCP broadcast на уровне процесса, не [MainActivity].
 * Иначе после onDestroy активити входящие JSON не доходят до Flutter.
 */
class MementoMoriApplication : Application() {

    private val meshTcpReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != MeshBackgroundService.ACTION_MESSAGE_RECEIVED) return
            val msg = intent.getStringExtra("message")
            val ip = intent.getStringExtra("senderIp")
            MeshTcpFlutterBridge.deliverMeshTcpMessage(msg, ip)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter(MeshBackgroundService.ACTION_MESSAGE_RECEIVED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(meshTcpReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(meshTcpReceiver, filter)
            }
            Log.d(TAG, "Mesh TCP broadcast receiver registered (process-level)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register mesh TCP receiver: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "MementoMoriApp"
    }
}
