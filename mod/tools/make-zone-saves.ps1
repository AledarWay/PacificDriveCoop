# The reference zone saves the tests start from (owner, 2026-11-14: "all tests on the reference saves"): the game's
# own Quick start garage (local\advsave\quickstart-<role>.sav, made by hand by the owner: Quick start + the garage's
# first task) driven out to a fixed map and saved there, so a test that starts in a zone gets the same zone every
# time - a zone from a loaded save is NOT the same twice even with the same seed and map (101 vs 114 wrecks, probed).
#   make-zone-saves.ps1 [-Roles host,client] [-SettleSec 45]
# Writes local\advsave\quickstart-<role>-zone.sav; start-zone.ps1 (COOPTEST_QUICKSTART=1) loads them.
param([string[]]$Roles = @('host', 'client'), [int]$SettleSec = 45)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $adv = "$root\local\advsave"
. "$t\zone-maps.ps1"
foreach ($role in $Roles) {
    $tag = "zs$role"; $dir = "$root\local\instances\$tag\coopdev"; $u = "$root\local\instances\$tag\userdir"
    function Send([string]$code) {
        $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
        (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120 6>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
    }
    $map = $ZoneMap.host
    "=== $role -> $map"
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
    & "$t\start-save.ps1" -Tag $tag -Save "$adv\quickstart-$role.sav" -Slot 9 | Select-Object -Last 2
    "  seed: " + (Send "FindFirstOf('DrivingGameInstance'):SetMasterSeed($($ZoneSeed[$role])) return 'set'")
    "  route: " + (Send "ROUTE_TARGET_MAP = '$map' $(Get-Content "$t\cmds\route-override.lua" -Raw)")
    Send 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController")) return "travel"' | Out-Null
    & "$t\wait-state.ps1" -State 5 -Dir $dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  $_" }
    Start-Sleep $SettleSec
    $sav = "$u\Saved\SaveGames\odsave9.sav"
    $before = (Get-Item $sav).LastWriteTime
    "  save: " + (Send "SP_OP = 'save' SP_SLOT = 9 $(Get-Content "$t\cmds\save-probe.lua" -Raw)")
    $t0 = Get-Date
    while ((Get-Item $sav).LastWriteTime -eq $before -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 1 }
    Start-Sleep 3
    if ((Get-Item $sav).LastWriteTime -eq $before) { "  FAILED: the save was not written"; continue }
    Copy-Item $sav "$adv\quickstart-$role-zone.sav" -Force
    "  -> $adv\quickstart-$role-zone.sav ($((Get-Item "$adv\quickstart-$role-zone.sav").Length) bytes)"
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
}
