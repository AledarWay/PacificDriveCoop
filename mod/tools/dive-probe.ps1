# (NOTES 2026-11-15 "The nose dive at a hand-over"; -HostPre: Lua run on the host before each round)
# the nose dive at a hand-over: the guest gets in at the host's car's driver's door; both sides sample the host's car
# every frame with its physics state; rounds until a dive (pitch > 5) is seen, then the frames around it
param([int]$Rounds = 8, [switch]$Reuse, [string]$HostPre = "")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"; $hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 2 }
$ce = Get-Content "$t\cmds\car-e.lua" -Raw
$carOf = "local function carOf(kind) local T = CoopPlayers.twinModule() if kind == 'own' then return T.ownCar() end for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then return c end end end "
# per frame: t z pitch sim fwd-vel side-vel vz angvel(pitch axis approx: Y) driving pawn-attached
function SampleStart($dir, [string]$kind) {
    Send $dir ($carOf + "local c = carOf('$kind') DIVE = {} OVL = nil local t0 = os.clock() local N = FName('None') local h " +
        "h = LoopInGameThreadWithDelay(1, function() if os.clock() - t0 > 9 then CancelDelayedAction(h) return end if not c:IsValid() then return end " +
        "local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation() local R = c.RootComponent local sim = R:IsSimulatingPhysics(N) local v = R:GetPhysicsLinearVelocity(N) local w = R:GetPhysicsAngularVelocityInDegrees(N) " +
        "local y = math.rad(r.Yaw) local f, s = v.X * math.cos(y) + v.Y * math.sin(y), -v.X * math.sin(y) + v.Y * math.cos(y) " +
        "local dr = CoopPlayers.twinModule().door(c, 1) local ds = (dr and dr:IsValid() and dr.MainMesh:IsSimulatingPhysics(N)) and 'D' or 'd' local pw = FindFirstOf('PlayerController').Pawn local a = pw:GetAttachParentActor() local att = a and a:IsValid() and (a:GetAddress() == c:GetAddress() and 'C' or 'o') or '-' " +
        "if sim and not OVL then OVL = {} local KSL = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary') local ot = {} for q = 0, 31 do ot[#ot + 1] = q end local out = {} pcall(function() KSL:ComponentOverlapComponents(R, c:GetTransform(), ot, nil, { c }, out) end) for q = 1, #out do local x = out[q]:get() if x:IsValid() then local ow = x:GetOwner() OVL[#OVL + 1] = (ow:IsValid() and ow:GetClass():GetFName():ToString() or '?') .. '.' .. x:GetFName():ToString() .. '/' .. x:GetCollisionObjectType() end end OVL[#OVL + 1] = string.format('t=%.3f n=%d', os.clock() - t0, #out) end local d = CoopPlayers.driveInfo() DIVE[#DIVE + 1] = { os.clock() - t0, l.X, l.Y, l.Z, r.Pitch, sim and 1 or 0, f, s, v.Z, w.X, w.Y, w.Z, d:match('driving=(%S+)') .. '/' .. d:match('driven_by=(%S+)'):sub(1, 1), att, pw.PercentInCar or -1, ds } end) return 'sampling'") | Out-Null
}
$read = "local ov = table.concat(OVL or {}, ', ') local s = DIVE or {} local a = s[1] if not a then return 'none' end local mp, at, mi = 0, 0, 1 for i, x in ipairs(s) do local d = math.abs(x[5] - a[5]) if d > mp then mp, at, mi = d, x[1], i end end return string.format('dive=%.1f at=%.2f n=%d', mp, at, #s) .. ' ovl: ' .. ov"
# every frame 0.8 s before the biggest pitch to 0.5 s after, plus the frames where sim / driving / attach changed
$series = "local s = DIVE or {} local a = s[1] if not a then return '' end local mp, mi = 0, 1 for i, x in ipairs(s) do local d = math.abs(x[5] - a[5]) if d > mp then mp, mi = d, i end end " +
    "local o = {} local prev for i, x in ipairs(s) do local key = x[6] .. x[13] .. x[14] .. x[16] local near = x[1] >= s[mi][1] - 0.8 and x[1] <= s[mi][1] + 0.5 " +
    "if near or key ~= prev then o[#o + 1] = string.format('%.3f z=%.0f p=%.1f sim=%d f=%.0f s=%.0f vz=%.0f w=%.0f/%.0f/%.0f %s %s pic=%.2f %s', x[1], x[4] - a[4], x[5] - a[5], x[6], x[7], x[8], x[9], x[10], x[11], x[12], x[13], x[14], x[15], x[16]) end prev = key end return table.concat(o, ' ;; ')"
function InCar($dir) { Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())" }
function OutOf($dir, [string]$kind) { for ($i = 0; $i -lt 3; $i++) { if ((InCar $dir) -eq 'false') { return 'out' }; Send $dir "CE_CAR = '$kind' CE_HL = 'ExitDoor' $ce" | Out-Null; Start-Sleep 4 }; 'still in' }
"both out: host " + (OutOf $hd 'own') + " guest " + (OutOf $cd 'own')
for ($r = 1; $r -le $Rounds; $r++) {
    "=== round $r  out: " + (OutOf $cd 'twin')
    if ($HostPre) { "  host pre: " + (Send $hd $HostPre) }
    Start-Sleep 2
    SampleStart $cd 'twin'; SampleStart $hd 'own'
    Send $cd ($carOf + "local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = carOf('twin') local pw = FindFirstOf('PlayerController').Pawn local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -150, Z = 0 }) w.Z = pw:K2_GetActorLocation().Z + 20 pw:K2_SetActorLocation(w, false, {}, true) return 'at'") | Out-Null
    Start-Sleep 1
    $e = Send $cd "CE_CAR = 'twin' CE_HL = 'door1' $ce"
    Start-Sleep 3
    if ((InCar $cd) -eq 'false') { $e += " | again: " + (Send $cd "CE_CAR = 'twin' CE_HL = 'door1' $ce") }
    Start-Sleep 5
    $g = Send $cd $read; $h = Send $hd $read
    "  E $e | in=$(InCar $cd) | guest: $g | host: $h | " + (Send $hd "local m = FindFirstOf('BP_CarManager_C') return 'host car ign=' .. tostring(m.CarIgnitionState) .. ' gear=' .. tostring(m.MyCarGearBox)")
    if ($g -match 'dive=([5-9]|\d\d)') { "  --- guest side (the twin it drives):"; (Send $cd $series) -split " ;; "; "  --- host side (its own car):"; (Send $hd $series) -split " ;; " }
}
