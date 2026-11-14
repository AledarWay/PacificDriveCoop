# The other's puppet sat outside by the driver's door (owner's alpha 21 test, "it was not so before"). Each side takes
# the seat geometry for the other's puppet from its own player sitting at the wheel, measured once. The game's own
# entry (native cars: the door's StartEntry, then CommandEnterCar) attaches the player to the car while it still
# stands at the door: measured in that moment, the seat was outside. Here the host gets out, its measure is reset, it
# gets in the game's way (door 1), every frame's relative place is sampled; the measured seat must be the seated one.
# Uses cars-test's pair (-Reuse: one already set up by cars-test -SetupOnly).
param([switch]$Keep, [switch]$Reuse)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 3 }
# (the host: the guest measures only in the host's car, its own car's seat is the game's driver seat - the default)
foreach ($x in @(@{ tag = 'host'; dir = $hd })) {
    "=== $($x.tag): out, the measure reset, in by the game's entry at door 1"
    "  " + (Send $x.dir "local par = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() if par and par:IsValid() then return CoopPlayers.botExitCar() end return 'on foot'")
    Start-Sleep 4
    "  " + (Send $x.dir "return CoopPlayers.testResetSeat()")
    "  " + (Send $x.dir ("local own = CoopPlayers.twinModule().ownCar() local d = CoopPlayers.twinModule().door(own, 1) " +
        "local p = FindFirstOf('PlayerController').Pawn local c = (d and d:K2_GetActorLocation()) or own:K2_GetActorLocation() p:K2_SetActorLocation({ X = c.X, Y = c.Y, Z = c.Z + 60 }, false, {}, true) " +
        "SEAT_S = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() if os.clock() - t0 > 5 then CancelDelayedAction(h) return end " +
        "local q = FindFirstOf('PlayerController').Pawn local a = q:GetAttachParentActor() if a and a:IsValid() then local r = q.RootComponent.RelativeLocation SEAT_S[#SEAT_S + 1] = string.format('%.0f,%.0f', r.X, r.Y) end end) " +
        "if d then pcall(function() d:StartEntry(true) end) end Dev.after(200, function() FindFirstOf('PlayerController').Pawn:CommandEnterCar(true, nil, false) end) return 'entering, door ' .. tostring(d ~= nil)"))
    Start-Sleep 7
    # (the seat measure waits for the player to sit still 1 s: what it was at 7 s, the check at 11 s)
    "  at 7 s: " + (Send $x.dir "return CoopPlayers.selfInfo()")
    Start-Sleep 4
    $s = Send $x.dir "local o, n, f = {}, #SEAT_S, nil for i, v in ipairs(SEAT_S) do local y = tonumber(v:match(',(.+)')) if not f and math.abs(y) > 80 then f = v end if i <= 3 or i == n then o[#o + 1] = v end end return 'attached_frames=' .. n .. ' outside_first=' .. tostring(f) .. ' samples=' .. table.concat(o, ';')"
    $i = Send $x.dir "return CoopPlayers.selfInfo()"
    "  $s"
    $m = if ($i -match 'driver_seat_measured=(-?[\d.]+),(-?[\d.]+),') { [double]$Matches[2] } else { $null }
    Check "$($x.tag): the driver's seat measured inside the cabin" ($m -ne $null -and [math]::Abs($m) -lt 80) "$i"
}
# (owner's test 2026-11-14: the session's first sit on the back-left seat was taken for the driver's - from then on the
# driver's door seated the player at the back. The game's own E on the doors, as a player)
$ce = Get-Content "$t\cmds\car-e.lua" -Raw
function InAt($dir, [int]$n) {
    $p = @{ 1 = '131,-150'; 3 = '8,-150' }[$n] -split ','
    Send $dir "local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = CoopPlayers.twinModule().ownCar() local pw = FindFirstOf('PlayerController').Pawn local w = KML:TransformLocation(c:GetTransform(), { X = $($p[0]), Y = $($p[1]), Z = 0 }) w.Z = pw:K2_GetActorLocation().Z + 20 pw:K2_SetActorLocation(w, false, {}, true) return 'at'" | Out-Null
    Start-Sleep 1
    $r = Send $dir "CE_CAR = 'own' CE_HL = 'door$n' $ce"
    Start-Sleep 6
    $r
}
function OutOf($dir) {
    for ($i = 0; $i -lt 3; $i++) {
        if ((Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())") -eq 'false') { return 'out' }
        Send $dir "CE_CAR = 'own' CE_HL = 'ExitDoor' $ce" | Out-Null; Start-Sleep 4
    }
    'still in'
}
foreach ($x in @(@{ tag = 'host'; dir = $hd })) {
    "=== $($x.tag): the session's first sit on the back-left seat, then in by the driver's door"
    "  out: " + (OutOf $x.dir) + " | " + (Send $x.dir "return CoopPlayers.testResetSeat()")
    "  back-left: " + (InAt $x.dir 3) + " | " + (Send $x.dir "return CoopPlayers.selfInfo()")
    "  out: " + (OutOf $x.dir)
    "  driver's door: " + (InAt $x.dir 1)
    $i = Send $x.dir "return CoopPlayers.selfInfo()"
    $rx = if ($i -match ' rel=(-?[\d.]+),') { [double]$Matches[1] } else { $null }
    $sock = Send $x.dir "local r = CoopPlayers.twinModule().ownCar().TempSocket_Seat.RelativeLocation return string.format('%.0f,%.0f', r.X, r.Y)"
    Check "$($x.tag): in by the driver's door after a back seat, at the wheel (forward of the back seats)" ($rx -ne $null -and $rx -gt 20) "$i | seat socket $sock"
}
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
