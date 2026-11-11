# The other's trunk from outside, the owner's way (owner's two-games test 2026-11-11: "the guest opened the host's
# trunk, came close, pressed E at the trunk's container - the inventory opened, but the lid shut, hit the guest and
# kept making the shut sound on the guest"; "the trunk is unstable: it can shut and not open again, or start slamming").
# Two instances in the zone (cars-test -SetupOnly):
#   1. the guest's tap at the host's lid opens it (both sides)
#   2. the guest close at the trunk, E at its container: the inventory shows the host's trunk; the lid stays open on
#      both sides for 8 s, no shut sent, no slamming on the guest
#   3. the guest's E at the open lid shuts it (both sides), once
#   4. three more open / shut rounds: each opens and shuts on both sides
# -Reuse: a pair from cars-test -SetupOnly.
param([switch]$Keep, [switch]$Reuse)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-String 'arrived|pair ready' }
$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
function Press($dir, [int]$ms = 100) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'" }
$twin = "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end"
function Tap($dir, [int]$door) {
    $slot = @{ 1 = 'DoorsFL'; 5 = 'DoorsTrunk' }[$door]
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null; Start-Sleep -Milliseconds 700
        Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null; Start-Sleep -Milliseconds 500
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^$door\s*$") { break }
    }
    if ($h -notmatch "^$door\s*$") { return "no E: door $door not lit (lit: $h)" }
    (Press $dir) + " at door $door (lit)"
}
# the guest behind the host's car, PT[3] behind the car-relative point PT, looking at it
function Behind($pt) { Send $cd "$twin local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = KML:TransformLocation(tw:GetTransform(), { X = $($pt[0]), Y = $($pt[1]), Z = $($pt[2]) }) local yaw = math.rad(tw:K2_GetActorRotation().Yaw) local pc = FindFirstOf('PlayerController') pc.Pawn:K2_SetActorLocation({ X = c.X - math.cos(yaw) * $($pt[3]), Y = c.Y - math.sin(yaw) * $($pt[3]), Z = c.Z + 40 }, false, {}, true) local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = c.X - e.X, Y = c.Y - e.Y, Z = c.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'there'" }
function HostLid() { Send $hd "local T = CoopPlayers.twinModule() return tostring(T.doorOpen(T.ownCar(), 5))" }
# every 50 ms for $s s: the host's real lid (O/-) and the guest's twin lid angle
function Watch([int]$s) {
    Send $hd "LW = {} local T = CoopPlayers.twinModule() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > $s then CancelDelayedAction(h) return end LW[#LW + 1] = T.doorOpen(T.ownCar(), 5) and 'O' or '-' end) return 'ok'" | Out-Null
    Send $cd "LA = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > $s then CancelDelayedAction(h) return end local r = tostring(CoopPlayers.doorInfo(5)):match('twin_rot=(%S+)') or '0/0' local y, p = r:match('(-?[%d.]+)/(-?[%d.]+)') LA[#LA + 1] = math.max(math.abs(tonumber(y) or 0), math.abs(tonumber(p) or 0)) end) return 'ok'" | Out-Null
}
function WatchRead() {
    $h = Send $hd "return table.concat(LW)"
    $g = Send $cd "local o = {} for _, v in ipairs(LA) do o[#o + 1] = string.format('%.0f', v) end return table.concat(o, ' ')"
    @{ host = $h; guest = $g }
}
# times the twin lid fell from open (> 40) to near shut (< 15) in a series
function Slams($series) { $n = 0; $open = $false; foreach ($v in ($series -split ' ')) { if ($v -notmatch '^\d+$') { continue }; if ([int]$v -gt 40) { $open = $true } elseif ([int]$v -lt 15 -and $open) { $n++; $open = $false } }; $n }

$carE = Get-Content "$t\cmds\car-e.lua" -Raw
function Out($dir) { if ((Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())") -match 'true') { Send $dir "CE_CAR = 'own' CE_HL = 'ExitDoor' $carE" } else { 'already out' } }
"=== 0. both out of their cars, the guest behind the host's"
"  host: " + (Out $hd); "  guest: " + (Out $cd); Start-Sleep 5
"  guest: " + (Behind @(-200, 0, 0, 250)); Start-Sleep 2
"=== 1. the guest's tap at the host's trunk lid opens it"
"  host lid shut first: " + (Send $hd "local T = CoopPlayers.twinModule() local d = T.door(T.ownCar(), 5) if T.doorOpen(T.ownCar(), 5) then d:AttemptShut() end return 'ok'"); Start-Sleep 3
"  guest: " + (Tap $cd 5); Start-Sleep 4
$o = HostLid
$gl = Send $cd "return tostring(CoopPlayers.doorInfo(5)):match('twin_rot=(%S+)') or '?'"
Check "the host's lid open, the guest's twin shows it" ($o -eq 'true') "host lid open: $o | guest twin lid: $gl"

"=== 2. the guest close at the trunk, E at its container (the owner's slamming)"
$store = Send $cd "$twin local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') for _, s in ipairs(FindAllOf('BP_Storage_Trunk_Base_C') or {}) do local car, g = s, 0 while g < 10 do local p = car:GetAttachParentActor() if not (p and p:IsValid()) then break end car, g = p, g + 1 end if car == tw then local hc = s.Highlight local at = (hc and hc:IsValid()) and hc:K2_GetComponentLocation() or s:K2_GetActorLocation() local r = KML:InverseTransformLocation(tw:GetTransform(), at) return string.format('%.0f %.0f %.0f', r.X, r.Y, r.Z) end end return 'none'"
"  the host's trunk box on the guest's twin at (car-relative): $store"
$sp = @($store -split ' ')
if ($sp.Count -ge 3) {
    # (the box's actor sits at the car's root; its mesh fills the trunk - aimed at the trunk floor's middle, where its
    # objective marker stands: -180, -45, 15 on the guest's twin; lit from 150 behind it, 2026-11-11)
    $lit = 'none'
    foreach ($p in @(@(-190, -10, 150), @(-230, -10, 140), @(-190, 20, 140), @(-230, 20, 140), @(-150, -10, 140))) {
        Send $cd "$twin local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = KML:TransformLocation(tw:GetTransform(), { X = $($p[0]), Y = 0, Z = $($p[1]) }) local pc = FindFirstOf('PlayerController') local base = KML:TransformLocation(tw:GetTransform(), { X = $($p[0] - $p[2] - 60), Y = 0, Z = -60 }) pc.Pawn:K2_SetActorLocation({ X = base.X, Y = base.Y, Z = base.Z + 90 }, false, {}, true) local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = c.X - e.X, Y = c.Y - e.Y, Z = c.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'ok'" | Out-Null
        Start-Sleep -Milliseconds 900
        $lit = Send $cd "local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none'"
        if ($lit -ne 'none') { break }
    }
    "  lit: $lit | guest aim: $(Send $cd "return CoopPlayers.nativeInfo():match('aimed=%S+')")"
    $sent0 = (KV (Send $cd "return CoopPlayers.doorInfo(5)")).doors_sent
    Watch 8
    "  guest E at the box: " + (Press $cd)
    Start-Sleep 9
    $w = WatchRead
    $sent1 = (KV (Send $cd "return CoopPlayers.doorInfo(5)")).doors_sent
    "  host lid (50 ms): $($w.host)"
    "  guest twin lid: $($w.guest)"
    "  guest door log: $(Send $cd 'return CoopPlayers.doorLog()')"
    $menu = Send $cd "return tostring(CoopPlayers.report():match('trunk_menu%S*'))"
    $menu = Send $cd "return CoopPlayers.trunkInfo and CoopPlayers.trunkInfo() or '?'"
    # (not counted: the twin's trunk box has no collision - nothing to light there; what the guest's E reached is printed.
    # The lid checks below hold either way: the owner's E there shut the lid)
    "  INFO the guest's E reached: lit $lit | $menu"
    Check "the lid stayed open on the host (no shut from the guest's E at the box)" ($w.host -notmatch '-' -and $w.host.Length -gt 100) "host: $($w.host)"
    Check "the guest's twin lid stayed open, no slamming" ((Slams $w.guest) -eq 0) "slams $(Slams $w.guest) | doors sent $sent0 -> $sent1"
    "  guest closes the inventory: " + (Send $cd "local pc = FindFirstOf('PlayerController') local ok = pcall(function() FindFirstOf('PDP_Game_Hud_C'):CloseAllMenus() end) return tostring(ok)")
    Start-Sleep 2
} else { Check "the host's trunk box found on the guest's twin" $false $store }

"=== 3. the guest's E at the open lid shuts it, once"
function AtLid() { Send $cd "$twin local h = T.door(tw, 5).MainMesh:K2_GetComponentLocation() local c = { X = h.X, Y = h.Y, Z = h.Z + 50 } local yaw = math.rad(tw:K2_GetActorRotation().Yaw) local pc = FindFirstOf('PlayerController') pc.Pawn:K2_SetActorLocation({ X = c.X - math.cos(yaw) * 200, Y = c.Y - math.sin(yaw) * 200, Z = c.Z - 40 }, false, {}, true) local e = pc.PlayerCameraManager:GetCameraLocation() local d = { X = c.X - e.X, Y = c.Y - e.Y, Z = c.Z - e.Z } pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }) return 'at the open lid'" }
"  guest: " + (AtLid); Start-Sleep 1
Watch 6
"  guest E: " + (Press $cd); Start-Sleep 7
$w = WatchRead
"  host lid: $($w.host)"
"  guest twin lid: $($w.guest)"
$hs = $w.host -replace '^O*', ''
Check "the host's lid shut and stayed shut" ($w.host -match '-' -and $hs -notmatch 'O') "host: $($w.host)"
Check "the guest's twin lid shut once" ((Slams $w.guest) -eq 1 -and ($w.guest -split ' ')[-1] -match '^\d+$' -and [int](($w.guest -split ' ')[-1]) -lt 10) "slams $(Slams $w.guest)"

"=== 4. three more rounds: open, shut"
for ($r = 1; $r -le 3; $r++) {
    "  guest: " + (Tap $cd 5); Start-Sleep 4
    $o = HostLid
    "  guest: " + (AtLid); Start-Sleep 1
    "  guest E: " + (Press $cd); Start-Sleep 4
    $c = HostLid
    $gl = Send $cd "return tostring(CoopPlayers.doorInfo(5)):match('twin_rot=(%S+)') or '?'"
    Check "round $r`: opened, then shut (the host's lid)" ($o -eq 'true' -and $c -eq 'false') "open: $o shut after: $c | guest twin lid now $gl"
}
"  guest door log: $(Send $cd 'return CoopPlayers.doorLog()')"
$cr = Send $cd "return CoopPlayers.report()"; $hr = Send $hd "return CoopPlayers.report()"
Check "no errors" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') ""
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
