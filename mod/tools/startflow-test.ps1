# The start of a co-op game as the owner set it (2026-10-24), two headless instances with the in-game network's
# local test link (-NetExe: CoopNet.exe):
#   1. both in their own garages, the lobby forms (create / join): each sees the other's puppet in its garage;
#   2. the guest's garage exit stays shut while the host is home (driving into it does nothing); the host leaves its
#      garage for a run (the game's TravelToNextLeg): CoopNet starts the run for the lobby, the guest's exit opens,
#      the guest drives out through it (its car put into the exit's volume, as the real drive does) and is taken
#      to the host's map without picking a junction, and syncs;
#   3. late join: the guest leaves the lobby (-NetExe: its CoopNet goes away) and comes back (a member of the run):
#      its exit opens again, it
#      drives out and is brought there again.
param([switch]$Keep, [switch]$NetExe, [int]$Port = 47821)
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
# the cars of each side's world (owner's alpha 17 / 18 tests: the guest had its own car twice, a hood floated by the
# host's car) and the zone through the save (zonesave.lua)
function Census($dir) { KV (Send $dir (Get-Content "$t\cmds\car-census.lua" -Raw)) }
# (the test's commands run in the dev mod's Lua state: the mod's own counts come from status.txt - twins=, zs=)
function CarsCheck($when) {
    # the other's car is spawned a little after "both see each other": waited for, then counted
    $end = (Get-Date).AddSeconds(30)
    do { $hs = Status $hchan; $cs = Status $cchan; if ($hs.twins -eq '1' -and $cs.twins -eq '1') { break }; Start-Sleep 2 } while ((Get-Date) -lt $end)
    Start-Sleep 3
    $hc = Census $hd; $cc = Census $cd; $hs = Status $hchan; $cs = Status $cchan
    $hn = [int]$hc.own + [int]$hc.twin; $cn = [int]$cc.own + [int]$cc.twin
    Check "${when}: two cars on each side, one of them the other's twin" ($hn -eq 2 -and $cn -eq 2 -and $hs.twins -eq '1' -and $cs.twins -eq '1') "host: twins=$($hs.twins) $($hc.raw) | guest: twins=$($cs.twins) $($cc.raw)"
    Check "${when}: no loose car parts by the cars" ($hc.loose -eq '0' -and $cc.loose -eq '0') "host: $($hc.parts) | guest: $($cc.parts)"
    # (owner's alpha 18 item 34: the host's own mirrors showed the parked twin's view - one mirror material shared by
    # both cars, the twin's mirror fix set it; every car's mirrors must read its own capture)
    $hm = Send $hd (Get-Content "$t\cmds\mirror-rt.lua" -Raw); $cm = Send $cd (Get-Content "$t\cmds\mirror-rt.lua" -Raw)
    Check "${when}: each car's mirrors show its own camera" ($hm -match 'OWN' -and $hm -notmatch 'OTHER' -and $cm -match 'OWN' -and $cm -notmatch 'OTHER') "host: $hm | guest: $cm"
    Check "${when}: the mod's car watch saw no extra car" ($hs.extra -eq '0' -and $cs.extra -eq '0') "host cars=$($hs.cars) extra=$($hs.extra) | guest cars=$($cs.cars) extra=$($cs.extra)"
}
function ZoneSaveCheck($when, [int]$n) {
    # (config zone_from_save on, the default again since 2026-11-11: each arrival loads the host's zone save through
    # slot 0 - the scene taken, no "FAILED TO LOAD V4 (Map) SCENE DATA" (its own slot's memory copy, the old way) - and
    # the own car is there after it: the game's, or built by the mod when the game built none; zs=<state>/<saved>/
    # <sent>/<loaded>. The game's own travel to a new zone logs a FAILED of its own - "Is this a new game or map?" -
    # one per travel: our loads are the LOAD V4 Map lines without one)
    $hz = ((Status $hchan).zs -split '/'); $cz = ((Status $cchan).zs -split '/')
    $gl = @(Get-Content "$inst\client\userdir\Saved\Logs\PenDriverPro.log" -ErrorAction SilentlyContinue)
    $maps = @($gl | Where-Object { $_ -cmatch 'LOAD V4: Map!!' }).Count
    $failed = @($gl | Where-Object { $_ -match 'FAILED TO LOAD V4 \(Map\)' }).Count
    $car = Send $cd "local c = FindFirstOf('BP_CarManager_C').NewCarActor local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() return 'car=' .. tostring(c:IsValid()) .. ' seated=' .. tostring(par and par:IsValid() and par:GetFullName() == c:GetFullName())"
    "  guest zone save: " + ((Get-Content (Get-ChildItem $cchan -Recurse -Filter hitches.log | Select-Object -First 1).FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match 'zone save' } | Select-Object -Last 3) -join ' | ')
    Check "${when}: the host's zone from its save, the scene taken, the own car there" ($hz.Count -eq 4 -and [int]$hz[1] -ge 1 -and $cz.Count -eq 4 -and [int]$cz[3] -eq $n -and $failed -le $maps - $n -and $car -match 'car=true seated=true') "host zs=$($hz -join '/') | guest zs=$($cz -join '/') (loads want $n) | LOAD V4 Map $maps, FAILED $failed | $car"
}# (owner's alpha 20 test: the guest's drive-out travelled five times in one frame - "concurrent save/load on top of
# LOADING LEVEL" - and its map to pick a junction stayed open through the load and in the zone)
function TravelCheck($when, [int]$n) {
    $log = "$inst\client\userdir\Saved\Logs\PenDriverPro.log"
    $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
    $trav = @($lines | Where-Object { $_ -match 'Traveling to level' }).Count
    $conc = @($lines | Where-Object { $_ -match 'concurrent save/load' }).Count
    $cs = Status $cchan
    # (a drive-out is a travel or the one load straight into the host's zone - config direct_load: no travel then)
    $dl = @(Get-Content (Get-ChildItem $cchan -Recurse -Filter hitches.log | Select-Object -First 1).FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match 'one load from the garage' }).Count
    Check "${when}: the guest travelled (or loaded) once per drive-out, to the host's junction" ($trav + $dl -eq $n -and $conc -eq 0 -and [int]$cs.travels + $dl -eq $n) "game log travels=$trav concurrent=$conc one loads=$dl | mod travels=$($cs.travels) | $($cs.note)"
    $menu = Send $cd "local v = 0 for _, w in ipairs(FindAllOf('UMG_PlayerMenu_Main_C') or {}) do pcall(function() if w:IsInViewport() and w:IsVisible() then v = v + 1 end end) end return 'menus=' .. v"
    Check "${when}: no junction map open on the guest" ($menu -match 'menus=0') "$menu exitmap=$($cs.exitmap)"
}
function Gate($chan) { $g = (Status $chan).gate; if ($g) { $p = $g -split '/'; @{ closed = [int]$p[0]; opened = [int]$p[1]; taken = [int]$p[2] } } else { @{ closed = 0; opened = 0; taken = 0 } } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-f$runId"; $cchan = "$inst\client\chan-f$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
. "$t\netlink.ps1"
$rh = NetExeStart $hchan Host
$rc = NetExeStart $cchan Guest

"=== 1. both in their garages, the lobby forms"
. "$t\boot-lib.ps1" # (the two games boot side by side)
$env:COOPSYNC_CHAN = $hchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Host; $boot0 = BootBg start-zone.ps1 "-Tag host -Seed 12345 -StopInGarage"
$env:COOPSYNC_CHAN = $cchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Guest; $boot1 = BootBg start-zone.ps1 "-Tag client -Seed 777 -StopInGarage"
BootWait $boot0 | Select-Object -Last 1; BootWait $boot1 | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
Start-Sleep 3
NetCtl $hchan 'create'; Start-Sleep 2
NetCtl $cchan 'join 1'; Start-Sleep 3
Check "lobby: both members" (@(Get-Content "$hchan\net-status.txt" | Where-Object { $_ -like 'member*' }).Count -eq 2) ((Get-Content "$hchan\net-status.txt") -join ' | ')
$h = WaitFor $hchan { param($s) $s.puppet -eq 'yes' } 60; $c = WaitFor $cchan { param($s) $s.puppet -eq 'yes' } 30
Check "in the garages both see each other (puppets)" ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
Check "the guest's role is its own car (default)" ($c.mode -eq 'car' -and $c.role -eq 'client') $c.raw
# the co-op checklist on the garage HUD (owner, alpha 18: like the game's driver's checklist): title, lobby, two
# players, the action
Check "the co-op checklist shows in both garages" ([int]$h.chk -ge 4 -and [int]$c.chk -ge 4) "host chk=$($h.chk) | guest chk=$($c.chk)"
# the guest sits in its car in its garage: the host's puppet of it sits too (the owner saw it stand, legs through the car)
"  guest: " + (Send $cd "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end return 'in its car'")
$h = WaitFor $hchan { param($s) $s.anim -eq 'sit' } 20
Check "in the garage the host's puppet of the seated guest sits" ($h.anim -eq 'sit') $h.raw

"=== 2. the guest's exit is shut while the host is home; the host leaves, the guest drives out after it"
Start-Sleep 3
"  guest: " + (Send $cd $driveOut)
Start-Sleep 8
$c = Status $cchan; $g = Gate $cchan
Check "the guest's exit is shut while the host is home: driving into it does nothing" ($c.gstate -eq '4' -and $g.taken -eq 0 -and $c.state -eq 'garage') "gate closed/opened/taken=$($c.gate) | $($c.raw)"
Send $hd 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
& "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
$c = WaitFor $cchan { param($s) (Gate $cchan).opened -ge 1 } 60
Check "the host's departure opens the guest's exit (and nothing travels by itself)" ((Gate $cchan).opened -ge 1 -and $c.gstate -eq '4') "gate=$($c.gate) | $($c.raw)"
"  guest: " + (Send $cd $driveOut)
$c = WaitFor $cchan { param($s) (Gate $cchan).taken -ge 1 } 30
Check "driving out through it takes the guest to the host (no junction pick)" ((Gate $cchan).taken -ge 1) "gate=$($c.gate) | $($c.raw)"
# (owner, alpha 16: the guest waited on the map screen until the host's zone had settled - minutes on a slow PC):
# the host publishes the map on arrival, the guest travels while the host's zone still generates
$t0 = Get-Date; $guestIn = $null; $hostUp = $null
$end = $t0.AddSeconds(240)
do {
    Start-Sleep 1; $h = Status $hchan; $c = Status $cchan
    if (-not $guestIn -and $c.gstate -eq '5') { $guestIn = ((Get-Date) - $t0).TotalSeconds }
    if (-not $hostUp -and $h.state -eq 'hosting') { $hostUp = ((Get-Date) - $t0).TotalSeconds }
} while (-not ($guestIn -and $hostUp) -and (Get-Date) -lt $end)
Check "host publishes its zone" ($h.state -eq 'hosting') $h.raw
# (owner, 2026-11-09: "only real work, no waits just in case"): the host published 25 s after arriving at the least
# (MIN_ZONE_S) though its zone was ready at once - the guest waited for it. Now as soon as the zone is ready: the
# host's timeline (hitches.log) - the time in "zone: generating" before "hosting"
$gen = @(Select-String -Path "$hchan\hitches.log" -Pattern 'timeline \+([\d.]+) hosting ' | ForEach-Object { [double]::Parse($_.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) })
Check "the host publishes its zone as soon as it is ready (no fixed wait)" ($gen.Count -ge 1 -and ($gen | Measure-Object -Maximum).Maximum -le 10) ("in 'zone: generating' {0} s; guest in the zone after {1:N0} s, host's list after {2:N0} s" -f ($gen -join '/'), $guestIn, $hostUp)
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
$playing = ((Get-Date) - $t0).TotalSeconds
Check "the guest was brought to the host's map and syncs" ($c.state -eq 'playing' -and $c.world -eq $h.world) ("guest: $($c.raw) | host: $($h.raw) | playing after {0:N0} s" -f $playing)
# (owner, alpha 19 item 5: the guest never sees a zone of its own - dark from the drive-out until it plays)
Start-Sleep 2
$cv = ((Status $cchan).cover -split '/')
Check "the guest's screen was dark while it synced, clear now" ([int]$cv[0] -ge 10 -and $cv[1] -eq '0') "cover ticks/shown=$($cv -join '/')"
$end = (Get-Date).AddSeconds(30)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
Check "both see each other in the zone" ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
ZoneSaveCheck "joined" 1
TravelCheck "joined" 1
CarsCheck "joined"

"=== 3. late join: the guest goes home, leaves the lobby and comes back"
"  guest: " + (& "$t\trace-on.ps1" -Dir $cd -Sec 120)
"  guest: " + (Send $cd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
# (the test's trip home is a direct rinse from the zone: for a while the game holds the car where it was saved)
Start-Sleep 20
if ($NetExe) {
    Stop-Process -Id $rc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 5
    $rc = NetExeStart $cchan Guest
} else { NetCtl $cchan 'leave'; Start-Sleep 5 }
Start-Sleep 3; NetCtl $cchan 'join 1'
$opened = (Gate $cchan).opened
$c = WaitFor $cchan { param($s) (Gate $cchan).opened -gt $opened } 60
Check "back in the lobby, the run member's exit opens" ((Gate $cchan).opened -gt $opened) "gate=$($c.gate) | $($c.raw)"
$taken = (Gate $cchan).taken
for ($i = 0; $i -lt 6 -and (Gate $cchan).taken -le $taken; $i++) {
    # (right after the trip home the game may still be placing the car: drive again when it did not count)
    "  guest: " + (Send $cd $driveOut)
    $c = WaitFor $cchan { param($s) (Gate $cchan).taken -gt $taken } 15
}
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
$h = Status $hchan
Check "a member of the run is brought back to the host's map" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
$end = (Get-Date).AddSeconds(30)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
Check "after the late join both see each other again" ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
ZoneSaveCheck "late join" 2
TravelCheck "late join" 2
CarsCheck "late join"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    NetExeStop
}
