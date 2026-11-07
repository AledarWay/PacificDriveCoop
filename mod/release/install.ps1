# Installs the CoopSync co-op mod alpha for Pacific Drive (run from Install.bat).
#   1. finds the game through Steam (or takes the path from -GameDir);
#   2. backs up the saves to Documents\PacificDriveCoop\saves-<date>;
#   3. puts UE4SS (dwmapi.dll + the ue4ss folder) and the CoopSync mod into PenDriverPro\Binaries\Win64;
#      a UE4SS already there (with its own mods) is set aside as ue4ss.before-coopsync and comes back on uninstall.
param([string]$GameDir, [string]$BackupRoot)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\common.ps1"
$KnownExe = '568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E' # the game build the mod was tested on
$Version = (Get-Content "$here\files\VERSION.txt" -ErrorAction SilentlyContinue | Select-Object -First 1)

function Say($s) { Write-Host $s }
function Fail($s) { Write-Host ""; Write-Host "ERROR: $s" -ForegroundColor Red; exit 1 }


Say "=== Installing the CoopSync co-op mod $Version for Pacific Drive ==="
if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir -or -not (Test-Path "$GameDir\PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe")) {
    Fail "The game was not found through Steam. Run from a command line: Install.bat ""<game folder>"" (the one with PenDriverPro.exe)."
}
$bin = "$GameDir\PenDriverPro\Binaries\Win64"
Say "Game: $GameDir"
if (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$bin*" }) { Fail "Close the game and run the installer again." }

$hash = (Get-FileHash "$bin\PenDriverPro-Win64-Shipping.exe" -Algorithm SHA256).Hash
if ($hash -ne $KnownExe) {
    Say ""
    Say "Warning: this game version differs from the one the mod was tested on (did the game update?)."
    Say "The mod may not work or may crash. Continue? (y/n)"
    $a = Read-Host
    if ($a -notmatch '^(y|yes|д|да)$') { Fail "Installation cancelled." }
}

# a backup of the saves: copied only, the originals are not touched
$saved = Join-Path $env:LOCALAPPDATA 'PenDriverPro\Saved\SaveGames'
$backRoot = if ($BackupRoot) { $BackupRoot } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PacificDriveCoop' }
if (Test-Path $saved) {
    $back = Join-Path $backRoot ("saves-" + (Get-Date -f 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force $back | Out-Null
    Copy-Item "$saved\*" $back -Recurse -Force
    Say "Saves copied to: $back"
} else { Say "No saves yet - nothing to copy." }

# UE4SS: someone else's (not ours) is set aside whole
$marker = "$bin\ue4ss\CoopSync-installed.txt"
if ((Test-Path "$bin\ue4ss") -and -not (Test-Path $marker)) {
    if (Test-Path "$bin\ue4ss.before-coopsync") { Fail "An old set-aside ue4ss.before-coopsync was found - run Uninstall.bat first." }
    Move-Item "$bin\ue4ss" "$bin\ue4ss.before-coopsync"
    if (Test-Path "$bin\dwmapi.dll") { Move-Item "$bin\dwmapi.dll" "$bin\dwmapi.dll.before-coopsync" }
    Say "The UE4SS that was there is set aside (it comes back when the mod is uninstalled)."
}
if (Test-Path $marker) {
    # an update: the mod's old scripts and program are replaced whole
    Remove-Item "$bin\ue4ss\Mods\CoopSync" -Recurse -Force -ErrorAction SilentlyContinue
}
Copy-Item "$here\files\dwmapi.dll" "$bin\dwmapi.dll" -Force
Copy-Item "$here\files\ue4ss" $bin -Recurse -Force
Set-Content $marker "CoopSync $Version installed $(Get-Date -f s)`r`ngame exe $hash" -Encoding utf8

Say ""
Say "Done. Start the game from Steam as usual."
Say "The co-op menu: the Co-op item in the pause menu (Esc), or the F7 key."
Say "If something broke: in the same menu Debug -> Collect report (or Report.bat next to the installer) - the zip appears on the desktop."
