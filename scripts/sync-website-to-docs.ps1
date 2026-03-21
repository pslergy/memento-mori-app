# Sync website/ to docs/ for GitHub Pages deploy.
# Run from project root: .\scripts\sync-website-to-docs.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Copy styles
Copy-Item "$root\website\styles.css" -Destination "$root\docs\styles.css" -Force

# Copy index.html and fix paths for docs (base href + local assets)
$index = Get-Content "$root\website\index.html" -Raw
$index = $index -replace 'href="../web/favicon.png"', 'href="favicon.png"'
$index = $index -replace 'src="../assets/screenshots/', 'src="screenshots/'
if ($index -notmatch '<base href=') {
  $index = $index -replace '(\s+<link rel="icon")', "  <base href=`"/memento-mori-app/`">`n`$1"
}
Set-Content "$root\docs\index.html" -Value $index -NoNewline

# Copy screenshots (only the ones used on the site)
New-Item -ItemType Directory -Force -Path "$root\docs\screenshots" | Out-Null
@("1.jpg","2.jpg","3.jpg","4.jpg","5.jpg") | ForEach-Object {
  Copy-Item "$root\assets\screenshots\$_" -Destination "$root\docs\screenshots\$_" -Force -ErrorAction SilentlyContinue
}

# Copy favicon
Copy-Item "$root\web\favicon.png" -Destination "$root\docs\favicon.png" -Force -ErrorAction SilentlyContinue

Write-Host "Done. docs/ updated for GitHub Pages."
