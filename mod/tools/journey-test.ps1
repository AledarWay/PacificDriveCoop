# A whole co-op session the way the owner plays it (2026-11-12: "more realistic tests, find the problems"): two
# headless games from the advanced save, the in-game network's test link through lag-proxy.ps1 (delay, jitter, lost
# segments resent), every game capped at -Fps. The session's own flow all the way, the mod as installed (no test
# dofile: the bots work through the running session's modules, CoopSyncSession.testMods):
#   1. both home in their garages, the lobby forms, the host leaves, the guest drives out after it (one load);
#   2. zone A: both play - bots (bot-lib.ps1, the soak's actions: drive, ram, walk, loot, the other's car, trunks,
#      parts) for -PlayRounds rounds, a state comparison every 3 rounds and at the zone's end;
#   3. both to the exit gate (the guest first), the host picks the next junction, the guest follows: zone B, play;
#   4. home together, out again (the second departure of the same game): zone C, play a little;
#   all along: the games alive, the mod's errors, both see each other / the other's car, no extra car, frame gaps,
#   fps, memory.
#   journey-test.ps1 [-PlayRounds 8] [-Seed 3] [-Lag 80,40,1] [-Fps 30] [-SettleSec 25] [-Keep]
param([int]$PlayRounds = 8, [int]$Seed = 3, [string]$Lag = '80,40,1', [int]$Fps = 30, [int]$SettleSec = 25, [switch]$Keep,
    [int]$Port = 47861, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$out = "$inst\journey\$(Get-Date -Format yyyyMMdd-HHmmss)"; New-Item -ItemType Directory -Force $out | Out-Null
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
$script:dead = $null
function Log([string]$s) {
    $line = "[$(Get-Date -f HH:mm:ss)] $s"; $line
    try { $fs = [IO.File]::Open("$out\journey.log", 'Append', 'Write', 'ReadWrite'); $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($b, 0, $b.Length); $fs.Close() } catch {}
}
# (into the running session's own Lua state - CoopSync's scmd.lua; -Dev: CoopDev's, for the commands that dofile a
# module of their own: a second runsync / spawnsync must not replace the session's)
function Send($dir, [string]$code, [int]$sec = 90, [switch]$Dev) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    $r = ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec $sec -Session:(-not $Dev)) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
    if ($r -match 'GAME DEAD') { $script:dead = "$(if ($dir -eq $hd) { 'host' } else { 'guest' }) game died" }
    $r
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ("$s" -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = "$s"; $h }
. "$t\bot-lib.ps1"
function Status($chan) { KV ((Get-Content "$chan\status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]) }
function WaitFor($chan, [scriptblock]$cond, [int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    do { $s = Status $chan; if (& $cond $s) { return $s }; Start-Sleep 3 } while ((Get-Date) -lt $end)
    Status $chan
}
function NetCtl($chan, [string]$line) { Add-Content "$chan\net-control.txt" $line -Encoding ascii }
function DriveInto($dir, [string]$gate) {
    $pick = if ($gate) { "e:GetFName():ToString() == '$gate'" } else { "e.IsGarageExit" }
    Send $dir ("local pc = FindFirstOf('PlayerController') local p = pc.Pawn local car = FindFirstOf('BP_CarManager_C').NewCarActor " +
        "local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end " +
        "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and $pick then ex = e end end " +
        "if not ex then return 'no such exit' end " +
        "local c = ex.Collision_Exit:K2_GetComponentLocation() local r = ex:K2_GetActorRotation() " +
        "Dev.after(1500, function() car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z + 100 }, { Pitch = 0, Yaw = r.Yaw, Roll = 0 }, false, {}, true) end) " +
        "return 'into ' .. ex:GetFName():ToString() .. ' (exit=' .. tostring(ex.ExitActive) .. ')'")
}
$script:pass = 0; $script:fail = 0; $script:fails = @()
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++; $script:fails += $name }
    Log ("  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
# the bots and probes on the running session's own modules (the mod as installed)
function Expose() {
    foreach ($d in $hd, $cd) {
        $r = Send $d "local m = CoopSyncSession.testMods() CoopSyncState = m.State return 'players=' .. tostring(CoopPlayers == m.Players) .. ' state=' .. tostring(CoopSyncState ~= nil)"
        Log "  expose $(if ($d -eq $hd) { 'host' } else { 'guest' }): $r"
    }
}
# both in their own cars (out of the other's first): the gate, the travels
function ToOwnCars() {
    foreach ($d in $hd, $cd) {
        $w = KV (Ops $d 'where')
        if ($w.where -eq 'twin') { Send $d "return CoopPlayers.botExitCar()" | Out-Null; Start-Sleep 4 }
        if ($w.where -ne 'own') { Send $d "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end return 'in'" | Out-Null }
    }
    Start-Sleep 4
}
# arrival in a zone: both play on the same map, each its own car + the other's twin, both see each other
function Arrived([string]$zone, $h, $c) {
    Check "${zone}: the guest is on the host's map and plays" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
    $end = (Get-Date).AddSeconds(60)
    do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.cars -eq '2/1' -and $c.cars -eq '2/1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
    Check "${zone}: each its own car and the other's twin, nothing more; both see each other" ($h.cars -eq '2/1' -and $c.cars -eq '2/1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host cars=$($h.cars) puppet=$($h.puppet) extra=$($h.extra) | guest cars=$($c.cars) puppet=$($c.puppet) extra=$($c.extra)"
}
# a zone's play: bot rounds, a state comparison every 3 and at the end
function Play([string]$zone, [int]$rounds) {
    Log "--- play in $zone ($rounds rounds)"
    $f0 = $script:failed.Count; $l0 = $script:lootBad; $c0 = $script:checks; $v0 = $script:converged
    $world = (Status $hchan).world
    for ($round = 1; $round -le $rounds -and -not $script:dead; $round++) {
        $hw = KV (Ops $hd 'where'); $gw = KV (Ops $cd 'where')
        foreach ($x in @(@{ t = 'host'; w = $hw }, @{ t = 'guest'; w = $gw })) {
            if ($x.w.world -and $x.w.world -ne '-' -and $x.w.world -ne $world) { $script:dead = "$($x.t) travelled to $($x.w.world) (health $($x.w.hp))" }
        }
        if ($script:dead) { break }
        if ([double]$hw.cars -gt 6000 -and $hw.where -ne 'twin' -and $gw.where -ne 'twin') { Log "  regroup: $(Ops $cd 'regroup' 'SOAK_SIDE = 900')" }
        $ha = Act 'host' $hd $hw $gw
        $ga = Act 'guest' $cd $gw $hw
        Log "  $zone round $round [host $($hw.where)/$($hw.seat) hp $($hw.hp)] $ha"
        Log "  $zone round $round [guest $($gw.where)/$($gw.seat) hp $($gw.hp)] $ga"
        Start-Sleep -Seconds ([int](Rnd 5 10))
        if (($round % 3 -eq 0 -or $round -eq $rounds) -and -not $script:dead) {
            foreach ($d in $hd, $cd) { Send $d "return CoopPlayers.botInput(3, 0, 0, 1)" | Out-Null }
            Start-Sleep 5
            $script:n++
            StateCheck $script:n
        }
    }
    $nc = $script:checks - $c0; $nv = $script:converged - $v0
    Check "${zone}: the two sides alike at every comparison (cars / twins, players / puppets)" ($nc -gt 0 -and $nv -eq $nc) "$nv of $nc alike; new diffs: $(@($script:failed.Keys | Select-Object -Skip $f0) -join ', ')"
    Check "${zone}: the world's loot alike" ($script:lootBad -eq $l0) "loot checks failed: $($script:lootBad - $l0)"
    Check "${zone}: both games alive, no travel by itself" (-not $script:dead) "$($script:dead)"
}
$script:n = 0

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1" | Out-Null
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-j$runId"; $cchan = "$inst\client\chan-j$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
# the link: the host listens on $Port; the guest through the proxy's $Port + 1
$lg = @("$Lag" -split '[,\s]+' | Where-Object { $_ })
$proxy = $null; $gPort = $Port
if ($lg.Count -ge 2) {
    $gPort = $Port + 1
    $proxy = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$t\lag-proxy.ps1`" -Listen $gPort -Target $Port -DelayMs $($lg[0]) -JitterMs $($lg[1]) -LossPct $(if ($lg.Count -ge 3) { $lg[2] } else { 0 }) -ParentPid $PID -Log `"$out\proxy.txt`""
    Start-Sleep 3
}
if ($Fps) { $env:COOPTEST_FPS = "$Fps" }
Log "=== journey: seed $Seed, network $Lag (delay ms, jitter ms, loss %), fps $Fps, $PlayRounds rounds a zone; log $out"

Log "=== 0. both from the advanced save, home to their garages"
. "$t\boot-lib.ps1" # (the two games boot side by side)
$pair = @(@{ tag = 'host'; chan = $hchan; dir = $hd; port = $Port; name = 'Host' }, @{ tag = 'client'; chan = $cchan; dir = $cd; port = $gPort; name = 'Guest' })
foreach ($x in $pair) {
    $env:COOPSYNC_CHAN = P $x.chan; $env:COOPSYNC_NET = "tcp:$($x.port):$($x.name)"
    $x.boot = BootBg start-save.ps1 "-Tag $($x.tag) -Save `"$Save`" -Slot 9"
}
foreach ($x in $pair) {
    BootWait $x.boot | Select-Object -Last 1 | ForEach-Object { Log "  $($x.tag): $_" }
    Log "  $($x.tag): $(Send $x.dir "$run return Run.goHome(false, 0)" -Dev)"
    & "$t\wait-state.ps1" -State 4 -Dir $x.dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "  $($x.tag): $_" }
}
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
Start-Sleep 5

Log "=== 1. the lobby, the host leaves, the guest drives out after it"
NetCtl $hchan 'create'; Start-Sleep 2
NetCtl $cchan 'join 1'
$c = WaitFor $cchan { param($s) [int](($s.map -split '/')[1]) -ge 1 } 90
Check "lobby: the guest has the host's map" ([int](($c.map -split '/')[1]) -ge 1) $c.raw
Start-Sleep 4
function Depart() {
    Log "  host: $(Send $hd 'local p = FindFirstOf("PlayerController").Pawn local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController")) return "host departs"')"
    & "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "  host: $_" }
    $g0 = [int]((Status $cchan).gate -split '/')[2]
    $c = WaitFor $cchan { param($s) [int](($s.gate -split '/')[1]) -ge 1 } 60
    for ($i = 0; $i -lt 5 -and [int]((Status $cchan).gate -split '/')[2] -le $g0; $i++) {
        Log "  guest: $(DriveInto $cd '')"
        $c = WaitFor $cchan { param($s) [int](($s.gate -split '/')[2]) -gt $g0 -or $s.state -ne 'lobby' } 15
    }
    $h = WaitFor $hchan { param($s) $s.state -eq 'hosting' } 240
    $c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
    @{ h = $h; c = $c }
}
$r = Depart
Arrived 'zone A' $r.h $r.c
Expose
Log ("  seats: host " + (Send $hd "return CoopPlayers.removeSeatDevice(3)") + " | guest " + (Send $cd "return CoopPlayers.removeSeatDevice(3, true)"))
Store $hd 'add' $FAB 3 | Out-Null; Store $cd 'add' $STEEL 3 | Out-Null
Send $hd "local im = FindFirstOf('BP_InventoryManager_C') im:GiveItemToPlayer(StaticFindObject('$FAB')) im:GiveItemToPlayer(StaticFindObject('$STEEL')) return 'given'" | Out-Null
Send $cd "local im = FindFirstOf('BP_InventoryManager_C') im:GiveItemToPlayer(StaticFindObject('$STEEL')) im:GiveItemToPlayer(StaticFindObject('$FAB')) return 'given'" | Out-Null
Play 'zone A' $PlayRounds
$worldA = (Status $hchan).world

if (-not $script:dead) {
    Log "=== 2. the next zone: the guest to the exit gate first, then the host picks a junction"
    ToOwnCars
    $gate = Send $hd "for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.ExitActive and not e.IsGarageExit then return e:GetFName():ToString() end end return 'none'"
    Log "  host's exit gate: $gate"
    # (the car put on the gate before the player sat in it went through unnoticed once: up to 3 tries)
    for ($try = 1; $try -le 3; $try++) {
        Log "  guest: $(DriveInto $cd $gate) (try $try)"
        $c = WaitFor $cchan { param($s) $s.state -eq 'zone:_at_the_exit' } 12
        if ($c.state -eq 'zone:_at_the_exit') { break }
    }
    Check "zone A's exit: the guest waits for the host there" ($c.state -eq 'zone:_at_the_exit' -and $c.world -eq $worldA) $c.raw
    Log "  host: $(DriveInto $hd $gate)"
    Start-Sleep 6
    Log "  host: $(Send $hd "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') EXITS_GO = 'travelto' EXITS_MAP = 'keep' EXITS_ANY_LEG = nil return dofile('$(P $t)/cmds/exits-probe.lua')" -Dev)"
    & "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "  host: $_" }
    $h = WaitFor $hchan { param($s) $s.state -eq 'hosting' -and $s.world -ne $worldA } 300
    $c = WaitFor $cchan { param($s) $s.state -eq 'playing' -and $s.world -eq $h.world } 480
    Check "zone B: a new zone" ($h.world -ne $worldA) "host world $($h.world), was $worldA"
    Arrived 'zone B' $h $c
    Expose
    Play 'zone B' $PlayRounds
}

if (-not $script:dead) {
    Log "=== 3. home together, out again"
    ToOwnCars
    Log "  host: $(Send $hd "$run return Run.goHome(false, 0)" -Dev)"
    & "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "  host: $_" }
    # (own-car mode: the guest stays in the zone, its sync stopped - it plays on alone; it goes home by itself)
    $c = WaitFor $cchan { param($s) $s.note -match 'host_left' } 30
    Check "the host home: the guest stays in its zone, its sync stopped, alive" ($c.note -match 'host_left' -and $c.world -notmatch 'Garage') $c.raw
    Log "  guest: $(Send $cd "$run return Run.goHome(false, 0)" -Dev)"
    & "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { Log "  guest: $_" }
    $h = Status $hchan; $c = Status $cchan
    Check "home: both in their garages, the lobby kept" ($h.world -match 'Garage' -and $c.world -match 'Garage') "host: $($h.raw) | guest: $($c.raw)"
    Start-Sleep 15
    $r = Depart
    Arrived 'zone C (out again)' $r.h $r.c
    Expose
    Play 'zone C' ([math]::Max(3, [int]($PlayRounds / 2)))
}

Log "=== SUMMARY"
Log ("actions: " + (($script:count.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))
$avg = if ($script:settle.Count) { ($script:settle | Measure-Object -Average -Maximum) } else { $null }
Log ("state checks: {0}, alike {1}, settled in avg {2:N1} s / max {3:N0} s; loot checks failed: {4}" -f $script:checks, $script:converged, $avg.Average, $avg.Maximum, $script:lootBad)
foreach ($k in ($script:failed.Keys | Sort-Object)) { Log "  DIFF $k in $($script:failed[$k][0]) checks, first $($script:failed[$k][1])" }
foreach ($k in $script:errs.Keys) { Log "  ERRORS $k`: $($script:errs[$k])" }
Check "no mod errors on either side" ($script:errs.Count -eq 0) "$(($script:errs.GetEnumerator() | ForEach-Object { "$($_.Name): $($_.Value)" }) -join ' | ')"
if ($script:mem.Count) { Log "memory first: $($script:mem[0]) | last: $($script:mem[-1])" }
foreach ($x in @(@{ t = 'host'; c = $hchan }, @{ t = 'guest'; c = $cchan })) {
    $hl = @(Get-Content "$($x.c)\hitches.log" -ErrorAction SilentlyContinue)
    $gaps = @($hl | Where-Object { $_ -match '^G' } | ForEach-Object { [double](($_ -split "`t")[2]) })
    $frs = @($hl | Where-Object { $_ -match '^F' } | ForEach-Object { [double](($_ -split "`t")[2]) })
    $mod = @($hl | Where-Object { $_ -match '^F' } | ForEach-Object { $f = $_ -split "`t"; if ($f.Count -ge 6) { [double]$f[5] } })
    Log ("{0}: frame gaps over 250 ms: {1} (worst {2:N0} ms); fps min {3:N0} avg {4:N0}; mod ms/frame avg {5:N1} max {6:N1}" -f $x.t, $gaps.Count, ($gaps | Measure-Object -Maximum).Maximum, ($frs | Measure-Object -Minimum).Minimum, ($frs | Measure-Object -Average).Average, ($mod | Measure-Object -Average).Average, ($mod | Measure-Object -Maximum).Maximum)
    Copy-Item "$($x.c)\hitches.log" "$out\hitches-$($x.t).log" -ErrorAction SilentlyContinue
    Copy-Item "$($x.c)\status.txt" "$out\status-$($x.t).txt" -ErrorAction SilentlyContinue
}
foreach ($tg in 'host', 'client') { Copy-Item "$inst\$tg\userdir\Saved\Logs\PenDriverPro.log" "$out\game-$tg.log" -ErrorAction SilentlyContinue }
if (Test-Path "$out\proxy.txt") { Log "link: $(Get-Content "$out\proxy.txt")" }
if ($script:fails.Count) { Log "failed: $($script:fails -join ' / ')" }
Log "=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
$env:COOPTEST_FPS = $null
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($proxy) { Stop-Process -Id $proxy.Id -Force -ErrorAction SilentlyContinue }
}
