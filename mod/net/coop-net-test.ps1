# Two-PC version of interact-test: each PC runs one half and drives only its own game. The halves talk
# only through the relay (sync traffic, the spawn list, phase markers and the client's score files).
#
#   Host PC:   coop-net-test.ps1 -Role host   -Token <secret> [-Bind 0.0.0.0] [-Port 27520]
#   Client PC: coop-net-test.ps1 -Role client -Token <secret> -HostAddr <host ip> [-Port 27520]
#
# Needs on both PCs: the test copy of the game with UE4SS + CoopDev + CoopSync (same game build),
# this repo's mod\ folder at C:\PacificDriveCoop\mod. The host scores and prints PASS/FAIL per stage.
param(
    [ValidateSet('host', 'client')] [string]$Role,
    [string]$Token,
    [string]$HostAddr = '127.0.0.1',
    [string]$Bind = '127.0.0.1',
    [int]$Port = 27520,
    [int]$DelayMs = 0, [int]$JitterMs = 0,
    [string]$Tag = ''   # instance folder name; defaults to the role (lets both halves share one test PC)
)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"
if (-not $Tag) { $Tag = $Role }
$dir = "$root\local\instances\$Tag\coopdev"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$chan = "$root\local\instances\$Tag\netchan-$runId"
New-Item -ItemType Directory -Force $chan, $dir | Out-Null
$P = { param($p) $p.Replace('\', '/') }
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
$libKeep = "CoopSync = CoopSync or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua')"
$snapSrc = Get-Content "$t\cmds\snapshot.lua" -Raw
$bot = Get-Content "$t\cmds\bot-actions.lua" -Raw
function Send([string]$code) {
    $f = "$dir\_net.lua"; Set-Content $f $code -Encoding ascii
    ((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' '
}
function Snap($path) { Send ($snapSrc.Replace('C:/PacificDriveCoop/local/coopdev/snapshot.txt', (& $P $path))) }
function Mark($name, $text = 'x') { Set-Content "$chan\outbox\$name.tmp" $text -Encoding ascii; Move-Item "$chan\outbox\$name.tmp" "$chan\outbox\$name" -Force }
function WaitMark($name, [int]$sec = 900) {
    $t0 = Get-Date
    while (-not (Test-Path "$chan\inbox\$name")) {
        if (((Get-Date) - $t0).TotalSeconds -gt $sec) { throw "timeout waiting for '$name' from the peer" }
        Start-Sleep -Milliseconds 300
    }
}
function SendFile($src, $name) { Copy-Item $src "$chan\outbox\$name.tmp" -Force; Move-Item "$chan\outbox\$name.tmp" "$chan\outbox\$name" -Force }
function WaitStable([int]$MinSec = 30, [int]$MaxSec = 180) {
    $t0 = Get-Date; $last = ''; $same = 0
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        $r = (& "$t\send.ps1" -File "$t\cmds\count.lua" -Dir $dir -TimeoutSec 30) -join ' '
        $cur = if ($r -match 'OK (total=\S+)') { $Matches[1] } else { '?' }
        if ($cur -eq $last -and $cur -ne '?') { $same++ } else { $same = 0; $last = $cur }
        if ($same -ge 3 -and ((Get-Date) - $t0).TotalSeconds -ge $MinSec) { return "stable after $([int]((Get-Date) - $t0).TotalSeconds) s: $cur" }
        Start-Sleep 5
    }
    "NOT stable after $MaxSec s: $last"
}
function Say($m) { "[$Role $(Get-Date -f HH:mm:ss)] $m" }
function Cut([string]$s, [int]$n = 160) { if ($s.Length -gt $n) { $s.Substring(0, $n) + "..." } else { $s } }

# relay
$relayArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$root\mod\net\relay.ps1`" -Role $Role -Dir `"$chan`" -Port $Port -Token $Token -DelayMs $DelayMs -JitterMs $JitterMs"
if ($Role -eq 'host') { $relayArgs += " -Bind $Bind" } else { $relayArgs += " -HostAddr $HostAddr" }
$relay = Start-Process powershell -ArgumentList $relayArgs -WindowStyle Hidden -PassThru
Say "relay started (pid $($relay.Id))"

$game = $null
try {
    $out = & "$t\start-zone.ps1" -Tag $Tag -Seed $(if ($Role -eq 'host') { 12345 } else { 999 })
    $game = [int](($out | Where-Object { $_ -match '^PID' }) -replace 'PID ', '')
    Say ("zone: " + ($out | Where-Object { $_ -match 'state=5' } | Select-Object -Last 1))
    Say (WaitStable)
    if ($Role -eq 'host') {
        $ob = & $P "$chan\outbox\host-spawnlist.tsv"
        Say ("spawn list -> network: " + (Send "$lib local n = CoopSync.export('$ob.tmp') os.rename('$ob.tmp', '$ob') return n"))
        Say ("sync: " + (Send "$lib return CoopSyncState.start(CoopSync, 'host', '$(& $P $chan)')"))
        WaitMark 'client-synced'
        Say "client is synced"
        function Score($stage) {
            Send "return CoopSync.export('$(& $P "$dir\net-spawnlist-$stage.tsv")')" | Out-Null
            Snap "$dir\net-snapshot-$stage.txt" | Out-Null
            Send "return CoopSync.exportLoot('$(& $P "$dir\net-loot-$stage.tsv")')" | Out-Null
            Mark "dump-$stage"
            WaitMark "client-snapshot-$stage.txt"; WaitMark "client-loot-$stage.tsv"
            "=== [$stage] host: " + (Send "return CoopSyncState.report()")
            & "$t\sync-score.ps1" -SpawnList "$dir\net-spawnlist-$stage.tsv" -HostSnap "$dir\net-snapshot-$stage.txt" -ClientSnap "$chan\inbox\client-snapshot-$stage.txt" | Select-Object -Last 2
            & "$t\loot-score.ps1" -HostLoot "$dir\net-loot-$stage.tsv" -ClientLoot "$chan\inbox\client-loot-$stage.tsv" -Show 4 | Select-Object -Last 4
        }
        Start-Sleep 4
        Score "synced"
        Say ("host bot: " + (Cut (Send "$libKeep BOT_SKIP = 0 BOT_ONLY = nil $bot")))
        Start-Sleep 6
        Score "after-host"
        Mark "client-bot-go"
        WaitMark "client-bot-done"
        Start-Sleep 12
        Score "after-client"
        Mark "finished"
        Say ("relay: " + (Get-Content "$chan\relay-status.txt"))
    } else {
        WaitMark 'host-spawnlist.tsv'
        Say ("spawn list from network: $((Get-Item "$chan\inbox\host-spawnlist.tsv").Length) bytes")
        $list = & $P "$chan\inbox\host-spawnlist.tsv"
        Say ("import: " + (Cut (Send "$lib return CoopSync.import('$list')")))
        Start-Sleep 10; Send "return CoopSync.cleanup()" | Out-Null
        Start-Sleep 5; Send "return CoopSync.cleanup()" | Out-Null
        Say ("sync: " + (Send "$lib return CoopSyncState.start(CoopSync, 'client', '$(& $P $chan)', '$list')"))
        Mark 'client-synced'
        function Dump($stage) {
            WaitMark "dump-$stage"
            Snap "$dir\net-snapshot-$stage.txt" | Out-Null
            Send "return CoopSync.exportLoot('$(& $P "$dir\net-loot-$stage.tsv")')" | Out-Null
            SendFile "$dir\net-snapshot-$stage.txt" "client-snapshot-$stage.txt"
            SendFile "$dir\net-loot-$stage.tsv" "client-loot-$stage.tsv"
            Say ("[$stage] client: " + (Send "return CoopSyncState.report()"))
        }
        Dump "synced"
        Dump "after-host"
        WaitMark "client-bot-go"
        Say ("client bot: " + (Cut (Send "$libKeep BOT_SKIP = 1 BOT_ONLY = nil $bot")))
        Mark "client-bot-done"
        Dump "after-client"
        WaitMark "finished"
        Say ("relay: " + (Get-Content "$chan\relay-status.txt"))
    }
} catch {
    Say "ERROR: $($_.Exception.Message)"
} finally {
    Start-Sleep 3 # let the last files leave the outbox
    if ($game) { Stop-Process -Id $game -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
    Say "DONE"
}
