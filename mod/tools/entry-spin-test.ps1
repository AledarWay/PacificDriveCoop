# A car turned on the spot as a player got in, now and then (owner's two-games tests, 2026-11-14 item j: "the twin
# rotates or gets a push on entry"). Each driver's-door way in - the own car and the other's car - ROUNDS times,
# the game's own E at the door as a player; both sides sample both cars every frame from just
# before the E until 5 s after: the most any car turned (yaw / pitch / roll) and moved from where it stood, on each side.
# Uses cars-test's pair (-Reuse: one already set up by cars-test -SetupOnly).
param([switch]$Keep, [switch]$Reuse, [int]$Rounds = 3, [double]$MaxDeg = 2, [double]$MaxMove = 20, [string]$Only = "")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 2 }
$ce = Get-Content "$t\cmds\car-e.lua" -Raw
$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
# the car of a kind on a side: 'own' or 'twin'
$carOf = "local function carOf(kind) local T = CoopPlayers.twinModule() if kind == 'own' then return T.ownCar() end for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then return c end end end "
# both cars sampled every frame for SEC s (SPIN.own / SPIN.twin: t, x, y, z, yaw, pitch, roll)
function SampleStart($dir) {
    Send $dir ($carOf + "local cars = { own = carOf('own'), twin = carOf('twin') } SPIN = { own = {}, twin = {} } local t0 = os.clock() local h " +
        "h = LoopInGameThreadWithDelay(1, function() if os.clock() - t0 > 20 then CancelDelayedAction(h) return end " +
        "for k, c in pairs(cars) do if c:IsValid() then local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation() local s = SPIN[k] s[#s + 1] = { os.clock() - t0, l.X, l.Y, l.Z, r.Yaw, r.Pitch, r.Roll } end end end) return 'sampling'") | Out-Null
}
# the most a car turned / moved over the samples: "<kind>: turn=<deg> (yaw/pitch/roll) move=<units> at=<s> n=<samples>"
$read = "local function wrap(d) return (d + 180) % 360 - 180 end local o = {} for _, k in ipairs({ 'own', 'twin' }) do local s = SPIN[k] or {} local a = s[1] " +
    "if a then local mt, mm, at, my, mp, mr = 0, 0, 0, 0, 0, 0 for _, x in ipairs(s) do local dy, dp, dr = math.abs(wrap(x[5] - a[5])), math.abs(wrap(x[6] - a[6])), math.abs(wrap(x[7] - a[7])) " +
    "local tt = math.max(dy, dp, dr) local m = math.sqrt((x[2] - a[2]) ^ 2 + (x[3] - a[3]) ^ 2 + (x[4] - a[4]) ^ 2) if tt > mt then mt, at, my, mp, mr = tt, x[1], dy, dp, dr end if m > mm then mm = m end end " +
    "o[#o + 1] = string.format('%s: turn=%.1f (%.1f/%.1f/%.1f) move=%.0f at=%.2f n=%d', k, mt, my, mp, mr, mm, at, #s) else o[#o + 1] = k .. ': none' end end return table.concat(o, ' | ')"
function InAt($dir, [string]$kind, [int]$n) {
    $p = @{ 1 = '131,-150'; 3 = '8,-150' }[$n] -split ','
    Send $dir ($carOf + "local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = carOf('$kind') local pw = FindFirstOf('PlayerController').Pawn local w = KML:TransformLocation(c:GetTransform(), { X = $($p[0]), Y = $($p[1]), Z = 0 }) w.Z = pw:K2_GetActorLocation().Z + 20 pw:K2_SetActorLocation(w, false, {}, true) return 'at'") | Out-Null
    Start-Sleep 1
    if ($kind -eq 'twin') {
        # A real camera highlight, as in cars / carswitch: car-e.lua's SetHighlight alone leaves the mod's aim state
        # stale after an earlier entry, so its synthetic E can do nothing on a later round.
        $slot = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR'; 5 = 'DoorsTrunk' }[$n]
        $h = ''
        foreach ($dz in 0, 20, -20, 40, -40) {
            Send $dir "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null
            Start-Sleep -Milliseconds 700
            $h = Send $dir "local g, doorNumber = CoopPlayers.twinModule().highlightedDoor() return tostring(doorNumber)"
            if ($h -match "^(OK )?$n\s*$") { break }
        }
        if ($h -notmatch "^(OK )?$n\s*$") { return "no E at door $n (highlighted: $($h.Trim()))" }
        return Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after(100, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E at door $n (highlighted: $($h.Trim()))'"
    }
    Send $dir "CE_CAR = '$kind' CE_HL = 'door$n' $ce"
}
function InCar($dir) { Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())" }
function OutOf($dir, [string]$kind) {
    for ($i = 0; $i -lt 3; $i++) {
        if ((InCar $dir) -eq 'false') { return 'out' }
        Send $dir "CE_CAR = '$kind' CE_HL = 'ExitDoor' $ce" | Out-Null; Start-Sleep 4
    }
    'still in'
}
# Park both sides' own cars before every entry: after a hand-over the owner's car can stay in drive with its engine on,
# and its ordinary creep would move it out of the test spot and look like an entry jolt. The nose dive also reproduced
# in park (dive-probe, 2026-11-15), so this keeps the hinge check while removing that unrelated movement.
function Park($dir) {
    $s = ''
    for ($i = 0; $i -lt 3; $i++) {
        $s = Send $dir "local m = FindFirstOf('BP_CarManager_C') local c = CoopPlayers.twinModule().ownCar() if m.MyCarGearBox == 0 then c:ToggleGearBoxState(0, false) end c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) return 'gear=' .. tostring(m.MyCarGearBox)"
        if ($s -match 'gear=1') { return $s }
        Start-Sleep 1
    }
    $s
}
# a way in: who gets in, into which of its cars (own / twin on its side), by which door; the car on the other side is
# the opposite kind. Back-door entries (3, 4) are tested in backseat-test: a back-door tap does not start the physics
# hand-over, so it cannot cause a nose-dive, and car-e.lua's SetHighlight path does not reach TD.doorPress for them.
$ways = @(
    @{ name = "host into its own car (driver's door)"; dir = $hd; other = $cd; kind = 'own'; door = 1 },
    @{ name = "guest into the host's car (driver's door)"; dir = $cd; other = $hd; kind = 'twin'; door = 1 },
    @{ name = "host into the guest's car (driver's door)"; dir = $hd; other = $cd; kind = 'twin'; door = 1 },
    @{ name = "guest into its own car (driver's door)"; dir = $cd; other = $hd; kind = 'own'; door = 1 }
)
"=== both out first"
"  host: " + (OutOf $hd 'own') + " | guest: " + (OutOf $cd 'own')
# (-Only 3,4: just those ways, by their number in the list above)
$onlyN = @($Only -split "[^0-9]+" | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($onlyN.Count -gt 0) { $ways = @(for ($i = 0; $i -lt $ways.Count; $i++) { if ($onlyN -contains ($i + 1)) { $ways[$i] } }) }
# a car's samples around its biggest turn or move (every 3rd frame, 1.5 s before to 1.5 s after): t yaw/pitch/roll moved
$series = "local function wrap(d) return (d + 180) % 360 - 180 end local o = {} for _, k in ipairs({ 'own', 'twin' }) do local s = SPIN[k] or {} local a = s[1] " +
    "if a then local bi, bv = 1, 0 for i, x in ipairs(s) do local v = math.max(math.abs(wrap(x[5] - a[5])), math.abs(wrap(x[6] - a[6])), math.abs(wrap(x[7] - a[7]))) + math.sqrt((x[2] - a[2]) ^ 2 + (x[3] - a[3]) ^ 2) / 10 if v > bv then bi, bv = i, v end end " +
    "if bv > 2 then local l = {} for i, x in ipairs(s) do if math.abs(x[1] - s[bi][1]) <= 1.5 and i % 3 == 0 then l[#l + 1] = string.format('%.2f:%.1f/%.1f/%.1f:%.0f', x[1], wrap(x[5] - a[5]), wrap(x[6] - a[6]), wrap(x[7] - a[7]), math.sqrt((x[2] - a[2]) ^ 2 + (x[3] - a[3]) ^ 2 + (x[4] - a[4]) ^ 2)) end end " +
    "o[#o + 1] = k .. ' ' .. table.concat(l, ' ') end end end return #o > 0 and table.concat(o, ' || ') or '-'"
foreach ($w in $ways) {
    "=== $($w.name), $Rounds rounds"
    $worst = @{ turn = 0; move = 0; line = '' }
    $enteredAll = $true
    for ($r = 1; $r -le $Rounds; $r++) {
        "  out: " + (OutOf $w.dir $w.kind)
        Start-Sleep 2
        "  park: host $(Park $hd) | guest $(Park $cd)"
        Start-Sleep 2
        SampleStart $w.dir; SampleStart $w.other
        $e = InAt $w.dir $w.kind $w.door
        Start-Sleep 3
        # (the E at the door missed now and then - the player not quite at it: once more)
        if ((InCar $w.dir) -eq 'false') { $e += " | again: " + (InAt $w.dir $w.kind $w.door) }
        Start-Sleep 3
        $inside = InCar $w.dir
        if ($inside -ne 'true') { $enteredAll = $false }
        $a = Send $w.dir $read; $b = Send $w.other $read
        "  round ${r}: E $e | in=$inside"
        "    getting in side: $a"
        "    other side:      $b"
        foreach ($x in @(@{ n = 'getting in side'; d = $w.dir; s = $a }, @{ n = 'other side'; d = $w.other; s = $b })) {
            if ($x.s -match 'turn=([3-9]|\d\d)|move=(2\d|[3-9]\d|\d{3,})') { "      $($x.n) series (t:yaw/pitch/roll:moved): " + (Send $x.d $series) }
        }
        "      guest: " + (Send $cd "local m = FindFirstOf('BP_CarManager_C') return 'ign=' .. tostring(m.CarIgnitionState) .. ' gear=' .. tostring(m.MyCarGearBox) .. ' ' .. tostring(CoopPlayers.nativeInfo():match('ctx=%S+'))") + " | host: " + (Send $hd "local m = FindFirstOf('BP_CarManager_C') return 'ign=' .. tostring(m.CarIgnitionState) .. ' gear=' .. tostring(m.MyCarGearBox) .. ' ' .. tostring(CoopPlayers.nativeInfo():match('ctx=%S+'))")
        foreach ($s in @($a, $b)) {
            foreach ($m in [regex]::Matches($s, 'turn=([\d.]+) \([^)]*\) move=([\d.]+)')) {
                $tt = [double]$m.Groups[1].Value; $mm = [double]$m.Groups[2].Value
                if ($tt -gt $worst.turn) { $worst.turn = $tt; $worst.line = "round $r - $s" }
                if ($mm -gt $worst.move) { $worst.move = $mm }
            }
        }
    }
    Check "$($w.name): every entry succeeded; no car turned (<= $MaxDeg deg) or moved (<= $MaxMove) on either side" ($enteredAll -and $worst.turn -le $MaxDeg -and $worst.move -le $MaxMove) ("entered every round: {0}; worst turn {1:N1} deg, move {2:N0} | {3}" -f $enteredAll, $worst.turn, $worst.move, $worst.line)
    "  out: " + (OutOf $w.dir $w.kind)
}
"=== the mod's own spin watch (playersync TD.spinWatch: a car turning on the spot noted in the hitch log)"
# (a real game's report shows when it happens: the hitch log's "spin:" lines; here the host's own car turned 45 on the
# spot by hand - it must be noted, and none of the entries above should have been)
function Spins([string]$s) { if ($s -match 'spins=(\d+)') { [int]$Matches[1] } else { -1 } }
$h0 = Send $hd "return CoopPlayers.spinInfo()"; $c0 = Send $cd "return CoopPlayers.spinInfo()"
"  host: " + (Send $hd ($carOf + "local c = carOf('own') local r = c:K2_GetActorRotation() c:K2_SetActorRotation({ Pitch = r.Pitch, Yaw = r.Yaw + 45, Roll = r.Roll }, true) return 'turned 45'"))
Start-Sleep 3
$h1 = Send $hd "return CoopPlayers.spinInfo()"
Check "the spin watch saw none during the entries, then the car turned by hand" ((Spins $h0) -eq 0 -and (Spins $c0) -eq 0 -and (Spins $h1) -ge 1) "before: host $h0 | guest $c0 | after: host $h1"
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
