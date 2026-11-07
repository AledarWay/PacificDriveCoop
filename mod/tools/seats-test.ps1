# Automated seats test over the network relays (two headless instances on this PC): four seats (driver,
# front passenger, back left, back right) taken by players or devices, the host decides, getting in at a
# door picks the nearest free seat, no free seat -> out of the car; driving = sitting on seat 1.
param([switch]$Keep)
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
function Seats($dir) { KV (Send $dir "return CoopPlayers.seatInfo()") }
function Wheel($dir) { KV (Send $dir "return CoopPlayers.wheelInfo()") }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# expected car-local X,Y of a seated character per seat (BACK_X = -60 in playersync.lua)
$SEAT = @{ 1 = @(46.2, -45.8); 2 = @(46.2, 45.8); 3 = @(-60, -45.8); 4 = @(-60, 45.8) }
function At($rel, [int]$n) { $v = Vec $rel; [math]::Abs($v.X - $SEAT[$n][0]) -lt 2 -and [math]::Abs($v.Y - $SEAT[$n][1]) -lt 2 }
function SeatCheck($label, [int]$hostSeat, [int]$clientSeat) {
    $hs = Self $hd; $cs = Self $cd; $hp = Info $cd; $cp = Info $hd; $tab = Seats $hd
    Check "$label host seat table: host=$hostSeat client=$clientSeat" ($tab.host_seat -eq "$hostSeat" -and $tab.client_seat -eq "$clientSeat") $tab.raw
    if ($hostSeat -gt 0) {
        Check "$label host's own character on seat $hostSeat" ($hs.in_car -eq 'True' -and $hs.seat -eq "$hostSeat" -and (At $hs.rel $hostSeat)) $hs.raw
        Check "$label host's puppet (on client) on seat $hostSeat" ($hp.state -eq 'sit' -and (At $hp.rel $hostSeat)) $hp.raw
    }
    if ($clientSeat -gt 0) {
        Check "$label client's own character on seat $clientSeat" ($cs.in_car -eq 'True' -and $cs.seat -eq "$clientSeat" -and (At $cs.rel $clientSeat)) $cs.raw
        Check "$label client's puppet (on host) on seat $clientSeat" ($cp.state -eq 'sit' -and (At $cp.rel $clientSeat)) $cp.raw
    }
}
function Out($dir) { Send $dir "return CoopPlayers.botExitCar()" }
function In($dir, $door) { Send $dir "return CoopPlayers.botEnterAt('$door')" }

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 8

"=== 1. start: host on the driver seat, every other seat taken by a device -> the client is put out"
$tab = Seats $hd; $cs = Self $cd; $ct = Seats $cd
Check "host drives (seat 1)" ($tab.host_seat -eq '1' -and $tab.driver -eq 'host') $tab.raw
Check "devices: ARC in front, base fuel tank back left, base battery back right" ($tab.devices -match '2:ARC' -and $tab.devices -match '3:IA_Attach_Fuel' -and $tab.devices -match '4:IA_Attach_Battery') $tab.devices
Check "client found no free seat and is out of the car" ($cs.in_car -eq 'False' -and [int]$ct.denied -ge 1 -and $tab.client_seat -eq '0') "client: $($cs.raw) | $($ct.raw)"

"=== 2. the client takes the battery off the back-right frame"
"  client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)")
Start-Sleep 3
$tab = Seats $hd
Check "back-right frame empty, battery in the host's trunk" ($tab.devices -match '4:-$' -and $tab.trunk -match 'IA_Attach_Battery') "$($tab.devices) trunk=$($tab.trunk) last=$($tab.last_device)"

"=== 3. the client gets in at the rear right door -> back right seat"
"  client: " + (In $cd 'RR')
Start-Sleep 4
SeatCheck "rear right door:" 1 4

"=== 4. the client gets in at the rear left door (fuel tank there) -> nearest free seat (back right)"
"  client: " + (Out $cd); Start-Sleep 3
"  client: " + (In $cd 'RL')
Start-Sleep 4
SeatCheck "rear left door:" 1 4

"=== 5. swap without a key: both get out, the client takes the driver door, the host the front right"
"  host: " + (Out $hd) + " | client: " + (Out $cd); Start-Sleep 3
"  client: " + (In $cd 'FL'); Start-Sleep 4
"  host: " + (In $hd 'FR'); Start-Sleep 4
SeatCheck "client drives:" 4 1
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = client" ($hw.driver -eq 'client' -and $cw.driver -eq 'client') "host: $($hw.raw) | client: $($cw.raw)"
$before = $hw.car
"  client: " + (Send $cd "return CoopPlayers.botInput(5, 1.0, 0.2)")
Start-Sleep 7
$hw = Wheel $hd
$moved = Dist $before $hw.car
Check "the client drives the host's car from the driver seat (>= 300 units)" ($moved -ge 300) "moved $moved | $($hw.raw)"
Start-Sleep 6

"=== 6. back: the client gets out, the host moves to the driver seat, the client gets in at the rear right"
"  client: " + (Out $cd); Start-Sleep 3
"  host: " + (Out $hd); Start-Sleep 3
"  host: " + (In $hd 'FL'); Start-Sleep 4
"  client: " + (In $cd 'RR'); Start-Sleep 4
SeatCheck "host drives again:" 1 4
$hw = Wheel $hd; $cw = Wheel $cd
Check "both sides: driver = host" ($hw.driver -eq 'host' -and $cw.driver -eq 'host') "host: $($hw.raw) | client: $($cw.raw)"

"host seats: " + (Send $hd "return CoopPlayers.seatInfo()")
"client seats: " + (Send $cd "return CoopPlayers.seatInfo()")
"host players: " + (Send $hd "return CoopPlayers.report()")
"client players: " + (Send $cd "return CoopPlayers.report()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
