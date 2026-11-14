# Automated test of the twins' car body controls (twin rework stage C): the headlights / top light / wipers are one
# state in the game's car manager, and the twin's own lever / switch handlers act on the manager's car. Outside the
# other's twin they are off (its E there must not touch the own car; EnterDoor is its driver's door); inside it the
# manager holds the owner's state, the game's own lever works on it and the change reaches the owner's real car (K /
# KG lights|top|wipers, the owner's game flips it with its own toggle). Two instances over the test network.
#   1. guest, outside the host car's twin: E at its left lever / top light / EnterDoor -> the guest's own car's lights
#      untouched, the guest not in its own car, the host's real driver's door opened
#   2. guest gets in the twin (back door): the levers' handlers back, the manager holds the host's state
#   3. guest works the headlight lever and the top light there -> host's real car; the guest stays in
#   4. host switches its wipers itself -> the guest's manager follows while it sits there
#   5. guest gets out -> its own state back in the manager, its own car's headlights off; no errors
# Radio and horn (2026-10-27): the twin's radio button from outside leaves the own radio alone, inside it switches the
# owner's real radio; the guest's horn in the twin honks the host's real car; the host's horn -> the guest's twin;
# the host's wipers on -> the guest's twin's blades sweep while the guest's own wipers are off.
# Gear lever (2026-10-27): the host's own lever moves with its gear (GetGearboxActor answered the twin's), the guest's
# twin shows it.
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function Probe($dir, [string]$pre, [string]$file) { Send $dir ($pre + " " + (Get-Content "$t\cmds\$file" -Raw)) }
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# the manager's lights / top / wipers and both cars' headlights / top light (cmds/ctl-probe.lua)
function Ctl($dir) { KV ((Probe $dir "" "ctl-probe.lua") -replace '^before: ', '') }
function CtlInfo($dir) { KV (Send $dir "return CoopPlayers.twinCtlInfo()") }
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Press($dir, [string]$hl) { Probe $dir "BODY_HL = '$hl'" "twin-body-press.lua" }
# twin doors: look at door n of the other's twin until the game highlights it, E down, up again after $ms
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

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4
$g0 = Ctl $cd
"  guest before: " + $g0.raw

"=== 1. guest, outside the host car's twin: E at its levers, top light, radio, EnterDoor"
# (native cars, 2026-10-30: a car's controls are its driver's only - the game is asked whether it may highlight them;
# before, the test forced the highlight and pressed E, which a player could do through the window: the manager's one
# lights state switched the own car's lights too)
$allow = Send $cd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local hm = FindFirstOf('BP_HighlightManager_C') local o = {} for _, n in ipairs({'LeftHandle', 'RightHandle', 'TopLight', 'Key'}) do local a, w = {}, {} pcall(function() hm['Should Allow Highlight'](hm, tw['Highlight_' .. n], a, w) end) o[#o + 1] = n .. '=' .. tostring(a.Allow) end return table.concat(o, ' ')"
Check "guest: the twin's levers, top light and key are not for it outside (the game may not highlight them)" ($allow -notmatch '=true' -and $allow -match '=false') $allow
$g = Ctl $cd
Check "guest: its own car's lights / radio untouched" ($g.lights -eq $g0.lights -and $g.top -eq $g0.top -and $g.wipers -eq $g0.wipers -and $g.radio -eq $g0.radio -and $g.own_head -eq $g0.own_head) "before: $($g0.raw) | after: $($g.raw)"
# (as a player: it looks at the twin's driver's door first - the mod makes that car the game's context then)
foreach ($i in 1..2) { Probe $cd "LOOK_SLOT = 'DoorsFL'" "twin-parts-look.lua" | Out-Null; Start-Sleep -Milliseconds 700 }
"  " + ((Press $cd 'EnterDoor') -split "`n" | Select-Object -Last 1); Start-Sleep 3
$par = Send $cd "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() return (par and par:IsValid()) and (CoopPlayers.twinModule().isTwin(par) and 'TWIN' or par:GetClass():GetFName():ToString()) or 'none'"
$hdoor = KV (Send $hd "return CoopPlayers.doorInfo(1)")
$gi = Ghost $cd
# (since alpha 17 the other's driver seat is free while its owner is out of the car: EnterDoor takes the wheel)
Check "guest: EnterDoor put it at the wheel of the host's car (its twin, not its own car), the host's driver's door opened" ($par -eq 'TWIN' -and $gi.in_ghost -eq 'H' -and $gi.seat -eq '1' -and $hdoor.last_done -match '^1:') "guest parent=$par seat=$($gi.seat) | host: $($hdoor.raw)"
"  guest gets out: " + ((Probe $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor'" "car-e.lua") -split "`n" | Select-Object -Last 1)
Start-Sleep 5
$gi = Ghost $cd
Check "guest: out of the twin again (the game's exit)" ($gi.in_ghost -eq '-') "in_ghost=$($gi.in_ghost)"
"  host shuts its door: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() return CoopPlayers.twinModule().setDoor(c, 1, 'shut')")
Start-Sleep 2

"=== 2. guest gets in at the twin's wheel (the controls are the driver's; the host is out)"
$h0 = CtlInfo $hd
"  host own ltw: " + $h0.own_ltw
foreach ($i in 1..2) { Probe $cd "LOOK_SLOT = 'DoorsFL'" "twin-parts-look.lua" | Out-Null; Start-Sleep -Milliseconds 700 }
"  guest: " + ((Press $cd 'EnterDoor') -split "`n" | Select-Object -Last 1); Start-Sleep 6
$gi = Ghost $cd
$gc = Ctl $cd
Check "guest: at the twin's wheel" ($gi.in_ghost -eq 'H' -and $gi.seat -eq '1') "in_ghost=$($gi.in_ghost) seat=$($gi.seat)"
$want = "$($h0.own_ltw)"
Check "guest: the manager holds the host's lights / top / wipers / radio" ($want.Length -eq 4 -and "$([int]($gc.lights -eq 'true'))$([int]($gc.top -eq 'true'))$([int]($gc.wipers -eq 'true'))$([int]($gc.radio -eq 'true'))" -eq $want) "host=$want guest manager: $($gc.raw)"

"=== 2b. the host on the guest's back seat - each in the other's car (owner's two-games test 2026-11-11: the lever lagged and jumped back)"
$gd = Send $cd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 3, 4 do local d = T.door(own, n) o[#o + 1] = (d and not d:GetClass():GetFName():ToString():find('EmptyDoor')) and 'd' or '-' end return table.concat(o)"
$bd = if ($gd.Substring(0, 1) -eq 'd') { 3 } else { 4 }; $by = if ($bd -eq 3) { -1 } else { 1 }; $frame = if ($bd -eq 3) { 'SLOT_BackSeatLeft' } else { 'SLOT_BackSeatRight' }
"  the guest's back doors 3/4: $gd -> door $bd"
"  that back seat free: " + (Send $cd "local sl = CoopPlayers.twinModule().ownCar().$frame.ItemSlot local n = sl.Items:GetArrayNum() if n > 0 then sl:RemoveItem(sl.Items[1]) end return n .. ' -> ' .. sl.Items:GetArrayNum()")
foreach ($spot in @(@(0, -260), @(-30, -220), @(20, -240))) {
    "  host to the guest's back left door ($($spot -join ',')): " + (Send $hd "LOOK_OWN = false local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = $($spot[0]), Y = $($by * [math]::Abs($spot[1])), Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
    Start-Sleep 2
    # (the camera at the door's middle - cmds/twin-parts-look turned the host away from the guest's car here)
    Send $hd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local m = KML:TransformLocation(tw:GetTransform(), { X = -40, Y = $($by * 94), Z = 10 }) local pc = FindFirstOf('PlayerController') local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = m.X - e.X, Y = m.Y - e.Y, Z = m.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'aimed'" | Out-Null
    Start-Sleep 1
    $lit = Send $hd "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
    $tp = if ($lit -match "^$bd") { (Send $hd "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after(100, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'") + " (highlighted door: $bd)" } else { "no E (lit: $lit)" }
    "  host: $tp"
    if ($tp -match "highlighted door: $bd") { break }
}
Start-Sleep 6
$hi = Ghost $hd
Check "host: on the guest's back seat $bd" ($hi.in_ghost -eq 'G' -and $hi.seat -eq "$bd") "in_ghost=$($hi.in_ghost) seat=$($hi.seat)"
# (the guest shifts in the host's twin; the guest's manager read every 200 ms for 4 s: the lever must not come back)
$gb0 = Send $cd "return tostring(FindFirstOf('BP_CarManager_C').MyCarGearBox)"
$gw = if ($gb0 -eq '1') { 0 } else { 1 }
Send $cd "GB = {} local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = $gw local t0 = os.clock() local h h = LoopInGameThreadWithDelay(200, function() if os.clock() - t0 > 4 then CancelDelayedAction(h) return end GB[#GB + 1] = tostring(m.MyCarGearBox) end) return 'shifted'" | Out-Null
Start-Sleep 5
$gb = Send $cd "return table.concat(GB, '')"
$hk = Send $hd "return CoopPlayers.twinCtlInfo()"
Check "guest: its lever shift held, not taken back by the host's lines" ($gb -notmatch "$gb0" -and $gb.Length -ge 15) "shifted $gb0 -> $gw, the guest's manager every 200 ms: $gb | host: $hk"
"  host out of the guest's car: " + ((Probe $hd "CE_CAR = 'twin' CE_HL = 'ExitDoor'" "car-e.lua") -split "`n" | Select-Object -Last 1); Start-Sleep 6
$hgear = Send $hd "return tostring(FindFirstOf('BP_CarManager_C').MyCarGearBox)"
Check "host: out, its own car's lever is the guest's shift" ($hgear -eq "$gw") "host lever $hgear (want $gw)"
# (the host's lever as before for the steps below; its lever must have moved with the guest's shift - checked by the
# gear-lever step: a kept state put back without the animation left it at drive with the gear in park)
"  host's lever back: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() c:ToggleGearBoxState(, false) return 'toggled'"); Start-Sleep 3
"  host's gear now: " + (Send $hd "return tostring(FindFirstOf('BP_CarManager_C').MyCarGearBox)")
"=== 3. guest works the headlight lever and the top light in the twin"
"  " + ((Press $cd 'LeftHandle') -split "`n" | Select-Object -Last 1); Start-Sleep 4
$h1 = CtlInfo $hd; $gi = Ghost $cd
Check "host: its real car's headlights follow the guest's lever" ($h1.own_ltw.Substring(0, 1) -ne $want.Substring(0, 1)) "host before=$want after=$($h1.own_ltw) last_ltw_done=$($h1.last_ltw_done)"
Check "guest: still in the twin after the lever" ($gi.in_ghost -eq 'H') "in_ghost=$($gi.in_ghost) last_leave=$($gi.last_leave)"
"  " + ((Press $cd 'TopLight') -split "`n" | Select-Object -Last 1); Start-Sleep 4
$h2 = CtlInfo $hd
Check "host: its real car's top light follows the guest's switch" ($h2.own_ltw.Substring(1, 1) -ne $want.Substring(1, 1)) "host before=$want after=$($h2.own_ltw) last_ltw_done=$($h2.last_ltw_done)"
$hh = Ctl $hd
Check "host: its own car's headlights really on / off with it" (($h2.own_ltw.Substring(0, 1) -eq '1') -eq ($hh.own_head -notmatch '^0(/0)*$')) "host: $($hh.raw)"
"  " + ((Press $cd 'Radio') -split "`n" | Select-Object -Last 1); Start-Sleep 4
$h2 = CtlInfo $hd; $gi = Ghost $cd
Check "host: its real car's radio follows the guest's radio button, the guest stays in" ($h2.own_ltw.Substring(3, 1) -ne $want.Substring(3, 1) -and $gi.in_ghost -eq 'H') "host before=$want after=$($h2.own_ltw) last_ltw_done=$($h2.last_ltw_done) in_ghost=$($gi.in_ghost)"
"  guest horn: " + (Probe $cd "HORN_DO = 'start'" "horn-probe.lua"); Start-Sleep 2
$hn = Probe $hd "" "horn-probe.lua"; $gi = Ghost $cd
Check "host: its real car honks with the guest's horn in the twin" ($hn -match 'horn=true' -and $gi.twin_horn -eq 'true' -and [int]$gi.horn_asked -ge 1) "host: $hn | guest: horn_asked=$($gi.horn_asked) twin_horn=$($gi.twin_horn)"
"  guest horn: " + (Probe $cd "HORN_DO = 'stop'" "horn-probe.lua"); Start-Sleep 2
$hn = Probe $hd "" "horn-probe.lua"; $hi = Ghost $hd
Check "host: its horn stops with the guest's" ($hn -match 'horn=false' -and $hi.last_horn_done -eq '0:true') "host: $hn last_horn_done=$($hi.last_horn_done)"

"=== 4. the host switches its wipers itself"
"  host: " + ((Probe $hd "CTL_DO = 'toggle_wipers'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1); Start-Sleep 5
$h3 = CtlInfo $hd; $gc = Ctl $cd
Check "guest: the manager follows the host's wipers while it sits in the twin" ("$([int]($gc.wipers -eq 'true'))" -eq $h3.own_ltw.Substring(2, 1)) "host=$($h3.own_ltw) guest manager: $($gc.raw)"

"=== 5. guest gets out"
"  guest: " + ((Probe $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor'" "car-e.lua") -split "`n" | Select-Object -Last 1); Start-Sleep 5
$gi = Ghost $cd; $g = Ctl $cd
Check "guest: out, its own lights / top / wipers / radio back in the manager" ($gi.in_ghost -eq '-' -and $g.lights -eq $g0.lights -and $g.top -eq $g0.top -and $g.wipers -eq $g0.wipers -and $g.radio -eq $g0.radio) "in_ghost=$($gi.in_ghost) before: $($g0.raw) | now: $($g.raw)"
Check "guest: its own car's headlights as before" ($g.own_head -eq $g0.own_head) "before=$($g0.own_head) now=$($g.own_head)"
$hi = CtlInfo $hd
Check "host: its lights stay as the guest left them" ($hi.own_ltw.Substring(0, 2) -eq $h2.own_ltw.Substring(0, 2)) "host=$($hi.own_ltw)"
Start-Sleep 2
$g = Ctl $cd; $hh = Ctl $hd
$dark = '^(0(/0)*|-|)$'
Check "guest: the twin shows the host's headlights and top light, its own car dark" ($g.twin_head -notmatch $dark -and $g.twin_top -ne '0' -and $g.own_head -match $dark -and $g.own_top -eq '0') "guest: $($g.raw)"
Check "host: its twin of the guest's car dark, its own car lit" ($hh.twin_head -match $dark -and $hh.twin_top -eq '0' -and $hh.own_head -notmatch $dark) "host: $($hh.raw)"
"  host: headlights off: " + ((Probe $hd "CTL_DO = 'toggle_head'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1); Start-Sleep 4
$g = Ctl $cd
Check "guest: the twin's headlights off with the host's" ($g.twin_head -match $dark) "guest: $($g.raw)"
$gi = Ghost $cd
Check "guest: LI lines in, lights set on the twin" ([int]$gi.li_recv -gt 0 -and [int]$gi.lights_set -gt 0) "li_recv=$($gi.li_recv) lights_set=$($gi.lights_set)"
$hw = Ctl $hd
if ($hw.wipers -ne 'true') { "  host wipers on: " + ((Probe $hd "CTL_DO = 'toggle_wipers'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1); Start-Sleep 3 }
$w1 = KV (Probe $cd "" "wiper-probe.lua"); Start-Sleep -Milliseconds 400; $w2 = KV (Probe $cd "" "wiper-probe.lua"); $g = Ctl $cd
Check "guest: the twin's wiper blades sweep with the host's wipers, its own car's still (own wipers off)" ($g.wipers -eq 'false' -and $w1.twin_rot -ne $w2.twin_rot -and $w1.own_rot -eq $w2.own_rot) "1: $($w1.raw) | 2: $($w2.raw) | guest manager wipers=$($g.wipers)"
# the other way (owner, alpha 19 item 7: "the wipers at the wheel not synced"): the guest's own wipers -> the host's
# twin of the guest's car sweeps; the host's wipers off first, so its own car's blades must stand still
"  host wipers off: " + ((Probe $hd "CTL_DO = 'toggle_wipers'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1)
$gw = Ctl $cd
# (the wipers run on the car's power: the guest's car from a zone save stands with the engine off - started first, as
# a player would)
"  guest ignition: " + (Send $cd "local m = FindFirstOf('BP_CarManager_C') local own = CoopPlayers.twinModule().ownCar() local was = m.CarIgnitionState if was == 0 and m.NewCarActor:GetAddress() == own:GetAddress() then own:ToggleIgnitionState(2) end return tostring(was) .. ' -> started'")
Start-Sleep 3
if ($gw.wipers -ne 'true') { "  guest wipers on: " + ((Probe $cd "CTL_DO = 'toggle_wipers'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1) }
Start-Sleep 4
$w1 = KV (Probe $hd "" "wiper-probe.lua"); Start-Sleep -Milliseconds 400; $w2 = KV (Probe $hd "" "wiper-probe.lua"); $hm = Ctl $hd
Check "host: the twin's wiper blades sweep with the guest's wipers, its own car's still (own wipers off)" ($hm.wipers -eq 'false' -and $w1.twin_rot -ne $w2.twin_rot -and $w1.own_rot -eq $w2.own_rot) "1: $($w1.raw) | 2: $($w2.raw) | host manager wipers=$($hm.wipers)"
"  guest wipers off: " + ((Probe $cd "CTL_DO = 'toggle_wipers'" "ctl-probe.lua") -split "`n" | Select-Object -Index 1)
"  host horn: " + (Probe $hd "HORN_DO = 'start'" "horn-probe.lua"); Start-Sleep 2
$gi = Ghost $cd; $gm = Probe $cd "" "horn-probe.lua"
Check "guest: the twin honks with the host's horn, its own car not" ($gi.twin_horn -eq 'true' -and $gm -match 'horn=false') "twin_horn=$($gi.twin_horn) horn_recv=$($gi.horn_recv) guest manager: $gm"
"  host horn: " + (Probe $hd "HORN_DO = 'stop'" "horn-probe.lua"); Start-Sleep 2
$gi = Ghost $cd
Check "guest: the twin's horn stops with the host's" ($gi.twin_horn -eq 'false') "twin_horn=$($gi.twin_horn)"
$s0 = KV (Probe $hd "" "shifter-probe.lua")
"  host gear lever: " + (Probe $hd "SHIFT_DO = true" "shifter-probe.lua"); Start-Sleep 3
$s1 = KV (Probe $hd "" "shifter-probe.lua"); $sg = KV (Probe $cd "" "shifter-probe.lua")
Check "host: its own gear lever moves, its car asks for its own lever" ($s1.gear -ne $s0.gear -and $s1.own -ne $s0.own -and $s1.own_asks -eq 'own' -and $s1.twin -eq $s0.twin) "before: $($s0.raw) | after: $($s1.raw)"
Check "guest: the twin's lever stands like the host's" ([math]::Abs([double]$sg.twin - [double]$s1.own) -lt 1.5 -and $sg.own_asks -eq 'own') "host: $($s1.raw) | guest: $($sg.raw)"
"  host gear lever back: " + (Probe $hd "SHIFT_DO = true" "shifter-probe.lua"); Start-Sleep 3
$eh = Send $hd "return CoopPlayers.report()"; $eg = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($eh -notmatch 'errors=[1-9]|ERR' -and $eg -notmatch 'errors=[1-9]|ERR') "host: $eh | guest: $eg"

"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
