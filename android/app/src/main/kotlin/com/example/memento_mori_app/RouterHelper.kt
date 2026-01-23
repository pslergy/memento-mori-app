package com.example.memento_mori_app

import android.content.Context
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.*

class RouterHelper(private val context: Context) {
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    companion object {
        private const val TAG = "RouterHelper"
    }

    /// Сканирует доступные Wi-Fi сети
    fun scanWifiNetworks(): List<Map<String, Any>> {
        if (!wifiManager.isWifiEnabled) {
            Log.w(TAG, "Wi-Fi is disabled")
            return emptyList()
        }

        val scanResults = wifiManager.scanResults
        val networks = mutableListOf<Map<String, Any>>()

        for (result in scanResults) {
            networks.add(mapOf(
                "ssid" to (result.SSID ?: ""),
                "bssid" to (result.BSSID ?: ""),
                "rssi" to result.level,
                "capabilities" to (result.capabilities ?: ""),
                "frequency" to result.frequency,
                "isSecure" to (result.capabilities?.contains("WPA") == true || result.capabilities?.contains("WEP") == true)
            ))
        }

        Log.d(TAG, "Scanned ${networks.size} Wi-Fi networks")
        return networks
    }

    /// Подключается к роутеру по SSID и паролю
    fun connectToRouter(ssid: String, password: String?): Boolean {
        try {
            if (!wifiManager.isWifiEnabled) {
                wifiManager.isWifiEnabled = true
                Thread.sleep(2000) // Ждем включения Wi-Fi
            }

            val wifiConfig = WifiConfiguration().apply {
                SSID = "\"$ssid\""
                if (password != null && password.isNotEmpty()) {
                    preSharedKey = "\"$password\""
                    allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
                } else {
                    allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
                }
            }

            // Удаляем старую конфигурацию если есть
            val existingConfig = wifiManager.configuredNetworks?.find { it.SSID == "\"$ssid\"" }
            if (existingConfig != null) {
                wifiManager.removeNetwork(existingConfig.networkId)
            }

            val networkId = wifiManager.addNetwork(wifiConfig)
            if (networkId == -1) {
                Log.e(TAG, "Failed to add network configuration")
                return false
            }

            val success = wifiManager.enableNetwork(networkId, true)
            wifiManager.reconnect()

            Log.d(TAG, "Connection to $ssid: ${if (success) "initiated" else "failed"}")
            return success
        } catch (e: Exception) {
            Log.e(TAG, "Error connecting to router: ${e.message}")
            return false
        }
    }

    /// Отключается от текущего роутера
    fun disconnectFromRouter(): Boolean {
        return try {
            wifiManager.disconnect()
            Log.d(TAG, "Disconnected from router")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting: ${e.message}")
            false
        }
    }

    /// Получает локальный IP адрес устройства в сети роутера
    fun getLocalIpAddress(): String? {
        return try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (intf in interfaces) {
                val addrs = Collections.list(intf.inetAddresses)
                for (addr in addrs) {
                    if (!addr.isLoopbackAddress && addr is java.net.Inet4Address) {
                        val ip = addr.hostAddress
                        Log.d(TAG, "Local IP: $ip")
                        return ip
                    }
                }
            }
            null
        } catch (e: Exception) {
            Log.e(TAG, "Error getting local IP: ${e.message}")
            null
        }
    }

    /// Проверяет доступность интернета через роутер
    fun checkInternetViaRouter(): Boolean {
        return try {
            val network = connectivityManager.activeNetwork ?: return false
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
            
            val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                             capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            
            Log.d(TAG, "Internet via router: $hasInternet")
            return hasInternet
        } catch (e: Exception) {
            Log.e(TAG, "Error checking internet: ${e.message}")
            false
        }
    }

    /// Получает информацию о текущем подключенном роутере
    fun getConnectedRouterInfo(): Map<String, Any?>? {
        return try {
            val wifiInfo = wifiManager.connectionInfo
            if (wifiInfo == null || wifiInfo.networkId == -1) {
                return null
            }

            mapOf(
                "ssid" to wifiInfo.ssid?.replace("\"", ""),
                "bssid" to wifiInfo.bssid,
                "ipAddress" to intToIp(wifiInfo.ipAddress),
                "rssi" to wifiInfo.rssi,
                "linkSpeed" to wifiInfo.linkSpeed,
                "networkId" to wifiInfo.networkId
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting router info: ${e.message}")
            null
        }
    }

    /// Конвертирует IP адрес из int в строку
    private fun intToIp(ip: Int): String {
        return String.format(
            "%d.%d.%d.%d",
            ip and 0xff,
            ip shr 8 and 0xff,
            ip shr 16 and 0xff,
            ip shr 24 and 0xff
        )
    }
}
