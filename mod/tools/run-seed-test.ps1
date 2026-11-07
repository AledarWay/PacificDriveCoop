# One automated headless run: fresh profile -> fixed master seed -> new game -> garage -> first zone -> actor snapshot.
# Usage: run-seed-test.ps1 -Seed 12345 -Tag a
param([int]$Seed, [string]$Tag, [int]$SettleSec = 30, [string]$PreTravelLua = "")
$ErrorActionPreference = 'Stop'
$root = "C:\PacificDriveCoop"
$t = "$root\mod\tools"
$w = "$root\testgame\PenDriverPro\Binaries\Win64"
$u = "$root\local\seedtest\userdir-$Tag"
$res = "$root\local\seedtest"
New-Item -ItemType Directory -Force $u | Out-Null
if (Test-Path "$root\local\coopdev\cmd.lua") { Remove-Item "$root\local\coopdev\cmd.lua" }

function Send([string]$code) {
    $f = "$res\cmd-$Tag.lua"; Set-Content $f $code -Encoding ascii
    (& "$t\send.ps1" -File $f -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -ne '' }
}
function Log($m) { $line = "[$Tag $(Get-Date -f HH:mm:ss)] $m"; $line; Add-Content "$res\run-$Tag.log" $line }

$p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $u) + "-userdir=`"$u`"") -WorkingDirectory $w -PassThru
try {
    Log "pid $($p.Id)"
    & "$t\wait-state.ps1" -State 1 -TimeoutSec 120 | Select-Object -Last 1 | ForEach-Object { Log $_ }
    Send @"
local gi = FindFirstOf("DrivingGameInstance")
gi:SetMasterSeed($Seed)
Dev.out("seed before new game", gi.MasterSeed)
FindFirstOf("BP_SaveGameManager_C"):UserNewGame(1, 1)
Dev.out("seed after UserNewGame call", gi.MasterSeed)
"@ | Select-String 'seed' | ForEach-Object { Log $_ }
    & "$t\wait-state.ps1" -State 3 -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
    Send 'local o = {} FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, true, false, false, 1, o) return tostring(o.Success)' | Select-String 'OK' | ForEach-Object { Log "garage: $_" }
    & "$t\wait-state.ps1" -State 4 -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
    Send (Get-Content "$t\cmds\seeds.lua" -Raw) | Where-Object { $_ -notmatch '^===' } | ForEach-Object { Log "garage seeds: $_" }
    if ($PreTravelLua) { Send $PreTravelLua | Where-Object { $_ -notmatch '^===' } | ForEach-Object { Log "pre-travel: $_" } }
    Send 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
    & "$t\wait-state.ps1" -State 5 -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log $_ }
    Start-Sleep $SettleSec
    Send (Get-Content "$t\cmds\seeds.lua" -Raw) | Where-Object { $_ -notmatch '^===' } | ForEach-Object { Log "run seeds: $_" }
    Send (Get-Content "$t\cmds\snapshot.lua" -Raw) | Select-String 'OK|ERR' | ForEach-Object { Log "snapshot: $_" }
    Copy-Item "$root\local\coopdev\snapshot.txt" "$res\snapshot-$Tag.txt" -Force
} finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
}
