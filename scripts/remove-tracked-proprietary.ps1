# Удаляет из индекса Git файлы, перечисленные в .gitignore (проприетарный код).
# Файлы остаются на диске, но перестают отслеживаться.
# Запуск: из корня репо: .\scripts\remove-tracked-proprietary.ps1

$paths = @(
    "android/app/src/main/kotlin/com/example/memento_mori_app/GattServerHelper.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/NativeMeshService.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/NativeBleAdvertiser.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/WifiP2pHelper.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/MeshBackgroundService.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/FFT.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/UltrasonicCalibrator.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/DeviceDetector.kt",
    "android/app/src/main/kotlin/com/example/memento_mori_app/RouterHelper.kt",
    "lib/core/mesh_service.dart",
    "lib/core/bluetooth_service.dart",
    "lib/core/gossip_manager.dart",
    "lib/core/ble_hardware_strategy.dart",
    "lib/core/ble_state_machine.dart",
    "lib/core/ble_session.dart",
    "lib/core/native_mesh_service.dart",
    "lib/core/ghost_transfer_manager.dart",
    "lib/core/crdt_reconciliation.dart",
    "lib/core/fragment_security_service.dart",
    "lib/core/mesh_protocol.dart",
    "lib/core/connection_stabilizer.dart",
    "lib/core/discovery_context_service.dart",
    "lib/core/peer_cache_service.dart",
    "lib/core/ble_vendor_profile.dart",
    "lib/core/ble_interaction_stats.dart",
    "lib/core/hardware_check_service.dart",
    "lib/core/ghost_behavior_flags.dart",
    "lib/core/ultrasonic_service.dart",
    "lib/core/message_signing_service.dart",
    "lib/core/repeater_service.dart",
    "lib/core/mesh_health_monitor.dart",
    "lib/core/mesh_diagnostics.dart",
    "lib/core/connection_phase.dart",
    "lib/core/network_phase_context.dart",
    "lib/core/link_capabilities.dart",
    "lib/core/role/ghost_role.dart",
    "lib/core/role/message_router.dart",
    "lib/core/role/delivery_path.dart",
    "lib/core/role/role_negotiator.dart",
    "lib/core/router",
    "lib/core/encryption_service.dart",
    "lib/core/security_service.dart",
    "lib/core/security_config.dart",
    "lib/core/security_utils.dart",
    "lib/core/security_timing.dart",
    "lib/core/decoy",
    "docs/BLE_DIAGNOSTIC_REPORT.md",
    "docs/RESUME_SYSTEM_AUDIT.md",
    "docs/FULL_APP_AUDIT.md",
    "docs/BEACON_AND_CHAT_RECOMMENDATIONS.md"
)

$root = (Get-Location).Path
if (-not (Test-Path ".git")) {
    Write-Host "Запустите скрипт из корня репозитория (где лежит .git)." -ForegroundColor Red
    exit 1
}

foreach ($p in $paths) {
    if (Test-Path $p) {
        git rm -r --cached $p 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "OK: $p" } else { git rm --cached $p 2>$null; Write-Host "OK: $p" }
    } else {
        Write-Host "Skip (not found): $p" -ForegroundColor Gray
    }
}

Write-Host "`nГотово. Дальше: git add .gitignore && git status && git commit -m \"...\" && git push" -ForegroundColor Green
