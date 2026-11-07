# Uninstalls the CoopSync co-op mod (run from Uninstall.bat): removes UE4SS and the mod from the game folder and brings
# back the UE4SS that was there before the install (if any). Saves and their backups are not touched.
param([string]$GameDir)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\common.ps1"
function Fail($s) { Write-Host ""; Write-Host "ERROR: $s" -ForegroundColor Red; exit 1 }

Write-Host "=== Uninstalling the CoopSync co-op mod ==="
if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir) { Fail "The game was not found through Steam. Run: Uninstall.bat ""<game folder>""." }
$bin = Game-Bin $GameDir
if (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$bin*" }) { Fail "Close the game and run the uninstaller again." }
Get-Process CoopNet -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$bin*" } | Stop-Process -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$bin\ue4ss\CoopSync-installed.txt")) { Fail "The mod is not installed in $bin (no install marker)." }

Remove-Item "$bin\ue4ss" -Recurse -Force
Remove-Item "$bin\dwmapi.dll" -Force -ErrorAction SilentlyContinue
# steam_appid.txt, if the two-copies script put it there (TwoGamesTest.bat)
if (Test-Path "$bin\steam_appid.txt.coopsync") { Remove-Item "$bin\steam_appid.txt", "$bin\steam_appid.txt.coopsync" -Force -ErrorAction SilentlyContinue }
if (Test-Path "$bin\ue4ss.before-coopsync") {
    Move-Item "$bin\ue4ss.before-coopsync" "$bin\ue4ss"
    if (Test-Path "$bin\dwmapi.dll.before-coopsync") { Move-Item "$bin\dwmapi.dll.before-coopsync" "$bin\dwmapi.dll" }
    Write-Host "The UE4SS that was there before the mod is back."
}
Write-Host ""
Write-Host "The mod is uninstalled. Saves are untouched; their copies from the install are in Documents\PacificDriveCoop."
