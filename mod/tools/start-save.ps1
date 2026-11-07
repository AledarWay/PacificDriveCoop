# Starts one headless game instance from a save copy instead of a new game: copies -Save into the instance's
# profile as odsave<Slot>.sav, loads that slot and waits until the game is in a zone (state 5) or garage (4).
# Usage: start-save.ps1 -Tag host -Save C:\PacificDriveCoop\local\advsave\odsave9.sav [-Slot 9]  -> "PID <n>" last
# The source save is never written to (copied first).
param([string]$Tag, [string]$Save, [int]$Slot = 9)
$ErrorActionPreference = 'Stop'
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $w = "$root\testgame\PenDriverPro\Binaries\Win64"
$u = "$root\local\instances\$Tag\userdir"; $dir = "$root\local\instances\$Tag\coopdev"
New-Item -ItemType Directory -Force "$u\Saved\SaveGames", $dir | Out-Null
# the game loads the newest of odsave<Slot>.sav and its backups (written on every travel), so drop old backups
Remove-Item "$u\Saved\SaveGames\odsave$Slot-backup-*.sav" -Force -ErrorAction SilentlyContinue
Copy-Item $Save "$u\Saved\SaveGames\odsave$Slot.sav" -Force
if (Test-Path "$dir\cmd.lua") { Remove-Item "$dir\cmd.lua" }
function Log($m) { $line = "[$Tag $(Get-Date -f HH:mm:ss)] $m"; $line; Add-Content "$dir\start.log" $line }
# a crashed game leaves its crash report window open: close leftovers (the game is gone anyway)
Get-Process CrashReportClient -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$env:COOPDEV_DIR = $dir.Replace('\', '/')
$p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $u) + "-userdir=`"$u`"") -WorkingDirectory $w -PassThru
Log "pid $($p.Id) dir $dir save $Save -> slot $Slot"
& "$t\wait-state.ps1" -State 1 -Dir $dir -TimeoutSec 120 | Select-Object -Last 1 | ForEach-Object { Log $_ }
$f = "$dir\_send.lua"; Set-Content $f "FindFirstOf('BP_SaveGameManager_C'):UserLoadGame($Slot, 1, 0) return 'load called'" -Encoding ascii
& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 60 | Out-Null
$end = (Get-Date).AddSeconds(240)
while ((Get-Date) -lt $end) {
    $r = (& "$t\send.ps1" -File "$t\cmds\st.lua" -Dir $dir -TimeoutSec 20) -join ' '
    if ($r -match 'OK (seed=\S+ state=(\d+) world=\S+)' -and ([int]$Matches[2] -eq 5 -or [int]$Matches[2] -eq 4)) { Log $Matches[1]; break }
    Start-Sleep 5
}
"PID $($p.Id)"
