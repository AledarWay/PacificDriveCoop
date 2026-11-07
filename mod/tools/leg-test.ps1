# Automated "the host drives on to the next leg" test (guest mode, two headless instances over the relays).
# Host: a copy of the owner's save further into the story (in a run, with next legs revealed). Guest: own new game,
# joins the host's zone. The host travels to a revealed next leg (the game's own BaseRouteState:TravelTo, what the
# gate ends in); its TravelTo hook announces "L leg"; on arrival the host publishes the new zone (spawn list +
# descriptor) like at the join.
#   -Scenario seated: the guest sits in the host's car -> follows by itself (Run.follow), imports the new zone
#   -Scenario behind: the guest stands outside -> left behind = failed run (the game's death, home)
param([switch]$Keep, [ValidateSet('seated', 'behind')] [string]$Scenario = 'seated', [int]$GuestSeed = 777,
    [string]$HostSave = "C:\PacificDriveCoop\local\advsave\odsave9.sav", [int]$HostSlot = 9)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"; $cu = "$inst\client\userdir"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
$snapSrc = Get-Content "$t\cmds\snapshot.lua" -Raw
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Snap($dir, $name) { Send $dir ($snapSrc.Replace('C:/PacificDriveCoop/local/coopdev/snapshot.txt', "$(P $dir)/$name")) }
function WaitStable($dir, [int]$MinSec = 30, [int]$MaxSec = 180) {
    $t0 = Get-Date; $last = ''; $same = 0
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        $r = (& "$t\send.ps1" -File "$t\cmds\count.lua" -Dir $dir -TimeoutSec 30) -join ' '
        $cur = if ($r -match 'OK (total=\S+)') { $Matches[1] } else { '?' }
        Add-Content "$inst\leg-polls.log" "$(Get-Date -f HH:mm:ss) $(Split-Path (Split-Path $dir) -Leaf) $($r -replace '.*OK ', '' -replace '=== end', '')"
        if ($cur -eq $last -and $cur -ne '?') { $same++ } else { $same = 0; $last = $cur }
        # and the zone generator done (its markers / origin candidates gone: CoopSync.zoneReady)
        if ($same -ge 3 -and $r -match 'ready=true' -and ((Get-Date) - $t0).TotalSeconds -ge $MinSec) { return "stable after $([int]((Get-Date) - $t0).TotalSeconds) s: $cur" }
        Start-Sleep 5
    }
    "NOT stable after $MaxSec s: $last ($($r -replace '.*(ready=\S+ markers=\S+ origin=\S+).*', '$1'))"
}
function WaitWorld($dir, [int]$state, [string]$notWorld, [int]$TimeoutSec = 300) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        $s = KV (Send $dir "$run return Run.where()")
        if ($s.state -eq "$state" -and $s.world -and $s.world -ne $notWorld) { return $s }
        Start-Sleep 5
    }
    KV (Send $dir "$run return Run.where()")
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
if (Test-Path "$cu\Saved\SaveGames") { Remove-Item "$cu\Saved\SaveGames\*" -Force -ErrorAction SilentlyContinue }
Remove-Item "$cu\Saved\CoopSyncGuestCar.tsv*" -Force -ErrorAction SilentlyContinue
& "$t\deploy.ps1"

"=== 1. host in its run (owner's save copy), the guest joins ($Scenario)"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed -HostSave $HostSave -HostSlot $HostSlot
$log | Select-String 'join|arrived|host is at|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
$h0 = KV (Send $hd "$run return Run.where()"); $g0 = KV (Send $cd "$run return Run.where()")
Check "the guest joined the host's map" ($g0.state -eq '5' -and $g0.world -eq $h0.world) "host $($h0.raw) | guest $($g0.raw)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 8
if ($Scenario -eq 'seated') {
    # free a back seat if a device is on it (the owner's car may carry upgrades there), get in at its door
    $hs = KV (Send $hd "return CoopPlayers.seatInfo()")
    "  host seats: $($hs.raw)"
    $seat = if ($hs.devices -match '4:-(,|$)') { 4 } elseif ($hs.devices -match '3:-(,|$)') { 3 } else { 4 }
    if (-not ($hs.devices -match "${seat}:-(,|$)")) { "  client: " + (Send $cd "return CoopPlayers.removeSeatDevice($seat)"); Start-Sleep 3 }
    $door = if ($seat -eq 4) { 'RR' } else { 'RL' }
    "  client: " + (Send $cd "return CoopPlayers.botEnterAt('$door')"); Start-Sleep 5
} else {
    "  client: " + (Send $cd "return CoopPlayers.botExitCar()"); Start-Sleep 3
}
$self = KV (Send $cd "return CoopPlayers.selfInfo()")
Check "the guest is $(if ($Scenario -eq 'seated') { 'in the host''s car' } else { 'outside the car' })" ($self.in_car -eq $(if ($Scenario -eq 'seated') { 'True' } else { 'False' })) $self.raw

"=== 2. the host drives on to a revealed next leg"
"  host: " + (Send $hd "EXITS_GO = 'travelto' EXITS_MAP = 'keep' EXITS_ANY_LEG = nil return dofile('$(P $t)/cmds/exits-probe.lua')")
$hl = KV (Send $hd "return CoopPlayers.leaveInfo()")
$h1 = WaitWorld $hd 5 $h0.world
Check "the host arrived on another map" ($h1.state -eq '5' -and $h1.world -ne $h0.world) $h1.raw
Check "the host announced leaving for the next leg" ($hl.leave_sent -eq 'leg') $hl.raw
$ob = "$(P $hchan)/outbox"
# export once the zone is generated; the generator was seen to run a second wave after looking finished, so
# check again after the snapshot and redo the export if the zone changed meanwhile
foreach ($try in 1..3) {
    "  host [$(Get-Date -f HH:mm:ss)]: " + (WaitStable $hd)
    "  host export (scoring): " + (Send $hd "$lib return CoopSync.export('$(P $hd)/spawnlist2.tsv')")
    "  host snapshot: " + (Snap $hd "snapshot2.txt")
    $after = (& "$t\send.ps1" -File "$t\cmds\count.lua" -Dir $hd -TimeoutSec 30) -join ' '
    $markers = (Get-Content "$hd\snapshot2.txt" | Where-Object { $_ -match '^BP_ClumpedSpawnMarker_' }).Count
    "  host after export [$(Get-Date -f HH:mm:ss)]: $($after -replace '.*OK ', '' -replace '=== end', '') snapshot_markers=$markers"
    if ($after -match 'ready=true' -and $markers -eq 0) { break }
    "  host: the zone changed after the export (try $try), waiting again"
}
# publish the new zone like at the join (tmp + rename so the relay never sends half a file)
"  host spawn list -> outbox: " + (Send $hd "$lib local n = CoopSync.export('$ob/host-spawnlist2.tsv.tmp') os.rename('$ob/host-spawnlist2.tsv.tmp', '$ob/host-spawnlist2.tsv') return n")
"  host loot: " + (Send $hd "return CoopSync.exportLoot('$(P $hd)/loot2.tsv')")
"  host descriptor -> outbox: " + (Send $hd "$run return Run.publish('$ob/host-run.txt')")

if ($Scenario -eq 'seated') {
    "=== 3. the guest follows by itself"
    $g1 = WaitWorld $cd 5 $g0.world
    Check "the guest followed the host to the new map" ($g1.state -eq '5' -and $g1.world -eq $h1.world -and $g1.seed -eq "$GuestSeed") "guest $($g1.raw) | host $($h1.raw)"
    "  guest: " + (WaitStable $cd)
    $list = "$cchan\inbox\host-spawnlist2.tsv"
    $t0 = Get-Date; while (-not (Test-Path $list) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 1 }
    "  client snapshot before: " + (Snap $cd "snapshot2-before.txt")
    "  client import: " + (Send $cd "$lib return table.concat({CoopSync.import('$(P $list)')}, ' | ')")
    "  client snapshot after import: " + (Snap $cd "snapshot2-after.txt")
    Start-Sleep 10
    "  client cleanup: " + (Send $cd "return CoopSync.cleanup()")
    "  client snapshot after cleanup: " + (Snap $cd "snapshot2-cleanup.txt")
    "  client loot: " + (Send $cd "return CoopSync.exportLoot('$(P $cd)/loot2.tsv')")
    $score = & "$t\sync-score.ps1" -SpawnList "$hd\spawnlist2.tsv" -HostSnap "$hd\snapshot2.txt" -ClientSnap "$cd\snapshot2-after.txt" -ExtraSnap "$cd\snapshot2-cleanup.txt" -ExtraTol 2
    $score | Select-Object -Last 2
    # keep this run's scoring files for miss-report.ps1 -Dir (later runs overwrite the instance folders)
    $keepDir = "$inst\leg-last"; New-Item -ItemType Directory -Force -Path "$keepDir\host\coopdev", "$keepDir\client\coopdev" | Out-Null
    Copy-Item "$hd\spawnlist2.tsv", "$hd\snapshot2.txt", "$hd\loot2.tsv" "$keepDir\host\coopdev" -Force
    Copy-Item "$cd\snapshot2-*.txt", "$cd\loot2.tsv" "$keepDir\client\coopdev" -Force
    Check "spawn replication in the new zone" (($score | Select-Object -Last 1) -eq 'PASS') (($score | Select-Object -Last 2) -join ' / ')
    $loot = & "$t\loot-score.ps1" -HostLoot "$hd\loot2.tsv" -ClientLoot "$cd\loot2.tsv" -Show 3
    $loot | Select-Object -Last 2
    Check "loot replication in the new zone" (($loot | Select-Object -Last 1) -eq 'LOOT PASS') (($loot | Select-Object -Last 2) -join ' / ')
    "  sync again: host " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)', '$(P $hd)/spawnlist2.tsv') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')") + " | client " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P $list)') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
    Start-Sleep 8
    $hp = KV (Send $hd "return CoopPlayers.report()"); $cp = KV (Send $cd "return CoopPlayers.report()")
    Check "players see each other again in the new zone" ($hp.puppet -eq 'yes' -and $cp.puppet -eq 'yes') "host: $($hp.raw) | client: $($cp.raw)"
    # live sync from the export on: what the zone did after the export (minefields coming alive) reaches the client
    Start-Sleep 20
    "  host export (live): " + (Send $hd "$lib return CoopSync.export('$(P $hd)/spawnlist3.tsv')")
    "  host snapshot (live): " + (Snap $hd "snapshot3.txt"); "  client snapshot (live): " + (Snap $cd "snapshot3.txt")
    $live = & "$t\sync-score.ps1" -SpawnList "$hd\spawnlist3.tsv" -HostSnap "$hd\snapshot3.txt" -ClientSnap "$cd\snapshot3.txt" -ExtraSnap "$cd\snapshot3.txt" -ExtraTol 2
    "  state sync: " + (Send $hd "return CoopSyncState.report()")
    Check "the zone still matches with live sync (20 s later)" (($live | Select-Object -Last 1) -eq 'PASS') (($live | Select-Object -Last 2) -join ' / ')
} else {
    "=== 3. the guest was left behind"
    $g1 = WaitWorld $cd 4 $g0.world
    Check "the guest is home in its own garage (failed run)" ($g1.state -eq '4' -and $g1.world -eq 'RB_Garage' -and $g1.seed -eq "$GuestSeed") $g1.raw
}

# a failed run keeps its scoring files (leg-last is overwritten by the next run)
if ($script:fail -gt 0 -and (Test-Path "$inst\leg-last")) { $keepFail = "$inst\leg-fail-$(Get-Date -f MMdd-HHmmss)"; Copy-Item "$inst\leg-last" $keepFail -Recurse -Force; Copy-Item "$cd\loot2.tsv" "$keepFail\client\coopdev\loot2-final.tsv" -Force -ErrorAction SilentlyContinue; "  failed run kept in $keepFail" }
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
