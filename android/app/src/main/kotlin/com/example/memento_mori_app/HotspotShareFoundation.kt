package com.example.memento_mori_app

import android.os.Build

/**
 * Основа для будущей раздачи файлов (APK) по локальной сети при работе точки доступа
 * или подключении к hotspot: HTTP-сервер на выделенном порту, без выхода в интернет.
 *
 * Полная реализация — отдельный этап:
 * - разрешения (TETHERING, локальная сеть на новых API);
 * - [android.net.wifi.WifiManager.startLocalOnlyHotspot] (O+) или системный hotspot + привязка сокета;
 * - жизненный цикл и остановка при уходе приложения в фон.
 *
 * Сейчас только контракт для MethodChannel и константы — **тетеринг и HTTP не запускаются**.
 */
object HotspotShareFoundation {

    /** Синхрон с Flutter [com.example mesh_constants kMeshHotspotShareHttpPort]. */
    const val PLANNED_HTTP_PORT: Int = 53280

    fun statusMap(): Map<String, Any?> {
        return mapOf(
            "ready" to false,
            "implemented" to false,
            "plannedHttpPort" to PLANNED_HTTP_PORT,
            "apiLevel" to Build.VERSION.SDK_INT,
            "hint" to "Stub: Hotspot + HTTP file relay not started. Use system share or P2P APK for now."
        )
    }

    fun startStubResult(): Map<String, Any?> {
        return mapOf(
            "ok" to false,
            "reason" to "not_implemented",
            "message" to "HotspotShareFoundation: tethering/HTTP server pending implementation."
        )
    }
}
