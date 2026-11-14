# Starts one headless game instance with its own profile and CoopDev command dir and leaves it running in a zone
# (or in its garage with -StopInGarage).
# Usage: start-zone.ps1 -Tag host [-Seed 12345] [-PreTravelLua <code>] [-StopInGarage]   -> prints "PID <n>" at the end
# -StopInGarage: leave the instance in its garage (a guest that joins a host's run from there).
# The start (owner, 2026-11-14: "all tests on the reference saves"): the game's own Quick start garage the owner made by
# hand (local\advsave\quickstart-<role>.sav: Quick start + the garage's first task; role = host for -Tag host, else
# client). UserNewGame + TravelToGarage skipped the opening the game sets the HUD up in (no hotbar, no Tab inventory, no
# scan / take-off prompts, an empty inventory and tank). A zone from a loaded save differs from run to run whatever the
# seed, so a start in a zone loads a saved zone (quickstart-<role>-zone.sav, make-zone-saves.ps1) - the same every
# time; a start in the garage gets its next departure pinned to that role's map (zone-maps.ps1). -Seed then is only
# the game's master seed. $env:COOPTEST_QUICKSTART=0: the old start (UserNewGame with -Seed, the story's first zone).
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
$quick = $env:COOPTEST_QUICKSTART -ne '0'
$role = if ($Tag -eq 'host') { 'host' } else { 'client' }
$inGarage = $StopInGarage -or $PreTravelLua
if ($quick) {
    . "$t\zone-maps.ps1"
    $qs = "$root\local\advsave\quickstart-$role$(if ($inGarage) { '' } else { '-zone' }).sav"
    if (-not (Test-Path $qs)) { throw "no reference save $qs (the garage ones are made by hand; the zones: make-zone-saves.ps1)" }
    New-Item -ItemType Directory -Force "$u\Saved\SaveGames" | Out-Null
    Remove-Item "$u\Saved\SaveGames\odsave9-backup-*.sav" -Force -ErrorAction SilentlyContinue
    Copy-Item $qs "$u\Saved\SaveGames\odsave9.sav" -Force
}
$p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $u) + "-userdir=`"$u`"") -WorkingDirectory $w -PassThru
Log "pid $($p.Id) dir $dir"
& "$t\wait-state.ps1" -State 1 -Dir $dir -TimeoutSec 120 | Select-Object -Last 1 | ForEach-Object { Log $_ }
if ($quick) {
    Send "FindFirstOf('BP_SaveGameManager_C'):UserLoadGame(9, 1, 0)" | Out-Null
    & "$t\wait-state.ps1" -State $(if ($inGarage) { 4 } else { 5 }) -Dir $dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "reference save: $_" }
    if (-not $inGarage) {
        # (a zone save loads the player on foot beside the car; a departure from the garage arrives at the wheel -
        # the tests start there: the game's own CommandEnterCar, teleported, as the departure seats the driver)
        $inCar = "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())"
        for ($i = 0; $i -lt 3; $i++) {
            if ((Send $inCar) -match '^OK true') { break }
            Send "FindFirstOf('PlayerController').Pawn:CommandEnterCar(true, nil, false)" | Out-Null
            Start-Sleep 4
        }
        Log "at the wheel: $((Send $inCar) -join ' ')"
    # (and a zone save loads the car with the engine off - a departure arrives with it running, as the tests expect)
    Send "local m = FindFirstOf('BP_CarManager_C') if m.CarIgnitionState == 0 then m.NewCarActor:ToggleIgnitionState(2) end return 'ign'" | Out-Null
    Start-Sleep 3
    Log "engine: $((Send "return tostring(FindFirstOf('BP_CarManager_C').CarIgnitionState)") -join ' ')"
        "PID $($p.Id)"; exit 0
    }
    Send "FindFirstOf('DrivingGameInstance'):SetMasterSeed($Seed)" | Out-Null
    Send "ROUTE_TARGET_MAP = '$($ZoneMap[$role])' $(Get-Content "$t\cmds\route-override.lua" -Raw)" | Where-Object { $_ -match '^OK' } | ForEach-Object { Log "next departure: $($_ -replace '^OK ', '' -replace ';.*$', ' ...')" }
} else {
    Send "local gi = FindFirstOf('DrivingGameInstance') gi:SetMasterSeed($Seed) FindFirstOf('BP_SaveGameManager_C'):UserNewGame(1, 1)" | Out-Null
    & "$t\wait-state.ps1" -State 3 -Dir $dir -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
    Send 'local o = {} FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, true, false, false, 1, o)' | Out-Null
    & "$t\wait-state.ps1" -State 4 -Dir $dir -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { Log $_ }
}
if ($PreTravelLua) { Send $PreTravelLua | Where-Object { $_ -notmatch '^===' } | ForEach-Object { Log "pre-travel: $_" } }
if ($StopInGarage) { "PID $($p.Id)"; exit 0 }
Send 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
& "$t\wait-state.ps1" -State 5 -Dir $dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log $_ }
"PID $($p.Id)"
