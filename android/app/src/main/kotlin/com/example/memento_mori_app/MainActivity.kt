package com.example.memento_mori_app

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.annotation.NonNull
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL_P2P = "memento/wifi_direct"
    private val CHANNEL_GOOGLE = "google_play_services"
    private val CHANNEL_SECURITY = "memento/security"

    private var p2pHelper: WifiP2pHelper? = null
    private var p2pChannel: MethodChannel? = null

    // 🔥 ПРИЕМНИК ДЛЯ СВЯЗИ: Background Service -> Flutter
    private val messageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val msg = intent.getStringExtra("message")
            val ip = intent.getStringExtra("senderIp")

            // Пробрасываем данные во Flutter через MethodChannel
            // runOnUiThread гарантирует, что вызов будет в главном потоке Flutter
            runOnUiThread {
                p2pChannel?.invokeMethod("onMessageReceived", mapOf(
                    "message" to msg,
                    "senderIp" to ip
                ))
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Регистрируем фильтр для прослушки сообщений от фонового сервиса
        val filter = IntentFilter("com.example.memento_mori_app.MESSAGE_RECEIVED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(messageReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(messageReceiver, filter)
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        p2pChannel = MethodChannel(messenger, CHANNEL_P2P)

        try {
            p2pHelper = WifiP2pHelper(this, this, p2pChannel!!)
        } catch (e: Exception) {
            Log.e("P2P", "Ошибка инициализации P2P: ${e.message}")
        }

        p2pChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 🔥 ЗАПУСК "БЕССМЕРТНОГО" СЕРВИСА
                "startMeshService" -> {
                    val serviceIntent = Intent(this, MeshBackgroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(true)
                }

                "stopMeshService" -> {
                    stopService(Intent(this, MeshBackgroundService::class.java))
                    result.success(true)
                }

                "startDiscovery" -> {
                    p2pHelper?.startDiscovery()
                    result.success(true)
                }

                "stopDiscovery" -> {
                    p2pHelper?.stopDiscovery()
                    result.success(true)
                }

                "connect" -> {
                    val address = call.argument<String>("deviceAddress")
                    if (address != null) {
                        p2pHelper?.connect(address)
                        result.success(true)
                    } else result.error("ERR", "No address", null)
                }

                "sendTcp" -> {
                    val host = call.argument<String>("host") ?: "192.168.49.1"
                    val port = call.argument<Int>("port") ?: 55555
                    val msg = call.argument<String>("message")
                    if (msg != null) {
                        p2pHelper?.sendTcp(host, port, msg)
                        result.success(true)
                    } else result.error("ERR", "No message", null)
                }

                else -> result.notImplemented()
            }
        }

        // --- 2. КАНАЛ ДЛЯ GOOGLE SERVICES ---
        MethodChannel(messenger, CHANNEL_GOOGLE).setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                try {
                    val api = GoogleApiAvailability.getInstance()
                    val status = api.isGooglePlayServicesAvailable(this)
                    result.success(status == ConnectionResult.SUCCESS)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }

        // --- 3. КАНАЛ БЕЗОПАСНОСТИ ---
        MethodChannel(messenger, CHANNEL_SECURITY).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureMode" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(true)
                }
                "disableSecureMode" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(true)
                }
                "changeIcon" -> {
                    val targetIcon = call.argument<String>("targetIcon")
                    if (targetIcon != null) {
                        changeAppIcon(targetIcon)
                        result.success(true)
                    } else {
                        result.error("ERR", "Icon name is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // 🔥 ЛОГИКА "ХАМЕЛЕОНА"
    private fun changeAppIcon(target: String) {
        val pkg = packageName
        val clsCalc = "$pkg.MainActivityCalculator"
        val clsNotes = "$pkg.MainActivityNotes"
        val pm = packageManager

        val (enable, disable) = if (target == "Notes") clsNotes to clsCalc else clsCalc to clsNotes

        try {
            pm.setComponentEnabledSetting(
                ComponentName(pkg, disable),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                0
            )

            pm.setComponentEnabledSetting(
                ComponentName(pkg, enable),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                0
            )
            Log.d("STEALTH", "Identity switched to $target")
        } catch (e: Exception) {
            Log.e("STEALTH", "Error: ${e.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            p2pHelper?.registerReceiver()
        } catch (e: Exception) {}
    }

    override fun onPause() {
        super.onPause()
        // ВАЖНО: Мы НЕ отключаем ресивер P2P в паузе,
        // чтобы Mesh-сеть продолжала работать, когда приложение свернуто.
        // Мы только отключаем системные анонсы, если это необходимо.
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(messageReceiver)
        } catch (e: Exception) {}
        p2pHelper?.unregisterReceiver()
        super.onDestroy()
    }
}