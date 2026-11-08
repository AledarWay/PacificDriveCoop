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
    $s = Send $x.dir "local o, n, f = {}, #SEAT_S, nil for i, v in ipairs(SEAT_S) do local y = tonumber(v:match(',(.+)')) if not f and math.abs(y) > 80 then f = v end if i <= 3 or i == n then o[#o + 1] = v end end return 'attached_frames=' .. n .. ' outside_first=' .. tostring(f) .. ' samples=' .. table.concat(o, ';')"
    $i = Send $x.dir "return CoopPlayers.selfInfo()"
    "  $s"
    $m = if ($i -match 'driver_seat_measured=(-?[\d.]+),(-?[\d.]+),') { [double]$Matches[2] } else { $null }
    Check "$($x.tag): the driver's seat measured inside the cabin" ($m -ne $null -and [math]::Abs($m) -lt 80) "$i"
}
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
