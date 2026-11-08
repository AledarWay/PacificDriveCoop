# Runs the automated two-instance tests one after another (never in parallel) and prints a summary.
#   (no switch)   full suite (~85 min)
#   -Quick        the core set after a change: join + spawn/loot, interaction, driving, own-car mode, session, map
#                 (on-foot guest tests only in the full suite: the on-foot mode is frozen, owner 2026-10-24)
#   -Only a,b     just these tests (names as in the table below)
#   -Lag d,j,l    every test's network relays on a link with d ms delay, j ms jitter, l % lost and resent (e.g.
#                 -Lag 60,40,1; COOPTEST_NET for relay.ps1)
#   -Fps n        every game capped at n frames per second (a slow friend's PC, e.g. -Fps 15; COOPTEST_FPS)
# Logs: local\instances\all-<name>.log, progress in all-progress.txt. A test whose game died is cut short by
# send.ps1 ("GAME DEAD") and reported as ABORTED instead of waiting out its timeouts.
param([switch]$Quick, [string[]]$Only, [string]$Lag = "", [int]$Fps = 0)
$t = "C:\PacificDriveCoop\mod\tools"; $L = "C:\PacificDriveCoop\local\instances"
& "$t\deploy.ps1"
$Lag = $Lag.Trim() -replace '\s+', ',' # (-Lag 150,60,1 from PowerShell arrives as "150 60 1": every relay broke)
if ($Lag) { $env:COOPTEST_NET = $Lag; "network: $Lag (delay, jitter, loss %)" | Add-Content "$L\all-progress.txt" }
if ($Fps) { $env:COOPTEST_FPS = "$Fps"; "fps cap: $Fps" | Add-Content "$L\all-progress.txt" }
$tests = @(
    @{ name = 'sync';          quick = $true;  cmd = { & "$t\sync-test.ps1" } },
    @{ name = 'interact';      quick = $true;  cmd = { & "$t\interact-test.ps1" } },
    @{ name = 'interact-net';  quick = $false; cmd = { & "$t\interact-test.ps1" -Net } },
    @{ name = 'interact-lag';  quick = $false; cmd = { & "$t\interact-test.ps1" -Net -DelayMs 75 -JitterMs 30 } },
    @{ name = 'players';       quick = $false; cmd = { & "$t\players-test.ps1" } },
    @{ name = 'anim';          quick = $false; cmd = { & "$t\anim-test.ps1" } },
    @{ name = 'drive';         quick = $true;  cmd = { & "$t\drive-test.ps1" } },
    @{ name = 'drive-lag';     quick = $false; cmd = { & "$t\drive-test.ps1" -DelayMs 75 -JitterMs 30 } },
    @{ name = 'wheel';         quick = $true;  cmd = { & "$t\wheel-test.ps1" } },
    @{ name = 'guest';         quick = $false; cmd = { & "$t\guest-test.ps1" } },
    @{ name = 'guest-death';   quick = $false; cmd = { & "$t\guest-test.ps1" -Outcome death } },
    @{ name = 'seats';         quick = $false; cmd = { & "$t\seats-test.ps1" } },
    @{ name = 'loot-share';    quick = $false; cmd = { & "$t\loot-share-test.ps1" } },
    @{ name = 'exit-seated';   quick = $false; cmd = { & "$t\exit-test.ps1" -Scenario seated } },
    @{ name = 'exit-behind';   quick = $false; cmd = { & "$t\exit-test.ps1" -Scenario behind } },
    @{ name = 'leg-seated';    quick = $false; cmd = { & "$t\leg-test.ps1" -Scenario seated } },
    @{ name = 'leg-behind';    quick = $false; cmd = { & "$t\leg-test.ps1" -Scenario behind } },
    @{ name = 'hazard';        quick = $false; cmd = { & "$t\hazard-test.ps1" } },
    @{ name = 'anchor';        quick = $true;  cmd = { & "$t\anchor-test.ps1" } },
    @{ name = 'portal';        quick = $true;  cmd = { & "$t\portal-test.ps1" } },
    @{ name = 'knock';         quick = $true;  cmd = { & "$t\knock-test.ps1" } },
    @{ name = 'paint';         quick = $true;  cmd = { & "$t\paint-test.ps1" } },
    @{ name = 'range';         quick = $true;  cmd = { & "$t\range-test.ps1" } },
    @{ name = 'runover';       quick = $true;  cmd = { & "$t\runover-test.ps1" } },
    @{ name = 'anomaly';       quick = $true;  cmd = { & "$t\anomaly-test.ps1" } },
    @{ name = 'anomaly-real';  quick = $false; cmd = { & "$t\anomaly-test.ps1" -Real } },
    @{ name = 'owncar-guest';  quick = $true;  cmd = { & "$t\owncar-test.ps1" -Scenario guestLeaves } },
    @{ name = 'owncar-host';   quick = $false; cmd = { & "$t\owncar-test.ps1" -Scenario hostLeaves } },
    @{ name = 'ghostseat';     quick = $true;  cmd = { & "$t\ghostseat-test.ps1" } },
    # (ghostseat-old - ghostseat-test.ps1 -Ghost - left out since 2026-11-03: the ghost path is used by no game, only
    # that test, and it fails 6/14 since the native cars; the owner's call: out of the suite, the code stays)
    @{ name = 'twin-equip';    quick = $true;  cmd = { & "$t\twin-equip-test.ps1" } },
    @{ name = 'twin-state';    quick = $true;  cmd = { & "$t\twin-state-test.ps1" } },
    @{ name = 'twin-ctl';      quick = $true;  cmd = { & "$t\twin-ctl-test.ps1" } },
    @{ name = 'twin-radio';    quick = $true;  cmd = { try { & "$t\twin-radio-test.ps1" } finally { $env:COOPTEST_SOUND = $null } } },
    @{ name = 'garage-radio';  quick = $true;  cmd = { try { & "$t\garage-radio-test.ps1" } finally { $env:COOPTEST_SOUND = $null } } },
    @{ name = 'collide';       quick = $true;  cmd = { & "$t\collide-test.ps1" } },
    @{ name = 'loot-live';     quick = $true;  cmd = { & "$t\loot-live-test.ps1" } },
    @{ name = 'car-store';     quick = $true;  cmd = { & "$t\car-store-test.ps1" } },
    @{ name = 'session';       quick = $false; cmd = { & "$t\session-test.ps1" } },
    @{ name = 'session-net';   quick = $true;  cmd = { & "$t\session-test.ps1" -CoopNet } },
    @{ name = 'menu';          quick = $true;  cmd = { & "$t\menu-test.ps1" } },
    @{ name = 'startflow';     quick = $true;  cmd = { & "$t\startflow-test.ps1" } },
    @{ name = 'nextzone';      quick = $true;  cmd = { & "$t\nextzone-test.ps1" } },
    @{ name = 'mapsync';       quick = $true;  cmd = { & "$t\mapsync-test.ps1" } },
    @{ name = 'staybehind';    quick = $true;  cmd = { & "$t\staybehind-test.ps1" } },
    @{ name = 'twin-outside';  quick = $true;  cmd = { & "$t\twin-outside-test.ps1" } },
    @{ name = 'seat-measure';  quick = $true;  cmd = { & "$t\seat-measure-test.ps1" } },
    @{ name = 'garage-seat';   quick = $true;  cmd = { & "$t\garage-seat-test.ps1" } },
    @{ name = 'gates';         quick = $true;  cmd = { & "$t\gates-test.ps1" } },
    @{ name = 'esc';           quick = $true;  cmd = { & "$t\esc-test.ps1" } },
    @{ name = 'contact';       quick = $true;  cmd = { & "$t\contact-test.ps1" } },
    @{ name = 'cars';          quick = $true;  cmd = { & "$t\cars-test.ps1" } },
    @{ name = 'f7';            quick = $true;  cmd = { & "$t\f7-test.ps1" } },
    @{ name = 'revisit';       quick = $true;  cmd = { & "$t\revisit-test.ps1" } },
    @{ name = 'soak';          quick = $false; cmd = { & "$t\soak-test.ps1" -Minutes 20 } }
)
# (-Only a,b through powershell -File arrives as one string "a,b": nothing ran)
$Only = @($Only | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if ($Only) { $tests = @($tests | Where-Object { $Only -contains $_.name }) }
elseif ($Quick) { $tests = @($tests | Where-Object { $_.quick }) }
# a lint failure leaves the old mod deployed: most tests (no deploy of their own) then pass on stale code - stop here
$dep = & "$t\deploy.ps1"
if ($LASTEXITCODE) { "run-all-tests: $dep" | Tee-Object -FilePath "$L\all-summary.txt"; exit 1 }
$summary = foreach ($x in $tests) {
    $log = "$L\all-$($x.name).log"
    $t0 = Get-Date
    "[$(Get-Date -f HH:mm:ss)] start $($x.name)" | Add-Content "$L\all-progress.txt"
    $aborted = $null
    try { & $x.cmd *>&1 | Out-File $log -Width 500 }
    catch { $aborted = "$_"; "ABORTED: $_" | Add-Content $log }
    "[$(Get-Date -f HH:mm:ss)] done  $($x.name)" | Add-Content "$L\all-progress.txt"
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
    Get-Process CrashReportClient -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # the network relays of a test (kept on purpose with -Keep, or left by an aborted test) piled up: 50 seen
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'relay\.ps1' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
    Start-Sleep 3
    # the test's own verdict: the RESULT line (Check-based tests) or the last PASS / FAIL line (sync, interact)
    $verdict = if ($aborted) { "ABORTED ($aborted)" } else {
        $r = Get-Content $log | Select-String '=== RESULT' | Select-Object -Last 1
        if ($r) { $r.Line.Trim() } else { (Get-Content $log | Select-String '^\s*(PASS|FAIL|LOOT PASS|LOOT FAIL)\b' | Select-Object -Last 1).Line }
    }
    "{0,-14} {1,5:N1} min  {2}" -f $x.name, ((Get-Date) - $t0).TotalMinutes, $verdict
}
$env:COOPTEST_NET = $null; $env:COOPTEST_FPS = $null
"ALL DONE" | Add-Content "$L\all-progress.txt"
$summary
$summary | Set-Content "$L\all-summary.txt"
