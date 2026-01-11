package com.example.memento_mori_app

import androidx.annotation.NonNull
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import android.content.ComponentName
import android.content.pm.PackageManager
import android.util.Log

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL_P2P = "memento/wifi_direct"
    private val CHANNEL_GOOGLE = "google_play_services"
    private val CHANNEL_SECURITY = "memento/security"

    private var p2pHelper: WifiP2pHelper? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // --- 1. КАНАЛ ДЛЯ WI-FI P2P ---
        val p2pChannel = MethodChannel(messenger, CHANNEL_P2P)
        try {
            p2pHelper = WifiP2pHelper(this, this, p2pChannel)
        } catch (e: Exception) {
            Log.e("P2P", "Ошибка инициализации P2P: ${e.message}")
        }

        p2pChannel.setMethodCallHandler { call, result ->
            when (call.method) {
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
                    val port = call.argument<Int>("port") ?: 8888
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

        // --- 3. КАНАЛ БЕЗОПАСНОСТИ (Обфускация экрана и смена иконки) ---
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
                    val targetIcon = call.argument<String>("targetIcon") // "Calculator" или "Notes"
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

    // 🔥 ЛОГИКА "ХАМЕЛЕОНА": Переключение Activity Alias
    private fun changeAppIcon(target: String) {
        val pkg = packageName
        val clsCalc = "$pkg.MainActivityCalculator"
        val clsNotes = "$pkg.MainActivityNotes"
        val pm = packageManager

        val (enable, disable) = if (target == "Notes") clsNotes to clsCalc else clsCalc to clsNotes

        try {
            // Сначала выключаем старый, потом включаем новый
            pm.setComponentEnabledSetting(
                ComponentName(pkg, disable),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                0 // УБИРАЕМ DONT_KILL_APP, чтобы процесс завершился чисто
            )

            pm.setComponentEnabledSetting(
                ComponentName(pkg, enable),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                0
            )

            // Приложение закроется само через секунду
            Log.d("STEALTH", "Identity switched. Android will now restart the launcher.")
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
        try {
            p2pHelper?.unregisterReceiver()
        } catch (e: Exception) {}
    }
}