# Automated shared-loot test over the network relays (two headless instances on this PC): one unit of loot
# goes to one player only (contested pick-ups and container takes are decided by the host; the side that
# lost gives its local copy back), and items can be handed over (the client drops one, the host picks it up).
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
# (not "LS": that is PowerShell's alias of Get-ChildItem; not $args: an automatic variable)
function Share($dir, [string]$role, [string]$code) { Send $dir "LS_ROLE = '$role' $code return dofile('$(P $t)/cmds/loot-share.lua')" }
function Count($dir, $arch) { [int](Share $dir '' "LS_OP = 'count' LS_ARCH = '$arch'") }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 8

"=== 1. both pick up the same world item at the same moment"
$k, $arch = (Share $cd 'client' "LS_OP = 'pickable'") -split "`t"
"  item: $k ($arch)"
$h0 = Count $hd $arch; $c0 = Count $cd $arch
"  client: " + (Share $cd 'client' "LS_OP = 'pick' LS_KEY = '$k'")
"  host:   " + (Share $hd 'host' "LS_OP = 'pick' LS_KEY = '$k'")
Start-Sleep 8
$h1 = Count $hd $arch; $c1 = Count $cd $arch
Check "exactly one of the two got it (either may win: the host decides whichever comes first)" ((($h1 - $h0) + ($c1 - $c0)) -eq 1 -and ($h1 - $h0) -ge 0 -and ($c1 - $c0) -ge 0) "host $h0 -> $h1, client $c0 -> $c1 | client: $(Send $cd 'return CoopSyncState.report()')"
Check "the item is gone from both worlds" ((Share $hd 'host' "LS_OP = 'exists' LS_KEY = '$k'") -eq 'no' -and (Share $cd 'client' "LS_OP = 'exists' LS_KEY = '$k'") -eq 'no') "host/client"

"=== 2. both take the only item of a kind out of the same container"
$ck, $carch = (Share $cd 'client' "LS_OP = 'takeable'") -split "`t"
"  container: $ck ($carch)"
$h0 = Count $hd $carch; $c0 = Count $cd $carch
"  client: " + (Share $cd 'client' "LS_OP = 'take' LS_KEY = '$ck' LS_ARCH = '$carch'")
"  host:   " + (Share $hd 'host' "LS_OP = 'take' LS_KEY = '$ck' LS_ARCH = '$carch'")
Start-Sleep 10
$h1 = Count $hd $carch; $c1 = Count $cd $carch
Check "exactly one of the two got it (either may win: the host decides whichever comes first)" ((($h1 - $h0) + ($c1 - $c0)) -eq 1 -and ($h1 - $h0) -ge 0 -and ($c1 - $c0) -ge 0) "host $h0 -> $h1, client $c0 -> $c1 | client: $(Send $cd 'return CoopSyncState.report()')"

"=== 3. the client drops an item it carries"
# something the client carries: pick a fresh world item first (uncontested)
$k2, $arch2 = (Share $cd 'client' "LS_OP = 'pickable'") -split "`t"
"  client picks: " + (Share $cd 'client' "LS_OP = 'pick' LS_KEY = '$k2'")
Start-Sleep 6
$c0 = Count $cd $arch2; $h0 = Count $hd $arch2
$drop = Share $cd 'client' "LS_OP = 'drop' LS_ARCH = '$arch2'"
"  client: $drop"
Start-Sleep 8
$at = if ($drop -match 'dropped at (-?\d+),(-?\d+),(-?\d+)') { @($Matches[1], $Matches[2], $Matches[3]) } else { @(0, 0, 0) }
$onHost = Share $hd 'host' "LS_OP = 'near' LS_ARCH = '$arch2' LS_X = $($at[0]) LS_Y = $($at[1]) LS_Z = $($at[2])"
Check "the dropped item is in the host's world where the client dropped it" ($onHost -ne 'none') "host item: $onHost | host: $(Send $hd 'return CoopSyncState.report()')"
$crep = Send $cd 'return CoopSyncState.report()'
Check "the client asked once and adopted the host's item (no duplicate on its side)" ($crep -match 'rq_DROP=1' -and $crep -match 'ap_S_adopted=') $crep

"=== 4. the host picks the dropped item up (handed over)"
"  host: " + (Share $hd 'host' "LS_OP = 'pick' LS_KEY = '$onHost'")
Start-Sleep 8
$h1 = Count $hd $arch2; $c1 = Count $cd $arch2
Check "the host got the item the client dropped (host +1, client -1 overall)" ($h1 -eq $h0 + 1 -and $c1 -eq $c0 - 1) "host $h0 -> $h1, client $c0 -> $c1"
$cNear = Share $cd 'client' "LS_OP = 'near' LS_ARCH = '$arch2' LS_X = $($at[0]) LS_Y = $($at[1]) LS_Z = $($at[2])"
Check "and it is gone from the client's world too" ($cNear -eq 'none') "client item: $cNear"

"host state: " + (Send $hd "return CoopSyncState.report()")
"client state: " + (Send $cd "return CoopSyncState.report()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
