# The bots and the shared state comparison of the long sessions (soak-test, journey-test). Dot-source it after
# $t (tools), $hd / $cd (the instances), $out (a folder for digests), $Seed, $SettleSec and the functions Send, P, KV
# and Log are set. Act <tag> <dir> <where> <other where>: one random player action by where it is; StateCheck <n>:
# both sides compared (cars against twins, characters against puppets, every other time the loot) until alike.
# Counters: $script:count (actions), checks / converged / settle / failed / lootBad / health / errs / mem.
$script:health = @(); $script:errs = @{}; $script:mem = @()
$FAB = '/Game/Gameplay/Inventory/Items/Resources/Basic/RawFabric/IA_Resource_Raw_Fabric.IA_Resource_Raw_Fabric'
$STEEL = '/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel'
. "$t\compare-state.ps1"
function Probe($dir, [string]$pre, [string]$file) { Send $dir ($pre + " " + (Get-Content "$t\cmds\$file" -Raw)) }
function Ops($dir, [string]$op, [string]$extra = '') { Probe $dir "SOAK_OP = '$op' $extra" 'soak-ops.lua' }
function Store($dir, [string]$op, [string]$arch, [int]$n = 1) { Probe $dir "ST_OP = '$op' ST_ARCH = '$arch' ST_N = $n" 'store-ops.lua' }
function SetPart($dir, [string]$which, [string]$slot, [string]$kv) { Probe $dir "STATE_CAR = '$which' STATE_SET = { slot = '$slot', $kv } STATE_SLOTS = {'$slot'}" 'part-state.lua' }

$rng = New-Object System.Random $Seed
function Rnd([double]$a, [double]$b) { $a + $rng.NextDouble() * ($b - $a) }
function Pick($weights) {
    $sum = 0; foreach ($w in $weights.Values) { $sum += $w }
    $x = $rng.NextDouble() * $sum
    foreach ($k in ($weights.Keys | Sort-Object)) { $x -= $weights[$k]; if ($x -le 0) { return $k } }
    ($weights.Keys | Sort-Object)[-1]
}
function Fmt([double]$x) { $x.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) }

# ---- one bot step on one side ($tag: host / guest)
$WHEELS = 'Car.Equip.Essentials.WheelFL', 'Car.Equip.Essentials.WheelFR', 'Car.Equip.Essentials.WheelRL', 'Car.Equip.Essentials.WheelRR'
$DOORSLOT = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR' }
$script:count = @{}
function Act($tag, $dir, $w, $otherW) {
    $where = $w.where
    $weights = switch ($where) {
        'own'  { @{ drive = 40; ram = $(if ($otherW.where -eq 'twin') { 0 } else { 8 }); horn = 4; lights = 4; radio = 4; exit = 14; owntrunk = 5; ownpart = 4 } }
        'twin' { @{ drivetwin = $(if ($w.seat -eq '1') { 35 } else { 0 }); leave = 30; sit = 15; owntrunk = 5 } }
        default { @{ walk = 15; enter = 15; visit = 20; loot = 10; trunk = 18; part = 8; owntrunk = 5; ownpart = 3 } }
    }
    $a = Pick $weights
    $script:count["$tag.$a"] = 1 + [int]$script:count["$tag.$a"]
    $r = switch ($a) {
        'drive' { Send $dir "return CoopPlayers.botInput($(Fmt (Rnd 2 6)), $(Fmt (Rnd 0.4 1.0)), $(Fmt (Rnd -0.7 0.7)))" }
        'ram' { (Probe $dir "COL_OP = 'aim' COL_BACK = $([int](Rnd 1200 2200))" 'collide-probe.lua') + ' | ' + (Send $dir "return CoopPlayers.botInput(4, 1.0, 0)") }
        'horn' { Ops $dir 'horn' }
        'lights' { ((Probe $dir "CTL_DO = 'toggle_head'" 'ctl-probe.lua') -split "`n" | Select-Object -Index 1) }
        'radio' { Send $dir "local T = CoopPlayers.twinModule() return tostring(T.changeChannel(T.ownCar(), $(if ($rng.Next(2) -eq 0) { 1 } else { -1 })))" }
        'exit' { Send $dir "return CoopPlayers.botExitCar()" }
        'enter' { Send $dir "return CoopPlayers.botEnterCar()" }
        'walk' { (Ops $dir 'face' "SOAK_YAW = $([int](Rnd -180 180))") + ' | ' + (Send $dir "return CoopPlayers.botWalk($(Fmt (Rnd 1 4)), $(Fmt (Rnd 0.4 1.0)))") }
        'visit' {
            # (seat 3 freed of its device in the setup: the driver's and the device seats only open the door)
            $door = if ($rng.Next(4) -eq 0) { $rng.Next(1, 5) } else { 3 }
            $look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
            $h = ''
            foreach ($dz in 0, 20, -20, 40) {
                Send $dir "LOOK_DZ = $dz LOOK_SLOT = '$($DOORSLOT[$door])' $look" | Out-Null
                Start-Sleep -Milliseconds 700
                $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
                if ($h -match "^$door\s*$") { break }
            }
            $e = Ops $dir 'interact' 'SOAK_MS = 100'; Start-Sleep 3
            "door $door (highlighted $h): $e -> " + (Ops $dir 'where')
        }
        'leave' { (Send $dir "return CoopPlayers.botTwinLookAt('FrontLeftWheel_Mesh')") + ' | ' + (Ops $dir 'interact' 'SOAK_MS = 100') + ' -> ' + $(Start-Sleep 3; Ops $dir 'where') }
        'sit' { 'sits' }
        'drivetwin' { Ops $dir 'drivetwin' "SOAK_S = $(Fmt (Rnd 2 5)) SOAK_THR = $(Fmt (Rnd 0.5 1.0)) SOAK_STEER = $(Fmt (Rnd -0.6 0.6))" }
        'loot' { $only = @('open', 'take', 'pick')[$rng.Next(3)]; (Send $dir "BOT_SKIP = $($rng.Next(0, 6)) BOT_ONLY = '$only' $(Get-Content "$t\cmds\bot-actions.lua" -Raw)") -replace "`n", ' ' }
        'trunk' {
            $op = @('twintake', 'twinput', 'twinmove')[$rng.Next(3)]
            Store $dir $op $(if ($rng.Next(2) -eq 0) { $FAB } else { $STEEL }) 1
        }
        'owntrunk' { Store $dir $(if ($rng.Next(2) -eq 0) { 'add' } else { 'take' }) $(if ($rng.Next(2) -eq 0) { $FAB } else { $STEEL }) $rng.Next(1, 3) }
        'part' {
            if ($rng.Next(3) -eq 0) { SetPart $dir 'twin' 'Car.Equip.Attachments.FuelCan' "fuel = $([int](Rnd 2 10))" }
            else { SetPart $dir 'twin' $WHEELS[$rng.Next(4)] "health = $([int](Rnd 120 175))" }
        }
        'ownpart' { SetPart $dir 'own' $WHEELS[$rng.Next(4)] "health = $([int](Rnd 60 175))" }
    }
    "$a`: " + ("$r" -replace "`n", ' ' | ForEach-Object { $_.Substring(0, [math]::Min(160, $_.Length)) })
}

# ---- the comparison
$script:checks = 0; $script:converged = 0; $script:settle = @(); $script:failed = @{}; $script:lootBad = 0
function Digest($dir, $file) { Probe $dir "DIGEST_OUT = '$(P $file)'" 'digest.lua' | Out-Null; ReadDigest $file }
function StateCheck([int]$n) {
    $script:checks++
    $t0 = Get-Date
    while ($true) {
        $h = Digest $hd "$out\h.txt"; $g = Digest $cd "$out\g.txt"
        $res = @(CompareState $h $g)
        $bad = @($res | Where-Object { -not $_.Ok })
        $sec = ((Get-Date) - $t0).TotalSeconds
        if ($bad.Count -eq 0) { $script:converged++; $script:settle += $sec; Log ("  check {0}: all {1} alike after {2:N0} s" -f $n, $res.Count, $sec); break }
        if ($sec -ge $SettleSec -or $script:dead) {
            foreach ($b in $bad) {
                Log "  check $n DIFF $($b.Name): $($b.Detail)"
                if (-not $script:failed.ContainsKey($b.Name)) { $script:failed[$b.Name] = @(0, "check $n`: $($b.Detail)") }
                $script:failed[$b.Name][0]++
            }
            Copy-Item "$out\h.txt" "$out\check$n-host.txt"; Copy-Item "$out\g.txt" "$out\check$n-guest.txt"
            break
        }
        Start-Sleep 2
    }
    # the world's loot (every other check: the export walks the zone)
    if ($n % 2 -eq 0) {
        Send $hd "return CoopSync.exportLoot('$(P "$out\loot-h.tsv")')" | Out-Null
        Send $cd "return CoopSync.exportLoot('$(P "$out\loot-g.tsv")')" | Out-Null
        $ls = (& "$t\loot-score.ps1" -HostLoot "$out\loot-h.tsv" -ClientLoot "$out\loot-g.tsv" -Show 3) -join ' | '
        # (the guest's own sites built after a zone-save load go with the stray sweep's 10 s grace: once more 15 s on)
        if ($ls -notmatch 'LOOT PASS') {
            Copy-Item "$out\loot-h.tsv" "$out\check$n-first-loot-h.tsv"; Copy-Item "$out\loot-g.tsv" "$out\check$n-first-loot-g.tsv"
            Log "  loot not alike yet: $(($ls -split ' \| ' | Select-Object -Last 2) -join ' | ') - again in 15 s"
            Start-Sleep 15
            Send $hd "return CoopSync.exportLoot('$(P "$out\loot-h.tsv")')" | Out-Null
            Send $cd "return CoopSync.exportLoot('$(P "$out\loot-g.tsv")')" | Out-Null
            $ls = (& "$t\loot-score.ps1" -HostLoot "$out\loot-h.tsv" -ClientLoot "$out\loot-g.tsv" -Show 3) -join ' | '
        }
        if ($ls -notmatch 'LOOT PASS') { $script:lootBad++; Copy-Item "$out\loot-h.tsv" "$out\check$n-loot-h.tsv"; Copy-Item "$out\loot-g.tsv" "$out\check$n-loot-g.tsv" }
        Log "  loot: $(($ls -split ' \| ' | Select-Object -Last 2) -join ' | ')"
    }
    # health
    $script:health += , @{ n = $n; h = $h['info']; g = $g['info'] }
    Log "  host: $($h['info'])"
    Log "  guest: $($g['info'])"
    foreach ($x in @(@{ t = 'host'; d = $h }, @{ t = 'guest'; d = $g })) {
        if ($x.d['report'] -match 'ERRORS: (.*)') { $script:errs[$x.t] = $Matches[1] }
    }
    $mem = foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='PenDriverPro-Win64-Shipping.exe'")) {
        $tg = if ($p.CommandLine -match 'instances\\host\\') { 'host' } elseif ($p.CommandLine -match 'instances\\client\\') { 'guest' } else { '?' }
        "$tg={0:N0}MB" -f ($p.WorkingSetSize / 1MB)
    }
    Log "  memory: $($mem -join ' ')"
    $script:mem += , ($mem -join ' ')
}

