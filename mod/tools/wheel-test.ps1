# Automated "the whole wheel" test: the client in the driver seat turns the key and moves the drive/park
# lever; the host's real car follows (K lines). Reverse = the game's pedal handling turns S at a stop into a
# negative UserThrottleInput, already in the input stream (-1 for 6 s = 8.5 m back). The host moving the lever shows on the client's car copy (state on the C line).
# The key / lever are called on the client's car copy the way the game's own input does (ToggleIgnitionState /
# ToggleGearBoxState(current lever state, false) flips the lever with its animation); the sync only watches BP_CarManager_C's state, so any path counts.
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
function Wheel($dir) { KV (Send $dir "return CoopPlayers.wheelInfo()") }
function Ctl($dir) { KV (Send $dir "return CoopPlayers.controlsInfo()") }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# wait until the host's controls show ign / gear (or time out), return the last reading
function WaitCtl($dir, [string]$what, [int]$want, [int]$sec = 10) {
    $end = (Get-Date).AddSeconds($sec)
    do { $c = Ctl $dir; if ($c[$what] -eq "$want") { return $c }; Start-Sleep 1 } while ((Get-Date) -lt $end)
    $c
}
function CarOn($dir, [string]$call) { Send $dir "local car = FindFirstOf('BP_PlayerCarNew_C') car:$call return 'called $call'" }
# host car's travel along its own forward axis during a block of client input
function Travel([scriptblock]$during, [int]$waitSec) {
    $a = Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l, f = c:K2_GetActorLocation(), c:GetActorForwardVector() WheelT = { x = l.X, y = l.Y, fx = f.X, fy = f.Y } return 'marked'"
    & $during | Out-Null
    Start-Sleep $waitSec
    KV (Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() local dx, dy = l.X - WheelT.x, l.Y - WheelT.y return string.format('moved=%.0f forward=%.0f', math.sqrt(dx * dx + dy * dy), dx * WheelT.fx + dy * WheelT.fy)")
}

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -DelayMs $DelayMs -JitterMs $JitterMs | Select-String 'matched on client|^PASS|^FAIL'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 6

"=== 1. the client takes the driver seat (host out, client in at the driver door, host in front right)"
"  host: " + (Send $hd "return CoopPlayers.botExitCar()"); Start-Sleep 3
"  client: " + (Send $cd "return CoopPlayers.botEnterAt('FL')"); Start-Sleep 4
"  host: " + (Send $hd "return CoopPlayers.botEnterAt('FR')"); Start-Sleep 4
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = client" ($hw.driver -eq 'client' -and $cw.driver -eq 'client') "host: $($hw.raw) | client: $($cw.raw)"
$h0 = Ctl $hd; "  host controls: $($h0.raw) | client: $((Ctl $cd).raw)"

"=== 2. the client turns the engine off"
"  client: " + (CarOn $cd "ToggleIgnitionState(0)")
$h = WaitCtl $hd 'ign' 0
Check "host's engine is off" ($h.ign -eq '0' -and [int]$h.ctl_applied -ge 1) "host: $($h.raw) | client: $((Ctl $cd).raw)"

"=== 3. the client starts the engine"
"  client: " + (CarOn $cd "ToggleIgnitionState(2)")
$h = WaitCtl $hd 'ign' 2 15
Check "host's engine runs again" ($h.ign -eq '2') "host: $($h.raw) | client: $((Ctl $cd).raw)"

"=== 4. the client puts the lever to park and gives gas"
"  client: " + (CarOn $cd "ToggleGearBoxState(0, false)")
$h = WaitCtl $hd 'gear' 1
Check "host's lever is on park" ($h.gear -eq '1') "host: $($h.raw)"
$tr = Travel { Send $cd "return CoopPlayers.botInput(4, 1.0, 0)" } 5
Check "parked: the car does not move on gas (< 100)" ([double]$tr.moved -lt 100) $tr.raw

"=== 5. the client puts the lever to drive and gives gas"
"  client: " + (CarOn $cd "ToggleGearBoxState(1, false)")
$h = WaitCtl $hd 'gear' 0
Check "host's lever is on drive" ($h.gear -eq '0') "host: $($h.raw)"
$tr = Travel { Send $cd "return CoopPlayers.botInput(4, 1.0, 0)" } 5
Check "drive: the car moves forward on gas (>= 300)" ([double]$tr.forward -ge 300) $tr.raw
Start-Sleep 8 # coast to a stop

"=== 6. reverse: the client backs up (negative throttle, what the game's pedal handling makes of S at a stop)"
$tr = Travel { Send $cd "return CoopPlayers.botInput(6, -1.0, 0)" } 7
Check "the car backs up on the client's reverse input (<= -100 along forward)" ([double]$tr.forward -le -100) $tr.raw
Start-Sleep 5

"=== 7. the host moves the lever: the client's copy follows"
"  host: " + (CarOn $hd "ToggleGearBoxState(0, false)")
$c = WaitCtl $cd 'gear' 1
Check "client's car copy shows park" ($c.gear -eq '1' -and [int]$c.ctl_followed -ge 1) "client: $($c.raw)"
"  host: " + (CarOn $hd "ToggleGearBoxState(1, false)")
$c = WaitCtl $cd 'gear' 0
Check "client's car copy shows drive again" ($c.gear -eq '0') "client: $($c.raw)"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
