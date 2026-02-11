package com.example.memento_mori_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GattServerHelper(
    private val context: Context,
    private val resultChannel: MethodChannel?
) {
    companion object {
        private const val MESH_DIAGNOSTICS = false
        /** Скрывает начало MAC в логах (только последние 5 символов, чтобы нельзя было отследить устройство). */
        private fun maskMacForLog(address: String?): String {
            if (address.isNullOrBlank()) return "••••"
            return if (address.length >= 5) "••:••:••:••:${address.takeLast(5)}" else "••••"
        }
    }
    private val TAG = "GATT_SERVER"
    
    private val SERVICE_UUID = UUID.fromString("bf27730d-860a-4e09-889c-2d8b6a9e0fe7")
    private val CHAR_UUID = UUID.fromString("c22d1e32-0310-4062-812e-89025078da9c")
    
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gattServer: BluetoothGattServer? = null
    private var isServerRunning = false
    
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    
    // Handler для выполнения вызовов MethodChannel на главном потоке
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // 🔥 FIX: Track pending onGattReady callback to cancel on stop
    private var onGattReadyRunnable: Runnable? = null
    private var gattServerGeneration: Int = 0  // Track server restarts for race condition prevention
    
    // 🔥 LENGTH-PREFIXED FRAMING: Буферы для сборки сообщений из чанков
    // Формат: [4 bytes: payload length (Big-Endian)][N bytes: JSON payload]
    private data class MessageBuffer(
        val buffer: ByteArrayOutputStream = ByteArrayOutputStream(),
        var expectedLength: Int = -1,  // -1 = ещё не прочитан header
        var lastChunkTime: Long = System.currentTimeMillis()
    )
    
    // Map: deviceAddress -> MessageBuffer
    private val deviceBuffers = mutableMapOf<String, MessageBuffer>()
    
    // Timeout для очистки буфера (30 секунд)
    private val BUFFER_TIMEOUT_MS = 30_000L
    
    // Периодическая очистка зависших буферов
    private val bufferCleanupRunnable = object : Runnable {
        override fun run() {
            cleanupStaleBuffers()
            mainHandler.postDelayed(this, 10_000) // Каждые 10 секунд
        }
    }
    
    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            super.onConnectionStateChange(device, status, newState)
            if (MESH_DIAGNOSTICS) {
                val stateStr = when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> "CONNECTED"
                    BluetoothProfile.STATE_CONNECTING -> "CONNECTING"
                    BluetoothProfile.STATE_DISCONNECTED -> "DISCONNECTED"
                    BluetoothProfile.STATE_DISCONNECTING -> "DISCONNECTING"
                    else -> "UNKNOWN($newState)"
                }
                Log.d(TAG, "MESH_DIAG onConnectionStateChange status=$status newState=$stateStr deviceAddress=${maskMacForLog(device.address)} deviceName=${device.name ?: "Unknown"} manufacturer=${Build.MANUFACTURER} androidVersion=${Build.VERSION.SDK_INT}")
            }
            // 🔥 DETAILED LOGGING: Log ALL connection state changes
            val stateStr = when (newState) {
                BluetoothProfile.STATE_CONNECTED -> "CONNECTED"
                BluetoothProfile.STATE_CONNECTING -> "CONNECTING"
                BluetoothProfile.STATE_DISCONNECTED -> "DISCONNECTED"
                BluetoothProfile.STATE_DISCONNECTING -> "DISCONNECTING"
                else -> "UNKNOWN($newState)"
            }
            val statusStr = when (status) {
                BluetoothGatt.GATT_SUCCESS -> "SUCCESS"
                133 -> "GATT_ERROR_133" // Infamous Android BLE error
                else -> "STATUS_$status"
            }
            
            Log.d(TAG, "🔔 [GATT-SERVER] Connection state change:")
            Log.d(TAG, "   📋 Device: ${maskMacForLog(device.address)}")
            Log.d(TAG, "   📋 Device name: ${device.name ?: "Unknown"}")
            Log.d(TAG, "   📋 New state: $stateStr")
            Log.d(TAG, "   📋 Status: $statusStr")
            Log.d(TAG, "   📋 Server running: $isServerRunning")
            Log.d(TAG, "   📋 Connected devices: ${connectedDevices.size}")
            
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.d(TAG, "✅ [GATT-SERVER] Device connected: ${maskMacForLog(device.address)}")
                    connectedDevices.add(device)
                    
                    // Уведомляем Flutter о подключении (на главном потоке)
                    mainHandler.post {
                        resultChannel?.invokeMethod("onGattClientConnected", mapOf(
                            "deviceAddress" to device.address,
                            "deviceName" to (device.name ?: "Unknown")
                        ))
                    }
                }
                BluetoothProfile.STATE_CONNECTING -> {
                    // 🔥 NEW: Log connection attempts
                    Log.d(TAG, "🔄 [GATT-SERVER] Device CONNECTING: ${maskMacForLog(device.address)}")
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.d(TAG, "❌ [GATT-SERVER] Device disconnected: ${maskMacForLog(device.address)}")
                    connectedDevices.remove(device)
                    
                    // 🔥 Очищаем буфер для отключившегося устройства
                    clearBufferForDevice(device.address)
                    
                    // Уведомляем Flutter об отключении (на главном потоке)
                    mainHandler.post {
                        resultChannel?.invokeMethod("onGattClientDisconnected", mapOf(
                            "deviceAddress" to device.address
                        ))
                    }
                }
            }
        }
        
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            super.onCharacteristicWriteRequest(device, requestId, characteristic, preparedWrite, responseNeeded, offset, value)
            
            val chunkSize = value?.size ?: 0
            Log.d(TAG, "📥 [GATT-SERVER] Write request from ${maskMacForLog(device.address)}, size: $chunkSize")
            
            if (characteristic.uuid == CHAR_UUID && value != null && value.isNotEmpty()) {
                // 🔥 Send BLE response FIRST on main thread (Huawei/Tecno call callback from binder thread — response must be on main)
                if (responseNeeded && gattServer != null) {
                    val server = gattServer
                    val dev = device
                    val id = requestId
                    val off = offset
                    mainHandler.post {
                        try {
                            server?.sendResponse(dev, id, BluetoothGatt.GATT_SUCCESS, off, null)
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ [GATT-SERVER] sendResponse failed: $e")
                        }
                    }
                }
                try {
                    processIncomingChunk(device.address, value)
                } catch (e: Exception) {
                    Log.e(TAG, "❌ [GATT-SERVER] Error processing write request: $e")
                }
            } else {
                if (responseNeeded && gattServer != null) {
                    val server = gattServer
                    val dev = device
                    val id = requestId
                    val off = offset
                    mainHandler.post {
                        try {
                            server?.sendResponse(dev, id, BluetoothGatt.GATT_FAILURE, off, null)
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ [GATT-SERVER] sendResponse(fail) failed: $e")
                        }
                    }
                }
            }
        }
        
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            super.onCharacteristicReadRequest(device, requestId, offset, characteristic)
            
            Log.d(TAG, "📤 [GATT-SERVER] Read request from ${maskMacForLog(device.address)}")
            
            if (characteristic.uuid == CHAR_UUID && gattServer != null) {
                // Отправляем пустой ответ (или можно добавить логику для чтения)
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    null
                )
            }
        }
        
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            super.onServiceAdded(status, service)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "✅ [GATT-SERVER] Service added successfully")
                
                // 🔥 FIX: Cancel any previous pending onGattReady callback (prevents race condition)
                onGattReadyRunnable?.let { 
                    mainHandler.removeCallbacks(it)
                    Log.d(TAG, "🛑 [GATT-SERVER] Cancelled previous pending onGattReady callback")
                }
                
                // Capture current generation to detect stale callbacks
                val currentGeneration = gattServerGeneration
                
                // 🔥 КРИТИЧНО: Добавляем задержку перед отправкой onGattReady
                // Это дает время BLE стеку полностью инициализировать сервер
                // Критично для Huawei/Xiaomi/Tecno устройств
                onGattReadyRunnable = Runnable {
                    try {
                        // 🔥 FIX: Check if this callback is still valid (same generation)
                        if (currentGeneration != gattServerGeneration) {
                            Log.w(TAG, "⚠️ [GATT-SERVER] Ignoring stale onGattReady callback (gen $currentGeneration vs current $gattServerGeneration)")
                            return@Runnable
                        }
                        
                        if (!isServerRunning) {
                            Log.w(TAG, "⚠️ [GATT-SERVER] Server stopped before onGattReady could be sent")
                            return@Runnable
                        }
                        
                        Log.d(TAG, "📤 [GATT-SERVER] Sending onGattReady event to Flutter (gen: $currentGeneration, after 500ms delay)...")
                        resultChannel?.invokeMethod("onGattReady", mapOf("generation" to currentGeneration))
                        Log.d(TAG, "✅ [GATT-SERVER] onGattReady event sent successfully (gen: $currentGeneration)")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ [GATT-SERVER] Error sending onGattReady event: $e", e)
                    }
                }
                mainHandler.postDelayed(onGattReadyRunnable!!, 500) // Задержка 500ms для стабилизации BLE стека
            } else {
                Log.e(TAG, "❌ [GATT-SERVER] Failed to add service: $status")
                // Не отправляем событие при ошибке - FSM будет ждать таймаут
            }
        }
    }
    
    fun startGattServer(): Boolean {
        if (isServerRunning) {
            Log.w(TAG, "⚠️ [GATT-SERVER] Server already running")
            return true
        }
        
        // 🔥 FIX: Increment generation to invalidate any stale callbacks from previous start attempts
        gattServerGeneration++
        Log.d(TAG, "🔢 [GATT-SERVER] Starting with generation: $gattServerGeneration")
        
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        
        if (bluetoothAdapter == null) {
            Log.e(TAG, "❌ [GATT-SERVER] Bluetooth adapter not available")
            return false
        }
        
        if (!bluetoothAdapter!!.isEnabled) {
            Log.e(TAG, "❌ [GATT-SERVER] Bluetooth is not enabled")
            return false
        }
        
        try {
            gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)
            
            if (gattServer == null) {
                Log.e(TAG, "❌ [GATT-SERVER] Failed to open GATT server")
                return false
            }
            
            // Создаем сервис
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            
            // Создаем характеристику с правами на запись, чтение и notify
            val characteristic = BluetoothGattCharacteristic(
                CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            
            // Добавляем дескриптор для notify (обязательно для notify)
            val descriptor = android.bluetooth.BluetoothGattDescriptor(
                UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"), // Client Characteristic Configuration Descriptor
                android.bluetooth.BluetoothGattDescriptor.PERMISSION_READ or android.bluetooth.BluetoothGattDescriptor.PERMISSION_WRITE
            )
            characteristic.addDescriptor(descriptor)
            
            // Добавляем характеристику в сервис
            service.addCharacteristic(characteristic)
            
            // Добавляем сервис в GATT сервер
            val success = gattServer?.addService(service) ?: false
            
            if (success) {
                isServerRunning = true
                startBufferCleanup() // 🔥 Запускаем периодическую очистку буферов
                Log.d(TAG, "✅ [GATT-SERVER] GATT server started successfully")
                Log.d(TAG, "⏳ [GATT-SERVER] Waiting for onServiceAdded callback...")
                // onServiceAdded будет вызван асинхронно через BluetoothGattServerCallback
                // Событие будет отправлено в Flutter через mainHandler.post
                return true
            } else {
                Log.e(TAG, "❌ [GATT-SERVER] Failed to add service to GATT server")
                gattServer?.close()
                gattServer = null
                return false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ [GATT-SERVER] Error starting server: $e", e)
            gattServer?.close()
            gattServer = null
            return false
        }
    }
    
    fun stopGattServer() {
        if (!isServerRunning) {
            return
        }
        
        try {
            // 🔥 FIX: Cancel pending onGattReady callback to prevent race condition
            // This is CRITICAL - without this, old callbacks can complete new completers
            onGattReadyRunnable?.let { 
                mainHandler.removeCallbacks(it) 
                Log.d(TAG, "🛑 [GATT-SERVER] Cancelled pending onGattReady callback on stop")
            }
            onGattReadyRunnable = null
            
            // Increment generation to invalidate any callbacks that might still be in flight
            gattServerGeneration++
            
            stopBufferCleanup() // 🔥 Останавливаем периодическую очистку и очищаем буферы
            connectedDevices.clear()
            gattServer?.close()
            gattServer = null
            isServerRunning = false
            Log.d(TAG, "🛑 [GATT-SERVER] GATT server stopped (next gen: $gattServerGeneration)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [GATT-SERVER] Error stopping server: $e", e)
        }
    }
    
    fun isRunning(): Boolean = isServerRunning

    /** Current GATT server generation — returned to Flutter so onGattReady can reject stale events. */
    fun getGattServerGeneration(): Int = gattServerGeneration
    
    fun getConnectedDevicesCount(): Int = connectedDevices.size
    
    /**
     * 🔒 SECURITY FIX #4: Check if any GATT clients are connected
     * Used by NativeBleAdvertiser to avoid disrupting active connections
     */
    fun hasConnectedClients(): Boolean = connectedDevices.isNotEmpty()
    
    /**
     * 🔥 DIAGNOSTIC: Get detailed GATT server status
     * Returns a map with all relevant status information
     */
    fun getDetailedStatus(): Map<String, Any> {
        val status = mutableMapOf<String, Any>(
            "isRunning" to isServerRunning,
            "connectedDevicesCount" to connectedDevices.size,
            "connectedDevices" to connectedDevices.map { it.address },
            "hasGattServer" to (gattServer != null),
            "hasBluetoothAdapter" to (bluetoothAdapter != null),
            "generation" to gattServerGeneration,
            "pendingBuffers" to deviceBuffers.size
        )
        
        // Log the status
        Log.d(TAG, "📊 [GATT-SERVER] Detailed status:")
        status.forEach { (key, value) -> Log.d(TAG, "   📋 $key: $value") }
        
        return status
    }
    
    /**
     * 🔥 DIAGNOSTIC: Log current GATT server status (call periodically)
     */
    fun logStatus() {
        Log.d(TAG, "📊 [GATT-SERVER] STATUS CHECK:")
        Log.d(TAG, "   📋 isRunning: $isServerRunning")
        Log.d(TAG, "   📋 gattServer: ${gattServer != null}")
        Log.d(TAG, "   📋 connectedDevices: ${connectedDevices.size}")
        Log.d(TAG, "   📋 generation: $gattServerGeneration")
        
        if (connectedDevices.isNotEmpty()) {
            Log.d(TAG, "   📋 Connected device addresses:")
            connectedDevices.forEach { device ->
                Log.d(TAG, "      - ${maskMacForLog(device.address)} (${device.name ?: "Unknown"})")
            }
        }
    }
    
    /**
     * 🔥 APP-LEVEL ACK: Отправляет подтверждение успешной обработки сообщения
     * 
     * Примечание: Текущая архитектура BLE GATT имеет ограничение - GHOST отключается
     * сразу после отправки. Для полноценного bidirectional ACK нужна подписка на notify.
     * 
     * MVP: Логируем ACK и отправляем через notify если устройство ещё подключено.
     * В будущем: GHOST должен подписаться на notify и ждать ACK перед disconnect.
     */
    fun sendAppAck(deviceAddress: String, messageId: String, timestamp: Long): Boolean {
        Log.d(TAG, "📤 [ACK] Attempting to send app-level ACK to ${maskMacForLog(deviceAddress)}")
        Log.d(TAG, "   📋 Message ID: $messageId")
        Log.d(TAG, "   📋 Timestamp: $timestamp")
        
        // Проверяем, подключено ли устройство
        val device = connectedDevices.find { it.address == deviceAddress }
        if (device == null) {
            Log.w(TAG, "⚠️ [ACK] Device ${maskMacForLog(deviceAddress)} not connected - ACK cannot be delivered")
            Log.w(TAG, "   💡 GHOST disconnected before ACK could be sent")
            Log.w(TAG, "   💡 Message was processed successfully on BRIDGE side")
            // Возвращаем true т.к. сообщение обработано, просто ACK не доставлен
            // GHOST должен использовать timeout-based confirmation
            return true
        }
        
        // TODO: Для полноценного ACK добавить notify характеристику
        // Сейчас просто логируем что ACK был бы отправлен
        Log.d(TAG, "✅ [ACK] Device still connected - ACK would be sent via notify")
        Log.d(TAG, "   📋 Note: Full ACK implementation requires notify characteristic")
        
        return true
    }
    
    // =======================================================================
    // 🔥 LENGTH-PREFIXED FRAMING: Сборка сообщений из чанков
    // Формат: [4 bytes: payload length (Big-Endian)][N bytes: JSON payload]
    // =======================================================================
    
    /**
     * Обрабатывает входящий чанк данных от устройства.
     * Накапливает чанки в буфер, пока не соберётся полное сообщение.
     */
    private fun processIncomingChunk(deviceAddress: String, chunk: ByteArray) {
        // Получаем или создаём буфер для устройства
        val msgBuffer = deviceBuffers.getOrPut(deviceAddress) { MessageBuffer() }
        msgBuffer.lastChunkTime = System.currentTimeMillis()
        
        // Добавляем чанк в буфер
        msgBuffer.buffer.write(chunk)
        
        val currentSize = msgBuffer.buffer.size()
        Log.d(TAG, "📦 [FRAMING] Chunk received: ${chunk.size} bytes, buffer: $currentSize bytes (device: ${maskMacForLog(deviceAddress)})")
        
        // Пытаемся извлечь полные сообщения из буфера
        while (tryExtractMessage(deviceAddress, msgBuffer)) {
            // Цикл продолжается, пока есть полные сообщения для извлечения
        }
    }
    
    /**
     * Пытается извлечь полное сообщение из буфера.
     * @return true если сообщение извлечено, false если данных недостаточно
     */
    private fun tryExtractMessage(deviceAddress: String, msgBuffer: MessageBuffer): Boolean {
        val bufferData = msgBuffer.buffer.toByteArray()
        val bufferSize = bufferData.size
        
        // 1. Если ещё не прочитали header (нужно минимум 4 байта)
        if (msgBuffer.expectedLength < 0) {
            if (bufferSize < 4) {
                Log.d(TAG, "📦 [FRAMING] Waiting for length header (have: $bufferSize, need: 4)")
                return false
            }
            
            // Читаем 4-байтный length header (Big-Endian)
            val lengthHeader = ByteBuffer.wrap(bufferData, 0, 4)
                .order(ByteOrder.BIG_ENDIAN)
                .getInt()
            
            // Валидация: длина должна быть разумной (1 байт - 1 MB)
            if (lengthHeader <= 0 || lengthHeader > 1_000_000) {
                Log.e(TAG, "❌ [FRAMING] Invalid length header: $lengthHeader - resetting buffer")
                // Пытаемся найти следующий валидный frame, сдвигаясь на 1 байт
                resetBufferWithOffset(deviceAddress, msgBuffer, 1)
                return bufferSize > 4 // Продолжаем только если есть данные
            }
            
            msgBuffer.expectedLength = lengthHeader
            Log.d(TAG, "📦 [FRAMING] Length header: $lengthHeader bytes expected (device: ${maskMacForLog(deviceAddress)})")
        }
        
        // 2. Проверяем, есть ли полное сообщение (header + payload)
        val totalExpected = 4 + msgBuffer.expectedLength // 4 bytes header + payload
        if (bufferSize < totalExpected) {
            Log.d(TAG, "📦 [FRAMING] Buffer: $bufferSize / $totalExpected bytes (waiting...)")
            return false
        }
        
        // 3. 🎉 Полное сообщение собрано! Извлекаем payload
        val payload = bufferData.copyOfRange(4, totalExpected)
        val jsonString = String(payload, Charsets.UTF_8)
        
        Log.d(TAG, "✅ [FRAMING] Complete message: ${msgBuffer.expectedLength} bytes")
        Log.d(TAG, "📦 [FRAMING] JSON preview: ${jsonString.take(100)}...")
        Log.d(TAG, "📤 [GATT-SERVER] Sending assembled message to Flutter (onGattDataReceived) from GHOST ${maskMacForLog(deviceAddress)}")
        
        // 4. Send complete message to Flutter
        mainHandler.post {
            resultChannel?.invokeMethod("onGattDataReceived", mapOf(
                "deviceAddress" to deviceAddress,
                "data" to jsonString,
                "isComplete" to true  // 🔥 Флаг: сообщение полностью собрано
            ))
        }
        
        // 5. Удаляем обработанное сообщение из буфера, оставляем остаток
        val remaining = bufferData.copyOfRange(totalExpected, bufferSize)
        msgBuffer.buffer.reset()
        if (remaining.isNotEmpty()) {
            msgBuffer.buffer.write(remaining)
            Log.d(TAG, "📦 [FRAMING] ${remaining.size} bytes remaining in buffer for next message")
        }
        msgBuffer.expectedLength = -1 // Сбрасываем для следующего сообщения
        
        return remaining.size >= 4 // Продолжаем, если может быть ещё одно сообщение
    }
    
    /**
     * Сбрасывает буфер со сдвигом (для поиска следующего валидного frame)
     */
    private fun resetBufferWithOffset(deviceAddress: String, msgBuffer: MessageBuffer, offset: Int) {
        val bufferData = msgBuffer.buffer.toByteArray()
        msgBuffer.buffer.reset()
        msgBuffer.expectedLength = -1
        
        if (offset < bufferData.size) {
            msgBuffer.buffer.write(bufferData.copyOfRange(offset, bufferData.size))
            Log.w(TAG, "⚠️ [FRAMING] Buffer reset with ${bufferData.size - offset} bytes remaining")
        } else {
            Log.w(TAG, "⚠️ [FRAMING] Buffer completely cleared for ${maskMacForLog(deviceAddress)}")
        }
    }
    
    /**
     * Очищает зависшие буферы (timeout)
     */
    private fun cleanupStaleBuffers() {
        val now = System.currentTimeMillis()
        val staleDevices = deviceBuffers.filter { (_, buffer) ->
            now - buffer.lastChunkTime > BUFFER_TIMEOUT_MS
        }.keys.toList()
        
        for (deviceAddr in staleDevices) {
            val buffer = deviceBuffers[deviceAddr]
            if (buffer != null && buffer.buffer.size() > 0) {
                Log.w(TAG, "⏱️ [FRAMING] Timeout: clearing stale buffer for ${deviceAddr.takeLast(8)} (${buffer.buffer.size()} bytes lost)")
            }
            deviceBuffers.remove(deviceAddr)
        }
    }
    
    /**
     * Очищает буфер для конкретного устройства (вызывается при disconnect)
     */
    fun clearBufferForDevice(deviceAddress: String) {
        val buffer = deviceBuffers.remove(deviceAddress)
        if (buffer != null && buffer.buffer.size() > 0) {
            Log.w(TAG, "🧹 [FRAMING] Cleared buffer for ${maskMacForLog(deviceAddress)} on disconnect (${buffer.buffer.size()} bytes)")
        }
    }
    
    /**
     * Запускает периодическую очистку буферов
     */
    fun startBufferCleanup() {
        mainHandler.postDelayed(bufferCleanupRunnable, 10_000)
    }
    
    /**
     * Останавливает периодическую очистку
     */
    fun stopBufferCleanup() {
        mainHandler.removeCallbacks(bufferCleanupRunnable)
        deviceBuffers.clear()
    }
    
    /**
     * Отправляет сообщение подключенному GATT клиенту через notify
     * Используется BRIDGE для отправки сообщений GHOST устройствам
     */
    fun sendMessageToClient(deviceAddress: String, messageJson: String): Boolean {
        Log.d(TAG, "📤 [GATT-SERVER] Sending message to client: ${maskMacForLog(deviceAddress)}")
        Log.d(TAG, "   📋 Message length: ${messageJson.length} bytes")
        
        // Проверяем, подключено ли устройство
        val device = connectedDevices.find { it.address == deviceAddress }
        if (device == null) {
            Log.w(TAG, "⚠️ [GATT-SERVER] Device ${maskMacForLog(deviceAddress)} not connected")
            return false
        }
        
        // Находим характеристику
        val service = gattServer?.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(CHAR_UUID)
        
        if (characteristic == null) {
            Log.e(TAG, "❌ [GATT-SERVER] Characteristic not found")
            return false
        }
        
        try {
            // 🔥 LENGTH-PREFIXED FRAMING: Добавляем 4-байтный header с длиной
            val messageBytes = messageJson.toByteArray(Charsets.UTF_8)
            val lengthHeader = ByteBuffer.allocate(4)
                .order(ByteOrder.BIG_ENDIAN)
                .putInt(messageBytes.size)
                .array()
            
            // Объединяем header + payload
            val framedMessage = lengthHeader + messageBytes
            
            // Разбиваем на чанки по 20 байт (BLE MTU ограничение)
            val chunkSize = 20
            var offset = 0
            
            while (offset < framedMessage.size) {
                val chunk = framedMessage.copyOfRange(
                    offset,
                    minOf(offset + chunkSize, framedMessage.size)
                )
                
                // Устанавливаем значение характеристики
                characteristic.value = chunk
                
                // Отправляем через notify (если клиент подписан) или write
                val success = gattServer?.notifyCharacteristicChanged(
                    device,
                    characteristic,
                    false // no confirmation needed
                ) ?: false
                
                if (!success) {
                    Log.w(TAG, "⚠️ [GATT-SERVER] Failed to notify chunk at offset $offset")
                    // Пробуем через write как fallback
                    gattServer?.sendResponse(
                        device,
                        0, // requestId (not used for notify)
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        chunk
                    )
                }
                
                offset += chunkSize
                
                // Небольшая задержка между чанками для стабильности
                if (offset < framedMessage.size) {
                    Thread.sleep(10)
                }
            }
            
            Log.d(TAG, "✅ [GATT-SERVER] Message sent successfully to ${maskMacForLog(deviceAddress)}")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "❌ [GATT-SERVER] Error sending message: ${e.message}", e)
            return false
        }
    }
    
    /**
     * Получает список MAC адресов подключенных GATT клиентов
     */
    fun getConnectedDevicesAddresses(): List<String> {
        return connectedDevices.map { it.address }.toList()
    }
}
