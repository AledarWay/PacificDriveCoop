# The players and the two cars, through the game's own paths (owner, alpha 16: "the weakest and the most important part"):
# the E presses go through the highlight manager and the character's Command Interact like a player's, never the mod's
# teleports. Two instances over the relays, own-car mode. Each side, both directions:
#   1. getting out of the own car (the game's ExitDoor): its door opens, here and on the other side's twin
#   2. into the other's car on a passenger seat and out again: the door opens both times, the player ends up outside
#   3. the own car's lights while sitting in the other's car stay as they were (here and on the other side)
#   4. the other's trunk lid: opened and shut again from outside; it carries the owner's paint
#   5. riding along while the owner drives: the twin moves smoothly (frame-to-frame speed changes like the real car's)
#   6. back in the own car: it drives
#   10. the host on the back seat of its own car (owner, alpha 18 item 10): in by the back door, no driving, out again
#   8b. (after 8, the guest's car still whole) the host at the wheel of the guest's car: every lever shift reaches it, it drives, out where it stopped (items 11 / 12)
# -SetupOnly: the pair in the zone with the sync running, nothing checked (probes by hand); -Reuse: such a pair.
param([switch]$Keep, [switch]$Reuse, [switch]$SetupOnly, [switch]$NoMute)
# native cars (the rebuild, 2026-10-30: nativecar.lua) on for this test; -NoMute: the old mode with the twins' own
# handlers kept (the first native probes)
$mute = if ($NoMute) { "CoopSyncNoMute = true CoopSyncNative = false " } else { "CoopSyncNoMute = nil CoopSyncNative = true " }
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
    "  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y - 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
    Start-Sleep 3
    "host: " + (Send $hd "$mute$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
    "client: " + (Send $cd "$mute$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
    Start-Sleep 15 # the car layouts come every 10 s
}
if ($SetupOnly) { "=== pair ready (probes by hand; cars-test -Reuse runs the checks)"; return }

$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
$carE = Get-Content "$t\cmds\car-e.lua" -Raw
function InCar($dir) { Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())" }
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Door($dir, [int]$n) { KV (Send $dir "return CoopPlayers.doorInfo($n)") }
function E($dir, [string]$pre) { Send $dir "$pre $carE" }
function Press($dir, [int]$ms = 100) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'" }
function Twin() { "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end" }
function OwnDoors($dir) { Send $dir "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do local d = T.door(own, n) o[#o + 1] = n .. '=' .. (d and (d:GetClass():GetFName():ToString():find('EmptyDoor') and 'NONE' or 'door') or '-') end return table.concat(o, ' ')" }
function OwnAt($dir) { Send $dir "local l = CoopPlayers.twinModule().ownCar():K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y)" }
function Moved($a, $b) { $p = $a -split ','; $q = $b -split ','; [math]::Round([math]::Sqrt(([double]$q[0] - [double]$p[0]) * ([double]$q[0] - [double]$p[0]) + ([double]$q[1] - [double]$p[1]) * ([double]$q[1] - [double]$p[1]))) }
# look at door n of the other's twin until the game highlights it (as a player aims), then E for $ms
function Tap($dir, [int]$door, [int]$ms = 100) {
    $slot = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR'; 5 = 'DoorsTrunk' }[$door]
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        # (twice: after the first the character settles on the ground - on a slope the aim was off)
        # (LOOK_OWN = false: a global left set by an own-car look - step 10 - aimed at the own car's door)
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null
        Start-Sleep -Milliseconds 700
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null
        Start-Sleep -Milliseconds 500
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^(OK )?$door\s*$") { break }
    }
    (Press $dir $ms) + " at door $door (highlighted: $($h.Trim()))"
}
# door n: of the own car (O = open) and of the other's twin (its largest yaw / pitch), every 100 ms for 4 s
$sampler = "DL = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(100, function() local dt = os.clock() - t0 if dt > 4 then CancelDelayedAction(h) return end local i = tostring(CoopPlayers.doorInfo(DLN)) local r = i:match('twin_rot=(%S+)') or '0/0' local y, p = r:match('(-?[%d.]+)/(-?[%d.]+)') DL[#DL + 1] = string.format('%s%d', i:match('own_open=(%a+)') == 'true' and 'O' or '-', math.floor(math.max(math.abs(tonumber(y) or 0), math.abs(tonumber(p) or 0)))) end) return 'sampling'"
function Sample($dir, [int]$n) { Send $dir "DLN = $n $sampler" | Out-Null }
function Samples($dir) { Send $dir "return table.concat(DL, ' ')" }
function OwnOpened($s) { $s -match 'O' }
function TwinOpened($s) { foreach ($x in ($s -split ' ')) { if ($x -match '^[O-](\d+)$' -and [int]$Matches[1] -gt 20) { return $true } }; $false }
# a car's position every frame for SM_S s; read: the median frame-to-frame speed change against the mean speed (a car
# moved in steps - 30 times a second while drawn 60+, pulled back at each sample - has large ones)
$smooth = "SM = {} local T = CoopPlayers.twinModule() local car = T.ownCar() if SM_TWIN then for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then car = c end end end local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local t = os.clock() if t - t0 > SM_S then CancelDelayedAction(h) return end local l = car:K2_GetActorLocation() SM[#SM + 1] = { t = t, x = l.X, y = l.Y } end) return 'sampling'"
$smoothRead = "local sp = {} for i = 2, #SM do local dt = SM[i].t - SM[i - 1].t if dt > 0.001 then sp[#sp + 1] = math.sqrt((SM[i].x - SM[i - 1].x) ^ 2 + (SM[i].y - SM[i - 1].y) ^ 2) / dt end end local d, sum = {}, 0 for i = 2, #sp do d[#d + 1] = math.abs(sp[i] - sp[i - 1]) end for _, v in ipairs(sp) do sum = sum + v end table.sort(d) local mean = #sp > 0 and sum / #sp or 0 local med = #d > 0 and d[math.floor(#d / 2) + 1] or 0 return string.format('frames=%d mean=%.0f jerk=%.3f', #SM, mean, mean > 1 and med / mean or 0)"
$ownDoors = "return CoopPlayers.ownDoorFlags()" # (native cars: the manager holds the context car's flags - the own car's kept aside while the other's is)
$lit = "local s = LL or '' local n = 0 for v, h in s:gmatch('=([%d.]+)(h?)') do if tonumber(v) > 0.5 and h == '' then n = n + 1 end end return tostring(n)"
$ownLights = "local T = CoopPlayers.twinModule() LL = T.lightLine(T.ownCar()) $lit"
$twinLights = "$(Twin) LL = tw and T.lightLine(tw, T.twinContainer(tw)) $lit"

"=== 0b. each side's twin has its hood in its place (owner's alpha 19 item 8: the hood fell off and hung in the air)"
# the twin's hood (door 6): simulating, and its mesh's distance from its door root (a fallen one: detached, 300-500 off)
$hoodPlace = "$(Twin) local d = tw and T.door(tw, 6) if not d then return 'no hood' end local a, b = d.MainMesh:K2_GetComponentLocation(), d.RootComponent:K2_GetComponentLocation() return string.format('sim=%s off=%.0f', tostring(d.MainMesh:IsSimulatingPhysics(FName('None'))), math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2))"
function HoodHome($s) { $s -match 'sim=false off=(\d+)' -and [int]$Matches[1] -lt 30 }
$hh = Send $hd $hoodPlace; $ch = Send $cd $hoodPlace
Check "the host's twin of the guest's car: the hood in its place" (HoodHome $hh) "host: $hh"
Check "the guest's twin of the host's car: the hood in its place" (HoodHome $ch) "guest: $ch"

"=== 0c. the guest's car's dash on the host's twin of it shows the guest's readings (owner's alpha 19 item 12)"
$dashRead = Get-Content "$t\cmds\dash-read.lua" -Raw
# the guest's own batteries down to 0.2 each, one of its parts hurt (its owner state: the host's twin gets it by the
# state line, its dash by the pose)
"  guest: " + (Send $cd "DASH_UNDO = {} local T = CoopPlayers.twinModule() local o = {} for k, v in (T.stateLine() or ''):gmatch('([^=;]+)=([^;]+)') do local f = {} for x in (v .. ','):gmatch('([^,]*),') do f[#f + 1] = x end local b = tonumber(f[3]) if b and b > 0.5 then o[#o + 1] = k .. ':' .. T.ownerState(k, 'b', -b + 0.2) DASH_UNDO[#DASH_UNDO + 1] = { k, b - 0.2 } end end o[#o + 1] = 'BackSeatLeft:' .. T.ownerState('Car.Equip.Attachments.BackSeatLeft', 'h', -60) return table.concat(o, ' ')")
Start-Sleep 15
$gd = KV (Send $cd $dashRead); $hd2 = KV (Send $hd $dashRead)
function Num($s) { if ($s) { [double]($s -replace ',', '.') } else { -1 } }
Check "the host's twin of the guest's car: the battery digits show the guest's charge, not the host's" ([math]::Abs((Num $hd2.twin_text) - [double]$gd.own_bat) -lt 0.2 -and [math]::Abs((Num $hd2.twin_text) - [double]$hd2.own_bat) -gt 1) "host twin text $($hd2.twin_text), guest's charge $($gd.own_bat), host's own $($hd2.own_bat) | $($hd2.raw)"
Check "the host's twin of the guest's car: the computer's part icon shows the twin's own part, hurt like the guest's" ($hd2.twin_part_item -eq 'this_car' -and [double]$hd2.twin_part -lt 0.99 -and [math]::Abs([double]$hd2.twin_part - [double]$gd.own_part) -lt 0.05) "host twin $($hd2.twin_part) ($($hd2.twin_part_item)), guest own $($gd.own_part), host own $($hd2.own_part)"
"  guest: charge back " + (Send $cd "local T = CoopPlayers.twinModule() for _, u in ipairs(DASH_UNDO) do T.ownerState(u[1], 'b', u[2]) end return #DASH_UNDO .. ' batteries'")

"=== 1. the host gets out of its car (the game's ExitDoor): its door opens, the guest sees it"
if ((InCar $hd) -ne 'true') { "  host in: " + (Send $hd "return CoopPlayers.botEnterCar()"); Start-Sleep 3 }
Sample $hd 1; Sample $cd 1
"  host: " + (E $hd "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 5
$hs = Samples $hd; $cs = Samples $cd
Check "the host's own door opened as it got out (not the twin's)" ((OwnOpened $hs) -and (InCar $hd) -eq 'false') "host: $hs"
Check "the guest's twin of the host's car showed that door open" (TwinOpened $cs) "guest: $cs"

"=== 1b. the host opens its hood, then shuts it: the guest's twin shows both, moving every frame (item 30)"
# the twin's hood (door 6) pitch against the car's, every frame for 3 s: its largest, and of the frames while it moved
# (between 10 % and 90 % of its way) the share that moved at all - posed 10 times a second it stood still in 2 of 3;
# eased: 0.6
$hoodWatch = "HW = {} local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() if os.clock() - t0 > 3 then CancelDelayedAction(h) return end local d = T.door(tw, 6) if d then HW[#HW + 1] = math.abs(d.MainMesh:K2_GetComponentRotation().Pitch - tw:K2_GetActorRotation().Pitch) end end) return 'watching'"
$hoodRead = "local mx = 0 for _, v in ipairs(HW) do mx = math.max(mx, v) end local lo, hi = mx * 0.1, mx * 0.9 local inn, moved = 0, 0 for i = 2, #HW do if HW[i] > lo and HW[i] < hi then inn = inn + 1 if math.abs(HW[i] - HW[i - 1]) > 0.05 then moved = moved + 1 end end end return string.format('max=%.0f frames=%d in_motion=%d moved=%d', mx, #HW, inn, moved)"
$hostHood = "local T = CoopPlayers.twinModule() local d = T.door(T.ownCar(), 6) if not d then return 'no hood' end d:HOODOP() return 'HOODOP'"
"  guest: " + (Send $cd $hoodWatch)
"  host: " + (Send $hd $hostHood.Replace('HOODOP', 'AttemptOpen'))
Start-Sleep 4
$hw = Send $cd $hoodRead
$m = @{}; foreach ($kv in ($hw -split ' ')) { $k, $v = $kv -split '=', 2; $m[$k] = [double]$v }
Check "the guest's twin shows the host's hood open" ($m.max -gt 25) "guest: $hw"
Check "it opened smoothly (moved in most frames of its way)" ($m.in_motion -ge 4 -and $m.moved / [math]::Max(1, $m.in_motion) -ge 0.5) "guest: $hw"
"  guest: " + (Send $cd $hoodWatch)
"  host: " + (Send $hd $hostHood.Replace('HOODOP', 'AttemptShut'))
Start-Sleep 4
$last = Send $cd "return string.format('%.0f', HW[#HW] or -1)"
Check "the guest's twin shows it shut again" ([double]$last -lt 10 -and [double]$last -ge 0) "guest: hood pitch at the end $last"

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 2. the guest gets out of its car the same way"
"  guest's driver door: " + (Send $cd "local T = CoopPlayers.twinModule() local d = T.door(T.ownCar(), 1) return d and d:GetClass():GetFName():ToString() or 'none'")
if ((InCar $cd) -ne 'true') { "  guest in: " + (Send $cd "return CoopPlayers.botEnterCar()"); Start-Sleep 3 }
Sample $hd 1; Sample $cd 1
"  guest: " + (E $cd "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 5
$hs = Samples $hd; $cs = Samples $cd
Check "the guest's own door opened as it got out" ((OwnOpened $cs) -and (InCar $cd) -eq 'false') "guest: $cs"
Check "the host's twin of the guest's car showed that door open" (TwinOpened $hs) "host: $hs"

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 3. the guest rides in the host's car (back left seat, its device off first); the guest's own lights stay"
"  host: " + (Send $hd "return CoopPlayers.removeSeatDevice(3, true)")
"  host in: " + (Send $hd "return CoopPlayers.botEnterCar()"); Start-Sleep 2
"  host lights: " + (Send $hd "local m = FindFirstOf('BP_CarManager_C') local o = {} m:GetCarLightsOn(o) if not o.AreCarLightsOn then m.NewCarActor:ToggleHeadlights() end return 'were on: ' .. tostring(o.AreCarLightsOn)")
Start-Sleep 3
$g0 = Send $cd $ownLights; $h0 = Send $hd $twinLights
"  guest: " + (Tap $cd 3); Start-Sleep 5
$g = Ghost $cd
"  guest own doors open: " + (Send $cd $ownDoors)
Check "the guest sits on the host car's back left seat" ($g.in_ghost -eq 'H' -and $g.seat -eq '3') $g.raw
Start-Sleep 3
$g1 = Send $cd $ownLights; $h1 = Send $hd $twinLights
Check "the guest's own car keeps its own lights (here and on the host's side)" ($g1 -eq $g0 -and $h1 -eq $h0) "guest own car lit $g0 -> $g1; the host's twin of it lit $h0 -> $h1"

# (owner, 2026-10-30: the back-seat passenger reached the lever and the front door - the controls are the driver's)
$reach = @()
foreach ($part in 'SH.MainMesh', 'KeyCylinder_Temp') {
    Send $cd "return CoopPlayers.botTwinLookAt('$part')" | Out-Null; Start-Sleep 1
    $reach += "$part -> " + (Send $cd "local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return (h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none') .. ' ' .. (CoopPlayers.nativeInfo():match('reach_denied=%S+') or '')")
}
Check "the back-seat passenger cannot reach the lever or the key" (($reach -join ' ') -notmatch 'Shifter|Highlight_Key' -and ($reach -join ' ') -notmatch 'reach_denied=0 ') ($reach -join ' | ')
"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 4. the host drives, the guest rides along: the twin moves smoothly"
Send $hd "local c = CoopPlayers.twinModule().ownCar() CARS_HOME = { l = c:K2_GetActorLocation(), r = c:K2_GetActorRotation() } return 'home kept'" | Out-Null
# (its doors shut first, as a player drives off: the bot's way in leaves the driver's door as the step-1 exit left it,
# and a door open while driving breaks off - the game's own; the host's door 1 was gone after this step in 2 suite runs)
"  host doors shut before driving: " + (Send $hd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do if T.doorOpen(own, n) then T.door(own, n):AttemptShut() o[#o + 1] = n end end return #o > 0 and table.concat(o, ',') or 'none were open'")
Start-Sleep 2
"  host: " + (Send $hd "return CoopPlayers.botDrive(8)"); Start-Sleep 2
Send $hd "SM_TWIN = false SM_S = 4 $smooth" | Out-Null; Send $cd "SM_TWIN = true SM_S = 4 $smooth" | Out-Null
Start-Sleep 5
$hsm = KV (Send $hd $smoothRead); $csm = KV (Send $cd $smoothRead)
Check "the guest's twin moves as smoothly as the host's car (jerk <= 3x the host's, 0.25 at least)" ([double]$csm.mean -gt 100 -and [double]$csm.jerk -le [math]::Max(0.25, 3 * [double]$hsm.jerk)) "host car: $($hsm.raw) | guest's twin: $($csm.raw)"
Start-Sleep 6
# (back where it stood - flat ground: after the drive it stood anywhere, a slope, and the test's aiming missed there)
"  host door 1 before the teleport home: simulating " + (Send $hd "local T = CoopPlayers.twinModule() local o = {} for n = 1, 5 do o[#o + 1] = n .. '=' .. tostring(T.doorOpen(T.ownCar(), n)) end return table.concat(o, ' ')")
"  host car back: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() c:K2_SetActorLocationAndRotation({ X = CARS_HOME.l.X, Y = CARS_HOME.l.Y, Z = CARS_HOME.l.Z + 30 }, CARS_HOME.r, false, {}, true) pcall(function() c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) end) return 'back'")
Start-Sleep 4

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 5. the guest gets out of the host's car: the door opens, it stands outside"
Sample $hd 3
# (and on its own side the twin's driver's door stays shut - the game's exit opens it there; owner's alpha 19 item 13)
Sample $cd 1
# the guest's place against the host's car (its twin) every 100 ms: the game's exit animation, no teleport jumps
Send $cd "$(Twin) EX = {} local p = FindFirstOf('PlayerController').Pawn local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local t0 = os.clock() local h h = LoopInGameThreadWithDelay(33, function() if os.clock() - t0 > 4 then CancelDelayedAction(h) return end local l = KML:InverseTransformLocation(tw:GetTransform(), p:K2_GetActorLocation()) EX[#EX + 1] = { x = l.X, y = l.Y } end) return 'sampling'" | Out-Null
# (as a player: looking at its own door, the twin's exit spot moved there for its seat - the game's ExitDoor + E)
"  guest: " + (E $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor'"); Start-Sleep 5
$g = Ghost $cd; $hs = Samples $hd
Check "the guest is out, the host's door 3 opened for it" ($g.in_ghost -eq '-' -and (InCar $cd) -eq 'false' -and (OwnOpened $hs)) "guest: $($g.raw) | host door 3: $hs"
$cs = Samples $cd; $wide = @($cs -split ' ' | Where-Object { $_ -match '^[O-](\d+)$' -and [int]$Matches[1] -gt 20 }).Count
Check "the guest's twin's driver's door stays shut as the guest gets out at the back (at most 6 samples over 20 degrees: the walk-out needs it open a moment)" ($wide -le 6) "guest's twin door 1: $cs | $(Send $cd "return CoopPlayers.nativeInfo():match('exit_doors_shut=%S+') or ''")"
"  guest own doors open: " + (Send $cd $ownDoors)
$ex = KV (Send $cd "local mx, steps = 0, 0 for i = 2, #EX do local d = math.sqrt((EX[i].x - EX[i - 1].x) ^ 2 + (EX[i].y - EX[i - 1].y) ^ 2) if d > mx then mx = d end if d > 2 then steps = steps + 1 end end local e = EX[#EX] return string.format('jump=%.0f moving_samples=%d end=%.0f,%.0f', mx, steps, e.x, e.y)")
Check "it walked out with the game's animation (over 3+ samples, no jump over 250, ends beside the car's left side)" ([double]$ex.jump -le 250 -and [int]$ex.moving_samples -ge 3 -and [math]::Abs([double]($ex.end -split ',')[1]) -le 350) $ex.raw

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 6. the host's trunk lid from the guest's side: open, then shut again"
"  guest own doors open: " + (Send $cd $ownDoors)
"  guest: " + (Tap $cd 5); Start-Sleep 3
$d1 = Door $hd 5
Check "the guest's tap opened the host's trunk" ($d1.own_open -eq 'true') $d1.raw
"  guest own doors open: " + (Send $cd $ownDoors)
"  guest aims at the open lid: " + (Send $cd "$(Twin) local h = T.door(tw, 5).MainMesh:K2_GetComponentLocation() local c = { X = h.X, Y = h.Y, Z = h.Z + 50 } local yaw = math.rad(tw:K2_GetActorRotation().Yaw) local pc = FindFirstOf('PlayerController') pc.Pawn:K2_SetActorLocation({ X = c.X - math.cos(yaw) * 200, Y = c.Y - math.sin(yaw) * 200, Z = c.Z - 40 }, false, {}, true) local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = c.X - e.X, Y = c.Y - e.Y, Z = c.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'aimed'")
Start-Sleep 1
"  guest before E: " + (Send $cd "local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return (h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none') .. ' ' .. (CoopPlayers.nativeInfo():match('aimed=%S+') or '') .. ' ' .. (CoopPlayers.nativeInfo():match('doors_local=%S*') or '')")
"  guest: " + (Press $cd); Start-Sleep 3
$d2 = Door $hd 5
Check "the guest's E at the open lid shut it" ($d2.own_open -eq 'false') "$($d2.raw) | door lines - guest: $(Send $cd 'return CoopPlayers.doorLog()')"
# (the twin's slot spots ran the game's own door handlers on the car manager: the guest's OWN doors opened far away)
# (native cars: the manager holds the context car's flags - the guest stands by the host's car: its own car's kept
# aside; they follow its doors within ~3 s of the last E)
Start-Sleep 3
$ds = Send $cd "local s = CoopPlayers.ownDoorFlags() return s == 'none' and 'all shut' or ('open: ' .. s)"
Check "the guest's own car's door flags (the dash, its door spots) all shut after riding in the host's car, like its doors" ($ds -eq 'all shut') $ds

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 7. the host's paint on the guest's twin"
$tint = "'/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_TintableComponent.BP_TintableComponent_C'"
"  host paints its trunk lid red: " + (Send $hd "local T = CoopPlayers.twinModule() local tc = T.door(T.ownCar(), 5):K2_GetComponentsByClass(StaticFindObject($tint))[1]:get() tc:SetPaint(StaticFindObject('/Game/BaseArt/Palettes/Paints/BP_Palette_Paint_Generic_Red.BP_Palette_Paint_Generic_Red_C'), {}) return 'painted'")
Start-Sleep 9
$paint = Send $cd "$(Twin) local tc = T.door(tw, 5):K2_GetComponentsByClass(StaticFindObject($tint))[1]:get() local p, e, d, v = {}, {}, {}, {} tc:GetTintableProperties(p, e, d, v) return p.Paint:GetFName():ToString()"
Check "the guest's twin's trunk lid is red too" ($paint -match 'Generic_Red') $paint

# (native cars, 2026-10-30: the guest's game sent the host door opens it never made, the host drove off with its door
# open and it broke off - no driver's door left to get in by)
$hdoors = Send $hd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do local d = T.door(own, n) o[#o + 1] = d and d:GetClass():GetFName():ToString():gsub('BP_CarPart_', '') or '-' end return table.concat(o, ',')"
Check "the host's car keeps all its doors after the rides and taps" ($hdoors -notmatch 'Empty|-') "host doors: $hdoors"
"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 8. the guest takes the wheel of the host's car (the host out, its engine on, in drive) and drives it"
"  host: " + (E $hd "CE_CAR = 'own' CE_HL = 'ExitDoor'")
Start-Sleep 5
# (the host steps 5 m away from its car: its puppet at the driver's door was in the guest's way)
"  host steps away: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local l, r = car:K2_GetActorLocation(), car:GetActorRightVector() p:K2_SetActorLocation({ X = l.X - r.X * 500, Y = l.Y - r.Y * 500, Z = l.Z + 80 }, false, {}, true) return 'away'")
Start-Sleep 2
# (the guest walks up to the driver's door - after the trunk steps it stood behind the car, the door out of sight)
"  guest to the driver's door: " + (Send $cd "$(Twin) local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = 100, Y = -230, Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
"  guest: " + (Tap $cd 1)
"  guest then: " + (Send $cd "$(Twin) local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local p = FindFirstOf('PlayerController').Pawn local a = p:GetAttachParentActor() local l = KML:InverseTransformLocation(tw:GetTransform(), p:K2_GetActorLocation()) local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return string.format('attached=%s rel=%.0f,%.0f,%.0f hl=%s | %s', tostring(a and a:IsValid() and a:GetFName():ToString()), l.X, l.Y, l.Z, h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none', CoopPlayers.nativeInfo())")
Start-Sleep 5
$g = Ghost $cd
Check "the guest sits at the host car's wheel" ($g.in_ghost -eq 'H' -and $g.seat -eq '1') $g.raw
# (the host's exit stopped the engine and put it in park, as the game does: the guest starts it and shifts, as a player in
# the twin does - the manager holds the owner's key / lever there and the change goes to the owner, K lines)
"  guest: key " + (Send $cd "FindFirstOf('BP_CarManager_C').CarIgnitionState = 2 return 'on'")
Start-Sleep 3
"  guest: lever " + (Send $cd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 0 return 'drive (0)'")
Start-Sleep 3
"  host: " + (Send $hd "return CoopPlayers.controlsInfo()")
# (the car in drive with nobody pressing the pedal creeps: the guest's input must move it more than that)
$creep0 = OwnAt $hd; Start-Sleep 3; $creep = Moved $creep0 (OwnAt $hd)
$before = OwnAt $hd
# (native cars: the pedals go to the car the game's car input controller drives - the twin while the guest sits at its
# wheel; its input fields every frame, as the player's keys make them. This side simulates it, the host's car follows)
"  guest drives: " + (Send $cd "local ctl = FindFirstOf('BP_Controller_PlayerCar_C') local car = ctl.PlayerCarReference local who = CoopPlayers.twinModule().isTwin(car) and 'twin' or 'own' local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 8 then car.UserThrottleInput = 0 car.UserHandBrakeInput = 0 CancelDelayedAction(h) return end if dt > 5 then car.UserThrottleInput = 0 car.UserHandBrakeInput = 1 return end car.UserThrottleInput = 1.0 car.UserBrakeInput = 0 end) return 'W 5 s on the ' .. who .. ' car'")
Start-Sleep 9
$moved = Moved $before (OwnAt $hd)
Check "the host's car drove on the guest's input (>= 300 more than it crept by itself)" ($moved -ge 300 + 2 * $creep) "moved $moved (crept $creep in 3 s before) | host: $(Send $hd 'return CoopPlayers.wheelInfo()')"
# (as a driver does: the lever to park first - left in drive with the engine on, a car creeps away by itself, the
# game's own behaviour; the host's car crept into something and its trunk lid flew open)
"  guest: lever " + (Send $cd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 1 return 'park (1)'"); Start-Sleep 3
"  guest out: " + (E $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor'"); Start-Sleep 4
$parked0 = OwnAt $hd; Start-Sleep 4; $rolled = Moved $parked0 (OwnAt $hd)
$hdoors2 = Send $hd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do o[#o + 1] = n .. '=' .. (T.doorOpen(own, n) and 'open' or 'shut') end return table.concat(o, ' ') .. ' gear=' .. tostring(FindFirstOf('BP_CarManager_C').MyCarGearBox)"
# (the guest by it: within 700 - the game's exit takes the first free of its exit points, one 560 off when the near
# ones were blocked, 2026-11-05)
# (items 11 / 12 the other way round: getting out of the other's car put the player - and the car - back where it had
# got in; here the lever's park reached the owner and the car stays where it was driven to)
$gp = Send $cd "$(Twin) local p = FindFirstOf('PlayerController').Pawn local a, b = p:K2_GetActorLocation(), tw:K2_GetActorLocation() return string.format('%.0f,%.0f|%.0f,%.0f', a.X, a.Y, b.X, b.Y)"
$gpos, $gtw = $gp -split '\|'
Check "the guest out where it drove the host's car to: the car stays, the guest by it, the lever's park reached the host (items 11 / 12)" ((Moved $before $parked0) -ge 300 -and (Moved $parked0 $gtw) -le 150 -and (Moved $gtw $gpos) -le 700 -and $hdoors2 -match 'gear=1') "drove from $before to $parked0 | guest's twin $gtw, guest $gpos | host: $hdoors2"
Check "the host's car stands parked after the guest got out, its doors and lid shut" ($rolled -le 100 -and $hdoors2 -notmatch 'open') "rolled $rolled in 4 s | host: $hdoors2 | door lines - guest: $(Send $cd 'return CoopPlayers.doorLog()') | host: $(Send $hd 'return CoopPlayers.doorLog()')"

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 8b. the host takes the wheel of the guest's car, shifts, drives it and gets out (owner, alpha 18 items 11 / 12)"
# (the test's guest car may have no driver's door - its slot an EmptyDoor: no way in there, the game shows no EnterDoor
# highlight either - then step 8's guest-in-the-host's-car checks cover items 11 / 12)
$d1 = Send $cd "local d = CoopPlayers.twinModule().door(CoopPlayers.twinModule().ownCar(), 1) return d and d:GetClass():GetFName():ToString() or '-'"
if ($d1 -notmatch 'Door_Base') { "  SKIP: the guest's car has no driver's door ($d1)" } else {
# (the guest stands 5 m off its car, out of the host's way)
"  guest steps away: " + (Send $cd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local l, r = car:K2_GetActorLocation(), car:GetActorRightVector() p:K2_SetActorLocation({ X = l.X + r.X * 600, Y = l.Y + r.Y * 600, Z = l.Z + 80 }, false, {}, true) return 'away'")
Start-Sleep 2
# (twice, from a second spot if the first aim found no highlight: on a slope the aim at the door missed, 2026-11-05)
foreach ($spot in '100, -230', '60, -190') {
    $xy = $spot -split ', '
    "  host to the twin's driver's door: " + (Send $hd "$(Twin) local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = $($xy[0]), Y = $($xy[1]), Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there ($spot)'")
    Start-Sleep 2
    $tap = Tap $hd 1
    "  host: $tap"
    if ($tap -notmatch 'highlighted: nil') { break }
}
Start-Sleep 5
$g = Ghost $hd
Check "the host sits at the guest car's wheel" ($g.in_ghost -eq 'G' -and $g.seat -eq '1') $g.raw
$start = OwnAt $cd
# (item 11: the lever the host works in the twin is the guest's car's lever, each time)
$gears = @()
foreach ($want in 0, 1, 0) {
    Send $hd "local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = $want return 'gear $want'" | Out-Null
    Start-Sleep 3
    $gears += "$want->" + (Send $cd "return tostring(FindFirstOf('BP_CarManager_C').MyCarGearBox)")
}
Check "every lever shift of the host's reaches the guest's car (item 11)" (($gears -join ' ') -eq '0->0 1->1 0->0') ($gears -join ' ')
$b0 = OwnAt $cd
"  host drives: " + (Send $hd "local ctl = FindFirstOf('BP_Controller_PlayerCar_C') local car = ctl.PlayerCarReference local who = CoopPlayers.twinModule().isTwin(car) and 'twin' or 'own' local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 8 then car.UserThrottleInput = 0 car.UserHandBrakeInput = 0 CancelDelayedAction(h) return end if dt > 5 then car.UserThrottleInput = 0 car.UserHandBrakeInput = 1 return end car.UserThrottleInput = 1.0 car.UserBrakeInput = 0 end) return 'W 5 s on the ' .. who .. ' car'")
Start-Sleep 9
$moved = Moved $b0 (OwnAt $cd)
Check "the guest's car drove on the host's input (>= 300)" ($moved -ge 300) "moved $moved"
"  host: lever " + (Send $hd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 1 return 'park (1)'"); Start-Sleep 3
$stop = OwnAt $cd
"  host out: " + (E $hd "CE_CAR = 'twin' CE_HL = 'ExitDoor'"); Start-Sleep 5
# (item 12: getting out put the host - and the car - back where it had got in)
$after = OwnAt $cd
$hp = Send $hd "$(Twin) local p = FindFirstOf('PlayerController').Pawn local a, b = p:K2_GetActorLocation(), tw:K2_GetActorLocation() return string.format('%.0f,%.0f|%.0f,%.0f|%s', a.X, a.Y, b.X, b.Y, tostring(p:GetAttachParentActor() ~= nil and p:GetAttachParentActor():IsValid()))"
$hpos, $twpos, $hatt = $hp -split '\|'
$cars = (Send $hd "local n = 0 for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c.RootComponent and c.RootComponent:IsValid() then n = n + 1 end end return n") + '/' + (Send $cd "local n = 0 for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c.RootComponent and c.RootComponent:IsValid() then n = n + 1 end end return n")
Check "out where it stopped: the guest's car stays, the host stands by it, two cars on each side (item 12)" ($hatt -match 'false' -and (Moved $stop $after) -le 150 -and (Moved $after $twpos) -le 150 -and (Moved $twpos $hpos) -le 500 -and (Moved $start $after) -ge 300 -and $cars -eq '2/2') "start $start stop $stop after $after | host's twin $twpos, host $hpos attached $hatt | cars host/guest $cars"

}

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 9. the guest back in its own car: it drives"
"  guest in: " + (Send $cd "return CoopPlayers.botEnterCar()"); Start-Sleep 3
# (the game parked it when the guest got out: the player shifts to drive)
"  guest: lever " + (Send $cd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 0 return 'drive'")
$b0 = OwnAt $cd
# (what the car was in when it did not move: physics, the controller's tick, ignition, lever, charge, the context car)
$gstate = Send $cd "local m = FindFirstOf('BP_CarManager_C') local c = CoopPlayers.twinModule().ownCar() local vc = c:GetComponentByClass(StaticFindObject('/Script/IWCarPhysics.VehicleControllerComponent')) local rm = FindFirstOf('BP_ResourceManager_C') return string.format('sim=%s vc_tick=%s ign=%s gear=%s lim=%.1f ctx_own=%s', tostring(c.RootComponent:IsSimulatingPhysics(FName('None'))), tostring(vc and vc:IsComponentTickEnabled()), tostring(m.CarIgnitionState), tostring(m.MyCarGearBox), rm.CarLim.Current, tostring(m.NewCarActor:GetAddress() == c:GetAddress()))"
"  guest car state: $gstate"
"  guest: " + (Send $cd "return CoopPlayers.botInput(4, 1.0, 0, 0)"); Start-Sleep 9
$moved = Moved $b0 (OwnAt $cd)
Check "the guest's own car drives after all that (>= 300)" ($moved -ge 300) "moved $moved | $gstate"
$hh = Send $hd $hoodPlace
Check "after the guest drove: the host's twin of its car still has the hood in its place (item 8)" (HoodHome $hh) "host: $hh"

"  guest's own car doors: " + (OwnDoors $cd) + " | host's: " + (OwnDoors $hd)
"=== 10. the host on the back seat of its own car (owner, alpha 18 item 10): in by its back door, no driving from there"
"  guest out of its car: " + (E $cd "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 4
# (its car back where it stood at step 4 first - flat ground: the guest drove it off in step 8, and on a slope the
# aim at its back door missed, 2026-11-04)
"  host car home: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() if not CARS_HOME then return 'no home' end c:K2_SetActorLocationAndRotation({ X = CARS_HOME.l.X, Y = CARS_HOME.l.Y, Z = CARS_HOME.l.Z + 30 }, CARS_HOME.r, false, {}, true) pcall(function() c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) end) return 'back'")
Start-Sleep 3
"  host to its back left door: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(car:GetTransform(), { X = 0, Y = -260, Z = 0 }) p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
$aim = ''
foreach ($dz in 0, 20, -20, 40) {
    Send $hd "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = 'DoorsRL' $look" | Out-Null; Start-Sleep -Milliseconds 700
    Send $hd "LOOK_OWN = true LOOK_DZ = $dz LOOK_SLOT = 'DoorsRL' $look" | Out-Null; Start-Sleep -Milliseconds 500
    $aim = Send $hd "return CoopPlayers.ownBackDoorAimed and tostring(CoopPlayers.ownBackDoorAimed()) or '?'"
    if ($aim -match '^3') { break }
}
"  host: " + (Press $hd) + " (aimed back door: $aim)"
Start-Sleep 6
"  host door 3: " + (Send $hd "return CoopPlayers.doorInfo(3)")
$hw = KV (Send $hd "return CoopPlayers.wheelInfo()")
$att = Send $hd "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a and a:IsValid() and a:GetAddress() == CoopPlayers.twinModule().ownCar():GetAddress())"
Check "the host got into its own car's back seat by the back door" ($att -match 'true' -and $hw.my_seat -eq '3') "attached to own: $att | $($hw.raw)"
$xh = Send $hd (Get-Content "$t\cmds\exit-highlight.lua" -Raw)
Check "its exit outlines the back door, not the driver's (items 13 / 19)" ($xh -match 'Door_Base') $xh
# (its pedals held off: the car in drive with the engine on creeps by itself - the throttle must not add to that)
"  host: lever " + (Send $hd "local m = FindFirstOf('BP_CarManager_C') m.CarIgnitionState = 2 m.MyCarGearBox = 0 return 'engine on, drive'"); Start-Sleep 3
$c0 = OwnAt $hd; Start-Sleep 3; $creep = Moved $c0 (OwnAt $hd)
$b0 = OwnAt $hd
"  host: " + (Send $hd "return CoopPlayers.botInput(4, 1.0, 0, 0)")
# (the car's own input fields while the bot holds the throttle - on a slope the creep alone grows from second to second)
$ins = @(); foreach ($i in 1..4) { Start-Sleep -Milliseconds 800; $ins += (KV (Send $hd "return CoopPlayers.wheelInfo()")).input }
Start-Sleep 1
$moved = Moved $b0 (OwnAt $hd)
"  host: lever " + (Send $hd "FindFirstOf('BP_CarManager_C').MyCarGearBox = 1 return 'park'"); Start-Sleep 2
Check "no driving from the back seat (the car's pedals stay off under the throttle; it may creep or roll down a slope)" ((@($ins | Where-Object { $_ -match '\d' -and (@(($_ -split ',') | Where-Object { [math]::Abs([double]$_) -gt 0.05 }).Count -gt 0) }).Count -eq 0) -and $ins.Count -eq 4) "inputs $($ins -join ' ') | moved $moved in 5 s on the throttle, crept $creep in 3 s"
"  host out: " + (E $hd "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 5
$att = Send $hd "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())"
$sock = Send $hd "local car = CoopPlayers.twinModule().ownCar() local r = car.TempSocket_Seat.RelativeLocation return string.format('%.0f,%.0f', r.X, r.Y)"
Check "out again; the seat socket back at the wheel" ($att -match 'false') "attached: $att | socket $sock"

$gd = OwnDoors $cd
Check "the guest's own car kept all its doors (the other's doors worked, not its own)" ($gd -notmatch 'NONE|-\s|-$') $gd
$hr = Send $hd "return CoopPlayers.report()"; $cr = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') "host: $hr | guest: $cr"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
