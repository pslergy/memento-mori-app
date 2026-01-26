package com.example.memento_mori_app

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native BLE Advertiser для устройств с проблемами flutter_ble_peripheral
 * Особенно для Huawei/Honor где flutter_ble_peripheral часто fail'ится
 * 
 * КРИТИЧНО: На Huawei BLE stack имеет ограничения:
 * 1. Максимум 1-2 advertising sets одновременно
 * 2. Размер данных строго ограничен 31 байтом
 * 3. Service UUID занимает 18 байт (2 header + 16 UUID)
 */
class NativeBleAdvertiser(
    private val context: Context,
    private val methodChannel: MethodChannel?
) {
    companion object {
        private const val TAG = "NativeBleAdvertiser"
        private val SERVICE_UUID = UUID.fromString("bf27730d-860a-4e09-889c-2d8b6a9e0fe7")
        
        // Manufacturer ID для тестирования (0xFFFF зарезервирован)
        private const val MANUFACTURER_ID = 0xFFFF
        
        // Таймаут ожидания callback
        private const val CALLBACK_TIMEOUT_MS = 2000L
    }
    
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertisingActive = AtomicBoolean(false)
    private var currentCallback: AdvertiseCallback? = null
    
    // Список всех callback'ов для очистки
    private val allCallbacks = mutableListOf<AdvertiseCallback>()
    
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // 🔥 FIX: Track initialization state
    private var isInitialized = AtomicBoolean(false)
    
    // 🔒 SECURITY FIX #4: Reference to GattServerHelper to check for connected clients
    private var gattServerHelper: GattServerHelper? = null
    
    // 🔒 SECURITY FIX #4: Track last successful strategy to avoid cycling when clients connected
    private var lastSuccessfulStrategy: Int = 0 // 0 = none, 1 = mfDataOnly, 2 = split, 3 = connectable
    
    /**
     * Set GattServerHelper reference for checking connected clients
     */
    fun setGattServerHelper(helper: GattServerHelper?) {
        gattServerHelper = helper
        Log.d(TAG, "✅ GattServerHelper reference set")
    }
    
    init {
        initializeAdvertiser()
    }
    
    /**
     * Initializes the Bluetooth advertiser
     * Can be called multiple times - will re-initialize if needed
     */
    private fun initializeAdvertiser() {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        
        // 🔥 FIX: Check if Bluetooth is enabled before getting advertiser
        if (bluetoothAdapter?.isEnabled == true) {
            advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
            if (advertiser != null) {
                isInitialized.set(true)
                Log.d(TAG, "✅ NativeBleAdvertiser initialized for ${DeviceDetector.detectDevice().brand}")
            } else {
                Log.e(TAG, "❌ BluetoothLeAdvertiser not available (adapter enabled but no advertiser)")
            }
        } else {
            Log.w(TAG, "⚠️ Bluetooth not enabled yet, advertiser will be initialized later")
        }
    }
    
    /**
     * Ensures the advertiser is available, waiting for Bluetooth if needed
     * @return true if advertiser is available
     */
    @SuppressLint("MissingPermission")
    private fun ensureAdvertiserAvailable(): Boolean {
        // If already initialized, check if still valid
        if (isInitialized.get() && advertiser != null && bluetoothAdapter?.isEnabled == true) {
            return true
        }
        
        // 🔥 FIX: Wait for Bluetooth to be enabled (max 3 seconds)
        var waitTime = 0
        val maxWaitMs = 3000
        val checkInterval = 100L
        
        while (waitTime < maxWaitMs) {
            if (bluetoothAdapter?.isEnabled == true) {
                // Bluetooth is now on, try to get advertiser
                advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
                if (advertiser != null) {
                    isInitialized.set(true)
                    Log.d(TAG, "✅ Advertiser available after ${waitTime}ms wait")
                    return true
                }
            }
            
            Thread.sleep(checkInterval)
            waitTime += checkInterval.toInt()
        }
        
        Log.e(TAG, "❌ Advertiser not available after ${maxWaitMs}ms wait (BT enabled: ${bluetoothAdapter?.isEnabled})")
        return false
    }
    
    /**
     * Запускает BLE advertising с указанными параметрами
     * @param localName Имя устройства (будет обрезано если слишком длинное)
     * @param manufacturerData Данные производителя (роль + токен)
     * @return true если advertising запущен успешно
     */
    @SuppressLint("MissingPermission")
    fun startAdvertising(localName: String, manufacturerData: ByteArray): Boolean {
        // 🔥 FIX: Wait for Bluetooth to be enabled before starting
        if (!ensureAdvertiserAvailable()) {
            Log.e(TAG, "❌ Advertiser not available (Bluetooth may still be turning on)")
            return false
        }
        
        // 🔒 SECURITY FIX #4: Check for connected GATT clients before force-stopping
        val hasClients = gattServerHelper?.hasConnectedClients() ?: false
        if (hasClients) {
            Log.w(TAG, "⚠️ [SECURITY] GATT clients connected - using soft advertising update")
            // Мягкое обновление - только останавливаем текущий callback без агрессивной очистки
            currentCallback?.let { callback ->
                try {
                    advertiser?.stopAdvertising(callback)
                    Log.d(TAG, "   ✅ Stopped current callback (soft)")
                } catch (e: Exception) {
                    Log.w(TAG, "   ⚠️ Error in soft stop: ${e.message}")
                }
            }
            currentCallback = null
            Thread.sleep(200) // Короткая пауза вместо 500ms
        } else {
            // 🔥 КРИТИЧНО: Агрессивная очистка ВСЕХ advertising sets (только без клиентов)
            forceStopAllAdvertising()
            Thread.sleep(500) // Ждём полной остановки
        }
        
        // Пробуем стратегии по одной с полной очисткой между попытками
        return tryStrategiesSequentially(manufacturerData)
    }
    
    /**
     * Агрессивно останавливает ВСЕ advertising sets
     */
    @SuppressLint("MissingPermission")
    private fun forceStopAllAdvertising() {
        Log.d(TAG, "🛑 Force stopping ALL advertising sets...")
        
        // 🔥 FIX: Check if advertiser is available before stopping
        val adv = advertiser
        if (adv == null) {
            Log.w(TAG, "   ⚠️ Advertiser is null, clearing callbacks only")
            currentCallback = null
            allCallbacks.clear()
            isAdvertisingActive.set(false)
            return
        }
        
        // Останавливаем текущий callback
        currentCallback?.let { callback ->
            try {
                adv.stopAdvertising(callback)
                Log.d(TAG, "   ✅ Stopped current callback")
            } catch (e: Exception) {
                Log.w(TAG, "   ⚠️ Error stopping current: ${e.message}")
            }
        }
        currentCallback = null
        
        // Останавливаем все сохранённые callback'и
        allCallbacks.forEach { callback ->
            try {
                adv.stopAdvertising(callback)
            } catch (e: Exception) {
                // Игнорируем - callback может быть уже остановлен
            }
        }
        allCallbacks.clear()
        
        isAdvertisingActive.set(false)
        Log.d(TAG, "🛑 All advertising stopped")
    }
    
    /**
     * Пробует стратегии последовательно с полной очисткой
     * 🔒 SECURITY FIX #4: Если GATT клиенты подключены - используем последнюю успешную стратегию
     * без cycling, чтобы не разорвать соединение
     */
    @SuppressLint("MissingPermission")
    private fun tryStrategiesSequentially(manufacturerData: ByteArray): Boolean {
        
        // 🔒 SECURITY FIX #4: Check for connected GATT clients
        val hasClients = gattServerHelper?.hasConnectedClients() ?: false
        if (hasClients) {
            Log.w(TAG, "⚠️ [SECURITY] GATT clients connected (${gattServerHelper?.getConnectedDevicesCount() ?: 0}) - skipping strategy cycling")
            Log.w(TAG, "   💡 Using last successful strategy ($lastSuccessfulStrategy) to avoid disrupting connection")
            
            // Используем последнюю успешную стратегию без cycling
            return when (lastSuccessfulStrategy) {
                1 -> {
                    Log.d(TAG, "📡 Re-using Strategy 1: manufacturerData ONLY")
                    tryManufacturerDataOnly(manufacturerData)
                }
                2 -> {
                    Log.d(TAG, "📡 Re-using Strategy 2: mfData + Service UUID in scan response")
                    tryMfDataWithServiceInScanResponse(manufacturerData)
                }
                3 -> {
                    Log.d(TAG, "📡 Re-using Strategy 3: Connectable with Service UUID only")
                    tryConnectableWithServiceOnly()
                }
                else -> {
                    // Если нет последней успешной стратегии - пробуем только первую (самую безопасную)
                    Log.d(TAG, "📡 No last strategy - trying Strategy 1 only (safest)")
                    if (tryManufacturerDataOnly(manufacturerData)) {
                        lastSuccessfulStrategy = 1
                        true
                    } else {
                        false
                    }
                }
            }
        }
        
        // 🔥 Стратегия 1: ТОЛЬКО manufacturerData (самая минимальная)
        // Для Huawei это единственный надёжный вариант
        Log.d(TAG, "📡 Trying Strategy 1: manufacturerData ONLY (no Service UUID)")
        if (tryManufacturerDataOnly(manufacturerData)) {
            Log.d(TAG, "✅ Strategy 1 (mfData only) succeeded!")
            lastSuccessfulStrategy = 1
            return true
        }
        
        // Очистка перед следующей попыткой
        forceStopAllAdvertising()
        Thread.sleep(300)
        
        // 🔥 Стратегия 2: manufacturerData в основных данных, Service UUID в scan response
        Log.d(TAG, "📡 Trying Strategy 2: mfData + Service UUID in scan response")
        if (tryMfDataWithServiceInScanResponse(manufacturerData)) {
            Log.d(TAG, "✅ Strategy 2 (split) succeeded!")
            lastSuccessfulStrategy = 2
            return true
        }
        
        // Очистка перед следующей попыткой
        forceStopAllAdvertising()
        Thread.sleep(300)
        
        // 🔥 Стратегия 3: Connectable без данных + Service UUID
        Log.d(TAG, "📡 Trying Strategy 3: Connectable with Service UUID only")
        if (tryConnectableWithServiceOnly()) {
            Log.d(TAG, "✅ Strategy 3 (connectable) succeeded!")
            lastSuccessfulStrategy = 3
            return true
        }
        
        Log.e(TAG, "❌ All advertising strategies failed")
        return false
    }
    
    /**
     * Стратегия 1: ТОЛЬКО manufacturerData
     * Максимально совместимо с Huawei
     * Размер: 2 (header) + 2 (mfId) + N (data) = 4 + N байт
     */
    @SuppressLint("MissingPermission")
    private fun tryManufacturerDataOnly(manufacturerData: ByteArray): Boolean {
        val latch = CountDownLatch(1)
        val success = AtomicBoolean(false)
        
        try {
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .setTimeout(0)
                .build()
            
            // ТОЛЬКО manufacturerData - ничего больше
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, manufacturerData)
                .build()
            
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    Log.d(TAG, "✅ [mfDataOnly] Advertising started!")
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf(
                            "strategy" to "mfDataOnly",
                            "success" to true
                        ))
                    }
                }
                
                override fun onStartFailure(errorCode: Int) {
                    val errorMsg = errorCodeToString(errorCode)
                    Log.e(TAG, "❌ [mfDataOnly] Advertising failed: $errorMsg")
                    isAdvertisingActive.set(false)
                    success.set(false)
                    latch.countDown()
                }
            }
            
            advertiser?.startAdvertising(settings, advertiseData, callback)
            
            // Ждём результат
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [mfDataOnly] Exception: ${e.message}")
            return false
        }
    }
    
    /**
     * Стратегия 2: manufacturerData отдельно, Service UUID в scan response
     */
    @SuppressLint("MissingPermission")
    private fun tryMfDataWithServiceInScanResponse(manufacturerData: ByteArray): Boolean {
        val latch = CountDownLatch(1)
        val success = AtomicBoolean(false)
        
        try {
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build()
            
            // Основные данные: только manufacturerData
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, manufacturerData)
                .build()
            
            // Scan Response: Service UUID
            val scanResponse = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    Log.d(TAG, "✅ [split] Advertising started!")
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf(
                            "strategy" to "split",
                            "success" to true
                        ))
                    }
                }
                
                override fun onStartFailure(errorCode: Int) {
                    val errorMsg = errorCodeToString(errorCode)
                    Log.e(TAG, "❌ [split] Advertising failed: $errorMsg")
                    isAdvertisingActive.set(false)
                    success.set(false)
                    latch.countDown()
                }
            }
            
            advertiser?.startAdvertising(settings, advertiseData, scanResponse, callback)
            
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [split] Exception: ${e.message}")
            return false
        }
    }
    
    /**
     * Стратегия 3: Просто connectable с Service UUID
     */
    @SuppressLint("MissingPermission")
    private fun tryConnectableWithServiceOnly(): Boolean {
        val latch = CountDownLatch(1)
        val success = AtomicBoolean(false)
        
        try {
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
                .setConnectable(true)
                .setTimeout(0)
                .build()
            
            // Только Service UUID
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    Log.d(TAG, "✅ [connectable] Advertising started!")
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf(
                            "strategy" to "connectable",
                            "success" to true
                        ))
                    }
                }
                
                override fun onStartFailure(errorCode: Int) {
                    val errorMsg = errorCodeToString(errorCode)
                    Log.e(TAG, "❌ [connectable] Advertising failed: $errorMsg")
                    isAdvertisingActive.set(false)
                    success.set(false)
                    latch.countDown()
                }
            }
            
            advertiser?.startAdvertising(settings, advertiseData, callback)
            
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ [connectable] Exception: ${e.message}")
            return false
        }
    }
    
    private fun errorCodeToString(errorCode: Int): String {
        return when (errorCode) {
            AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
            AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
            AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
            AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
            AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
            else -> "UNKNOWN ($errorCode)"
        }
    }
    
    /**
     * Останавливает advertising
     */
    @SuppressLint("MissingPermission")
    fun stopAdvertising() {
        // 🔥 FIX: Only stop if we're actually advertising
        if (!isAdvertisingActive.get()) {
            Log.d(TAG, "ℹ️ Not advertising, nothing to stop")
            return
        }
        forceStopAllAdvertising()
    }
    
    /**
     * Проверяет, активен ли advertising
     */
    fun isAdvertising(): Boolean = isAdvertisingActive.get()
    
    /**
     * Обновляет данные advertising (перезапускает с новыми данными)
     */
    fun updateAdvertising(localName: String, manufacturerData: ByteArray): Boolean {
        return startAdvertising(localName, manufacturerData)
    }
    
    /**
     * Освобождает ресурсы
     */
    fun cleanup() {
        forceStopAllAdvertising()
    }
}
