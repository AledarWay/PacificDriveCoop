# Starts one headless game instance with its own profile and CoopDev command dir,
# drives it new game -> garage -> first zone and leaves it running there.
# Usage: start-zone.ps1 -Tag host [-Seed 12345] [-PreTravelLua <code>] [-StopInGarage]   -> prints "PID <n>" at the end
# -StopInGarage: leave the instance in its garage (a guest that joins a host's run from there).
param([string]$Tag, [int]$Seed = 12345, [string]$PreTravelLua = "", [switch]$StopInGarage)
$ErrorActionPreference = 'Stop'
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $w = "$root\testgame\PenDriverPro\Binaries\Win64"
$u = "$root\local\instances\$Tag\userdir"; $dir = "$root\local\instances\$Tag\coopdev"
New-Item -ItemType Directory -Force $u, $dir | Out-Null
if (Test-Path "$dir\cmd.lua") { Remove-Item "$dir\cmd.lua" }

function Send([string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -ne '' }
}
function Log($m) { $line = "[$Tag $(Get-Date -f HH:mm:ss)] $m"; $line; Add-Content "$dir\start.log" $line }

# a crashed game leaves its crash report window open: close leftovers (the game is gone anyway)
Get-Process CrashReportClient -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$env:COOPDEV_DIR = $dir.Replace('\', '/')
# the mod's texts in Russian whatever the test game's language (the tests check Russian labels; loc.lua)
if (-not $env:COOPSYNC_LANG) { $env:COOPSYNC_LANG = 'ru' }
$p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $u) + "-userdir=`"$u`"") -WorkingDirectory $w -PassThru
Log "pid $($p.Id) dir $dir"
& "$t\wait-state.ps1" -State 1 -Dir $dir -TimeoutSec 120 | Select-Object -Last 1 | ForEach-Object { Log $_ }
Send "local gi = FindFirstOf('DrivingGameInstance') gi:SetMasterSeed($Seed) FindFirstOf('BP_SaveGameManager_C'):UserNewGame(1, 1)" | Out-Null
& "$t\wait-state.ps1" -State 3 -Dir $dir -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
Send 'local o = {} FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, true, false, false, 1, o)' | Out-Null
& "$t\wait-state.ps1" -State 4 -Dir $dir -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
if ($PreTravelLua) { Send $PreTravelLua | Where-Object { $_ -notmatch '^===' } | ForEach-Object { Log "pre-travel: $_" } }
if ($StopInGarage) { "PID $($p.Id)"; exit 0 }
Send 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
& "$t\wait-state.ps1" -State 5 -Dir $dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log $_ }
"PID $($p.Id)"
