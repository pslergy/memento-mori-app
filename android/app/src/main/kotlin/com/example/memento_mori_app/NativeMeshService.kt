package com.example.memento_mori_app

import android.content.Context
import android.content.Intent
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NativeMeshService(
    private val context: Context, // Добавляем контекст
    private val manager: WifiP2pManager,
    private val p2pChannel: WifiP2pManager.Channel,
    private val p2pHelper: WifiP2pHelper?
) : MethodChannel.MethodCallHandler {

    private val uiHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 🔥 ПЕРЕНОСИМ ЛОГИКУ ЗАПУСКА СЕРВИСА СЮДА
            "startMeshService" -> {
                val intent = Intent(context, MeshBackgroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success(true)
            }

            "stopMeshService" -> {
                context.stopService(Intent(context, MeshBackgroundService::class.java))
                result.success(true)
            }

            "runFrequencySweep" -> {
                Thread {
                    try {
                        val spectrum = UltrasonicCalibrator.runSweep()
                        uiHandler.post { result.success(spectrum) }
                    } catch (e: Exception) {
                        uiHandler.post { result.error("FFT_ERROR", e.message, null) }
                    }
                }.start()
            }

            "startDiscovery" -> {
                p2pHelper?.startDiscovery()
                result.success(true)
            }

            "stopDiscovery" -> {
                manager.stopPeerDiscovery(p2pChannel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { result.success(true) }
                    override fun onFailure(r: Int) { result.error("P2P_ERR", "Stop failed: $r", null) }
                })
            }

            "connect" -> {
                val addr = call.argument<String>("deviceAddress")
                if (addr != null) {
                    p2pHelper?.connect(addr)
                    result.success(true)
                } else result.error("ERR", "No address", null)
            }

            "sendTcp" -> {
                val host = call.argument<String>("host") ?: "192.168.49.1"
                val msg = call.argument<String>("message") ?: ""
                p2pHelper?.sendTcp(host, 55555, msg)
                result.success(true)
            }

            "forceReset" -> {
                p2pHelper?.forceReset { result.success(true) }
            }

            else -> result.notImplemented()
        }
    }
}