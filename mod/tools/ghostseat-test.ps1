# Automated own-car mode test, step 2 (two headless instances over the relays): getting into the other player's
# car (this side's copy of it: a TWIN - a real car - by default, a ghost with -Ghost) with the game's interact at its
# door, being seated by the car's owner, driving it (twin: the car interface axes the game sends, AccelerateBrake /
# HANDBRAKE; ghost: the character's own input), getting out (twin: car manager and item links back on the own car);
# the owner leaving while the other sits in its car (no leaving in another's car: the passenger is put out, split),
# and (twin) a new run after both went home.
param([switch]$Keep, [switch]$Ghost, [switch]$OldZone)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { if ($a -eq '-' -or $b -eq '-' -or -not $a -or -not $b) { return 1e9 }; $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
function Cars($dir) { KV (Send $dir "return CoopPlayers.carsInfo()") }
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Puppet($dir) { KV (Send $dir "return CoopPlayers.puppetInfo()") }
function Place($dir) { KV (Send $dir "$run return Run.where()") }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# stand at door n of the other's car (ghost) and press interact
function Board($dir, [int]$door) {
    $at = Send $dir "return CoopPlayers.ghostDoor($door)"
    if ($at -eq 'none' -or -not $at) { return "no ghost ($at)" }
    $v = Vec $at
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = $($v.X), Y = $($v.Y), Z = $($v.Z + 100) }, false, {}, true) p['Command Interact'](p, true) return 'interact at door $door'"
}
function Interact($dir) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) return 'interact'" }
# twin doors: look at door n of the other's twin until the game highlights it (as a player aims), E down, up again
# after $ms (100: a tap; 700: held - the door only)
function Tap($dir, [int]$door, [int]$ms = 100) {
    $slot = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR'; 5 = 'DoorsTrunk' }[$door]
    $look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        Send $dir "LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null
        Start-Sleep 1
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^(OK )?$door\s*$") { break }
    }
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E at door $door for $ms ms (highlighted door: $($h.Trim()))'"
}
function Door($dir, [int]$n) { KV (Send $dir "return CoopPlayers.doorInfo($n)") }
function TwinYaw($d) { $y = "$($d.twin_rot)" -split '/'; if ($y.Count -lt 2) { return 0 }; [math]::Max([math]::Abs([double]$y[0]), [math]::Abs([double]$y[1])) }
# the character's own input, every frame: W for 4 s, then space (handbrake), kept pressed so the car stands for
# the comparison (released, it rolled on downhill); the loop cancels itself
function DriveGhost($dir) {
    if (-not $Ghost) {
        # a twin (real car): the game calls the car interface (AccelerateBrake, HANDBRAKE) on the own car with the
        # driver's axes every frame; the mod takes them as the twin driver's input
        return Send $dir "local c = CoopPlayers.ownCarActor() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 9 then CancelDelayedAction(h) return end if dt > 4 then c:AccelerateBrake(0) c:HANDBRAKE(1) return end c:AccelerateBrake(1.0) c:SteerLeftRight(0) end) return 'driving the twin'"
    }
    Send $dir "local p = FindFirstOf('PlayerController').Pawn local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 9 then CancelDelayedAction(h) return end if dt > 4 then p['Command Move Forward/Backward'](p, 0) p['Command Jump'](p, 0) return end p['Command Move Forward/Backward'](p, 1.0) p['Command Move Left/Right'](p, 0) end) return 'driving from the ghost'"
}
# a car may still creep (handbrake only, on a slope) and the two sides are read one after the other:
# tolerance 30 + its speed x 0.8 s (transport + the ghost's smoothing; still cars: owncar-test, error 0)
function Speed($dir) { [double](Send $dir "local c = CoopPlayers.ownCarActor() local v = c:GetVelocity() return string.format('%.0f', math.sqrt(v.X * v.X + v.Y * v.Y))") }
function OwnCarAt($dir) { Send $dir "local c = CoopPlayers.ownCarActor() local l = c:K2_GetActorLocation() return string.format('%.1f,%.1f,%.1f', l.X, l.Y, l.Z)" }

$kind = if ($Ghost) { 'ghost' } else { 'twin' }
$hostOpts = if ($Ghost) { '{ ghost = true }' } else { 'nil' }
$guestOpts = if ($Ghost) { '{ ownCar = true, ghost = true }' } else { '{ ownCar = true }' }
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 1. the guest joins with its own car; both get out of their cars"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -OldZone:$OldZone | Select-String 'arrived|matched on client'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)', $hostOpts)")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)', $guestOpts)")
Start-Sleep 15 # the car layouts come every 10 s
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4
$h = Cars $hd; $c = Cars $cd
Check "both have the other's car as a $kind" ($h.copy -ne '-' -and $c.copy -ne '-' -and $h.copy_kind -eq $kind -and $c.copy_kind -eq $kind) "host: $($h.raw) | guest: $($c.raw)"

if ($Ghost) {
"=== 2. the guest gets into the host's car at the driver door"
"  guest: " + (Board $cd 1); Start-Sleep 4
$g = Ghost $cd; $hp = Puppet $hd; $hs = KV (Send $hd "return CoopPlayers.seatInfo()")
Check "guest sits in the host's car (ghost), driver seat" ($g.in_ghost -eq 'H' -and $g.seat -eq '1') $g.raw
Check "host: the guest's puppet sits on its driver seat" ($hp.state -eq 'sit' -and $hs.client_seat -eq '1') "puppet: $($hp.raw) | seats: $($hs.raw)"

"=== 3. the guest drives the host's car (W, then handbrake)"
$before = (Cars $hd).own
"  guest: " + (DriveGhost $cd); Start-Sleep 2
"  mid-drive guest: " + (Send $cd "return CoopPlayers.wheelInfo() .. ' | ' .. CoopPlayers.ghostAxesInfo()")
"  mid-drive host: " + (Send $hd "return CoopPlayers.wheelInfo() .. ' | ' .. CoopPlayers.controlsInfo()")
Start-Sleep 12
$sp = Speed $hd; $h = Cars $hd; $c = Cars $cd
$moved = Dist $before $h.own
Check "the host's car drove on the guest's input (>= 300)" ($moved -ge 300) "moved $moved"
$e = Dist $h.own $c.copy
Check "the guest's ghost of the host's car is on it (<= 30 + speed x 0.8)" ($e -le 30 + 0.8 * $sp) "host car $($h.own) | guest ghost $($c.copy) | error $e | speed $sp"

"=== 4. the guest gets out"
"  guest: " + (Interact $cd); Start-Sleep 3
$g = Ghost $cd; $s = KV (Send $cd "return CoopPlayers.selfInfo()")
Check "guest is out, walking next to the car" ($g.in_ghost -eq '-' -and $s.in_car -eq 'False') "$($g.raw) | $($s.raw)"

"=== 5. the host gets into the guest's car and drives it"
"  host: " + (Board $hd 1); Start-Sleep 4
$g = Ghost $hd; $cg = Ghost $cd; $cp = Puppet $cd
Check "host sits in the guest's car (ghost), driver seat" ($g.in_ghost -eq 'G' -and $g.seat -eq '1') $g.raw
Check "guest: the host's puppet sits in its car, its table says host on 1" ($cp.state -eq 'sit' -and $cg.seatG_host -eq '1') "puppet: $($cp.raw) | $($cg.raw)"
$before = OwnCarAt $cd
"  host: " + (DriveGhost $hd); Start-Sleep 2
"  mid-drive host: " + (Send $hd "return CoopPlayers.ghostAxesInfo()")
Start-Sleep 12
$sp = Speed $cd; $after = OwnCarAt $cd; $moved = Dist $before $after
Check "the guest's car drove on the host's input (>= 300)" ($moved -ge 300) "moved $moved"
$e = Dist $after (Cars $hd).copy
Check "the host's ghost of the guest's car is on it (<= 30 + speed x 0.8)" ($e -le 30 + 0.8 * $sp) "guest car $after | host ghost $((Cars $hd).copy) | error $e | speed $sp"
"  host: " + (Interact $hd); Start-Sleep 3
$g = Ghost $hd
Check "host is out again" ($g.in_ghost -eq '-') $g.raw
} else {
# a twin (owner's ask, alpha 9 test: "sat for a second at the wheel, then thrown out"): its doors work like the own
# car's - E tapped opens the door and gets in with the game's entry animation when the seat behind it is free; held,
# or at a taken seat (the driver's - never for the other player -, a player's, a device's), the door only
"=== 2. twin doors: the guest's E held at the host car's driver door opens it; the host shuts it, the twin follows"
# (native cars, 2026-10-31: the doors are the game's own on both cars - a hold at a shut driver's door opens it (a tap
# there gets in: cars-test), a tap at an open one gets in too; shutting it is its owner's or a tap from inside)
"  guest: " + (Tap $cd 1 700); Start-Sleep 3
$g = Ghost $cd; $hdoor = Door $hd 1; $cdoor = Door $cd 1
Check "guest not seated at the twin's wheel" ($g.in_ghost -eq '-') "$($g.raw) | guest doors: $($cdoor.raw)"
$par = Send $cd "local p = FindFirstOf('PlayerController').Pawn local a = p:GetAttachParentActor() return (a and a:IsValid()) and a:GetFName():ToString() or 'none'"
$hslot = Send $hd "local sl = FindFirstOf('BP_InventoryManager_C').Inventory_CarEquipped:GetSlot(FName('Car.Equip.Body.DoorsFL')) return sl.Items:GetArrayNum() > 0 and 'on' or 'GONE'"
Check "nor put into its own car by the game's E (alpha 12), the host's door still on its car" ($par -eq 'none' -and $hslot -eq 'on') "guest parent=$par host door=$hslot"
Check "the host's driver door opened (the guest's hold)" ($hdoor.own_open -eq 'true') "host: $($hdoor.raw)"
Check "the guest's twin shows that door open" ((TwinYaw $cdoor) -gt 20) "guest: $($cdoor.raw)"
"  host shuts it: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() return CoopPlayers.twinModule().setDoor(c, 1, 'shut')")
Start-Sleep 6 # (the twin's door, open by the game here too, is shut here once the owner's is: TD.DOOR_LOCAL_MS + a try)
$hdoor = Door $hd 1; $cdoor = Door $cd 1
Check "the host's driver door shut, the guest still outside" ($hdoor.own_open -eq 'false' -and (Ghost $cd).in_ghost -eq '-') "host: $($hdoor.raw) | guest: $($cdoor.raw)"
Check "the guest's twin shows it shut" ((TwinYaw $cdoor) -lt 5) "guest: $($cdoor.raw)"

"=== 3. the guest gets into the host car's back seat through its door (seat freed of its device first)"
"  host: " + (Send $hd "return CoopPlayers.removeSeatDevice(3)"); Start-Sleep 3
"  guest: " + (Tap $cd 3); Start-Sleep -Milliseconds 900
$hdoor = Door $hd 3
Check "the host's back door opened for the entry" ($hdoor.own_open -eq 'true') "host: $($hdoor.raw)"
Start-Sleep 4
$g = Ghost $cd; $hp = Puppet $hd; $hs = KV (Send $hd "return CoopPlayers.seatInfo()"); $hdoor = Door $hd 3
Check "guest sits in the host's car (twin), back left seat" ($g.in_ghost -eq 'H' -and $g.seat -eq '3') $g.raw
Check "host: the guest's puppet sits on its seat 3" ($hp.state -eq 'sit' -and $hs.client_seat -eq '3') "puppet: $($hp.raw) | seats: $($hs.raw)"
Check "the host's back door shut after the entry" ($hdoor.own_open -eq 'false') "host: $($hdoor.raw)"
$g = Ghost $cd
Check "guest: the host's car pose (wheels, steering wheel, needles) reaches its twin" ([int]$g.poses -gt 20) $g.raw
"  guest twin mirror (headless: may be false - no rendering): mirror=$($g.mirror)"

"=== 4. the guest gets out"
# (native cars: the game's exit - the passenger looks at its door, the ExitDoor spot moved there, and presses E)
"  guest: " + ((Send $cd ("CE_CAR = 'twin' CE_HL = 'ExitDoor' " + (Get-Content "$PSScriptRoot\cmds\car-e.lua" -Raw))) -split "`n" | Select-Object -Last 1); Start-Sleep 4
$g = Ghost $cd; $s = KV (Send $cd "return CoopPlayers.selfInfo()")
Check "guest is out, walking next to the car" ($g.in_ghost -eq '-' -and $s.in_car -eq 'False') "$($g.raw) | $($s.raw)"
Check "guest: the car manager is back on its own car, its items still link to its own parts" ($g.manager_on_twin -eq 'false' -and $g.broken_links -eq '0') $g.raw

"=== 5. the host gets into the guest's car: a seat with a device only opens the door, a free one seats it"
"  host: " + (Tap $hd 4); Start-Sleep 3
$g = Ghost $hd; $cdoor = Door $cd 4; $hdoor = Door $hd 4
$busy = "$($hdoor.busyG)".Contains('4')
if ($busy) {
    Check "seat 4 holds a device: the host stays outside, the guest's door 4 opened" ($g.in_ghost -eq '-' -and $cdoor.own_open -eq 'true') "$($g.raw) | guest: $($cdoor.raw) | host: $($hdoor.raw)"
    "  host: " + (Tap $hd 4 700); Start-Sleep 2
    "  guest: " + (Send $cd "return CoopPlayers.removeSeatDevice(4, true)"); Start-Sleep 3
    "  host: " + (Tap $hd 4); Start-Sleep 5
} else { "  (seat 4 of the guest's car was free: busyG=$($hdoor.busyG))"; Start-Sleep 2 }
$g = Ghost $hd; $cg = Ghost $cd; $cp = Puppet $cd
Check "host sits in the guest's car (twin), back right seat" ($g.in_ghost -eq 'G' -and $g.seat -eq '4') $g.raw
Check "guest: the host's puppet sits in its car, its table says host on 4" ($cp.state -eq 'sit' -and $cg.seatG_host -eq '4') "puppet: $($cp.raw) | $($cg.raw)"
"  host: " + ((Send $hd ("CE_CAR = 'twin' CE_HL = 'ExitDoor' " + (Get-Content "$PSScriptRoot\cmds\car-e.lua" -Raw))) -split "`n" | Select-Object -Last 1); Start-Sleep 4
$g = Ghost $hd
Check "host is out again" ($g.in_ghost -eq '-') $g.raw
Check "host: the car manager is back on its own car, its items still link to its own parts" ($g.manager_on_twin -eq 'false' -and $g.broken_links -eq '0') $g.raw
}

"=== 6. the guest sits in the host's car, the host goes home: the guest stays (no leaving in another's car)"
"  guest: " + $(if ($Ghost) { Board $cd 1 } else { Tap $cd 3 }); Start-Sleep 5
"  guest: " + (Ghost $cd).raw
"  host: " + (Send $hd "$run return Run.goHome(false, 0)"); Start-Sleep 25
$w = Place $hd; $gp = Place $cd; $g = Ghost $cd; $c = Cars $cd; $s = KV (Send $cd "return CoopPlayers.selfInfo()")
Check "host is home" ($w.state -eq '4' -and $w.world -eq 'RB_Garage') $w.raw
Check "guest stayed in the zone, put out of the host's car (split)" ($gp.state -eq '5' -and $c.split -eq 'True' -and $g.in_ghost -eq '-' -and $s.in_car -eq 'False') "$($gp.raw) | $($g.raw) | $($c.raw)"
"=== 7. the guest goes home"
"  guest: " + (& "$t\trace-on.ps1" -Dir $cd -Sec 150)
"  guest: " + (Send $cd "$run return Run.goHome(false, 0)"); Start-Sleep 25
$gp = Place $cd
Check "guest is home" ($gp.state -eq '4' -and $gp.world -eq 'RB_Garage') $gp.raw
if (-not $Ghost) {
    "=== 8. both home after twins: the next run starts (the travel crash of a second car is gone)"
    "  guest: " + (Send $cd "StaticFindObject('/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C'):TravelToNextLeg(FindFirstOf('PlayerController')) return 'out'")
    & "$t\wait-state.ps1" -State 5 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
    $gp = Place $cd
    Check "guest drove out to a new zone after the twin runs" ($gp.state -eq '5') $gp.raw
}

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
