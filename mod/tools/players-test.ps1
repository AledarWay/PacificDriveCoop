# Automated players + car sync test over the network relays (two headless instances on this PC).
# Phases: host drives the car along a line; host walks; client walks. Both sides trace positions.
param([switch]$Keep, [int]$DelayMs = 0, [int]$JitterMs = 0)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' '
}
function P($p) { $p.Replace('\', '/') }
function Now($dir) { [long]((Send $dir "return CoopPlayers.nowMs()") -replace '^OK ', '') }

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -DelayMs $DelayMs -JitterMs $JitterMs | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
$htr = "$hd\players-trace.tsv"; $ctr = "$cd\players-trace.tsv"
Set-Content $htr "" -Encoding ascii; Set-Content $ctr "" -Encoding ascii

"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') CoopPlayers.trace('$(P $htr)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') CoopPlayers.trace('$(P $ctr)') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 5
# a new game's car has no free passenger seat (ARC in front, base fuel tank / battery on the back frames): the
# client takes the battery off and gets in at the rear right door, as a guest would
"client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)"); Start-Sleep 3
"client: " + (Send $cd "return CoopPlayers.botEnterAt('RR')"); Start-Sleep 5
"client self: " + (Send $cd "return CoopPlayers.selfInfo()")
"host players: " + (Send $hd "return CoopPlayers.report()")
"client players: " + (Send $cd "return CoopPlayers.report()")

$phases = @()
# bots use the game's own mechanics: car physics throttle, "Exit Car", character movement input
function Phase($name, $dir, [string]$lua, [int]$seconds, [int]$settle) {
    $t0 = Now $dir
    "--- ${name}: " + (Send $dir "return $lua")
    Start-Sleep -Seconds ($seconds + $settle)
    $t1 = Now $dir
    $script:phases += [pscustomobject]@{ Name = $name; From = $t0; To = $t1 }
}
Phase "car (host drives)" $hd "CoopPlayers.botDrive(6)" 6 4
"--- both leave the car: host " + (Send $hd "return CoopPlayers.botExitCar()") + " | client " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 5
Phase "host walks" $hd "CoopPlayers.botWalk(5)" 5 4
Phase "client walks" $cd "CoopPlayers.botWalk(5)" 5 4

"host players: " + (Send $hd "return CoopPlayers.report()")
"client players: " + (Send $cd "return CoopPlayers.report()")
"host state: " + (Send $hd "return CoopSyncState.report()")
"client state: " + (Send $cd "return CoopSyncState.report()")
"relay: " + (Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue)

"host profile: " + (Send $hd "return CoopSyncState.profile()")
"client profile: " + (Send $cd "return CoopSyncState.profile()")
"host seats: " + (Send $hd "return CoopPlayers.seatInfo()")
"client seats: " + (Send $cd "return CoopPlayers.seatInfo()")
"client self: " + (Send $cd "return CoopPlayers.selfInfo()")
"=== scores"
$p = $phases[0]; & "$t\players-score.ps1" -Name "client car follows host car" -OwnerTrace $htr -OwnerKind car -ObsTrace $ctr -ObsKind carcopy -From $p.From -To $p.To
& "$t\players-score.ps1" -Name "host player (in car) on client" -OwnerTrace $htr -OwnerKind self -ObsTrace $ctr -ObsKind puppet -From $p.From -To $p.To
$p = $phases[1]; & "$t\players-score.ps1" -Name "host player walking, seen on client" -OwnerTrace $htr -OwnerKind self -ObsTrace $ctr -ObsKind puppet -From $p.From -To $p.To
$p = $phases[2]; & "$t\players-score.ps1" -Name "client player walking, seen on host" -OwnerTrace $ctr -OwnerKind self -ObsTrace $htr -ObsKind puppet -From $p.From -To $p.To

if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
