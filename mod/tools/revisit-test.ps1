# A second visit to the same zone in one game (owner, alpha 9: back home through the pause menu, out again to the same
# junction - then the host froze 1-2 min, the guest's car hung in the air with no control, the host could not get into
# its car, 15-22 fps). Two headless instances, the in-game network's local test link (-NetExe: CoopNet.exe):
#   1. lobby in the garages, the host leaves for a run, the guest drives out after it: both sync in the zone;
#   2. both go home; the host leaves again (the same first leg: the same zone), the guest drives out again;
#   3. on this second visit: each own car simulates and drives (not taken for a twin), the host gets into its car,
#      the mod's own time per frame stays small, no long frame after the sync started, both see each other.
param([switch]$Keep, [switch]$NetExe, [int]$Port = 47871, [switch]$NoDeploy)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Status($chan) { KV ((Get-Content "$chan\status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]) }
function WaitFor($chan, [scriptblock]$cond, [int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    do { $s = Status $chan; if (& $cond $s) { return $s }; Start-Sleep 3 } while ((Get-Date) -lt $end)
    Status $chan
}
function NetCtl($chan, [string]$line) { Add-Content "$chan\net-control.txt" $line -Encoding ascii }
# the guest "drives out": seated in its own car, the car put into the garage exit's drive-through volume
$driveOut = "local pc = FindFirstOf('PlayerController') local p = pc.Pawn local car = FindFirstOf('BP_CarManager_C').NewCarActor " +
    "local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end " +
    "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.IsGarageExit then ex = e end end " +
    "local c = ex.Collision_Exit:K2_GetComponentLocation() " +
    "car:K2_SetActorLocationAndRotation({ X = c.X - 300, Y = c.Y + 2500, Z = c.Z - 150 }, { Pitch = 0, Yaw = -80, Roll = 0 }, false, {}, true) " +
    "Dev.after(700, function() car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z - 150 }, { Pitch = 0, Yaw = -80, Roll = 0 }, false, {}, true) end) " +
    "return string.format('drove to the exit (active=%s)', tostring(ex.ExitActive))"
function Gate($chan) { $g = (Status $chan).gate; if ($g) { $p = $g -split '/'; @{ closed = [int]$p[0]; opened = [int]$p[1]; taken = [int]$p[2] } } else { @{ closed = 0; opened = 0; taken = 0 } } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
if (-not $NoDeploy) { & "$t\deploy.ps1" }
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-r$runId"; $cchan = "$inst\client\chan-r$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
. "$t\netlink.ps1"
$rh = NetExeStart $hchan Host
$rc = NetExeStart $cchan Guest

"=== 1. both in their garages, the lobby forms; the host leaves, the guest after it"
. "$t\boot-lib.ps1" # (the two games boot side by side)
$env:COOPSYNC_CHAN = $hchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Host; $boot0 = BootBg start-zone.ps1 "-Tag host -Seed 12345 -StopInGarage"
$env:COOPSYNC_CHAN = $cchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Guest; $boot1 = BootBg start-zone.ps1 "-Tag client -Seed 777 -StopInGarage"
BootWait $boot0 | Select-Object -Last 1; BootWait $boot1 | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
Start-Sleep 3
NetCtl $hchan 'create'; Start-Sleep 2
NetCtl $cchan 'join 1'; Start-Sleep 3
function Trip([string]$label) {
    Send $hd 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
    & "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
    $c = WaitFor $cchan { param($s) (Gate $cchan).opened -ge 1 } 60
    $taken = (Gate $cchan).taken
    for ($i = 0; $i -lt 6 -and (Gate $cchan).taken -le $taken; $i++) {
        "  guest: " + (Send $cd $driveOut)
        $c = WaitFor $cchan { param($s) (Gate $cchan).taken -gt $taken } 15
    }
    $h = WaitFor $hchan { param($s) $s.state -eq 'hosting' } 240
    $c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
    Check "${label}: the guest is on the host's map and syncs" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
    $script:world = $h.world
}
Trip "first visit"
$world1 = $script:world

"=== 2. both home, the host leaves again, the guest after it"
"  host: " + (Send $hd "$run return Run.goHome(false, 0)")
# (the guest too: nothing sends it home with the host - left in the zone it never went home, the whole case untested
# since the reference saves at least: "guest: TIMEOUT", the drive-out found no garage exit, 2026-11-14)
"  guest: " + (Send $cd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Start-Sleep 20
# (the Quick start's route: home again, the garage's next departure is the route's next leg - a new map; the case to
# check is the same zone again, so the leg is pinned to the first trip's map as start-zone pinned the first)
. "$t\zone-maps.ps1"
"  host: " + ((Send $hd "ROUTE_TARGET_MAP = '$($ZoneMap.host)' $(Get-Content "$t\cmds\route-override.lua" -Raw)") -replace ';.*$', ' ...')
Trip "second visit"
Check "the second trip went to the same zone (the case to check)" ($script:world -eq $world1) "first $world1, second $($script:world)"

"=== 3. the second visit"
Start-Sleep 20
$own = "local car = FindFirstOf('BP_CarManager_C').NewCarActor local sim = car.RootComponent:IsSimulatingPhysics(FName('None')) local tick = '?' " +
    "for _, c in ipairs(FindAllOf('VehicleControllerComponent') or {}) do if c:GetOuter():GetAddress() == car:GetAddress() then tick = tostring(c:IsComponentTickEnabled()) end end " +
    "return 'sim=' .. tostring(sim) .. ' tick=' .. tick"
$ho = Send $hd $own; $go = Send $cd $own
Check "the host's own car simulates and drives itself (not taken for a twin)" ($ho -match 'sim=true' -and $ho -match 'tick=true') $ho
Check "the guest's own car simulates and drives itself (it hung in the air, alpha 9)" ($go -match 'sim=true' -and $go -match 'tick=true') $go
"  host: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() if par and par:IsValid() then p['Exit Car'](p, false, true) end return 'out'")
Start-Sleep 4
"  host: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn p:CommandEnterCar(true, nil, false) return 'getting in'")
Start-Sleep 5
$in = Send $hd "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() local car = FindFirstOf('BP_CarManager_C').NewCarActor return 'in_own=' .. tostring(par ~= nil and par:IsValid() and par:GetAddress() == car:GetAddress())"
Check "the host gets into its own car again (it could not, alpha 9)" ($in -match 'in_own=true') $in
$end = (Get-Date).AddSeconds(30)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
Check "both see each other" ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
# the mod's own time per frame (hitch.lua's 10 s window): headless frames are cheap, so this is the mod's cost alone
# (the last F line of hitches.log: F <time> <fps> <frame ms avg> <frame ms worst> <mod ms per frame> <world>)
function LastF($chan) { @(Get-Content "$chan\hitches.log" | Where-Object { $_ -like "F`t*" }) | Select-Object -Last 1 }
function ModMs($line) { $f = "$line" -split "`t"; if ($f.Count -ge 6) { [double]$f[5] } else { 999 } }
$fh = LastF $hchan; $fc = LastF $cchan
Check "host: the mod takes < 8 ms per frame" ((ModMs $fh) -lt 8) "F line: $fh"
Check "guest: the mod takes < 8 ms per frame" ((ModMs $fc) -lt 8) "F line: $fc"
# no long frame once the guest synced (the host froze 1-2 min on the second visit, alpha 9): hitches.log gaps after the
# guest's last import, the arrival loads left out
# the time of the guest's last import (N line), then the worst gap at or after it in each log (same PC clock)
$gl = @(Get-Content "$cchan\hitches.log")
$since = '99:99:99'
foreach ($x in $gl) { $f = $x -split "`t"; if ($f[0] -eq 'N' -and $f[2] -like 'import:*') { $since = $f[1] } }
function LongAfter($chan, [string]$since) {
    $worst = 0
    foreach ($x in @(Get-Content "$chan\hitches.log")) {
        $f = $x -split "`t"
        if ($f[0] -eq 'G' -and $f[1] -ge $since -and [double]$f[2] -gt $worst) { $worst = [double]$f[2] }
    }
    $worst
}
$wh = LongAfter $hchan $since; $wg = LongAfter $cchan $since
Check "host: no frame over 2 s after the guest's second import" ($wh -lt 2000) "worst $wh ms since $since"
Check "guest: no frame over 2 s after its second import" ($wg -lt 2000) "worst $wg ms since $since"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    NetExeStop
}
