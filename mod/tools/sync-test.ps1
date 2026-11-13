# Automated spawn-replication test with two real game instances (headless).
# Host: seed 12345 -> zone -> export spawn list + snapshot. Client: seed 999 -> zone -> import -> snapshot.
# Usage: sync-test.ps1 [-KeepHost] [-KeepClient] [-ReuseHost] [-Net [-DelayMs n -JitterMs n]] [-GuestJoin [-GuestSeed n]]
# -HostSave <file>: the host loads a copy of that save (start-save.ps1) instead of a new game (a run further
#       into the story, with next legs to drive to)
# -GuestJoin: the client starts its own game (own seed), stays in its garage, gets the host's run descriptor
#       (map location of the host's zone) and drives out to that map itself (runsync.lua) instead of
#       travelling to its own first zone.
# -Net: the spawn list (and later all sync traffic) goes through two TCP relays (mod\net\relay.ps1),
#       each instance with its own channel dir; nothing is copied between the instances' folders.
# With -GuestJoin the guest gets the host's zone the way the game does it now (zonesave.lua, owner 2026-11-02: "the
# tests on the new mechanism"): the host's game saves its zone, the guest's game loads it spliced into its departure
# save, then the host's list is imported over it (finding every actor in place). -OldZone: the old way (the guest's
# own generated zone, the host's list imported over it - ~1200 actors removed, ~1700 spawned).
param([switch]$KeepHost, [switch]$KeepClient, [switch]$ReuseHost, [switch]$Net, [int]$DelayMs = 0, [int]$JitterMs = 0, [double]$LossPct = 0, [int]$Port = 27520, [switch]$GuestJoin, [int]$GuestSeed = 777, [string]$HostSave = "", [int]$HostSlot = 9, [switch]$OldZone, [switch]$NoImport)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua')"
$snapSrc = Get-Content "$t\cmds\snapshot.lua" -Raw

function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }
}
function Snap($dir, $name) { Send $dir ($snapSrc.Replace('C:/PacificDriveCoop/local/coopdev/snapshot.txt', "$($dir.Replace('\','/'))/$name")) }
# The zone keeps changing for ~20-25 s after RUN (leaf spawners cull variants). Wait until the
# replicated-actor count is unchanged for 3 polls (15 s) and at least $MinSec passed.
function WaitStable($dir, [int]$MinSec = 30, [int]$MaxSec = 180) {
    $t0 = Get-Date; $last = ''; $same = 0
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        $r = (& "$t\send.ps1" -File "$t\cmds\count.lua" -Dir $dir -TimeoutSec 30) -join ' '
        $cur = if ($r -match 'OK (total=\S+)') { $Matches[1] } else { '?' }
        if ($cur -eq $last -and $cur -ne '?') { $same++ } else { $same = 0; $last = $cur }
        # and the zone generator done (its markers / origin candidates gone: CoopSync.zoneReady)
        if ($same -ge 3 -and $r -match 'ready=true' -and ((Get-Date) - $t0).TotalSeconds -ge $MinSec) { return "stable after $([int]((Get-Date) - $t0).TotalSeconds) s: $cur" }
        Start-Sleep 5
    }
    "NOT stable after $MaxSec s: $last ($($r -replace '.*(ready=\S+ markers=\S+ origin=\S+).*', '$1'))"
}
function StartInst($tag, $seed, [switch]$Garage) {
    $out = & "$t\start-zone.ps1" -Tag $tag -Seed $seed -StopInGarage:$Garage
    $out | Where-Object { $_ -notmatch '^PID' }
    [int](($out | Where-Object { $_ -match '^PID' }) -replace 'PID ', '')
}
# The guest's game boots (menu, new game, garage / its own zone) while the host's starts and settles: nothing of it
# waits for the host (~45-65 s of every test before, the two one after the other). start-zone in a process of its own.
$script:guestBoot = $null
function StartInstBg($tag, $seed, [switch]$Garage) {
    $o = "$inst\$tag-boot.txt"; Remove-Item $o -ErrorAction SilentlyContinue
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$t\start-zone.ps1`" -Tag $tag -Seed $seed" + $(if ($Garage) { " -StopInGarage" } else { "" })
    $script:guestBoot = @{ p = (Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $o); o = $o }
}
function WaitInstBg() {
    $b = $script:guestBoot; $script:guestBoot = $null
    $b.p.WaitForExit()
    $out = @(Get-Content $b.o -ErrorAction SilentlyContinue)
    $out | Where-Object { $_ -notmatch '^PID' }
    [int](($out | Where-Object { $_ -match '^PID' }) -replace 'PID ', '')
}

if ($Net) {
    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $hchan = "$inst\host\chan-$runId"; $cchan = "$inst\client\chan-$runId"
    New-Item -ItemType Directory -Force $hchan, $cchan | Out-Null
    $relay = "$root\mod\net\relay.ps1"; $token = [guid]::NewGuid().ToString("N")
    $rh = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role host -Dir `"$hchan`" -Port $Port -Token $token -DelayMs $DelayMs -JitterMs $JitterMs -LossPct $LossPct" -WindowStyle Hidden -PassThru
    $rc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role client -Dir `"$cchan`" -Port $Port -Token $token -DelayMs $DelayMs -JitterMs $JitterMs -LossPct $LossPct" -WindowStyle Hidden -PassThru
    # interact-test.ps1 picks the session up from here
    Set-Content "$inst\net-session.txt" "hchan=$hchan`ncchan=$cchan`nrelayHost=$($rh.Id)`nrelayClient=$($rc.Id)" -Encoding ascii
    "net: relays started (delay $DelayMs ms, jitter $JitterMs ms), host chan $hchan"
}
$hostPid = 0
if (-not $ReuseHost) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3
    if ($GuestJoin) { StartInstBg client $GuestSeed -Garage } else { StartInstBg client 999 }
    if ($HostSave) {
        $out = & "$t\start-save.ps1" -Tag host -Save $HostSave -Slot $HostSlot
        $out | Where-Object { $_ -notmatch '^PID' }
        $hostPid = [int](($out | Where-Object { $_ -match '^PID' }) -replace 'PID ', '')
    } else {
        $r = StartInst host 12345; $r | Select-Object -SkipLast 1; $hostPid = $r[-1]
    }
}
$hostZoneAt = Get-Date
"host: " + (WaitStable $hd)
"host export: " + (Send $hd "$lib return CoopSync.export('$($hd.Replace('\','/'))/spawnlist.tsv')")
"host snapshot: " + (Snap $hd "snapshot.txt")
"host loot: " + (Send $hd "return CoopSync.exportLoot('$($hd.Replace('\','/'))/loot.tsv')")
if ($Net) {
    # the host game itself puts the list into the relay outbox (tmp + rename so it is never sent half-written)
    $ob = "$($hchan.Replace('\','/'))/outbox/host-spawnlist.tsv"
    "host -> relay outbox: " + (Send $hd "local n = CoopSync.export('$ob.tmp') os.rename('$ob.tmp', '$ob') return n")
} else {
    Copy-Item "$hd\spawnlist.tsv" "$cd\host-spawnlist.tsv" -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $cd)) { New-Item -ItemType Directory -Force $cd | Out-Null; Copy-Item "$hd\spawnlist.tsv" "$cd\host-spawnlist.tsv" }
}

$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
if ($GuestJoin) {
    if ($Net) {
        $ob = "$($hchan.Replace('\','/'))/outbox/host-run.txt"
        "host run descriptor -> relay outbox: " + (Send $hd "$run return Run.publish('$ob')")
    } else {
        "host run descriptor: " + (Send $hd "$run return Run.publish('$($hd.Replace('\','/'))/host-run.txt')")
    }
    $r = if ($script:guestBoot) { @(WaitInstBg) } else { @(StartInst client $GuestSeed -Garage) }; $r | Select-Object -SkipLast 1; $clientPid = $r[-1]
    "guest in its garage: " + (Send $cd "$run return Run.where() .. ' carries ' .. Run.inventory()")
    "guest car before the run: " + (Send $cd "$run return Run.carState('$($cd.Replace('\','/'))/car-before.txt')")
    $desc = if ($Net) { "$cchan\inbox\host-run.txt" } else { Copy-Item "$hd\host-run.txt" "$cd\host-run.txt" -Force; "$cd\host-run.txt" }
    $t0 = Get-Date; while (-not (Test-Path $desc) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 1 }
    "guest join: " + (Send $cd "$run return Run.join('$($desc.Replace('\','/'))')")
    & "$t\wait-state.ps1" -State 5 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "guest arrived: $_" }
    "host is at: " + (Send $hd "$run return Run.where()")
    if (-not $OldZone) {
        # the host's zone save (a scratch slot, the file to the guest), its async write waited for
        $zs = "ZS = ZS or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/zonesave.lua')"
        $zfile = if ($Net) { "$($hchan.Replace('\','/'))/outbox/host-zonesave.sav" } else { "$($hd.Replace('\','/'))/host-zonesave.sav" }
        "host zone save: " + (Send $hd "$zs return ZS.hostSave('$zfile')")
        $t0 = Get-Date
        do { Start-Sleep 1; $zst = Send $hd "$zs ZS.tick() return ZS.s.state" } while ($zst -match 'saving' -and ((Get-Date) - $t0).TotalSeconds -lt 60)
        "host zone save: $zst - " + (Send $hd "$zs return ZS.info()")
        $gfile = if ($Net) { "$cchan\inbox\host-zonesave.sav" } else { Copy-Item "$hd\host-zonesave.sav" "$cd\host-zonesave.sav" -Force; "$cd\host-zonesave.sav" }
        $t0 = Get-Date; while (-not (Test-Path $gfile) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 1 }
        # (the load replaces the level: a new World object - the state reads 5 all along, the load takes 20-60 s)
        $w0 = Send $cd "return tostring(FindFirstOf('World'):GetAddress())"
        $gl = Send $cd "$zs local r, e = ZS.guestLoad('$($gfile.Replace('\','/'))', 500) return tostring(r) .. ' ' .. tostring(e or '')"
        "guest loads the host's zone: $gl"
        $t0 = Get-Date
        # (no load started - the splice failed: no waiting 4 minutes for a reload that never comes)
        if ($gl -match '^OK nil') { $w1 = $w0 } else {
        do { Start-Sleep 3; $w1 = Send $cd "local w = FindFirstOf('World') return w and w:IsValid() and tostring(w:GetAddress()) or 'none'" } while (($w1 -eq $w0 -or $w1 -eq 'none' -or $w1 -eq '') -and ((Get-Date) - $t0).TotalSeconds -lt 240) }
        "guest's level reloaded after $([int]((Get-Date) - $t0).TotalSeconds) s: $(if ($w1 -ne $w0) { 'yes' } else { 'NO' })"
        & "$t\wait-state.ps1" -State 5 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "guest in the host's zone: $_" }
        # (the load leaves the guest without its car now and then - the mod's session builds it, zonesave.afterLoad;
        # here no session runs: the same in one call, beside the host's car, 3 s after the load; then seated)
        if ($w1 -ne $w0) {
            Start-Sleep 3
            $hc = Send $hd "local l = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorLocation() local y = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorRotation().Yaw return string.format('{X=%.0f,Y=%.0f,Z=%.0f,Yaw=%.1f}', l.X + math.cos(math.rad(y + 90)) * 600, l.Y + math.sin(math.rad(y + 90)) * 600, l.Z, y)"
            $hc = ($hc -replace '^OK\s+', '').Trim()
            "guest's car after the load: " + (Send $cd "$zs return ZS.finishNow($hc)")
            Start-Sleep 2
            "guest seated: " + (Send $cd "$zs return ZS.seatNow()")
        }
    }
} else {
    $r = if ($script:guestBoot) { @(WaitInstBg) } else { @(StartInst client 999) }; $r | Select-Object -SkipLast 1; $clientPid = $r[-1]
    # (booted beside the host: in its zone since the host's own arrival - its settling counted from there)
    if ($hostZoneAt) { $script:clientMinSec = [math]::Max(0, 30 - [int]((Get-Date) - $hostZoneAt).TotalSeconds) }
}
"client: " + (WaitStable $cd $(if ($null -ne $script:clientMinSec) { $script:clientMinSec } else { 30 }))
if ($Net) {
    $inboxList = "$cchan\inbox\host-spawnlist.tsv"
    $t0 = Get-Date; while (-not (Test-Path $inboxList) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 1 }
    "client got spawn list over the network: $(Test-Path $inboxList) ($((Get-Item $inboxList -ErrorAction SilentlyContinue).Length) bytes); relay: $(Get-Content "$cchan\relay-status.txt" -ErrorAction SilentlyContinue)"
    $importPath = $inboxList.Replace('\', '/')
} else {
    Copy-Item "$hd\spawnlist.tsv" "$cd\host-spawnlist.tsv" -Force
    $importPath = "$($cd.Replace('\','/'))/host-spawnlist.tsv"
}
"client snapshot before: " + (Snap $cd "snapshot-before.txt")
if ($NoImport) { "=== stopped before the import (-NoImport)"; return }
"client loot before: " + (Send $cd "$lib return CoopSync.exportLoot('$($cd.Replace('\','/'))/loot-before.tsv')")
"client import: " + (Send $cd "$lib return table.concat({CoopSync.import('$importPath')}, ' | ')")
"client snapshot right after import: " + (Snap $cd "snapshot-after.txt")
Start-Sleep 10
"client cleanup: " + (Send $cd "return CoopSync.cleanup()")
Start-Sleep 5
"client cleanup 2 (should remove nothing): " + (Send $cd "return CoopSync.cleanup()")
"client snapshot after cleanup: " + (Snap $cd "snapshot-cleanup.txt")
"client loot after import+cleanup: " + (Send $cd "return CoopSync.exportLoot('$($cd.Replace('\','/'))/loot-after.tsv')")

"=== BEFORE import"
& "$t\sync-score.ps1" -SpawnList "$hd\spawnlist.tsv" -HostSnap "$hd\snapshot.txt" -ClientSnap "$cd\snapshot-before.txt" | Select-Object -Last 2
"=== AFTER import (positions right after import, extras after cleanup)"
& "$t\sync-score.ps1" -SpawnList "$hd\spawnlist.tsv" -HostSnap "$hd\snapshot.txt" -ClientSnap "$cd\snapshot-after.txt" -ExtraSnap "$cd\snapshot-cleanup.txt"




"=== LOOT before import"
& "$t\loot-score.ps1" -HostLoot "$hd\loot.tsv" -ClientLoot "$cd\loot-before.tsv" -Show 0 | Select-Object -Last 2
"=== LOOT after import"
& "$t\loot-score.ps1" -HostLoot "$hd\loot.tsv" -ClientLoot "$cd\loot-after.tsv"
# the whole zone, every class (buildings' dressing included): informational, the line the tests may read
"=== WHOLE ZONE after cleanup"
& "$t\compare-snapshots.ps1" "$hd\snapshot.txt" "$cd\snapshot-cleanup.txt" -Top 12 | Select-Object -First 20 |
    ForEach-Object { if ($_ -match '^TOTAL matched (\d+) of (\d+)') { "$_; client actors: $((Get-Content "$cd\snapshot-cleanup.txt").Count - 1)" } else { $_ } }
if (-not $KeepClient) { Stop-Process -Id $clientPid -Force -ErrorAction SilentlyContinue }
if ($Net -and -not ($KeepClient -or $KeepHost)) { Stop-Process -Id $rh.Id, $rc.Id -Force -ErrorAction SilentlyContinue }
if (-not $KeepHost -and $hostPid) { Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue }
