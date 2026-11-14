# Automated test of the live loot (statesync "Live", owner 2026-10-27: when the other player takes something or puts
# something in, the loot must change at once). Two headless instances over the relays; how long each change takes to
# show on the other side is measured (polled every ~0.3 s).
#   1. the host takes an item out of a container -> gone in the guest's copy
#   2. the guest takes an item out -> gone in the host's container, the guest keeps it
#   3. the guest puts it back -> in the host's container, still in the guest's (not wiped by the host's update)
#   4. the host puts its item in -> in the guest's copy
#   5. the guest picks a world item up -> gone in the host's world
param([switch]$Keep, [int]$LimitMs = 2000)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function Share($dir, [string]$role, [string]$code) { Send $dir "LS_ROLE = '$role' $code return dofile('$(P $t)/cmds/loot-share.lua')" }
function Count($dir, $arch) { [int](Share $dir '' "LS_OP = 'count' LS_ARCH = '$arch'") }
function InCount($dir, $role, $key, $arch) { [int](Share $dir $role "LS_OP = 'incount' LS_KEY = '$key' LS_ARCH = '$arch'") }
# ms until cond (a script block over nothing) holds, or -1 after 8 s
function Until([scriptblock]$cond) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000) { if (& $cond) { return [int]$sw.ElapsedMilliseconds }; Start-Sleep -Milliseconds 150 }
    -1
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 10

"=== 1. the host takes an item out of a container"
$ck, $carch = (Share $cd 'client' "LS_OP = 'takeable'") -split "`t"
"  container: $ck ($carch)"
$g0 = InCount $cd 'client' $ck $carch
"  host: " + (Share $hd 'host' "LS_OP = 'take' LS_KEY = '$ck' LS_ARCH = '$carch'")
$ms = Until { (InCount $cd 'client' $ck $carch) -eq $g0 - 1 }
Check "guest: gone from its copy of the container (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "before=$g0 after $ms ms"

"=== 2. the guest takes an item out"
$ck2, $carch2 = (Share $cd 'client' "LS_OP = 'takeable'") -split "`t"
"  container: $ck2 ($carch2)"
$h0 = InCount $hd 'host' $ck2 $carch2; $c0 = Count $cd $carch2
"  guest: " + (Share $cd 'client' "LS_OP = 'take' LS_KEY = '$ck2' LS_ARCH = '$carch2'")
$ms = Until { (InCount $hd 'host' $ck2 $carch2) -eq $h0 - 1 }
Start-Sleep 2
$c1 = Count $cd $carch2
Check "host: gone from its container (<= $LimitMs ms), the guest keeps it" ($ms -ge 0 -and $ms -le $LimitMs -and $c1 -eq $c0 + 1) "host before=$h0 after $ms ms; guest carries $c0 -> $c1"

"=== 3. the guest puts it back"
$g0 = InCount $cd 'client' $ck2 $carch2; $h0 = InCount $hd 'host' $ck2 $carch2
"  guest: " + (Share $cd 'client' "LS_OP = 'put' LS_KEY = '$ck2' LS_ARCH = '$carch2'")
$ms = Until { (InCount $hd 'host' $ck2 $carch2) -eq $h0 + 1 }
Start-Sleep 4
$g1 = InCount $cd 'client' $ck2 $carch2; $c2 = Count $cd $carch2; $h1 = InCount $hd 'host' $ck2 $carch2
Check "host: in its container (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "host $h0 -> after $ms ms"
Check "guest: still in its copy, gone from its inventory, no duplicate on the host" ($g1 -eq $g0 + 1 -and $c2 -eq $c1 - 1 -and $h1 -eq $h0 + 1) "guest container $g0 -> $g1, carries $c1 -> $c2, host $h0 -> $h1"

"=== 4. the host puts its item in"
$g0 = InCount $cd 'client' $ck $carch
"  host: " + (Share $hd 'host' "LS_OP = 'put' LS_KEY = '$ck' LS_ARCH = '$carch'")
$ms = Until { (InCount $cd 'client' $ck $carch) -eq $g0 + 1 }
Check "guest: in its copy of the container (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "before=$g0 after $ms ms"

"=== 5. the guest picks a world item up"
$k, $arch = (Share $cd 'client' "LS_OP = 'pickable'") -split "`t"
"  item: $k ($arch)"
"  guest: " + (Share $cd 'client' "LS_OP = 'pick' LS_KEY = '$k'")
$ms = Until { (Share $hd 'host' "LS_OP = 'exists' LS_KEY = '$k'") -eq 'no' }
Check "host: gone from its world (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "after $ms ms"

# (owner's alpha 21 item 8: "pickups are late on the guest - in that lag an item can be picked up again (duplicated);
# dropped items appear late". The host's pick-up went with its next pass, a dropped item with the next root scan, 2 s)
"=== 5b. the host picks a world item up"
$k2, $arch2 = (Share $cd 'client' "LS_OP = 'pickable'") -split "`t"
"  item: $k2 ($arch2)"
"  host: " + (Share $hd 'host' "LS_OP = 'pick' LS_KEY = '$k2'")
$ms = Until { (Share $cd 'client' "LS_OP = 'exists' LS_KEY = '$k2'") -eq 'no' }
Check "guest: gone from its world (<= 1000 ms)" ($ms -ge 0 -and $ms -le 1000) "after $ms ms"
"=== 5c. the host drops it"
$dr = Share $hd 'host' "LS_OP = 'drop' LS_ARCH = '$arch2'"
"  host: $dr"
if ($dr -match 'at (-?\d+),(-?\d+),(-?\d+)') {
    $x, $y, $z = $Matches[1], $Matches[2], $Matches[3]
    $ms = Until { (Share $cd 'client' "LS_OP = 'near' LS_ARCH = '$arch2' LS_X = $x LS_Y = $y LS_Z = $z") -ne 'none' }
    Check "guest: the host's dropped item on its ground (<= 1000 ms)" ($ms -ge 0 -and $ms -le 1000) "after $ms ms"
} else { Check "guest: the host's dropped item on its ground (<= 1000 ms)" $false "drop: $dr" }
"=== 5d. the guest drops the one it picked"
$dr = Share $cd 'client' "LS_OP = 'drop' LS_ARCH = '$arch'"
"  guest: $dr"
if ($dr -match 'at (-?\d+),(-?\d+),(-?\d+)') {
    $x, $y, $z = $Matches[1], $Matches[2], $Matches[3]
    $ms = Until { (Share $hd 'host' "LS_OP = 'near' LS_ARCH = '$arch' LS_X = $x LS_Y = $y LS_Z = $z") -ne 'none' }
    Check "host: the guest's dropped item on its ground (<= 1000 ms)" ($ms -ge 0 -and $ms -le 1000) "after $ms ms"
} else { Check "host: the guest's dropped item on its ground (<= 1000 ms)" $false "drop: $dr" }

# a wreck's trunk (owner, alpha 16: the host's changes there reached the guest, the guest's never reached the host -
# the trunk's container belongs to the trunk part's item; this test only had lootable containers)
function Sub($dir, $role, [string]$op, $key, $sub, $arch) { Share $dir $role "LS_OP = '$op' LS_KEY = '$key' LS_SUB = '$sub' LS_ARCH = '$arch'" }
$tk, $tsub, $tarch = (Share $cd 'client' "LS_OP = 'trunkable'") -split "`t"
"=== 6. a wreck's trunk: $tk $tsub ($tarch)"
if ($tk -and $tk -ne 'none') {
    $h0 = [int](Sub $hd 'host' 'subcount' $tk $tsub $tarch); $g0 = [int](Sub $cd 'client' 'subcount' $tk $tsub $tarch)
    "  guest: " + (Sub $cd 'client' 'subtake' $tk $tsub $tarch)
    $ms = Until { [int](Sub $hd 'host' 'subcount' $tk $tsub $tarch) -eq $h0 - 1 }
    Check "the guest takes from a wreck's trunk -> gone from the host's (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "host $h0 -> after $ms ms (guest had $g0)"
    Start-Sleep 2
    "  guest: " + (Sub $cd 'client' 'subput' $tk $tsub $tarch)
    $ms = Until { [int](Sub $hd 'host' 'subcount' $tk $tsub $tarch) -eq $h0 }
    Start-Sleep 3
    $g1 = [int](Sub $cd 'client' 'subcount' $tk $tsub $tarch); $h1 = [int](Sub $hd 'host' 'subcount' $tk $tsub $tarch)
    Check "the guest puts it back -> in the host's trunk, one copy on each side (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs -and $g1 -eq $g0 -and $h1 -eq $h0) "after $ms ms; host $h1, guest $g1 (before $h0 / $g0)"
    "  host: " + (Sub $hd 'host' 'subtake' $tk $tsub $tarch)
    $ms = Until { [int](Sub $cd 'client' 'subcount' $tk $tsub $tarch) -eq $g0 - 1 }
    Check "the host takes from it -> gone from the guest's (<= $LimitMs ms)" ($ms -ge 0 -and $ms -le $LimitMs) "after $ms ms"
} else { Check "a wreck with a filled trunk in the zone" $false "none mapped" }

# a wreck's locked trunk pried open (owner, alpha 16: "I pried it open with the crowbar, the friend's stayed shut"): the
# trunk part's state (0 locked, 2 open) on both sides, either side opening it
"=== 7. wrecks' locked trunks opened: one by the host, one by the guest"
$l1k, $l1s = (Share $cd 'client' "LS_OP = 'lockedtrunk' LS_N = 1") -split "`t"
$l2k, $l2s = (Share $cd 'client' "LS_OP = 'lockedtrunk' LS_N = 2") -split "`t"
if ($l1k -and $l1k -ne 'none' -and $l2k -and $l2k -ne 'none') {
    "  host opens: " + (Sub $hd 'host' 'opentrunk' $l1k $l1s '')
    $ms = Until { (Sub $cd 'client' 'trunkstate' $l1k $l1s '') -eq '2' }
    Check "the host's pried trunk is open on the guest's side too (<= 3000 ms)" ($ms -ge 0 -and $ms -le 3000) "after $ms ms"
    "  guest opens: " + (Sub $cd 'client' 'opentrunk' $l2k $l2s '')
    $ms = Until { (Sub $hd 'host' 'trunkstate' $l2k $l2s '') -eq '2' }
    Start-Sleep 7
    $g2 = Sub $cd 'client' 'trunkstate' $l2k $l2s ''
    Check "the guest's pried trunk is open on the host's side, and stays open on the guest's (<= 3000 ms)" ($ms -ge 0 -and $ms -le 3000 -and $g2 -eq '2') "after $ms ms; guest's now $g2"
} else { Check "two wrecks with locked trunks in the zone" $false "found: $l1k / $l2k" }

# the world's doors (owner, alpha 16: "a container's door open on my side, shut on the friend's"): opened by either side
"=== 8. doors of buildings / containers: one opened by the host, one by the guest"
# (two shut doors both sides have loaded - the nearest the host's player first; a zone's doors can all be far off in an
# underground site the guest has not streamed in: reference saves 2026-11-14)
$both = @()
for ($n = 1; $n -le 12 -and $both.Count -lt 2; $n++) {
    $k = Share $hd 'host' "LS_OP = 'shutdoor' LS_N = $n"
    if ($k -eq 'none') { break }
    if ((Share $cd 'client' "LS_OP = 'doorstate' LS_KEY = '$k'") -eq '0') { $both += $k }
}
$d1, $d2 = if ($both.Count -ge 2) { $both[0], $both[1] } else { 'none', 'none' }
if ($d1 -ne 'none' -and $d2 -ne 'none') {
    "  host: " + (Share $hd 'host' "LS_OP = 'setdoor' LS_KEY = '$d1' LS_STATE = 2")
    $ms = Until { (Share $cd 'client' "LS_OP = 'doorstate' LS_KEY = '$d1'") -eq '2' }
    Check "the host's opened door is open on the guest's side (<= 3000 ms)" ($ms -ge 0 -and $ms -le 3000) "after $ms ms"
    "  guest: " + (Share $cd 'client' "LS_OP = 'setdoor' LS_KEY = '$d2' LS_STATE = 2")
    $ms = Until { (Share $hd 'host' "LS_OP = 'doorstate' LS_KEY = '$d2'") -eq '2' }
    Start-Sleep 3
    $g2 = Share $cd 'client' "LS_OP = 'doorstate' LS_KEY = '$d2'"
    Check "the guest's opened door is open on the host's side, still open on its own (<= 3000 ms)" ($ms -ge 0 -and $ms -le 3000 -and $g2 -eq '2') "after $ms ms; guest's $g2"
} else { "  (no two shut doors loaded on both sides near the players: skipped) $($both -join ' ')" }

$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
"host state: $hr"
"client state: $cr"
Check "no errors on either side" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') "-"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
