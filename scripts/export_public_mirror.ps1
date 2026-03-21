<#
.SYNOPSIS
  Копирует репозиторий в целевую папку и удаляет пути из tools/opensource/exclude-from-public.txt.
  Подставляет заглушку MainActivity (tools/opensource/stubs/MainActivity.public.kt).
  Не трогает исходный .git — в целевой папке делайте git init отдельно.

.EXAMPLE
  .\scripts\export_public_mirror.ps1 -Destination "D:\memento_mori_public"
#>
param(
  [Parameter(Mandatory = $true)]
  [string] $Destination,

  [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$manifest = Join-Path $RepoRoot "tools\opensource\exclude-from-public.txt"
$stubMain = Join-Path $RepoRoot "tools\opensource\stubs\MainActivity.public.kt"
$noticeSrc = Join-Path $RepoRoot "tools\opensource\PUBLIC_SNAPSHOT_NOTICE.txt"

if (-not (Test-Path $manifest)) { throw "Manifest not found: $manifest" }
if (-not (Test-Path $stubMain)) { throw "Stub not found: $stubMain" }
if (-not (Test-Path $noticeSrc)) { throw "Notice not found: $noticeSrc" }

$dest = $Destination.TrimEnd('\', '/')
if (Test-Path $dest) {
  throw "Destination already exists: $dest (удалите или укажите другую папку)"
}

Write-Host "Mirroring to $dest ..."
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# robocopy: зеркало без .git / build / IDE
$excludeDirs = @('.git', '.dart_tool', 'build', '.idea', 'ios/Pods', 'node_modules', '_public_export', 'public_mirror_out')
$rcArgs = @($RepoRoot, $dest, '/E', '/XD') + $excludeDirs + @('/XF', '.DS_Store')
& robocopy @rcArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }

function Remove-RelPath {
  param([string] $rel)
  $rel = $rel.Trim()
  if ($rel -match '^\s*#' -or $rel -eq '') { return }
  $full = Join-Path $dest $rel.Replace('/', '\')
  if (Test-Path $full) {
    Remove-Item -LiteralPath $full -Recurse -Force
    Write-Host "  removed: $rel"
  }
}

Get-Content -LiteralPath $manifest -Encoding UTF8 | ForEach-Object { Remove-RelPath $_ }

# Публично не публикуем ни один .md (внутренние отчёты, README в подпроектах и т.д.)
$mdFiles = Get-ChildItem -LiteralPath $dest -Recurse -File -Filter "*.md" -ErrorAction SilentlyContinue
if ($mdFiles) {
  $mdFiles | Remove-Item -Force
  Write-Host "  removed: all *.md ($($mdFiles.Count) file(s))"
}

$mainDest = Join-Path $dest "android\app\src\main\kotlin\com\example\memento_mori_app\MainActivity.kt"
$mainDir = Split-Path $mainDest -Parent
if (-not (Test-Path $mainDest)) {
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  Copy-Item -LiteralPath $stubMain -Destination $mainDest -Force
  Write-Host "  stub: MainActivity.kt"
}

$noticeDest = Join-Path $dest "docs\PUBLIC_SNAPSHOT_NOTICE.txt"
New-Item -ItemType Directory -Path (Split-Path $noticeDest -Parent) -Force | Out-Null
Copy-Item -LiteralPath $noticeSrc -Destination $noticeDest -Force
Write-Host "  copied: docs/PUBLIC_SNAPSHOT_NOTICE.txt"

Write-Host "Done. В $dest выполните: git init && git add -A && git commit -m 'Public snapshot'"
Write-Host "Подробности: docs/OPENSOURCE_PUBLIC_MIRROR.md (в приватном репо)"
