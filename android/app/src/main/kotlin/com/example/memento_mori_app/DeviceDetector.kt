package com.example.memento_mori_app

import android.os.Build
import android.util.Log

/**
 * Утилита для определения производителя устройства и прошивки
 * Используется для применения специфичных фиксов для китайских устройств
 */
object DeviceDetector {
    private const val TAG = "DeviceDetector"
    
    enum class DeviceBrand {
        XIAOMI, POCO, TECNO, INFINIX, HUAWEI, HONOR, OPPO, VIVO, REALME, OTHER
    }
    
    enum class FirmwareType {
        MIUI, HYPEROS, XOS, HIOS, OTHER
    }
    
    data class DeviceInfo(
        val brand: DeviceBrand,
        val firmware: FirmwareType,
        val manufacturer: String,
        val model: String,
        val androidVersion: Int
    )
    
    /**
     * Определяет информацию об устройстве
     */
    fun detectDevice(): DeviceInfo {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        val model = Build.MODEL
        val androidVersion = Build.VERSION.SDK_INT
        
        // Определение бренда
        val deviceBrand = when {
            manufacturer.contains("xiaomi") || brand.contains("xiaomi") -> DeviceBrand.XIAOMI
            manufacturer.contains("poco") || brand.contains("poco") -> DeviceBrand.POCO
            manufacturer.contains("tecno") || brand.contains("tecno") -> DeviceBrand.TECNO
            manufacturer.contains("infinix") || brand.contains("infinix") -> DeviceBrand.INFINIX
            manufacturer.contains("huawei") || brand.contains("huawei") -> DeviceBrand.HUAWEI
            manufacturer.contains("honor") || brand.contains("honor") -> DeviceBrand.HONOR
            manufacturer.contains("oppo") || brand.contains("oppo") -> DeviceBrand.OPPO
            manufacturer.contains("vivo") || brand.contains("vivo") -> DeviceBrand.VIVO
            manufacturer.contains("realme") || brand.contains("realme") -> DeviceBrand.REALME
            else -> DeviceBrand.OTHER
        }
        
        // Определение прошивки
        val firmware = detectFirmware(manufacturer, brand, androidVersion)
        
        val info = DeviceInfo(deviceBrand, firmware, manufacturer, model, androidVersion)
        Log.d(TAG, "🔍 Device detected: $info")
        return info
    }
    
    /**
     * Определяет тип прошивки
     */
    private fun detectFirmware(manufacturer: String, brand: String, androidVersion: Int): FirmwareType {
        // Проверка MIUI/HyperOS (Xiaomi/Poco)
        if (manufacturer.contains("xiaomi") || brand.contains("xiaomi") || brand.contains("poco")) {
            // HyperOS обычно на Android 14+
            return if (androidVersion >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                FirmwareType.HYPEROS
            } else {
                FirmwareType.MIUI
            }
        }
        
        // Проверка XOS (Tecno)
        if (manufacturer.contains("tecno") || brand.contains("tecno")) {
            return FirmwareType.XOS
        }
        
        // Проверка HIOS (Infinix)
        if (manufacturer.contains("infinix") || brand.contains("infinix")) {
            return FirmwareType.HIOS
        }
        
        return FirmwareType.OTHER
    }
    
    /**
     * Проверяет, является ли устройство китайским (требует специальных фиксов)
     */
    fun isChineseDevice(): Boolean {
        val info = detectDevice()
        return info.brand in listOf(
            DeviceBrand.XIAOMI, DeviceBrand.POCO, DeviceBrand.TECNO, DeviceBrand.INFINIX,
            DeviceBrand.HUAWEI, DeviceBrand.HONOR, DeviceBrand.OPPO, DeviceBrand.VIVO, DeviceBrand.REALME
        )
    }
    
    /**
     * Проверяет, требуется ли native BLE advertising (flutter_ble_peripheral не работает)
     * На Huawei/Honor flutter_ble_peripheral часто fail'ится
     */
    fun requiresNativeBleAdvertising(): Boolean {
        val info = detectDevice()
        return info.brand in listOf(DeviceBrand.HUAWEI, DeviceBrand.HONOR)
    }
    
    /**
     * Проверяет, требуется ли минимальный advertising data (ограничения BLE стека)
     */
    fun requiresMinimalAdvertising(): Boolean {
        val info = detectDevice()
        return info.brand in listOf(DeviceBrand.HUAWEI, DeviceBrand.HONOR, DeviceBrand.OPPO, DeviceBrand.VIVO)
    }
    
    /**
     * Проверяет, требуется ли MulticastLock
     */
    fun requiresMulticastLock(): Boolean {
        return isChineseDevice()
    }
    
    /**
     * Проверяет, требуется ли Wi-Fi Lock
     */
    fun requiresWifiLock(): Boolean {
        return isChineseDevice()
    }
    
    /**
     * Проверяет, требуется ли Heartbeat (для Tecno/Infinix)
     */
    fun requiresHeartbeat(): Boolean {
        val info = detectDevice()
        return info.brand in listOf(DeviceBrand.TECNO, DeviceBrand.INFINIX)
    }
    
    /**
     * Проверяет, требуется ли проверка Autostart (для Xiaomi/Poco)
     */
    fun requiresAutostartCheck(): Boolean {
        val info = detectDevice()
        return info.brand in listOf(DeviceBrand.XIAOMI, DeviceBrand.POCO)
    }
    
    /**
     * Проверяет, является ли устройство слабым/сомнительным
     * Слабые устройства: Xiaomi, Poco, Tecno, Infinix (но НЕ Huawei!)
     * На таких устройствах не поднимаем TCP сервер, сразу используем BLE GATT
     * Huawei/Honor имеют проблемы с BLE advertising, но TCP работает хорошо
     */
    fun isWeakDevice(): Boolean {
        val info = detectDevice()
        // Huawei/Honor НЕ слабые - у них хороший TCP, но плохой BLE advertising
        return info.brand in listOf(DeviceBrand.XIAOMI, DeviceBrand.POCO, DeviceBrand.TECNO, DeviceBrand.INFINIX)
    }
    
    /**
     * Проверяет, можно ли поднимать TCP сервер на этом устройстве
     * Возвращает false для слабых устройств или если сервер уже падал
     */
    fun canStartTcpServer(context: android.content.Context): Boolean {
        // Для слабых устройств - не поднимаем сервер
        if (isWeakDevice()) {
            Log.d(TAG, "🚫 Weak device detected, TCP server disabled")
            return false
        }
        
        // Проверяем, был ли краш сервера ранее
        val prefs = context.getSharedPreferences("memento_prefs", android.content.Context.MODE_PRIVATE)
        val serverCrashed = prefs.getBoolean("tcp_server_crashed", false)
        
        if (serverCrashed) {
            Log.d(TAG, "🚫 TCP server previously crashed, disabled")
            return false
        }
        
        return true
    }
    
    /**
     * Отмечает, что TCP сервер упал
     */
    fun markTcpServerCrashed(context: android.content.Context) {
        val prefs = context.getSharedPreferences("memento_prefs", android.content.Context.MODE_PRIVATE)
        prefs.edit().putBoolean("tcp_server_crashed", true).apply()
        Log.w(TAG, "⚠️ TCP server crash marked - will use BLE GATT on next launch")
    }
    
    /**
     * Сбрасывает флаг падения сервера (для тестирования или после обновления)
     */
    fun resetTcpServerCrashFlag(context: android.content.Context) {
        val prefs = context.getSharedPreferences("memento_prefs", android.content.Context.MODE_PRIVATE)
        prefs.edit().putBoolean("tcp_server_crashed", false).apply()
        Log.d(TAG, "✅ TCP server crash flag reset")
    }
}
