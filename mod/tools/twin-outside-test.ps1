# The other's car seen from outside, the two PCs' clocks apart (owner's alpha 21 test: "the other's car still moved in
# jerks, as if updated a few times a second"). The prediction of the twin seen from outside took its age by the
# sender's clock: on two PCs whose clocks differ it was 0 or the cap. On one PC the clocks are the same - here the
# guest's clock is skewed by hand (CoopPlayers.testClockSkew). The host drives (the test bot), the guest stands outside;
# the guest's twin of the host's car moves smoothly (jerk <= 0.3; the old age: 0.63 / 0.76 at +-1500, the fix 0.13) at
# a skew of 0, +1500 and -1500 ms.
# Uses cars-test's pair (-Reuse: one already set up by cars-test -SetupOnly).
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
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 3 }
$smooth = "SM = {} local T = CoopPlayers.twinModule() local car = T.ownCar() if SM_TWIN then for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then car = c end end end local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local t = os.clock() if t - t0 > SM_S then CancelDelayedAction(h) return end local l = car:K2_GetActorLocation() SM[#SM + 1] = { t = t, x = l.X, y = l.Y } end) return 'sampling'"
$smoothRead = "local sp = {} for i = 2, #SM do local dt = SM[i].t - SM[i - 1].t if dt > 0.001 then sp[#sp + 1] = math.sqrt((SM[i].x - SM[i - 1].x) ^ 2 + (SM[i].y - SM[i - 1].y) ^ 2) / dt end end local d, sum = {}, 0 for i = 2, #sp do d[#d + 1] = math.abs(sp[i] - sp[i - 1]) end for _, v in ipairs(sp) do sum = sum + v end table.sort(d) local mean = #sp > 0 and sum / #sp or 0 local med = #d > 0 and d[math.floor(#d / 2) + 1] or 0 return string.format('frames=%d mean=%.0f jerk=%.3f', #SM, mean, mean > 1 and med / mean or 0)"
"=== the host in its car, the guest on foot"
"  host: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end return 'in'")
"  guest: " + (Send $cd "local par = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() if par and par:IsValid() then return CoopPlayers.botExitCar() end return 'on foot'")
Start-Sleep 4
"  host doors shut: " + (Send $hd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do if T.doorOpen(own, n) then T.door(own, n):AttemptShut() o[#o + 1] = n end end return #o > 0 and table.concat(o, ',') or 'none were open'")
Start-Sleep 2
foreach ($skew in 0, 1500, -3000) {
    "  guest: " + (Send $cd "return CoopPlayers.testClockSkew($skew)")
    # (the bot drives straight on: by the third run the car had left the road and stood wedged on a slope - mean 2,
    # pitch -31. Each run starts from the first one's spot and heading, on the same road)
    if ($skew -eq 0) { "  host start kept: " + (Send $hd "local car = CoopPlayers.twinModule().ownCar() local l, r = car:K2_GetActorLocation(), car:K2_GetActorRotation() TO_START = { l = { X = l.X, Y = l.Y, Z = l.Z + 30 }, r = { Pitch = 0, Yaw = r.Yaw, Roll = 0 } } return string.format('%.0f,%.0f yaw %.0f', l.X, l.Y, r.Yaw)") }
    else { "  host back at the start: " + (Send $hd "local car = CoopPlayers.twinModule().ownCar() car:K2_SetActorLocationAndRotation(TO_START.l, TO_START.r, false, {}, true) pcall(function() car:GetRootComponent():SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, nil) car:GetRootComponent():SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, nil) end) local l = car:K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y)"); Start-Sleep 2 }
    "  host: " + (Send $hd "return CoopPlayers.botDrive(9)")
    Start-Sleep 3
    Send $hd "SM_TWIN = false SM_S = 4 $smooth" | Out-Null; Send $cd "SM_TWIN = true SM_S = 4 $smooth" | Out-Null
    Start-Sleep 5
    $hsm = KV (Send $hd $smoothRead); $csm = KV (Send $cd $smoothRead)
    $net = @{ 0 = '0'; 1500 = '+1500'; -3000 = '-1500' }[$skew]
    Check "guest clock $net ms: the twin seen from outside moves as smoothly as the host's car (jerk <= 0.3)" ([double]$csm.mean -gt 100 -and [double]$csm.jerk -le 0.3) "host car: $($hsm.raw) | guest's twin: $($csm.raw)"
    Start-Sleep 3
}
"  guest: " + (Send $cd "return CoopPlayers.testClockSkew(1500)")

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
