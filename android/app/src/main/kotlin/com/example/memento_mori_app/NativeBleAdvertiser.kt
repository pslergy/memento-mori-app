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
 * Native BLE Advertiser для устройств с проблемами flutter_ble_peripheral.
 * Huawei/Honor: single strategy, strict restart gate, no ANR.
 *
 * RULES: Do not change GATT server, connectable flag, Service UUID, or BLE connect() logic.
 */
class NativeBleAdvertiser(
    private val context: Context,
    private val methodChannel: MethodChannel?
) {
    companion object {
        private const val TAG = "NativeBleAdvertiser"
        private val SERVICE_UUID = UUID.fromString("bf27730d-860a-4e09-889c-2d8b6a9e0fe7")
        private const val MANUFACTURER_ID = 0xFFFF
        private const val CALLBACK_TIMEOUT_MS = 2000L
        private const val HUAWEI_RESTART_COOLDOWN_MS = 6000L
        private const val HUAWEI_MF_DATA_MAX_BYTES = 12
        private const val HUAWEI_COMPACT_PAYLOAD_MAX_BYTES = 18
        private const val RETRY_DELAY_MS_MIN = 8000
        private const val RETRY_DELAY_MS_MAX = 10000
        private const val STOP_WAIT_MS = 400
    }

    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertisingActive = AtomicBoolean(false)
    private var currentCallback: AdvertiseCallback? = null
    private val allCallbacks = mutableListOf<AdvertiseCallback>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isInitialized = AtomicBoolean(false)
    private var gattServerHelper: GattServerHelper? = null
    private var lastSuccessfulStrategy: Int = 0

    // PART 2 — Strict restart gate (Huawei cooldown 6000ms)
    @Volatile
    private var lastAdvStartTime: Long = 0L
    @Volatile
    private var advStartInProgress: Boolean = false

    // PART 3 — Pending data for scheduled retry (do not start in same call stack)
    @Volatile
    private var pendingRetryLocalName: String? = null
    @Volatile
    private var pendingRetryManufacturerData: ByteArray? = null
    private val retryRunnable = Runnable {
        val name = pendingRetryLocalName ?: return@Runnable
        val data = pendingRetryManufacturerData ?: return@Runnable
        pendingRetryLocalName = null
        pendingRetryManufacturerData = null
        Log.d(TAG, "📡 [RETRY] Scheduled retry starting...")
        startAdvertising(name, data)
    }

    fun setGattServerHelper(helper: GattServerHelper?) {
        gattServerHelper = helper
    }

    /** Huawei-like device: use minimal AdvertiseData to avoid DATA_TOO_LARGE. */
    private fun isHuaweiLikeDevice(): Boolean {
        val brand = DeviceDetector.detectDevice().brand
        return brand == DeviceDetector.DeviceBrand.HUAWEI || brand == DeviceDetector.DeviceBrand.HONOR
    }

    /** Truncate manufacturer payload for advertising layer only (GATT still uses full data). */
    private fun buildCompactPayload(original: ByteArray): ByteArray {
        val maxSize = HUAWEI_COMPACT_PAYLOAD_MAX_BYTES
        return if (original.size <= maxSize) original else original.copyOf(maxSize)
    }

    init {
        initializeAdvertiser()
    }

    private fun initializeAdvertiser() {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        if (bluetoothAdapter?.isEnabled == true) {
            advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
            if (advertiser != null) {
                isInitialized.set(true)
                Log.d(TAG, "✅ NativeBleAdvertiser initialized (${DeviceDetector.detectDevice().brand})")
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun ensureAdvertiserAvailable(): Boolean {
        if (isInitialized.get() && advertiser != null && bluetoothAdapter?.isEnabled == true) return true
        var waitTime = 0
        while (waitTime < 3000) {
            if (bluetoothAdapter?.isEnabled == true) {
                advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
                if (advertiser != null) {
                    isInitialized.set(true)
                    return true
                }
            }
            Thread.sleep(100)
            waitTime += 100
        }
        return false
    }

    /**
     * PART 2: Before ANY stop/start — gate. PART 4: Stop only current set.
     * PART 5: If singleStrategyOnly true, use only primary strategy (no cascade).
     */
    @SuppressLint("MissingPermission")
    fun startAdvertising(localName: String, manufacturerData: ByteArray, singleStrategyOnly: Boolean = false): Boolean {
        if (!ensureAdvertiserAvailable()) return false

        if (advStartInProgress) {
            Log.w(TAG, "⏸️ [GATE] advStartInProgress=true, skipping")
            return false
        }
        val now = System.currentTimeMillis()
        if (now - lastAdvStartTime < HUAWEI_RESTART_COOLDOWN_MS) {
            Log.w(TAG, "⏸️ [GATE] Restart cooldown (${now - lastAdvStartTime}ms < ${HUAWEI_RESTART_COOLDOWN_MS}ms), skipping")
            return false
        }

        val hasClients = gattServerHelper?.hasConnectedClients() ?: false
        if (hasClients) {
            currentCallback?.let { cb ->
                try {
                    advertiser?.stopAdvertising(cb)
                } catch (_: Exception) { }
            }
            currentCallback = null
            Thread.sleep(200)
        } else {
            // PART 4: Stop only current set, never force-stop-all
            currentCallback?.let { cb ->
                try {
                    advertiser?.stopAdvertising(cb)
                    Log.d(TAG, "   ✅ Stopped current advertising set only")
                } catch (e: Exception) {
                    Log.w(TAG, "   ⚠️ Error stopping current: ${e.message}")
                }
                currentCallback = null
            }
            allCallbacks.clear()
            Thread.sleep(STOP_WAIT_MS.toLong())
        }

        val useSingleOnly = singleStrategyOnly || DeviceDetector.requiresNativeBleAdvertising()
        return if (useSingleOnly) {
            startHuaweiSingleStrategy(localName, manufacturerData)
        } else {
            tryStrategiesSequentially(manufacturerData)
        }
    }

    /**
     * PART 1 — Huawei/Honor: SINGLE strategy. Connectable=true, Service UUID, minimal manufacturerData (8–12 bytes), no scanResponse.
     * PART 3 — Set advStartInProgress=true before start; clear in callback; on failure schedule retry 8–10s.
     */
    @SuppressLint("MissingPermission")
    private fun startHuaweiSingleStrategy(localName: String, manufacturerData: ByteArray): Boolean {
        val isHuawei = isHuaweiLikeDevice()
        val mfData = if (isHuawei) {
            Log.d(TAG, "[BLE-HUAWEI] Advertising payload size = ${manufacturerData.size}")
            val compact = buildCompactPayload(manufacturerData)
            Log.d(TAG, "[BLE-HUAWEI] Compact payload size = ${compact.size}")
            compact
        } else {
            if (manufacturerData.size > HUAWEI_MF_DATA_MAX_BYTES) {
                manufacturerData.copyOf(HUAWEI_MF_DATA_MAX_BYTES)
            } else {
                manufacturerData
            }
        }
        advStartInProgress = true
        pendingRetryLocalName = localName
        pendingRetryManufacturerData = manufacturerData

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val advertiseData = if (isHuawei) {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, mfData)
                .build()
        } else {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, mfData)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
        }

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                advStartInProgress = false
                lastAdvStartTime = System.currentTimeMillis()
                isAdvertisingActive.set(true)
                currentCallback = this
                allCallbacks.add(this)
                Log.d(TAG, "✅ [Huawei single] Advertising started")
                mainHandler.post {
                    methodChannel?.invokeMethod("onAdvertisingStarted", mapOf("strategy" to "huawei_single", "success" to true))
                }
            }
            override fun onStartFailure(errorCode: Int) {
                advStartInProgress = false
                isAdvertisingActive.set(false)
                currentCallback = null
                val msg = errorCodeToString(errorCode)
                Log.e(TAG, "❌ [Huawei single] Advertising failed: $msg")
                mainHandler.post {
                    methodChannel?.invokeMethod("onAdvertisingStarted", mapOf("strategy" to "huawei_single", "success" to false))
                }
                val delay = (RETRY_DELAY_MS_MIN..RETRY_DELAY_MS_MAX).random().toLong()
                Log.d(TAG, "📡 [RETRY] Scheduling retry in ${delay}ms (not immediate)")
                mainHandler.postDelayed(retryRunnable, delay)
            }
        }
        try {
            advertiser?.startAdvertising(settings, advertiseData, callback)
            return true
        } catch (e: Exception) {
            advStartInProgress = false
            Log.e(TAG, "❌ [Huawei single] Exception: ${e.message}")
            return false
        }
    }

    @SuppressLint("MissingPermission")
    private fun tryStrategiesSequentially(manufacturerData: ByteArray): Boolean {
        val hasClients = gattServerHelper?.hasConnectedClients() ?: false
        if (hasClients) {
            return when (lastSuccessfulStrategy) {
                1 -> tryManufacturerDataOnly(manufacturerData)
                2 -> tryMfDataWithServiceInScanResponse(manufacturerData)
                3 -> tryConnectableWithServiceOnly()
                else -> tryManufacturerDataOnly(manufacturerData).also { if (it) lastSuccessfulStrategy = 1 }
            }
        }
        advStartInProgress = true
        val ok = tryManufacturerDataOnly(manufacturerData)
        if (ok) {
            advStartInProgress = false
            lastAdvStartTime = System.currentTimeMillis()
            lastSuccessfulStrategy = 1
            return true
        }
        advStartInProgress = false
        currentCallback?.let { cb -> try { advertiser?.stopAdvertising(cb) } catch (_: Exception) { } }
        currentCallback = null
        Thread.sleep(STOP_WAIT_MS.toLong())
        advStartInProgress = true
        val ok2 = tryMfDataWithServiceInScanResponse(manufacturerData)
        if (ok2) {
            advStartInProgress = false
            lastAdvStartTime = System.currentTimeMillis()
            lastSuccessfulStrategy = 2
            return true
        }
        advStartInProgress = false
        currentCallback?.let { cb -> try { advertiser?.stopAdvertising(cb) } catch (_: Exception) { } }
        currentCallback = null
        Thread.sleep(STOP_WAIT_MS.toLong())
        advStartInProgress = true
        val ok3 = tryConnectableWithServiceOnly()
        if (ok3) {
            advStartInProgress = false
            lastAdvStartTime = System.currentTimeMillis()
            lastSuccessfulStrategy = 3
            return true
        }
        advStartInProgress = false
        return false
    }

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
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, manufacturerData)
                .build()
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    lastAdvStartTime = System.currentTimeMillis()
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf("strategy" to "mfDataOnly", "success" to true))
                    }
                }
                override fun onStartFailure(errorCode: Int) {
                    isAdvertisingActive.set(false)
                    latch.countDown()
                }
            }
            advertiser?.startAdvertising(settings, advertiseData, callback)
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
        } catch (e: Exception) {
            return false
        }
    }

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
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER_ID, manufacturerData)
                .build()
            val scanResponse = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    lastAdvStartTime = System.currentTimeMillis()
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf("strategy" to "split", "success" to true))
                    }
                }
                override fun onStartFailure(errorCode: Int) {
                    isAdvertisingActive.set(false)
                    latch.countDown()
                }
            }
            advertiser?.startAdvertising(settings, advertiseData, scanResponse, callback)
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
        } catch (e: Exception) {
            return false
        }
    }

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
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    lastAdvStartTime = System.currentTimeMillis()
                    isAdvertisingActive.set(true)
                    success.set(true)
                    currentCallback = this
                    allCallbacks.add(this)
                    latch.countDown()
                    mainHandler.post {
                        methodChannel?.invokeMethod("onAdvertisingStarted", mapOf("strategy" to "connectable", "success" to true))
                    }
                }
                override fun onStartFailure(errorCode: Int) {
                    isAdvertisingActive.set(false)
                    latch.countDown()
                }
            }
            advertiser?.startAdvertising(settings, advertiseData, callback)
            latch.await(CALLBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return success.get()
        } catch (e: Exception) {
            return false
        }
    }

    private fun errorCodeToString(errorCode: Int): String = when (errorCode) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
        else -> "UNKNOWN ($errorCode)"
    }

    @SuppressLint("MissingPermission")
    fun stopAdvertising() {
        if (!isAdvertisingActive.get()) return
        currentCallback?.let { cb ->
            try {
                advertiser?.stopAdvertising(cb)
            } catch (_: Exception) { }
        }
        currentCallback = null
        allCallbacks.clear()
        isAdvertisingActive.set(false)
    }

    fun isAdvertising(): Boolean = isAdvertisingActive.get()

    fun updateAdvertising(localName: String, manufacturerData: ByteArray): Boolean {
        return startAdvertising(localName, manufacturerData)
    }

    fun cleanup() {
        mainHandler.removeCallbacks(retryRunnable)
        pendingRetryLocalName = null
        pendingRetryManufacturerData = null
        stopAdvertising()
    }
}
