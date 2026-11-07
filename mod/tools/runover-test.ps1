# Automated "a car runs over the other player" test (owner, alpha 18 item 22: "a car drives through the other player:
# must collide, damage and push, as with the own car in the game"). Setup as collide-test's (both cars in the zone,
# state and player sync on both).
#   1. the guest on foot in front of the host's car, the host's car comes at it: the guest is knocked along the car's
#      way and hurt (run_over on the guest's side), the host sees the guest's puppet thrown too
#   2. the other way round: the host on foot, the guest's own car comes at it
#   each way the driver's side (owner's alpha 19 item 18: "a car still drives through the player") sees the hit itself
#   and throws the other's puppet at once - within 0.3 s, not when the walker's own knock comes back
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', '').Trim()
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Stat($s, $name) { if ($s -match "\b$name=(\d+)") { [int]$Matches[1] } else { 0 } }
# this side's player put 900 in front of the other player's car (its twin here), at the car's height (+100: on its
# ground; a player out of its car by the other car can be under the map)
$inFront = "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local l, f = tw:K2_GetActorLocation(), tw:GetActorForwardVector() local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = l.X + f.X * 900, Y = l.Y + f.Y * 900, Z = l.Z + 100 }, false, {}, true) RO0 = p:K2_GetActorLocation() return string.format('stands at %.0f,%.0f', RO0.X, RO0.Y)"
# this side's own car (its player at the wheel) sent forward
$drive = "local car = CoopPlayers.twinModule().ownCar() local f = car:GetActorForwardVector() car.RootComponent:SetPhysicsLinearVelocity({ X = f.X * 1300, Y = f.Y * 1300, Z = 0 }, false, FName('None')) return 'car sent at 1300'"
$out = "local p = FindFirstOf('PlayerController').Pawn local a = p:GetAttachParentActor() return (a and a:IsValid()) and 'still in a car' or 'on foot'"
function OnFoot($dir) { for ($i = 0; $i -lt 10; $i++) { $s = Send $dir $out; if ($s -eq 'on foot') { break }; Start-Sleep 1 }; $s }
# the driver's side: the other's puppet (its distance from where it stood) and this side's drove_over, every frame for 3 s
$pupWatch = "PW = {} local p0 = CoopPlayers.puppetParts():K2_GetActorLocation() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local t = os.clock() - t0 if t > 3 then CancelDelayedAction(h) return end local p = CoopPlayers.puppetParts() if not p then return end local l = p:K2_GetActorLocation() PW[#PW + 1] = { t = t, d = math.sqrt((l.X - p0.X) ^ 2 + (l.Y - p0.Y) ^ 2), n = tonumber(CoopPlayers.runOverInfo():match('drove_over=(%d+)')) or 0 } end) return 'watching the puppet'"
$pupRead = "local n0 = PW[1] and PW[1].n or 0 local th, dh for _, s in ipairs(PW) do if not th and s.n > n0 then th, dh = s.t, s.d end if th and s.t >= th + 0.3 then return string.format('hit_at=%.2f moved=%.0f', th, s.d - dh) end end return string.format('hit_at=%s moved=0 samples=%d', tostring(th), #PW)"
function Thrown($s) { if ($s -match 'moved=(\d+)') { [int]$Matches[1] -gt 150 } else { $false } }
$moved = "local p = FindFirstOf('PlayerController').Pawn:K2_GetActorLocation() return string.format('%.0f', math.sqrt((p.X - RO0.X) ^ 2 + (p.Y - RO0.Y) ^ 2))"

& "$t\collide-test.ps1" -SetupOnly | Select-String 'started|arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }

"=== 1. the host's car at the guest on foot"
"  guest: " + (Send $cd "return CoopPlayers.botExitCar()")
"  host: " + (Send $hd "return CoopPlayers.botEnterCar()")
Start-Sleep 5
"  guest: " + (OnFoot $cd)
"  guest: " + (Send $cd $inFront)
Start-Sleep 2
$g0 = Send $cd "return CoopPlayers.runOverInfo()"
"  host: " + (Send $hd $pupWatch)
"  host: " + (Send $hd $drive)
for ($i = 0; $i -lt 6; $i++) { "    guest at: " + (Send $cd $moved); Start-Sleep -Milliseconds 500 }
$g1 = Send $cd "return CoopPlayers.runOverInfo()"; $gm = Send $cd $moved
Check "the guest was hit (run over on its side, hurt)" ((Stat $g1 'run_over') -gt (Stat $g0 'run_over') -and $g1 -match '_dmg_ok') "guest: $g1"
Check "the guest was knocked away" ([int]$gm -gt 200) "guest moved $gm from where it stood"
Start-Sleep 1
$hp = Send $hd $pupRead; $h1d = Send $hd "return CoopPlayers.runOverInfo()"
Check "the host (driving) saw the hit and threw the guest's puppet at once (item 18)" (Thrown $hp) "host: $hp | $h1d"

"=== 2. the guest's car at the host on foot"
"  host: " + (Send $hd "return CoopPlayers.botExitCar()")
"  guest: " + (Send $cd "return CoopPlayers.botEnterCar()")
Start-Sleep 5
"  host: " + (OnFoot $hd)
"  host: " + (Send $hd $inFront)
Start-Sleep 2
$h0 = Send $hd "return CoopPlayers.runOverInfo()"
$twinAt = "local T = CoopPlayers.twinModule() for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then local l = c:K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y) end end return 'none'"
$tw0 = Send $hd $twinAt
"  guest: " + (Send $cd $pupWatch)
"  guest: " + (Send $cd $drive)
for ($i = 0; $i -lt 6; $i++) { "    host at: " + (Send $hd $moved); Start-Sleep -Milliseconds 500 }
$h1 = Send $hd "return CoopPlayers.runOverInfo()"
"  host: the guest's car (twin) from $tw0 to $(Send $hd $twinAt)"; $hm = Send $hd $moved
Check "the host was hit (run over on its side, hurt)" ((Stat $h1 'run_over') -gt (Stat $h0 'run_over') -and $h1 -match '_dmg_ok') "host: $h1"
Check "the host was knocked away" ([int]$hm -gt 200) "host moved $hm from where it stood"
Start-Sleep 1
$gp = Send $cd $pupRead; $g2d = Send $cd "return CoopPlayers.runOverInfo()"
Check "the guest (driving) saw the hit and threw the host's puppet at once (item 18)" (Thrown $gp) "guest: $gp | $g2d"

"=== 3. the host's trunk lid shut on the guest's head (item 24)"
"  host: " + (Send $hd "return CoopPlayers.botExitCar()")
"  guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4
# (parked first: after steps 1-2 the host's car stood anywhere, in drive - on a slope it rolled 500-2000 away
# with its lid while the guest stood where the lid had been, 2026-11-02)
"  host: " + (Send $hd "local m = FindFirstOf('BP_CarManager_C') local c = m.NewCarActor if m.MyCarGearBox == 0 then c:ToggleGearBoxState(0, false) end pcall(function() c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) end) return 'parked: gear ' .. tostring(m.MyCarGearBox)")
Start-Sleep 3
"  host: " + (Send $hd "local T = CoopPlayers.twinModule() T.door(T.ownCar(), 5):AttemptOpen() return 'trunk open'")
Start-Sleep 3
# the guest under the open lid (its bounds' middle), at the car's height + 60, right before it shuts (the
# host's car, left out of gear, may roll)
"  guest: " + (Send $cd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local f, l = tw:GetActorForwardVector(), tw:K2_GetActorLocation() local o, e = {}, {} StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'):GetComponentBounds(T.door(tw, 5).MainMesh, o, e, {}) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = o.X, Y = o.Y, Z = l.Z + 60 }, false, {}, true) return string.format('under the lid (its middle %.0f,%.0f,%.0f, the car z %.0f)', o.X, o.Y, o.Z, l.Z)")
$gAt = "local p = FindFirstOf('PlayerController').Pawn local l = p:K2_GetActorLocation() local v = p:GetVelocity() return string.format('%.0f,%.0f,%.0f v=%.0f,%.0f,%.0f', l.X, l.Y, l.Z, v.X, v.Y, v.Z)"
"  guest right after: " + (Send $cd $gAt)
$l0 = Send $cd "return CoopPlayers.runOverInfo()"
"  guest before the shut: " + (Send $cd $gAt) + " | $l0 | now " + (Send $cd "return CoopPlayers.nowMs()")
"  host: " + (Send $hd "local T = CoopPlayers.twinModule() T.door(T.ownCar(), 5):AttemptShut() return 'trunk shut'")
Start-Sleep 3
$l1 = Send $cd "return CoopPlayers.runOverInfo()"
Check "the lid hit the guest's head (hurt, pushed back)" ((Stat $l1 'lid_hits') -gt (Stat $l0 'lid_hits') -and $l1 -match 'last_lid_hit=ok') "guest: $l1"

$he = Send $hd "return CoopPlayers.report()"; $ge = Send $cd "return CoopPlayers.report()"
Check "no player sync errors" ($he -notmatch 'run over' -and $ge -notmatch 'run over') "host: $($he.Substring(0, [math]::Min(200, $he.Length))) | guest: $($ge.Substring(0, [math]::Min(200, $ge.Length)))"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
