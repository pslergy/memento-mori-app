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
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class GattServerHelper(
    private val context: Context,
    private val resultChannel: MethodChannel?
) {
    private val TAG = "GATT_SERVER"
    
    private val SERVICE_UUID = UUID.fromString("bf27730d-860a-4e09-889c-2d8b6a9e0fe7")
    private val CHAR_UUID = UUID.fromString("c22d1e32-0310-4062-812e-89025078da9c")
    
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gattServer: BluetoothGattServer? = null
    private var isServerRunning = false
    
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    
    // Handler для выполнения вызовов MethodChannel на главном потоке
    private val mainHandler = Handler(Looper.getMainLooper())
    
    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            super.onConnectionStateChange(device, status, newState)
            
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.d(TAG, "✅ [GATT-SERVER] Device connected: ${device.address}")
                    connectedDevices.add(device)
                    
                    // Уведомляем Flutter о подключении (на главном потоке)
                    mainHandler.post {
                        resultChannel?.invokeMethod("onGattClientConnected", mapOf(
                            "deviceAddress" to device.address,
                            "deviceName" to (device.name ?: "Unknown")
                        ))
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.d(TAG, "❌ [GATT-SERVER] Device disconnected: ${device.address}")
                    connectedDevices.remove(device)
                    
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
            
            Log.d(TAG, "📥 [GATT-SERVER] Write request from ${device.address}, size: ${value?.size ?: 0}")
            
            if (characteristic.uuid == CHAR_UUID && value != null) {
                try {
                    // Отправляем данные в Flutter для обработки
                    val dataString = String(value, Charsets.UTF_8)
                    Log.d(TAG, "📦 [GATT-SERVER] Received data: ${dataString.take(100)}...")
                    
                    // Уведомляем Flutter на главном потоке
                    mainHandler.post {
                        resultChannel?.invokeMethod("onGattDataReceived", mapOf(
                            "deviceAddress" to device.address,
                            "data" to dataString
                        ))
                    }
                    
                    // Отправляем успешный ответ
                    if (responseNeeded && gattServer != null) {
                        gattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            null
                        )
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ [GATT-SERVER] Error processing write request: $e")
                    
                    // Отправляем ошибку
                    if (responseNeeded && gattServer != null) {
                        gattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_FAILURE,
                            offset,
                            null
                        )
                    }
                }
            } else {
                // Неизвестная характеристика или пустые данные
                if (responseNeeded && gattServer != null) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_FAILURE,
                        offset,
                        null
                    )
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
            
            Log.d(TAG, "📤 [GATT-SERVER] Read request from ${device.address}")
            
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
                // Уведомляем Flutter о готовности GATT сервера (на главном потоке)
                mainHandler.post {
                    try {
                        Log.d(TAG, "📤 [GATT-SERVER] Sending onGattReady event to Flutter...")
                        resultChannel?.invokeMethod("onGattReady", null)
                        Log.d(TAG, "✅ [GATT-SERVER] onGattReady event sent successfully")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ [GATT-SERVER] Error sending onGattReady event: $e", e)
                    }
                }
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
            
            // Создаем характеристику с правами на запись и чтение
            val characteristic = BluetoothGattCharacteristic(
                CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            
            // Добавляем характеристику в сервис
            service.addCharacteristic(characteristic)
            
            // Добавляем сервис в GATT сервер
            val success = gattServer?.addService(service) ?: false
            
            if (success) {
                isServerRunning = true
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
            connectedDevices.clear()
            gattServer?.close()
            gattServer = null
            isServerRunning = false
            Log.d(TAG, "🛑 [GATT-SERVER] GATT server stopped")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [GATT-SERVER] Error stopping server: $e", e)
        }
    }
    
    fun isRunning(): Boolean = isServerRunning
    
    fun getConnectedDevicesCount(): Int = connectedDevices.size
}
