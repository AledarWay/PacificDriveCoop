param([string]$Only = "")
# Host only: sync with deep breadcrumbs + repeated bot actions and forced GC, until crash or 6 min.
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $hd = "$root\local\instances\host\coopdev"; $chan = "$root\local\instances\channel"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3
& "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
Start-Sleep 35
Set-Content "$hd\sync-crumbs.txt" "" -Encoding ascii
Set-Content "$hd\bot-crumbs.txt" "" -Encoding ascii
$code = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopSyncDebug = '$($hd.Replace('\','/'))/sync-crumbs.txt' CoopSyncDebugDeep = true return CoopSyncState.start(CoopSync, 'host', '$($chan.Replace('\','/'))')"
Set-Content "$hd\..\soak.lua" $code -Encoding ascii
& "$t\send.ps1" -File "$hd\..\soak.lua" -Dir $hd -TimeoutSec 60
"local gi = FindFirstOf('DrivingGameInstance') return 'Unreachable flag = ' .. tostring(EInternalObjectFlags and EInternalObjectFlags.Unreachable) .. ' HasAnyInternalFlags ok = ' .. tostring(pcall(function() return gi:HasAnyInternalFlags(EInternalObjectFlags.Unreachable) end))" | Set-Content "$hd\..\soak-flag.lua" -Encoding ascii
"flag check: " + ((& "$t\send.ps1" -File "$hd\..\soak-flag.lua" -Dir $hd -TimeoutSec 30) -join ' ')
$bot = Get-Content "$t\cmds\bot-actions.lua" -Raw
$t0 = Get-Date; $round = 0
while (((Get-Date) - $t0).TotalSeconds -lt 360) {
    $onlyLua = if ($Only) { "'$Only'" } else { "nil" }
    "BOT_SKIP = $round BOT_ONLY = $onlyLua $bot" | Set-Content "$hd\..\soak-bot.lua" -Encoding ascii
    $r = (& "$t\send.ps1" -File "$hd\..\soak-bot.lua" -Dir $hd -TimeoutSec 30) -join ' '
    "round $round bot: " + $r.Substring(0, [math]::Min(200, $r.Length))
    Start-Sleep 3
    "StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'):CollectGarbage() return 'gc'" | Set-Content "$hd\..\soak-gc.lua" -Encoding ascii
    & "$t\send.ps1" -File "$hd\..\soak-gc.lua" -Dir $hd -TimeoutSec 30 | Out-Null
    Start-Sleep 12
    "return CoopSyncState.report() .. ' || ' .. CoopSyncState.profile()" | Set-Content "$hd\..\soak-rep.lua" -Encoding ascii
    $rep = (& "$t\send.ps1" -File "$hd\..\soak-rep.lua" -Dir $hd -TimeoutSec 30) -join ' '
    "   report: " + $rep.Substring(0, [math]::Min(500, $rep.Length))
    $round++
    if (-not (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue)) { "CRASHED in round $round after $([int]((Get-Date) - $t0).TotalSeconds) s"; break }
}
"--- last sync crumbs"; Get-Content "$hd\sync-crumbs.txt" | Select-Object -Last 25
"--- last bot crumbs"; Get-Content "$hd\bot-crumbs.txt" | Select-Object -Last 6
"DONE"



