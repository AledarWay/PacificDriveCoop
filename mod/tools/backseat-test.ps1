# The own car's back seat, out by its back door (owner's two-games test 2026-11-11: "in my car's back seat, out by the
# same back door: the driver's door opens, I go through the back door and end up as if out of the driver's door"; the
# same in the zone in the guest's car). Each side on its own car's back left seat, then the game's exit:
#   the back door opens, the driver's door does not; the player ends up by the back door.
# (cars-test step 10 only checked that the player got off the seat.) -Reuse: a pair from cars-test -SetupOnly.
param([switch]$Keep, [switch]$Reuse)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
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
    & "$t\cars-test.ps1" -SetupOnly | Select-String 'arrived|pair ready'
}
$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
$carE = Get-Content "$t\cmds\car-e.lua" -Raw
function E($dir, [string]$pre) { Send $dir "$pre $carE" }
function Press($dir, [int]$ms = 100) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'" }
$att = "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a and a:IsValid() and a:GetAddress() == CoopPlayers.twinModule().ownCar():GetAddress())"
$watch = "EW_S = 7 return dofile('$(P $t)/cmds/exit-watch.lua')"
function OwnDoors($dir) { Send $dir "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do local d = T.door(own, n) o[#o + 1] = n .. '=' .. (d and (d:GetClass():GetFName():ToString():find('EmptyDoor') and 'NONE' or 'door') or '-') end return table.concat(o, ' ')" }
function AimDoorway($dir, [string]$which) { Send $dir "local T = CoopPlayers.twinModule() local car = T.ownCar() if '$which' == 'twin' then for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then car = c end end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local m = KML:TransformLocation(car:GetTransform(), { X = -40, Y = -94, Z = 0 }) local pc = FindFirstOf('PlayerController') local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = m.X - e.X, Y = m.Y - e.Y, Z = m.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'aimed at the doorway'" }
# (out by the game's exit only when seated: its ExitDoor pressed on foot took the car's driver's door off - backseat-test 2026-11-11)
function Out($dir) { if ((Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())") -match 'true') { E $dir "CE_CAR = 'own' CE_HL = 'ExitDoor'" } else { 'already out' } }
function DoorsNow($what) { "  doors after $what - host: $(OwnDoors $hd) | guest: $(OwnDoors $cd)" }
# x of a "x,y" pair
function X($s) { if ($s -match '^(-?\d+),') { [double]$Matches[1] } else { 1e9 } }
function Y($s) { if ($s -match ',(-?\d+)$') { [double]$Matches[1] } else { 1e9 } }

# (the host by its back left door, the guest by its back right one: the right side's exit spot is mirrored)
foreach ($side in @(@{ name = 'host'; dir = $hd; n = 3 }, @{ name = 'guest'; dir = $cd; n = 4 })) {
    $d = $side.dir; $who = $side.name; $bn = $side.n; $slotName = @{ 3 = 'DoorsRL'; 4 = 'DoorsRR' }[$bn]; $frame = @{ 3 = 'SLOT_BackSeatLeft'; 4 = 'SLOT_BackSeatRight' }[$bn]; $sy = if ($bn -eq 3) { -260 } else { 260 }
    "=== $who`: on its own car's back seat $bn, out by that back door"
    if ((Send $d $att) -match 'true') { "  out first: " + (E $d "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 5 }
    # (the back left seat free: a device there takes the seat)
    "  free the back seat: " + (Send $d "local sl = CoopPlayers.twinModule().ownCar().$frame.ItemSlot local n = sl.Items:GetArrayNum() if n > 0 then sl:RemoveItem(sl.Items[1]) end return n .. ' -> ' .. sl.Items:GetArrayNum()")
    "  to its back door: " + (Send $d "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(car:GetTransform(), { X = 0, Y = $sy, Z = 0 }) p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
    Start-Sleep 2
    $aim = ''
    foreach ($dz in 0, 20, -20, 40) {
        Send $d "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = '$slotName' $look" | Out-Null; Start-Sleep -Milliseconds 700
        Send $d "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = '$slotName' $look" | Out-Null; Start-Sleep -Milliseconds 500
        $aim = Send $d "return tostring(CoopPlayers.ownBackDoorAimed())"
        if ($aim -match "^$bn") { break }
    }
    "  E (aimed back door: $aim): " + (Press $d)
    Start-Sleep 6
    $a = Send $d $att; $n = Send $d "return CoopPlayers.seatNowN()"
    Check "$who on its back seat $bn" ($a -match 'true' -and $n -eq "$bn") "attached: $a seat: $n"
    # (the other side: its twin of this car - doors 1 and 3, the largest angle seen)
    $od = if ($who -eq 'host') { $cd } else { $hd }
    Send $od "TW = { [1] = 0, [$bn] = 0 } local t0 = os.clock() local h h = LoopInGameThreadWithDelay(100, function() if os.clock() - t0 > 7 then CancelDelayedAction(h) return end for _, n in ipairs({ 1, $bn }) do local r = tostring(CoopPlayers.doorInfo(n)):match('twin_rot=(%S+)') or '0/0' local y, p = r:match('(-?[%d.]+)/(-?[%d.]+)') TW[n] = math.max(TW[n], math.abs(tonumber(y) or 0), math.abs(tonumber(p) or 0)) end end) return 'ok'" | Out-Null
    "  watch: " + (Send $d $watch)
    "  out: " + (Out $d)
    Start-Sleep 8
    $w = KV (Send $d "return EW_READ()")
    "  exit: $($w.raw)"
    Check "$who`: its back door opened, the driver's did not" ($w.opened -match "$bn" -and $w.opened -notmatch '1') "opened $($w.opened)"
    # (by the back door: its x nearer the back door's than the driver's door's; on the left side, out of the car)
    $tw = Send $od "return string.format('%.0f/%.0f', TW[1], TW[$bn])"
    $t1, $t3 = $tw -split '/'
    Check "$who`: on the other side its twin's back door opened, the driver's stayed shut" ([double]$t3 -gt 20 -and [double]$t1 -lt 10) "twin door 1 / $bn largest angle: $tw"
    $e = $w.end
    $dB = $w["door$bn"]
    $byBack = [math]::Abs((X $e) - (X $dB)) -lt [math]::Abs((X $e) - (X $w.door1))
    $sideOk = if ($bn -eq 3) { (Y $e) -lt -80 } else { (Y $e) -gt 80 }
    Check "$who`: out by the back door (beside it, not by the driver's door)" ($w.attached -eq 'false' -and $byBack -and $sideOk) "end $e | door1 $($w.door1) door$bn $dB"
}

DoorsNow 'the back seats'
"=== the host at its own wheel, the guest at that driver's door (owner's two-games test: not lit, nothing to do with it)"
# (cars-test's Tap: look at the twin's door until the game lights it)
function Tap($dir, [int]$door, [int]$ms = 100) {
    $slot = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR'; 5 = 'DoorsTrunk' }[$door]
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null; Start-Sleep -Milliseconds 700
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null; Start-Sleep -Milliseconds 500
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^$door\s*$") { break }
    }
    if ($h -notmatch "^$door\s*$") { return "no E: door $door not lit (lit: $h)" }
    (Press $dir $ms) + " at door $door (lit)"
}
function HostDoor1() { Send $hd "local T = CoopPlayers.twinModule() return tostring(T.doorOpen(T.ownCar(), 1))" }
"  host in at its wheel: " + (Send $hd "return CoopPlayers.botEnterCar()"); Start-Sleep 5
"  host's door 1 shut first: " + (Send $hd "local T = CoopPlayers.twinModule() local d = T.door(T.ownCar(), 1) if T.doorOpen(T.ownCar(), 1) then d:AttemptShut() end return 'ok'"); Start-Sleep 3
"  guest to the host's driver's door: " + (Send $cd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = 100, Y = -230, Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
$tap = Tap $cd 1
"  guest: $tap"
Start-Sleep 3
$o1 = HostDoor1
$inH = Send $hd $att
Check "the guest's E at the lit driver's door opened the host's door (the host still at the wheel)" ($tap -match '\(lit\)' -and $o1 -eq 'true' -and $inH -match 'true') "tap: $tap | host door 1 open: $o1 | host in its car: $inH"
$tap2 = Tap $cd 1
Start-Sleep 3
$o2 = HostDoor1
Check "its E again shut it" ($o2 -eq 'false') "tap: $tap2 | host door 1 open: $o2"
$ci = Send $cd "return CoopPlayers.ghostInfo()"
Check "the guest stayed outside (the seat is the host's)" ($ci -match 'in_ghost=-') $ci.Substring(0, [math]::Min(120, $ci.Length))
DoorsNow 'the driver''s door with the host at the wheel'
"=== the guest onto the host's back left seat: the door it came in by shuts once (owner: it tried, stayed open, then shut)"
"  host out of its car: " + (Out $hd); Start-Sleep 4
"  host's back left seat free: " + (Send $hd "local sl = CoopPlayers.twinModule().ownCar().SLOT_BackSeatLeft.ItemSlot local n = sl.Items:GetArrayNum() if n > 0 then sl:RemoveItem(sl.Items[1]) end return n .. ' -> ' .. sl.Items:GetArrayNum()")
"  guest to the host's back left door: " + (Send $cd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = 0, Y = -260, Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
# (the twin's door 3 angle every 50 ms for 8 s, from the tap)
Send $cd "DS = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > 8 then CancelDelayedAction(h) return end local r = tostring(CoopPlayers.doorInfo(3)):match('twin_rot=(%S+)') or '0/0' local y, p = r:match('(-?[%d.]+)/(-?[%d.]+)') DS[#DS + 1] = math.max(math.abs(tonumber(y) or 0), math.abs(tonumber(p) or 0)) end) return 'ok'" | Out-Null
Send $hd "DH = {} local T = CoopPlayers.twinModule() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > 8 then CancelDelayedAction(h) return end DH[#DH + 1] = T.doorOpen(T.ownCar(), 3) and 'O' or '-' end) return 'ok'" | Out-Null
$tap = Tap $cd 3
"  guest: $tap"
Start-Sleep 9
"  timeline (50 ms) - host's real door 3: $(Send $hd 'return table.concat(DH)')"
"  guest's twin door 3 angle: $(Send $cd 'local o = {} for _, v in ipairs(DS) do o[#o + 1] = string.format(''%.0f'', v) end return table.concat(o, '' '')')"
"  guest door log: $(Send $cd 'return CoopPlayers.doorLog()')"
$ds = Send $cd "local mx, at = 0, 0 for i, v in ipairs(DS) do if v > mx then mx, at = v, i end end local shut, rises, low = nil, 0, math.huge for i = at, #DS do local v = DS[i] if v < low then low = v end if v > low + 10 then rises = rises + 1 low = v end if not shut and v < 5 then shut = i end end return string.format('max=%.0f open_at=%.1f shut_at=%s reopened=%d n=%d', mx, at * 0.05, shut and string.format('%.1f', shut * 0.05) or 'never', rises, #DS)"
$g = KV (Send $cd "return CoopPlayers.ghostInfo()")
"  door 3 on the guest's twin: $ds"
$m = KV $ds
Check "the guest sits on the host's back left seat" ($g.in_ghost -eq 'H' -and $g.seat -eq '3') "in_ghost=$($g.in_ghost) seat=$($g.seat)"
Check "the door it came in by opened and shut once, within 3 s of standing open" ([double]$m.max -gt 20 -and $m.shut_at -ne 'never' -and ([double]$m.shut_at - [double]$m.open_at) -lt 3 -and $m.reopened -eq '0') $ds
"  guest out: " + (E $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor'"); Start-Sleep 6
DoorsNow 'the guest in and out of the host''s back seat'
"=== the guest's back left door off: in through the doorway (its own car; owner's two-games test: no way onto a doorless back seat)"
"  host out of its car: " + (Out $hd); Start-Sleep 4
"  guest takes the door off: " + (Send $cd "return CoopPlayers.twinModule().ownerEquip('Car.Equip.Body.DoorsRL', '-')")
"  guest's back left seat free: " + (Send $cd "local sl = CoopPlayers.twinModule().ownCar().SLOT_BackSeatLeft.ItemSlot local n = sl.Items:GetArrayNum() if n > 0 then sl:RemoveItem(sl.Items[1]) end return n .. ' -> ' .. sl.Items:GetArrayNum()")
Start-Sleep 5
"  guest's doors: " + (Send $cd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do local d = T.door(own, n) o[#o + 1] = n .. '=' .. (d and (d:GetClass():GetFName():ToString():find('EmptyDoor') and 'NONE' or 'door') or '-') end return table.concat(o, ' ')")
"  guest to the doorway: " + (Send $cd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(car:GetTransform(), { X = -40, Y = -210, Z = 0 }) p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
$aim = ''
foreach ($dz in 0, 20, -20, 40, -40) {
    Send $cd "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = 'DoorsRL' $look" | Out-Null; Start-Sleep -Milliseconds 700
    Send $cd "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = 'DoorsRL' $look" | Out-Null; Start-Sleep -Milliseconds 500
    $aim = Send $cd "return tostring(CoopPlayers.ownBackDoorAimed())"
    if ($aim -match '^3') { break }
}
"  guest: " + (AimDoorway $cd 'own'); Start-Sleep 1
$lit = Send $cd "local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none'"
"  doorway: $(Send $cd 'return CoopPlayers.doorwayInfo()')"
"  E (aimed: $aim, lit: $lit): " + (Press $cd)
Start-Sleep 6
$a = Send $cd $att; $n = Send $cd "return CoopPlayers.seatNowN()"
Check "the guest got onto its doorless back left seat" ($a -match 'true' -and $n -eq '3') "attached: $a seat: $n | aimed $aim lit $lit | $(Send $cd 'return CoopPlayers.nativeInfo()' | Select-String -Pattern 'own_enter=\S+' -AllMatches | ForEach-Object { $_.Matches.Value })"
"  out: " + (Out $cd); Start-Sleep 6
Check "and out again" ((Send $cd $att) -match 'false') "attached: $(Send $cd $att)"
"=== the host onto that doorless seat of the guest's twin"
"  host to the doorway: " + (Send $hd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = -40, Y = -210, Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
# (no light there: the host looks at the doorway - the slot's spot - and presses E, as a player does)
"  host: " + (AimDoorway $hd 'twin'); Start-Sleep 1
"  doorway: $(Send $hd 'return CoopPlayers.doorwayInfo()')"
$tap = (Press $hd) + ' at the doorway'
"  host: $tap"
Start-Sleep 6
$g = KV (Send $hd "return CoopPlayers.ghostInfo()")
Check "the host got onto the guest's doorless back left seat" ($g.in_ghost -eq 'G' -and $g.seat -eq '3') "tap: $tap | in_ghost=$($g.in_ghost) seat=$($g.seat) doorless=$(Send $hd 'return tostring(CoopPlayers.report():match(''doorless%S*''))')"
DoorsNow 'the doorless seat'
$hdz = OwnDoors $hd; $gdz = OwnDoors $cd
Check "both cars kept their doors (the guest's back left one taken off by the test)" ($hdz -eq '1=door 2=door 3=door 4=door 5=door' -and $gdz -eq '1=door 2=door 3=NONE 4=door 5=door') "host: $hdz | guest: $gdz"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
}
