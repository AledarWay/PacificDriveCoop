# Repeats drive-test's phases 4+5 (host takes the driver seat back and the client's input is ignored; then the
# host gets out and the client drives alone) -Rounds times in one session, with a mid-drive diagnostic line,
# to catch the intermittent "client drives but the car does not move" case.
param([int]$Rounds = 6)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Wheel($dir) { KV (Send $dir "return CoopPlayers.wheelInfo()") }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
function Out($dir) { Send $dir "return CoopPlayers.botExitCar()" }
function In($dir, $door) { Send $dir "return CoopPlayers.botEnterAt('$door')" }
# host-side car state: engine, parking brake, vehicle controller inputs, BP raw inputs, speed, where the
# host's character stands relative to the car, the car's up vector (flipped?)
$diag = @'
local car
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end end
local vc
for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do if c:IsValid() and c:GetOuter():GetFullName() == car:GetFullName() then vc = c end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local pawn = FindFirstOf("PlayerController").Pawn
local pl = KML:InverseTransformLocation(car:GetTransform(), pawn:K2_GetActorLocation())
local v = car:GetVelocity()
local up = car:GetActorUpVector()
return string.format("engineOn=%s park=%s vcT=%.2f vcB=%.2f vcHB=%.2f userT=%.2f userB=%.2f thrCur=%.2f brakeCur=%.2f speed=%.0f hostChar=%.0f,%.0f,%.0f up=%.2f",
  tostring(car.EngineOn), tostring(vc:GetParkingBrakeActive()), vc.ThrottleInput, vc.BrakeInput, vc.HandbrakeInput,
  car.UserThrottleInput, car.UserBrakeInput, car.ThrottleCurrent, car.BrakeCurrent, math.sqrt(v.X*v.X+v.Y*v.Y), pl.X, pl.Y, pl.Z, up.Z)
'@

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|import:|matched on client|^PASS|^FAIL'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 6
"  client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)"); Start-Sleep 3
"  client: " + (In $cd 'RR'); Start-Sleep 5
$fails = 0
for ($r = 1; $r -le $Rounds; $r++) {
    "=== round $r"
    "  client: " + (Out $cd); Start-Sleep 3
    "  host: " + (Out $hd); Start-Sleep 3
    "  host: " + (In $hd 'FL'); Start-Sleep 4
    "  client: " + (In $cd 'RR'); Start-Sleep 4
    "  client (ignored): " + (Send $cd "return CoopPlayers.botInput(3, 1.0, 0)"); Start-Sleep 4
    "  host: " + (Out $hd); Start-Sleep 3
    "  client: " + (Out $cd); Start-Sleep 3
    "  client: " + (In $cd 'FL'); Start-Sleep 4
    "  before: " + (Send $hd $diag)
    $before = (Wheel $hd).car
    "  client: " + (Send $cd "return CoopPlayers.botInput(4, 1.0, 0)")
    Start-Sleep 2
    "  mid: " + (Send $hd $diag) + " | " + (Wheel $hd).raw
    Start-Sleep 3
    $hw = Wheel $hd
    $moved = Dist $before $hw.car
    if ($moved -lt 300) {
        $fails++
        "  round ${r}: moved $moved <-- STUCK, trying reverse (brake held from standstill)"
        $b2 = (Wheel $hd).car
        "  client: " + (Send $cd "return CoopPlayers.botInput(4, 0, 0, 1.0)")
        Start-Sleep 2
        "  mid reverse: " + (Send $hd $diag)
        Start-Sleep 3
        "  reverse moved: " + (Dist $b2 (Wheel $hd).car)
    } else { "  round ${r}: moved $moved" }
    Start-Sleep 5
}
"=== RESULT: $fails of $Rounds rounds stuck"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
