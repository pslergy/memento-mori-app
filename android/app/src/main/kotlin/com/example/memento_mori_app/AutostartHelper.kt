package com.example.memento_mori_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import android.app.Activity

/**
 * Утилита для проверки и настройки Autostart на китайских устройствах (Xiaomi/Poco)
 */
object AutostartHelper {
    private const val TAG = "AutostartHelper"
    
    /**
     * Проверяет, требуется ли проверка Autostart для текущего устройства
     */
    fun requiresAutostartCheck(): Boolean {
        return DeviceDetector.requiresAutostartCheck()
    }
    
    /**
     * Проверяет, включен ли Autostart для приложения
     * Возвращает true, если Autostart включен или проверка не требуется
     */
    fun isAutostartEnabled(context: Context): Boolean {
        if (!requiresAutostartCheck()) {
            return true // Не требуется проверка
        }
        
        val deviceInfo = DeviceDetector.detectDevice()
        
        // Для Xiaomi/Poco проверяем через Intent
        return when (deviceInfo.brand) {
            DeviceDetector.DeviceBrand.XIAOMI, DeviceDetector.DeviceBrand.POCO -> {
                checkXiaomiAutostart(context)
            }
            else -> true
        }
    }
    
    /**
     * Проверяет Autostart на Xiaomi/Poco устройствах
     */
    private fun checkXiaomiAutostart(context: Context): Boolean {
        // На Xiaomi/Poco нет прямого способа проверить статус Autostart через API
        // Поэтому всегда возвращаем false, чтобы показать диалог
        // Пользователь может вручную проверить в настройках
        return false
    }
    
    /**
     * Открывает настройки Autostart для приложения
     */
    fun openAutostartSettings(activity: Activity) {
        if (!requiresAutostartCheck()) {
            Log.d(TAG, "Autostart check not required for this device")
            return
        }
        
        val deviceInfo = DeviceDetector.detectDevice()
        
        when (deviceInfo.brand) {
            DeviceDetector.DeviceBrand.XIAOMI, DeviceDetector.DeviceBrand.POCO -> {
                openXiaomiAutostartSettings(activity)
            }
            else -> {
                Log.w(TAG, "Unknown device brand for Autostart: ${deviceInfo.brand}")
            }
        }
    }
    
    /**
     * Открывает настройки Autostart на Xiaomi/Poco
     */
    private fun openXiaomiAutostartSettings(activity: Activity) {
        val packageName = activity.packageName
        
        // Различные Intent для разных версий MIUI/HyperOS
        val intents = listOf(
            // MIUI 12+ / HyperOS
            Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            },
            // Альтернативный путь для MIUI
            Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.securitycenter.MainActivity"
                )
            },
            // Общие настройки приложения
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:$packageName")
            }
        )
        
        // Пробуем открыть каждый Intent по очереди
        for (intent in intents) {
            try {
                activity.startActivity(intent)
                Log.d(TAG, "✅ Opened Autostart settings: ${intent.component?.className}")
                return
            } catch (e: Exception) {
                Log.w(TAG, "Failed to open Autostart settings: ${e.message}")
            }
        }
        
        // Если ничего не сработало, открываем общие настройки приложения
        try {
            val fallbackIntent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:$packageName")
            }
            activity.startActivity(fallbackIntent)
            Log.d(TAG, "Opened fallback settings")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open fallback settings: ${e.message}")
        }
    }
    
    /**
     * Показывает диалог с инструкцией по включению Autostart
     */
    fun showAutostartDialog(activity: Activity, onOpenSettings: () -> Unit) {
        if (!requiresAutostartCheck()) return
        
        val deviceInfo = DeviceDetector.detectDevice()
        val instructions = when (deviceInfo.brand) {
            DeviceDetector.DeviceBrand.XIAOMI, DeviceDetector.DeviceBrand.POCO -> {
                when (deviceInfo.firmware) {
                    DeviceDetector.FirmwareType.HYPEROS -> {
                        """
                        Для стабильной работы Wi-Fi Direct в фоне необходимо включить автозапуск:
                        
                        1. Откройте "Настройки" → "Приложения" → "Автозапуск"
                        2. Найдите "${activity.applicationInfo.loadLabel(activity.packageManager)}"
                        3. Включите переключатель "Автозапуск"
                        
                        Это предотвратит остановку приложения системой в фоне.
                        """.trimIndent()
                    }
                    else -> {
                        """
                        Для стабильной работы Wi-Fi Direct в фоне необходимо включить автозапуск:
                        
                        1. Откройте "Безопасность" → "Автозапуск"
                        2. Найдите "${activity.applicationInfo.loadLabel(activity.packageManager)}"
                        3. Включите переключатель
                        
                        Это предотвратит остановку приложения системой в фоне.
                        """.trimIndent()
                    }
                }
            }
            else -> ""
        }
        
        if (instructions.isNotEmpty()) {
            android.app.AlertDialog.Builder(activity)
                .setTitle("Включите автозапуск")
                .setMessage(instructions)
                .setPositiveButton("Открыть настройки") { _, _ ->
                    onOpenSettings()
                }
                .setNegativeButton("Позже", null)
                .show()
        }
    }
}
