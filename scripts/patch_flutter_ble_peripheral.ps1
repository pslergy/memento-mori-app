# Patch flutter_ble_peripheral to fix "Reply already submitted" crash
# Run after: flutter pub get
# Issue: onAdvertisingSetStarted can be called multiple times by Android BLE stack

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$patchFile = Join-Path $scriptDir "patches\PeripheralAdvertisingSetCallback.kt"
$pubCache = $env:LOCALAPPDATA + "\Pub\Cache\hosted\pub.dev"
$pluginPath = Join-Path $pubCache "flutter_ble_peripheral-2.0.1"
$targetPath = Join-Path $pluginPath "android\src\main\kotlin\dev\steenbakker\flutter_ble_peripheral\callbacks\PeripheralAdvertisingSetCallback.kt"

if (-not (Test-Path $patchFile)) {
    Write-Host "Patch file not found: $patchFile" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path (Split-Path $targetPath -Parent))) {
    Write-Host "Plugin not found. Run 'flutter pub get' first." -ForegroundColor Red
    exit 1
}

Copy-Item $patchFile $targetPath -Force
Write-Host "Patch applied successfully." -ForegroundColor Green
