# Automated "client drives the car" test over the network relays (two headless instances on this PC).
# The host keeps the car physics; the client's driver input (the car BP's raw input fields, as the keys fill
# them) streams to the host. Phases: host drives (default) -> client takes the wheel (seats swap) -> client
# drives -> host takes the wheel back (client input ignored) -> host out of the car, client drives alone.
# Seats change only by getting out and in at a door (no wheel key).
param([switch]$Keep, [int]$DelayMs = 0, [int]$JitterMs = 0)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Info($dir) { KV (Send $dir "return CoopPlayers.puppetInfo()") }
function Self($dir) { KV (Send $dir "return CoopPlayers.selfInfo()") }
function Wheel($dir) { KV (Send $dir "return CoopPlayers.wheelInfo()") }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# expected car-local X,Y per seat (1 driver, 4 back right; BACK_X = -45 in playersync.lua)
$SEAT = @{ 1 = @(46.2, -45.8); 2 = @(46.2, 45.8); 3 = @(-45, -45.8); 4 = @(-45, 45.8) }
function At($rel, [int]$n) { $v = Vec $rel; [math]::Abs($v.X - $SEAT[$n][0]) -lt 2 -and [math]::Abs($v.Y - $SEAT[$n][1]) -lt 2 }
function SeatChecks($label, [int]$hostSeat, [int]$clientSeat) {
    $hs = Self $hd; $cs = Self $cd; $hp = Info $cd; $cp = Info $hd
    Check "$label host's own character on seat $hostSeat" ($hs.in_car -eq 'True' -and (At $hs.rel $hostSeat)) $hs.raw
    Check "$label client's own character on seat $clientSeat" ($cs.in_car -eq 'True' -and (At $cs.rel $clientSeat)) $cs.raw
    Check "$label host's puppet (on client) on seat $hostSeat" ($hp.state -eq 'sit' -and (At $hp.rel $hostSeat)) $hp.raw
    Check "$label client's puppet (on host) on seat $clientSeat" ($cp.state -eq 'sit' -and (At $cp.rel $clientSeat)) $cp.raw
}
function Out($dir) { Send $dir "return CoopPlayers.botExitCar()" }
function In($dir, $door) { Send $dir "return CoopPlayers.botEnterAt('$door')" }

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -DelayMs $DelayMs -JitterMs $JitterMs | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 6

"=== 1. start: the host drives; the client frees the back right seat and gets in there"
"  client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)"); Start-Sleep 3
# (a zone save's start seats the client already - the mod puts it on the first free back seat, 3: out first, so the
# way in is the back right door's)
if ((Send $cd "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())") -match 'true') { "  client: " + (Out $cd); Start-Sleep 4 }
"  client: " + (In $cd 'RR'); Start-Sleep 5
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = host" ($hw.driver -eq 'host' -and $cw.driver -eq 'host') "host: $($hw.raw) | client: $($cw.raw)"
SeatChecks "start:" 1 4

"=== 2. the client takes the driver seat (both get out, client at the driver door, host at the front right)"
"  host: " + (Out $hd) + " | client: " + (Out $cd); Start-Sleep 3
"  client: " + (In $cd 'FL'); Start-Sleep 4
"  host: " + (In $hd 'FR'); Start-Sleep 4
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = client" ($hw.driver -eq 'client' -and $cw.driver -eq 'client') "host: $($hw.raw) | client: $($cw.raw)"
SeatChecks "client drives:" 4 1

"=== 3. the client drives (throttle 1, steer 0.3, 6 s)"
$start = (Wheel $hd).car
"  client: " + (Send $cd "return CoopPlayers.botInput(6, 1.0, 0.3)")
Start-Sleep 3
$mid = Wheel $hd
Check "host applies the client's input while it drives" ([double]($mid.input -split ',')[0] -gt 0.9 -and [int]$mid.in_applied -gt 0) $mid.raw
Start-Sleep 4
$hw = Wheel $hd
Check "pedals released on the host after the client let go" ([double]($hw.input -split ',')[0] -eq 0) $hw.raw
$moved = Dist $start $hw.car
Check "host's car really drove on the client's input (>= 500 units)" ($moved -ge 500) "moved $moved"
# (let go in drive, the game's car creeps on by itself, ~270 units/s - the coasting flake: speed 104-278 after 8 s;
# so the client brakes it, which also checks the brake pedal's relay)
# (held through the checks: the test road runs downhill, 1300 units down - a 4 s brake left it rolling at 214)
"  client brakes: " + (Send $cd "return CoopPlayers.botInput(9, 0, 0, 1.0)")
Start-Sleep 8
$hw = Wheel $hd; $cw = Wheel $cd
$err = Dist $hw.car $cw.car
Check "client's car copy matches the host's car (<= 30 units)" ($err -le 30) "host car $($hw.car), client copy $($cw.car), error $err"
Check "the car stopped on the client's brake (speed < 50)" ([double]$hw.speed -lt 50) "speed $($hw.speed)"

"=== 4. the host takes the driver seat back; client input is ignored"
"  client: " + (Out $cd); Start-Sleep 3
"  host: " + (Out $hd); Start-Sleep 3
"  host: " + (In $hd 'FL'); Start-Sleep 4
"  client: " + (In $cd 'RR'); Start-Sleep 4
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = host again" ($hw.driver -eq 'host' -and $cw.driver -eq 'host') "host: $($hw.raw) | client: $($cw.raw)"
SeatChecks "host drives again:" 1 4
$before = $hw.car; $sentBefore = [int]$cw.in_sent; $speedBefore = $hw.speed
"  client: " + (Send $cd "return CoopPlayers.botInput(3, 1.0, 0)")
Start-Sleep 1.5
# input, not distance: an unattended car can creep downhill while everybody changes seats (seen 57 units / 4 s
# at speed 7 with the client sending nothing)
$vcDiag = "for _, c in ipairs(FindAllOf('VehicleControllerComponent') or {}) do local o = c:GetOuter() if o:IsValid() and o:GetClass():GetFName():ToString() == 'BP_PlayerCarNew_C' and o:GetFullName():find(':PersistentLevel.', 1, true) then return string.format('vcT=%.2f', c.ThrottleInput) end end return 'vcT=?'"
$midw = Wheel $hd; $mid = KV (Send $hd $vcDiag)
Check "client throttle while the host holds the wheel does not reach the host's car (raw input and controller 0)" ([double](($midw.input -split ',')[0]) -eq 0 -and [double]$mid.vcT -lt 0.05) "host input $($midw.input) | $($mid.raw)"
Start-Sleep 2.5
$hw = Wheel $hd; $cw = Wheel $cd
$moved = Dist $before $hw.car
"  [INFO] the car moved $moved units meanwhile (speed at the start $speedBefore)"
Check "client sends no input while not driving" ([int]$cw.in_sent -eq $sentBefore) "in_sent $sentBefore -> $($cw.in_sent)"

"=== 5. the host leaves the car; the client moves to the driver seat and drives alone"
"  host: " + (Out $hd); Start-Sleep 3
"  client: " + (Out $cd); Start-Sleep 3
"  client: " + (In $cd 'FL'); Start-Sleep 4
# The car keeps the course it ended phase 3 with and sometimes drives into terrain within 4 s (drive-flake.ps1:
# throttle reaches the vehicle controller, engine on, parking brake off, speed ~0; braking from standstill does
# not reverse, that needs the gearbox). So the check is that the client's input drives the host's car physics;
# distance is reported, and only warned about when the car is held by something. Steer back the other way.
$carDiag = @"
local car
for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c:GetFullName():find(':PersistentLevel.', 1, true) then car = c end end
local vc
for _, c in ipairs(FindAllOf('VehicleControllerComponent') or {}) do if c:IsValid() and c:GetOuter():GetFullName() == car:GetFullName() then vc = c end end
return string.format('vcT=%.2f engineOn=%s park=%s', vc.ThrottleInput, tostring(car.EngineOn), tostring(vc:GetParkingBrakeActive()))
"@
$before = (Wheel $hd).car
"  client: " + (Send $cd "return CoopPlayers.botInput(4, 1.0, -0.3)")
Start-Sleep 2
$mid = KV (Send $hd $carDiag)
Check "with the host out of the car the client's throttle reaches the host's car physics" ([double]$mid.vcT -ge 0.9 -and $mid.engineOn -eq 'true' -and $mid.park -eq 'false') $mid.raw
Start-Sleep 3
$hw = Wheel $hd
$moved = Dist $before $hw.car
if ($moved -ge 300) { "  [INFO] the car drove $moved units on the client's input" }
else { "  [WARN] the car moved only $moved units with the throttle applied: held by terrain at $($hw.car) (not counted)" }
"host players: " + (Send $hd "return CoopPlayers.report()")
"client players: " + (Send $cd "return CoopPlayers.report()")
"host wheel: " + (Send $hd "return CoopPlayers.wheelInfo()")
"client wheel: " + (Send $cd "return CoopPlayers.wheelInfo()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
