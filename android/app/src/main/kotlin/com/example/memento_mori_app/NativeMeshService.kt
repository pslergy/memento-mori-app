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
    private val context: Context,
    private val manager: WifiP2pManager,
    private val p2pChannel: WifiP2pManager.Channel,
    private val p2pHelper: WifiP2pHelper?
) : MethodChannel.MethodCallHandler {

    private val uiHandler = Handler(Looper.getMainLooper())
    private var gattServerHelper: GattServerHelper? = null
    
    fun setGattServerHelper(helper: GattServerHelper?) {
        gattServerHelper = helper
    }

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

            "checkP2pState" -> {
                val isEnabled = p2pHelper?.isP2pEnabled() ?: false
                result.success(mapOf("enabled" to isEnabled))
            }

            "checkDiscoveryState" -> {
                val isActive = p2pHelper?.isDiscoveryActive() ?: false
                result.success(mapOf("active" to isActive))
            }

            "requestP2pActivation" -> {
                p2pHelper?.requestP2pActivation()
                result.success(true)
            }

            "connect" -> {
                val addr = call.argument<String>("deviceAddress")
                val networkName = call.argument<String>("networkName")
                val passphrase = call.argument<String>("passphrase")
                val groupOwnerIntent = call.argument<Int>("groupOwnerIntent") ?: 15
                if (addr != null) {
                    p2pHelper?.connect(addr, networkName, passphrase, groupOwnerIntent)
                    result.success(true)
                } else result.error("ERR", "No address", null)
            }

            "sendTcp" -> {
                val host = call.argument<String>("host") ?: "192.168.49.1"
                val port = call.argument<Int>("port") ?: 55556 // Единый порт: BRIDGE слушает, GHOST шлёт
                val msg = call.argument<String>("message") ?: ""
                p2pHelper?.sendTcp(host, port, msg)
                result.success(true)
            }

            "forceReset" -> {
                p2pHelper?.forceReset { result.success(true) }
            }
            
            // 🔥 АВТОМАТИЧЕСКОЕ УПРАВЛЕНИЕ WI-FI DIRECT ГРУППОЙ
            "createGroup" -> {
                val forceCreate = call.argument<Boolean>("forceCreate") ?: false
                p2pHelper?.createGroup(forceCreate) { groupInfo ->
                    uiHandler.post {
                        if (groupInfo != null) {
                            result.success(mapOf(
                                "success" to true,
                                "networkName" to groupInfo.networkName,
                                "passphrase" to groupInfo.passphrase,
                                "isGroupOwner" to groupInfo.isGroupOwner,
                                "clientCount" to groupInfo.clientCount
                            ))
                        } else {
                            result.success(mapOf("success" to false))
                        }
                    }
                } ?: result.success(mapOf("success" to false))
            }
            
            "removeGroup" -> {
                p2pHelper?.removeGroup { success ->
                    uiHandler.post {
                        result.success(mapOf("success" to success))
                    }
                } ?: result.success(mapOf("success" to false))
            }
            
            "getGroupInfo" -> {
                p2pHelper?.getGroupInfo { groupInfo ->
                    uiHandler.post {
                        if (groupInfo != null) {
                            result.success(mapOf(
                                "exists" to true,
                                "networkName" to groupInfo.networkName,
                                "passphrase" to groupInfo.passphrase,
                                "isGroupOwner" to groupInfo.isGroupOwner,
                                "ownerAddress" to groupInfo.ownerAddress,
                                "clientCount" to groupInfo.clientCount
                            ))
                        } else {
                            result.success(mapOf("exists" to false))
                        }
                    }
                } ?: result.success(mapOf("exists" to false))
            }
            
            "ensureGroupExists" -> {
                p2pHelper?.ensureGroupExists { groupInfo ->
                    uiHandler.post {
                        if (groupInfo != null) {
                            result.success(mapOf(
                                "success" to true,
                                "networkName" to groupInfo.networkName,
                                "passphrase" to groupInfo.passphrase,
                                "isGroupOwner" to groupInfo.isGroupOwner,
                                "clientCount" to groupInfo.clientCount
                            ))
                        } else {
                            result.success(mapOf("success" to false))
                        }
                    }
                } ?: result.success(mapOf("success" to false))
            }
            
            "isGroupOwner" -> {
                val isOwner = p2pHelper?.isCurrentlyGroupOwner() ?: false
                result.success(mapOf("isGroupOwner" to isOwner))
            }

            "canStartTcpServer" -> {
                val canStart = DeviceDetector.canStartTcpServer(context)
                result.success(canStart)
            }
            
            "startGattServer" -> {
                val success = gattServerHelper?.startGattServer() ?: false
                result.success(success)
            }
            
            "stopGattServer" -> {
                gattServerHelper?.stopGattServer()
                result.success(true)
            }
            
            "isGattServerRunning" -> {
                val isRunning = gattServerHelper?.isRunning() ?: false
                result.success(isRunning)
            }

            "startTemporaryTcpServer" -> {
                // Проверяем перед запуском
                val canStart = DeviceDetector.canStartTcpServer(context)
                if (!canStart) {
                    result.error("TCP_SERVER_DISABLED", "TCP server disabled for weak device or after crash", null)
                    return@onMethodCall
                }
                
                val durationSeconds = call.argument<Int>("durationSeconds") ?: 20
                MeshBackgroundService.startTemporaryServer(context, durationSeconds)
                result.success(true)
            }

            "stopTemporaryTcpServer" -> {
                MeshBackgroundService.stopTemporaryServer(context)
                result.success(true)
            }

            "getQueuedMessages" -> {
                Thread {
                    try {
                        val messages = MeshBackgroundService.getQueuedMessages(context)
                        uiHandler.post { result.success(messages) }
                    } catch (e: Exception) {
                        uiHandler.post { result.error("QUEUE_ERROR", e.message, null) }
                    }
                }.start()
            }

            else -> result.notImplemented()
        }
    }
}