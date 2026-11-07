# Automated interaction-sync test on two headless instances.
# 1) sync-test.ps1 (load-time spawn + loot replication), instances kept running
# 2) start state sync on host and client
# 3) host bot acts (open with roll, take, pick up, detach) -> client must match the host
# 4) client bot acts on other targets -> requests -> host decides -> both must match
# -Net: all sync traffic goes through two TCP relays (see sync-test.ps1 -Net); -DelayMs/-JitterMs emulate latency
param([switch]$Keep, [switch]$Net, [int]$DelayMs = 0, [int]$JitterMs = 0)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"; $chan = "$inst\channel"
New-Item -ItemType Directory -Force $chan | Out-Null
# always reload: a stale module from an earlier command would otherwise stay in the Lua state
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
$libKeep = "CoopSync = CoopSync or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }
}
function P($dir) { $dir.Replace('\', '/') }
$snapSrc = Get-Content "$t\cmds\snapshot.lua" -Raw
function Snap($dir, $name) { Send $dir ($snapSrc.Replace('C:/PacificDriveCoop/local/coopdev/snapshot.txt', "$(P $dir)/$name")) }
function Score($tag) {
    "--- [$tag] host export: " + (Send $hd "return CoopSync.export('$(P $hd)/spawnlist-$tag.tsv')")
    Snap $hd "snapshot-$tag.txt" | Out-Null; Snap $cd "snapshot-$tag.txt" | Out-Null
    Send $hd "return CoopSync.exportLoot('$(P $hd)/loot-$tag.tsv')" | Out-Null
    Send $cd "return CoopSync.exportLoot('$(P $cd)/loot-$tag.tsv')" | Out-Null
    $score = & "$t\sync-score.ps1" -SpawnList "$hd\spawnlist-$tag.tsv" -HostSnap "$hd\snapshot-$tag.txt" -ClientSnap "$cd\snapshot-$tag.txt" -ShowMisses
    $score
    if ($score -match '^FAIL') {
        # which props drifted, and why (physics still on? no sync record?)
        foreach ($cls in @($score | Select-String 'miss \w+\s+(\S+) at' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)) {
            "  diag host   ${cls}: " + ((Send $hd "DIAG_CLASS = '$cls' return dofile('$(P $t)/cmds/cone-diag.lua')") -join ' ')
            "  diag client ${cls}: " + ((Send $cd "DIAG_CLASS = '$cls' return dofile('$(P $t)/cmds/cone-diag.lua')") -join ' ')
        }
    }
    & "$t\loot-score.ps1" -HostLoot "$hd\loot-$tag.tsv" -ClientLoot "$cd\loot-$tag.tsv" -Show 6
}

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net:$Net -DelayMs $DelayMs -JitterMs $JitterMs | Select-String 'net:|network|import:|cleanup|matched on client|^PASS|^FAIL|LOOT|identical'

"=== start state sync"
if ($Net) {
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    $hchan = $sess.hchan; $cchan = $sess.cchan; $hostList = "$cchan\inbox\host-spawnlist.tsv"
} else { $hchan = $chan; $cchan = $chan; $hostList = "$cd\host-spawnlist.tsv" }
"host: " + (Send $hd "$lib CoopSyncDebug = '$(P $hd)/sync-crumbs.txt' return CoopSyncState.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncDebug = '$(P $cd)/sync-crumbs.txt' return CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P $hostList)')")
Start-Sleep 4
"host report: " + (Send $hd "return CoopSyncState.report()")
"client report: " + (Send $cd "return CoopSyncState.report()")
if ($Net) { "relay: " + (Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue) }
Score "synced"

"=== host bot acts"
"host bot: " + (Send $hd "$libKeep BOT_SKIP = 0 BOT_ONLY = nil $(Get-Content "$t\cmds\bot-actions.lua" -Raw)")
Start-Sleep 6
"host report: " + (Send $hd "return CoopSyncState.report()")
"client report: " + (Send $cd "return CoopSyncState.report()")
if ($Net) { "relay: " + (Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue) }
Score "after-host"

"=== client bot acts"
"client bot: " + (Send $cd "$libKeep BOT_SKIP = 1 BOT_ONLY = nil $(Get-Content "$t\cmds\bot-actions.lua" -Raw)")
Start-Sleep 12
"host report: " + (Send $hd "return CoopSyncState.report()")
"client report: " + (Send $cd "return CoopSyncState.report()")
if ($Net) { "relay: " + (Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue) }
Score "after-client"

if ($Net) { "relay host: " + (Get-Content "$hchan\relay-status.txt" -ErrorAction SilentlyContinue); "relay client: " + (Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue) }
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($Net) { Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue }
}

