# Automated test of the two cars colliding (own-car mode): each side's own car is a simulated body, the other's twin a
# kinematic one moved by the stream. Two instances over the test relays.
#   1. the host drives its car into the guest's parked car: the cars never go through each other (either side); the
#      striker keeps part of its speed (the twin no wall), the car hit about half of it (the shared speed, BI)
#   2. on the guest's side the host's twin drives into the guest's real car: the guest's car is pushed
param([switch]$Keep, [switch]$SetupOnly)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Col($dir, [string]$op, [string]$extra = '') { Send $dir "COL_OP = '$op' $extra $(Get-Content "$t\cmds\collide-probe.lua" -Raw)" }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4
"  guest's twin of the host's car: " + (Col $cd 'info')
"  host's twin of the guest's car: " + (Col $hd 'info')
if ($SetupOnly) { return }

"=== 1. the host drives into the guest's parked car"
"  host: " + (Col $hd 'aim' 'COL_BACK = 1500')
Start-Sleep 3
$hp0 = Col $hd 'hp'; $gp0 = Col $cd 'hp'
"  parts' health before: host $hp0 | guest $gp0"
$g0 = Col $cd 'where'
"  guest before: $g0"
"  host: " + (Send $hd "return CoopPlayers.botInput(5, 1.0, 0)")
"  guest: " + (Col $cd 'peak' 'COL_MS = 6000') + " | host: " + (Col $hd 'peak' 'COL_MS = 6000')
# (the gas again, before the launch: the first 5 s may be over by now - the probes above take a few seconds - and a car with no gas
# brakes from 15 m/s to a stop in ~1 s, short of the twin: 2026-11-04 runs. And launched where it stands, not teleported again: the twin's glide to the new spot
# near the guest's car read there as a hit, BI held the striker to ~3 m/s. Waking its controller - SetParkingBrakeActive
# / Wake - crashed the host's game once)
"  host: " + (Send $hd "return CoopPlayers.botInput(4, 1.0, 0)")
# (the guest's car held still until the striker is near: parked here it rolled down the slope at 3.5 m/s before the hit -
# a weak or a missed hit, the top speed the slope's; with the parking lever on it stopped the striker like a wall;
# quick suite 2026-11-10. Free, in drive, its speed put to 0 every 30 ms until the twin came 80 closer)
"  guest: " + (Send $cd "HOLD_D0 = nil local T = CoopPlayers.twinModule() local c = T.ownCar() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(30, function() local tw for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and T.isTwin(x) then tw = x end end local near = true if tw and c:IsValid() then local a, b = c:K2_GetActorLocation(), tw:K2_GetActorLocation() local d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) HOLD_D0 = HOLD_D0 or d near = d < HOLD_D0 - 80 end if near or os.clock() - t0 > 12 then CancelDelayedAction(h) return end c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) c.RootComponent:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName('None')) end) return 'held still until the twin comes'")
"  host: " + (Col $hd 'launch' 'COL_SPEED = 1500')
for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 600; "    host: " + (Col $hd 'where') + " | guest: " + (Col $cd 'where') }
Start-Sleep 4
$h1 = Col $hd 'where'
# the closest the cars' centres came on each side, sampled every 30 ms (through each other: near 0; touching side by
# side: ~200; the old check along the twin's axis failed when the hit turned the car)
$mh = (Col $hd 'peakget') -replace '.*mind=(-?[\d.]+).*', '$1'; $mg = (Col $cd 'peakget') -replace '.*mind=(-?[\d.]+).*', '$1'
Check "the cars never went through each other (centres >= 150 apart on both sides)" ([double]$mh -ge 150 -and [double]$mg -ge 150) "closest: host side $mh, guest side $mg | $h1"

"=== 2. the guest's real car on the guest's side"
$g1 = Col $cd 'where'
"  guest after: $g1"
$o0 = (($g0 -split ' ')[1] -replace 'own=', '') -split ','; $o1 = (($g1 -split ' ')[1] -replace 'own=', '') -split ','
$moved = [math]::Sqrt(([double]$o1[0] - [double]$o0[0]) * ([double]$o1[0] - [double]$o0[0]) + ([double]$o1[1] - [double]$o0[1]) * ([double]$o1[1] - [double]$o0[1]))
Check "guest: its real car was pushed by the host's twin" ($moved -gt 20) "moved $([math]::Round($moved)) units"
$hi = KV (Send $hd "return CoopPlayers.ghostInfo()"); $gi = KV (Send $cd "return CoopPlayers.ghostInfo()")
# (the twin as an infinite mass: thrown 42 m at the striker's 15 m/s, or pushed 0.5 m; equal cars: half the speed)
Check "the hit seen and its shared speed sent (BI) by one side, taken by the other" (([int]$hi.bi_sent -ge 1 -and [int]$gi.bi_got -ge 1) -or ([int]$gi.bi_sent -ge 1 -and [int]$hi.bi_got -ge 1)) "host bi_sent=$($hi.bi_sent) bi_got=$($hi.bi_got) last=$($hi.last_bump) | guest bi_sent=$($gi.bi_sent) bi_got=$($gi.bi_got) last=$($gi.last_bump)"
# the striker after its hit: it kept part of its speed (the twin of the car hit no wall: it moves on at once)
$hp = Col $hd 'peakget'
# the closing speed of the hit: the hardest either side saw (strike_max)
$hb = [math]::Max([double]$hi.strike_max, [double]$gi.strike_max)
$ha = [double]($hp -replace '.*after=(-?[\d.]+).*', '$1')
Check "host: its car kept moving after the hit (0.25 s on: >= 30 % of its speed into it), not stopped as by a wall" ($hb -gt 300 -and $ha -ge 0.3 * $hb) "host $hp, its speed into the hit $hb"
# the guest's car's top speed after the hit against the striker's speed into it (host's "sent <striker>><shared>")
$pk = Col $cd 'peakget' 'COL_CTX = true'
$peak = [double]($pk -replace '(?s)^held=([\d.]+).*', '$1')
# (the speed the hit gave, not the top speed: the parked car rolled down a slope before and after the hit, 2026-11-10)
$dv = [double]($pk -replace '(?s)^.*? dv=(-?[\d.]+).*', '$1')
$striker = $hb
Check "guest: pushed like by a car of its own mass (the speed the hit gave, held over 2 samples: 25-75 % of the striker's), not thrown or barely moved" ($striker -gt 300 -and $dv -ge 0.25 * $striker -and $dv -le 0.75 * $striker) "guest gained $([math]::Round($dv)) cm/s (top $([math]::Round($peak))) ($pk), striker $striker cm/s, moved $([math]::Round($moved)) units (a slope: it may roll on)"

"=== 3. damage: each car's parts on its owner's side, shown on the other side's twin"
Start-Sleep 12 # (ES lines: every 1 s when changed)
$hp1 = Col $hd 'hp'; $gp1 = Col $cd 'hp'
"  parts' health after: host $hp1 | guest $gp1"
$h0v = [double]($hp0 -replace '^hp=([\d.]+).*', '$1'); $h1v = [double]($hp1 -replace '^hp=([\d.]+).*', '$1')
$g0v = [double]($gp0 -replace '^hp=([\d.]+).*', '$1'); $g1v = [double]($gp1 -replace '^hp=([\d.]+).*', '$1')
Check "host: its car's parts damaged by the crash" ($h1v -lt $h0v - 1) "health $h0v -> $h1v"
Check "guest: its car's parts damaged by the crash" ($g1v -lt $g0v - 1) "health $g0v -> $g1v"
# (the host's car can still take a scratch after the reading above: compared again for a few seconds, ES every 1 s)
for ($i = 0; $i -lt 6; $i++) {
    $tw = Send $cd "local T = rawget(_G, 'CoopPlayers').twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end return tostring(T.twinStateSum and T.twinStateSum(tw))"
    $h1v = [double]((Col $hd 'hp') -replace '^hp=([\d.]+).*', '$1')
    if ($tw -match '^[\d.]+$' -and [math]::Abs([double]$tw - $h1v) -lt 5) { break }
    Start-Sleep 1
}
# (a part's change under 0.5 is not applied to the twin (STATE_EPS): small scratches on 21 parts add up to ~3)
Check "guest: its twin of the host's car shows the host's damage" ($tw -match '^[\d.]+$' -and [math]::Abs([double]$tw - $h1v) -lt 5 -and [double]$tw -lt $h0v - 10) "twin $tw | host's car $h1v (before $h0v)"

$eh = Send $hd "return CoopPlayers.report()"; $eg = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($eh -notmatch 'errors=[1-9]|ERR' -and $eg -notmatch 'errors=[1-9]|ERR') "host: $eh | guest: $eg"
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
