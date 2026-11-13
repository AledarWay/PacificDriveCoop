# The long bot session (owner 2026-10-28: tests closer to a real game). Two instances over the test relays on a link
# like the internet (-Lag: delay, jitter, % of lines lost and resent), both players in own-car mode. Every round each
# side's bot does what a player does, picked at random by where it is (seeded: -Seed repeats a run):
#   in its own car    drive (throttle / steer), ram the other's car, horn, lights, radio channel, get out
#   on foot           walk, get into its own car, get into the other's car (look at a door, E), loot, take / put in
#                     the other's trunk, repair / fill a part of the other's car
#   in the other's    drive it (at the wheel), get out
#   anywhere          change its own trunk, damage its own part (as the owner's own play does)
# Every -CheckEvery rounds both stop and the shared state comparison (cmds/digest.lua, compare-state.ps1) runs until
# the two sides agree (each car against its twin there, each player against its puppet) or -SettleSec passes; the
# world's loot is compared too (loot-score.ps1). Watched all along: the game alive, the mod's errors, FPS, frame gaps
# (hitch log), the Lua state's memory, the processes' memory.
# Output: local\instances\soak\<time>\soak.log (+ the digests of every failed check), a summary at the end.
#   soak-test.ps1 [-Minutes 40] [-Seed 1] [-Lag 60,40,1] [-CheckEvery 3] [-SettleSec 25] [-Keep]
param([int]$Minutes = 40, [int]$Seed = 1, [string]$Lag = '60,40,1', [int]$CheckEvery = 3, [int]$SettleSec = 25, [switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$Lag = "$Lag".Trim() -replace '[\s,]+', ',' # (-Lag 80,40,1 from PowerShell arrives as "80 40 1": the relays had no delay)
$out ="$inst\soak\$(Get-Date -Format yyyyMMdd-HHmmss)"; New-Item -ItemType Directory -Force $out | Out-Null
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
. "$t\bot-lib.ps1"
$script:dead = $null
function Log([string]$s) {
    $line = "[$(Get-Date -f HH:mm:ss)] $s"; $line
    # (shared: a reader tailing the log must not stop the writes)
    try { $fs = [IO.File]::Open("$out\soak.log", 'Append', 'Write', 'ReadWrite'); $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($b, 0, $b.Length); $fs.Close() } catch {}
}
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    $r = ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
    if ($r -match 'GAME DEAD') { $script:dead = "$(if ($dir -eq $hd) { 'host' } else { 'guest' }) game died" }
    $r
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h }
# ---- setup: the guest joins the host's zone with its own car, both sync
$script:health = @(); $script:errs = @{}; $script:mem = @(); $script:lastHp = @{}
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1" | Out-Null
$env:COOPTEST_NET = $Lag
Log "=== soak: $Minutes min, seed $Seed, network $Lag (delay ms, jitter ms, loss %), check every $CheckEvery rounds"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived|relays started' | ForEach-Object { Log "$_" }
$env:COOPTEST_NET = $null
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
Log ("guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'"))
Start-Sleep 3
Log ("host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')"))
Log ("guest: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })"))
# the hitch log (the session starts it in a real game): frame gaps, FPS, the mod's ms per frame
foreach ($x in @(@{ d = $hd; c = $sess.hchan }, @{ d = $cd; c = $sess.cchan })) {
    Send $x.d "if not CoopSoakHitch then CoopSoakHitch = true local H = rawget(_G, 'CoopSyncHitch') or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/hitch.lua') H.start('$(P $x.c)') end return 'hitch on'" | Out-Null
}
Start-Sleep 15
# a seat for the visitor in each car (the test save has a device on every passenger seat)
Log ("seats: host " + (Send $hd "return CoopPlayers.removeSeatDevice(3)") + " | guest " + (Send $cd "return CoopPlayers.removeSeatDevice(3, true)"))
# a few items to carry for the trunk puts
Store $hd 'add' $FAB 3 | Out-Null; Store $cd 'add' $STEEL 3 | Out-Null
Send $hd "local im = FindFirstOf('BP_InventoryManager_C') im:GiveItemToPlayer(StaticFindObject('$FAB')) im:GiveItemToPlayer(StaticFindObject('$STEEL')) return 'given'" | Out-Null
Send $cd "local im = FindFirstOf('BP_InventoryManager_C') im:GiveItemToPlayer(StaticFindObject('$STEEL')) im:GiveItemToPlayer(StaticFindObject('$FAB')) return 'given'" | Out-Null
StateCheck 0

# ---- the session
$t0 = Get-Date; $round = 0
while (((Get-Date) - $t0).TotalMinutes -lt $Minutes -and -not $script:dead) {
    $round++
    $hw = KV (Ops $hd 'where'); $gw = KV (Ops $cd 'where')
    # a travel (home: death, the zone's end) ends the session: the game logs kept, the last rounds' health shown
    if ($round -eq 1) { $script:world0 = $hw.world }
    foreach ($x in @(@{ t = 'host'; w = $hw }, @{ t = 'guest'; w = $gw })) {
        if ($x.w.world -and $x.w.world -ne '-' -and $x.w.world -ne $script:world0) { $script:dead = "$($x.t) travelled to $($x.w.world) (health $($x.w.hp), last seen $($script:lastHp[$x.t]))" }
        $script:lastHp[$x.t] = $x.w.hp
    }
    if ($script:dead) { break }
    # bots drift apart: a car more than 60 m from the other's comes back beside it
    if ([double]$hw.cars -gt 6000) {
        if ($hw.where -ne 'twin' -and $gw.where -ne 'twin') { Log "round $round regroup: $(Ops $cd 'regroup' 'SOAK_SIDE = 900')" }
    }
    $ha = Act 'host' $hd $hw $gw
    $ga = Act 'guest' $cd $gw $hw
    Log "round $round [host $($hw.where)/$($hw.seat) hp $($hw.hp)] $ha"
    Log "round $round [guest $($gw.where)/$($gw.seat) hp $($gw.hp)] $ga"
    Start-Sleep -Seconds ([int](Rnd 5 10))
    if ($round % $CheckEvery -eq 0 -and -not $script:dead) {
        # both stop: the drivers brake and wait for the stream to settle
        foreach ($d in $hd, $cd) { Send $d "return CoopPlayers.botInput(3, 0, 0, 1)" | Out-Null }
        Start-Sleep 5
        StateCheck ($round / $CheckEvery)
    }
}
if ($script:dead) { Log "!!! $($script:dead) in round $round after $([int]((Get-Date) - $t0).TotalMinutes) min" }

# ---- summary
Log "=== SUMMARY: $round rounds, $([int]((Get-Date) - $t0).TotalMinutes) min, seed $Seed, network $Lag"
Log ("actions: " + (($script:count.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))
$avg = if ($script:settle.Count) { ($script:settle | Measure-Object -Average -Maximum) } else { $null }
Log ("checks: {0}, all alike {1}, settled in avg {2:N1} s / max {3:N0} s; loot checks failed: {4}" -f $script:checks, $script:converged, $avg.Average, $avg.Maximum, $script:lootBad)
foreach ($k in ($script:failed.Keys | Sort-Object)) { Log "  DIFF $k in $($script:failed[$k][0]) checks, first $($script:failed[$k][1])" }
foreach ($k in $script:errs.Keys) { Log "  ERRORS $k`: $($script:errs[$k])" }
if ($script:health.Count) { Log "health first: host $($script:health[0].h) | guest $($script:health[0].g)"; Log "health last:  host $($script:health[-1].h) | guest $($script:health[-1].g)" }
if ($script:mem.Count) { Log "memory first: $($script:mem[0]) | last: $($script:mem[-1])" }
foreach ($x in @(@{ t = 'host'; c = $sess.hchan }, @{ t = 'guest'; c = $sess.cchan })) {
    $gaps = @(Get-Content "$($x.c)\hitches.log" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^G' })
    $fps = @(Get-Content "$($x.c)\hitches.log" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^F' } | ForEach-Object { [double](($_ -split "`t")[2]) })
    $fm = if ($fps.Count) { $fps | Measure-Object -Minimum -Average } else { $null }
    Log ("{0}: frame gaps over 250 ms: {1} (worst {2}); fps min {3:N0} avg {4:N0}; relay: {5}" -f $x.t, $gaps.Count, (($gaps | ForEach-Object { [double](($_ -split "`t")[2]) } | Measure-Object -Maximum).Maximum), $fm.Minimum, $fm.Average, (Get-Content "$($x.c)\relay-status.txt" -ErrorAction SilentlyContinue))
    Copy-Item "$($x.c)\hitches.log" "$out\hitches-$($x.t).log" -ErrorAction SilentlyContinue
}
# the games' own logs (a travel, a crash: the next run overwrites them)
foreach ($tg in 'host', 'client') { Copy-Item "$inst\$tg\userdir\Saved\Logs\PenDriverPro.log" "$out\game-$tg.log" -ErrorAction SilentlyContinue }
$ok = -not $script:dead -and $script:failed.Count -eq 0 -and $script:errs.Count -eq 0 -and $script:lootBad -eq 0
Log "=== RESULT: $(if ($ok) { 1 } else { 0 }) passed, $(if ($ok) { 0 } else { 1 }) failed (log: $out)"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
