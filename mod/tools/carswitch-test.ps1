# Repeated switching between the own car and the other's (owner, 2026-11-13): each side own -> other -> own ->
# other, to catch bugs that only show up on a SECOND entry (a stale door/seat/highlight left from the first visit,
# the lever/key still wired to the car just left, a light state bled from the other car). At every switch point
# both sides' full car readouts (stateLine: every part's health/fuel/battery/wear; lights; door-open flags) are
# compared between this side's own car and the other side's twin VIEW of it - a generic sync check, not just the
# few fields the other tests happen to look at.
# -SetupOnly: the pair in the zone with the sync running, nothing checked (probes by hand); -Reuse: such a pair.
param([switch]$Keep, [switch]$Reuse, [switch]$SetupOnly)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

if (-not $Reuse) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
    & "$t\deploy.ps1"
    "=== 0. the guest joins with its own car"
    & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived|matched on client'
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    # (the guest's own car beside the host's, never ahead of it - cars-test's own freeSpot placement, item 8b note)
    "  guest car aside: " + (Send $cd "local c = FindFirstOf('BP_CarManager_C').NewCarActor local R = dofile('$($t.Replace('\', '/'))/../CoopSync/Scripts/runsync.lua') local at = $(Send $hd "local c = FindFirstOf('BP_CarManager_C').NewCarActor local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f,Yaw=%.2f}', l.X, l.Y, l.Z, r.Yaw)") local fy, ry = math.rad(at.Yaw), math.rad(at.Yaw + 90) local to, why = R.freeSpot(c, at, function(q) local dx, dy = q.X - at.X, q.Y - at.Y local along, side = dx * math.cos(fy) + dy * math.sin(fy), dx * math.cos(ry) + dy * math.sin(ry) return dx * dx + dy * dy < 450 ^ 2 or (along > 0 and math.abs(side) < 350) end) c.RootComponent:SetSimulatePhysics(false) c:K2_SetActorLocationAndRotation(to, { Pitch = 0, Yaw = at.Yaw, Roll = 0 }, false, {}, true) c.RootComponent:SetSimulatePhysics(true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved: ' .. tostring(why)")
    Start-Sleep 3
    "host: " + (Send $hd "CoopSyncNative = true $lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
    "client: " + (Send $cd "CoopSyncNative = true $lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
    Start-Sleep 15 # the car layouts come every 10 s
}
if ($SetupOnly) { "=== pair ready (probes by hand; carswitch-test -Reuse runs the checks)"; return }

function InCar($dir) { Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())" }
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Twin() { "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end" }
function OwnAt($dir) { Send $dir "local l = CoopPlayers.twinModule().ownCar():K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y)" }
function Moved($a, $b) { $p = $a -split ','; $q = $b -split ','; [math]::Round([math]::Sqrt(([double]$q[0] - [double]$p[0]) * ([double]$q[0] - [double]$p[0]) + ([double]$q[1] - [double]$p[1]) * ([double]$q[1] - [double]$p[1]))) }
function E($dir, [string]$pre) { Send $dir "$pre $(Get-Content "$t\cmds\car-e.lua" -Raw)" }
# look at the other's twin driver door until the game highlights it, then E (cars-test's Tap, trimmed to door 1 only)
$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
# -OnlyIfLit: no blind E when the aim missed (cars-test's own safeguard - an E on something else got the host into
# the car and the next spot's try started seated, 2026-11-10); returns whether it actually found and tapped the door
function TapDriver($dir, [switch]$OnlyIfLit) {
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = 'DoorsFL' $look" | Out-Null
        Start-Sleep -Milliseconds 500
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^(OK )?1\s*$") { break }
    }
    if ($OnlyIfLit -and $h -notmatch "^(OK )?1\s*$") { return @{ ok = $false; msg = "no E (highlighted: $($h.Trim()))" } }
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after(100, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'" | Out-Null
    @{ ok = $true; msg = "tap driver door (highlighted: $($h.Trim()))" }
}
# walk up to the other's car's driver door, from its known parked (home) transform - not the twin's live transform:
# that depends on this side's twin catching up to a teleport that may have just happened, and twin doors get muted/
# rebuilt now and then, which can shift what tw:GetTransform() answers at the exact moment asked. $home is the car's
# own "X,Y,Z,Yaw" (CarHome); a second, different local spot as a fallback (cars-test 8b: the first aim misses now
# and then, a slope or just camera jitter)
function WalkToTwinDoor($dir, [string]$home, [double]$lx = 100, [double]$ly = -230) {
    $p = $home -split ','
    Send $dir "local X, Y, Z, Yaw = $($p[0]), $($p[1]), $($p[2]), $($p[3]) local yaw = math.rad(Yaw) local lx, ly = $lx, $ly local wx = X + lx * math.cos(yaw) - ly * math.sin(yaw) local wy = Y + lx * math.sin(yaw) + ly * math.cos(yaw) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = wx, Y = wy, Z = Z + 100 }, false, {}, true) return 'there'"
}
function StepAwayFromOwn($dir) {
    Send $dir "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local l, r = car:K2_GetActorLocation(), car:GetActorRightVector() p:K2_SetActorLocation({ X = l.X - r.X * 500, Y = l.Y - r.Y * 500, Z = l.Z + 80 }, false, {}, true) return 'away'"
}
# every readable car indicator at once: part health/fuel/battery/wear (stateLine), how many lamps are lit, and
# which of the 5 doors are open - of the local player's OWN car, or of this side's view of the OTHER's (twin)
$metricsFn = "local function CSW_metrics(which) local T = CoopPlayers.twinModule() local car if which == 'own' then car = T.ownCar() else for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then car = c end end end if not (car and car:IsValid()) then return 'NOCAR' end local cont = (which == 'own') and nil or T.twinContainer(car) local st = T.stateLine(cont) or '' local li = T.lightLine(car, cont) or '' local lit = 0 for v, h in li:gmatch('=([%d.]+)(h?)') do if tonumber(v) > 0.5 and h == '' then lit = lit + 1 end end local doors = {} for n = 1, 5 do doors[n] = (T.doorOpen(car, n) and 'T' or 'F') end return string.format('STATE[%s] LIT=%d DOORS=%s', st, lit, table.concat(doors)) end"
function Metrics($dir, [string]$which) { Send $dir "$metricsFn return CSW_metrics('$which')" }
function ParseLine($s) {
    $m = @{}
    if ($s) { foreach ($kv in (($s -replace '^STATE\[', '') -replace '\].*$', '' -split ';')) { if ($kv -match '^([^=]+)=(.*)$') { $m[$Matches[1]] = $Matches[2] -split ',' } } }
    $m
}
# every numeric field of two stateLine readouts (same slot, same position in the comma list), within a loose
# tolerance - not an exact-replica of the sync code's own epsilon, just a net wide enough to miss float jitter and
# catch a real desync (one side's value holding still while the other moved, or a part missing on one side)
function StateDiff($a, $b, [double]$eps = 1.0) {
    $ma = ParseLine $a; $mb = ParseLine $b
    $bad = @()
    foreach ($k in $ma.Keys) {
        if (-not $mb.ContainsKey($k)) { $bad += "$k missing on the other side"; continue }
        for ($i = 0; $i -lt $ma[$k].Count; $i++) {
            $x = $ma[$k][$i]; $y = $mb[$k][$i]
            if ($x -and $y) {
                $dx = [double]$x; $dy = [double]$y
                if ([math]::Abs($dx - $dy) -gt $eps) { $bad += "$k`[$i]: $x vs $y" }
            }
        }
    }
    foreach ($k in $mb.Keys) { if (-not $ma.ContainsKey($k)) { $bad += "$k missing on this side" } }
    $bad
}
function MetricLine($s) { if ($s -match '^(STATE\[.*\]) LIT=(\d+) DOORS=(\w+)$') { @{ state = $Matches[1]; lit = [int]$Matches[2]; doors = $Matches[3] } } else { @{ state = ''; lit = -1; doors = '?????' } } }
# compares this side's OWN car readout against the other side's TWIN-of-it readout: what should be the same car
function CompareSync($label, $ownRaw, $twinRaw) {
    $o = MetricLine $ownRaw; $w = MetricLine $twinRaw
    $diff = StateDiff $o.state $w.state
    Check "${label}: the other side's twin matches every part's health/fuel/battery/wear" ($diff.Count -eq 0) $(if ($diff.Count -eq 0) { "ok ($($o.state.Length) chars)" } else { ($diff | Select-Object -First 5) -join ' | ' })
    Check "${label}: the other side's twin shows the same lamps lit" ($o.lit -eq $w.lit) "own lit=$($o.lit), twin lit=$($w.lit)"
    Check "${label}: the other side's twin shows the same doors open" ($o.doors -eq $w.doors) "own doors=$($o.doors), twin doors=$($w.doors)"
}

function EnterOwn($dir, $who) {
    if ((InCar $dir) -ne 'true') { "  $who in (own): " + (Send $dir "return CoopPlayers.botEnterCar()"); Start-Sleep 3 }
}
# the native ExitDoor E sometimes opens the door but does not let go (still attached a moment later - caught once
# live: the guest stayed in its own car, which then blocked both sides' phase-4 entries since the game correctly
# saw that seat as taken); press again until InCar is actually false
function ExitCar($dir, [string]$kind, $who) {
    for ($i = 0; $i -lt 3; $i++) {
        E $dir "CE_CAR = '$kind' CE_HL = 'ExitDoor'" | Out-Null
        Start-Sleep 4
        if ((InCar $dir) -eq 'false') { return "  $who out ($kind), try $($i + 1)" }
    }
    "  $who STILL IN after 3 exit tries ($kind)"
}
function ExitOwn($dir, $who) { ExitCar $dir 'own' $who }
function EnterOther($dir, $who, [string]$otherHome) {
    $r = $null
    foreach ($spot in @(100, -230), @(60, -190)) {
        WalkToTwinDoor $dir $otherHome $spot[0] $spot[1] | Out-Null; Start-Sleep 1
        $r = TapDriver $dir -OnlyIfLit
        if ($r.ok) { break }
    }
    if (-not $r.ok) { $r = TapDriver $dir } # both spots missed: tap anyway so the check below reports it plainly
    "  $who -> other: $($r.msg)"; Start-Sleep 5
}
function ExitOther($dir, $who) { ExitCar $dir 'twin' $who }
function ToggleLights($dir) { Send $dir "local m = FindFirstOf('BP_CarManager_C') m.NewCarActor:ToggleHeadlights() return 'toggled'" | Out-Null }
function ShiftAndDrive($dir, $seconds) {
    Send $dir "local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = 0 return 'drive'" | Out-Null
    Start-Sleep 2
    Send $dir "local ctl = FindFirstOf('BP_Controller_PlayerCar_C') local car = ctl.PlayerCarReference local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > $seconds then car.UserThrottleInput = 0 car.UserHandBrakeInput = 0 CancelDelayedAction(h) return end car.UserThrottleInput = 1.0 car.UserBrakeInput = 0 end) return 'driving'" | Out-Null
    Start-Sleep ($seconds + 2)
    Send $dir "local m = FindFirstOf('BP_CarManager_C') m.MyCarGearBox = 1 return 'park'" | Out-Null
    Start-Sleep 2
}

# its own car's spot (X,Y,Z,Yaw): put back here after every drive, so the next walk-up-and-tap (a fixed offset from
# the car, like cars-test's) always finds it on the same flat ground, never wherever it got driven to or rolled on
# a slope - the one thing that made the entries flaky on the first try (carswitch-test 2026-11-13)
function CarHome($dir) { Send $dir "local c = CoopPlayers.twinModule().ownCar() local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation() return string.format('%.1f,%.1f,%.1f,%.2f', l.X, l.Y, l.Z, r.Yaw)" }
# physics off for the teleport itself (the setup's own placement trick): landing with it on could bump something at
# the destination and knock a door off (CoopPlayers.ghostInfo's bumps=1, seen live - a car's driver's door turned
# into an EmptyDoor between phase 2 and phase 4, 2026-11-13)
function ParkHome($dir, [string]$home) {
    $p = $home -split ','
    Send $dir "local c = CoopPlayers.twinModule().ownCar() c.RootComponent:SetSimulatePhysics(false) c:K2_SetActorLocationAndRotation({ X = $($p[0]), Y = $($p[1]), Z = $([double]$p[2] + 30) }, { Pitch = 0, Yaw = $($p[3]), Roll = 0 }, false, {}, true) pcall(function() c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) end) c.RootComponent:SetSimulatePhysics(true) return 'parked'" | Out-Null
}
$hHome = CarHome $hd; $cHome = CarHome $cd
# a car's driver's door can come up as an EmptyDoor slot - no door, no highlight, no way in there: its random spawn,
# or knocked off along the way (cars-test's own long-known case: "the guest's car may have no driver's door"; here,
# confirmed knocked off BETWEEN phase 2 and phase 4 by a physics bump - CoopPlayers.ghostInfo's bumps=1 - most likely
# ParkHome's teleport landing the car on something). Checked fresh before EACH phase, not once: a door that was
# there in phase 2 is not guaranteed to still be there in phase 4 (carswitch-test 2026-11-13: chased a phantom
# "can't re-enter" failure here before finding this - skip that side's "other car" steps this phase instead of
# reporting a false switching bug).
function HasDriverDoor($dir) {
    $c = Send $dir "local T = CoopPlayers.twinModule() local d = T.door(T.ownCar(), 1) return d and d:GetClass():GetFName():ToString() or '-'"
    $c -match 'Door_Base'
}
$hostCanEnterGuest = HasDriverDoor $cd
$guestCanEnterHost = HasDriverDoor $hd
if (-not $hostCanEnterGuest) { "  NOTE: the guest's car has no driver's door this run - skipping the host's entry into it" }
if (-not $guestCanEnterHost) { "  NOTE: the host's car has no driver's door this run - skipping the guest's entry into it" }

"=== phase 1: each side in its OWN car - baseline metrics, both ways"
EnterOwn $hd 'host'; EnterOwn $cd 'guest'
ToggleLights $hd; ToggleLights $cd
Start-Sleep 3
$h1 = Metrics $hd 'own'; $c1 = Metrics $cd 'own'
$h1w = Metrics $hd 'twin'; $c1w = Metrics $cd 'twin' # this side's view of the other's car
CompareSync "phase 1, host's car" $h1 $c1w
CompareSync "phase 1, guest's car" $c1 $h1w
ExitOwn $hd 'host'; ExitOwn $cd 'guest'

"=== phase 2: each side in the OTHER's car for the first time"
if ($hostCanEnterGuest) { EnterOther $hd 'host' $cHome }
if ($guestCanEnterHost) { EnterOther $cd 'guest' $hHome }
if ($hostCanEnterGuest) { $gh = Ghost $hd; Check "the host sits at the guest car's wheel" ($gh.in_ghost -eq 'G' -and $gh.seat -eq '1') $gh.raw }
if ($guestCanEnterHost) { $gc = Ghost $cd; Check "the guest sits at the host car's wheel" ($gc.in_ghost -eq 'H' -and $gc.seat -eq '1') $gc.raw }
# the own car's lights must not follow the driver into the other's car (cars-test item 3, from the driver's seat)
if ($hostCanEnterGuest) { $hOwnLit0 = (MetricLine (Metrics $hd 'own')).lit; ToggleLights $hd } # toggles the OTHER's lights (the car under the seat)
if ($guestCanEnterHost) { $cOwnLit0 = (MetricLine (Metrics $cd 'own')).lit; ToggleLights $cd }
Start-Sleep 3
if ($hostCanEnterGuest) { $hOwnLit1 = (MetricLine (Metrics $hd 'own')).lit; Check "toggling the other's lights from its wheel leaves the host's own car's lights alone" ($hOwnLit0 -eq $hOwnLit1) "own lit $hOwnLit0 -> $hOwnLit1" }
if ($guestCanEnterHost) { $cOwnLit1 = (MetricLine (Metrics $cd 'own')).lit; Check "toggling the other's lights from its wheel leaves the guest's own car's lights alone" ($cOwnLit0 -eq $cOwnLit1) "own lit $cOwnLit0 -> $cOwnLit1" }
if ($hostCanEnterGuest) { ShiftAndDrive $hd 4 }
if ($guestCanEnterHost) { ShiftAndDrive $cd 4 }
Start-Sleep 4 # let the state sync (checked every 1 s) catch up with the wear from driving before comparing
if ($guestCanEnterHost) { $h2 = Metrics $hd 'own'; $c2w = Metrics $cd 'twin'; CompareSync "phase 2, host's car (guest driving it)" $h2 $c2w }
if ($hostCanEnterGuest) { $c2 = Metrics $cd 'own'; $h2w = Metrics $hd 'twin'; CompareSync "phase 2, guest's car (host driving it)" $c2 $h2w }
if ($hostCanEnterGuest) { ExitOther $hd 'host' }
if ($guestCanEnterHost) { ExitOther $cd 'guest' }
# each side parks its OWN car back home (the other side just drove it off): phase 4's walk-up-and-tap needs it
# where it started, not wherever it rolled to or stopped askew
ParkHome $hd $hHome; ParkHome $cd $cHome
Start-Sleep 2

"=== phase 3: each side back in its OWN car - no stale wiring from the other car"
EnterOwn $hd 'host'; EnterOwn $cd 'guest'
Start-Sleep 2
# the lever/key must affect THIS car again, not the one just left (the stale-reference bug this test exists for)
$h0 = OwnAt $hd; $c0 = OwnAt $cd
Send $hd "local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = 0 return 'drive'" | Out-Null
Send $cd "local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = 0 return 'drive'" | Out-Null
Start-Sleep 2
Send $hd "return CoopPlayers.botInput(4, 1.0, 0, 0)" | Out-Null; Send $cd "return CoopPlayers.botInput(4, 1.0, 0, 0)" | Out-Null
Start-Sleep 6
$hMoved = Moved $h0 (OwnAt $hd); $cMoved = Moved $c0 (OwnAt $cd)
Send $hd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 1 return 'park'" | Out-Null
Send $cd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 1 return 'park'" | Out-Null
Check "back in its own car, the host's drive input moves its OWN car (>= 300), not the guest's" ($hMoved -ge 300) "host's own car moved $hMoved"
Check "back in its own car, the guest's drive input moves its OWN car (>= 300), not the host's" ($cMoved -ge 300) "guest's own car moved $cMoved"
# the own car's lights after this re-entry should reflect phase 1's toggle, not anything bled from phase 2
$h3 = Metrics $hd 'own'; $c3 = Metrics $cd 'own'
$h3w = Metrics $hd 'twin'; $c3w = Metrics $cd 'twin'
CompareSync "phase 3, host's car (re-entered)" $h3 $c3w
CompareSync "phase 3, guest's car (re-entered)" $c3 $h3w
ExitOwn $hd 'host'; ExitOwn $cd 'guest'

"=== phase 4: each side in the OTHER's car a second time - no leftover twin / ghost state from phase 2"
$hostCanEnterGuest = HasDriverDoor $cd
$guestCanEnterHost = HasDriverDoor $hd
if (-not $hostCanEnterGuest) { "  NOTE: the guest's car has no driver's door by now - skipping the host's entry into it" }
if (-not $guestCanEnterHost) { "  NOTE: the host's car has no driver's door by now - skipping the guest's entry into it" }
if ($hostCanEnterGuest) { EnterOther $hd 'host' $cHome }
if ($guestCanEnterHost) { EnterOther $cd 'guest' $hHome }
if ($hostCanEnterGuest) { $gh = Ghost $hd; Check "the host sits at the guest car's wheel again (not stuck in a phase-2 ghost state)" ($gh.in_ghost -eq 'G' -and $gh.seat -eq '1') $gh.raw }
if ($guestCanEnterHost) { $gc = Ghost $cd; Check "the guest sits at the host car's wheel again" ($gc.in_ghost -eq 'H' -and $gc.seat -eq '1') $gc.raw }
if ($hostCanEnterGuest) { ShiftAndDrive $hd 4 }
if ($guestCanEnterHost) { ShiftAndDrive $cd 4 }
Start-Sleep 4 # let the state sync (checked every 1 s) catch up with the wear from driving before comparing
if ($guestCanEnterHost) { $h4 = Metrics $hd 'own'; $c4w = Metrics $cd 'twin'; CompareSync "phase 4, host's car (guest driving it again)" $h4 $c4w }
if ($hostCanEnterGuest) { $c4 = Metrics $cd 'own'; $h4w = Metrics $hd 'twin'; CompareSync "phase 4, guest's car (host driving it again)" $c4 $h4w }
# exactly two cars should still exist on each side - no leaked duplicate twin from four switches
$cars = (Send $hd "local n = 0 for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c.RootComponent and c.RootComponent:IsValid() then n = n + 1 end end return n") + '/' + (Send $cd "local n = 0 for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c.RootComponent and c.RootComponent:IsValid() then n = n + 1 end end return n")
Check "still exactly two cars on each side after four switches (no leaked duplicate)" ($cars -eq '2/2') "cars host/guest: $cars"
if ($hostCanEnterGuest) { ExitOther $hd 'host' }
if ($guestCanEnterHost) { ExitOther $cd 'guest' }

$hr = Send $hd "return CoopPlayers.report()"; $cr = Send $cd "return CoopPlayers.report()"
Check "no errors on either side after the whole cycle" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') "host: $hr | guest: $cr"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
