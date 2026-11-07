# The host's and the guest's worlds compared (cmds/world-digest.lua on each side): the sun / time / weather event,
# every class's actor count and places, the looks of abandoned cars / lamps (owner's alpha 18 test: items 6, 15, 16,
# 18, 20, 36 - the sky, clouds, a lamp, the abandoned cars, a whole trial zone differed).
# Dot-source it for WorldDigest / CompareWorld, or run it on two digest files:
#   world-compare.ps1 <host digest> <guest digest>
param([string]$HostFile, [string]$GuestFile)

# classes that move or belong to one side only: not judged by place
$script:WorldMoving = 'Character|PlayerCar|Puppet|Camera|Controller|Pawn|Projectile|HUD|PlayerState|GameState|GameMode|Spectator|Emitter|Sound|Manifestation|CarPart|Ghost|Twin|Debris|Ragdoll|Physics|Pickup|Loot|Item_'

function ReadWorld($f) {
    $w = @{ cls = @{}; mat = @{} }
    foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) {
        $k, $rest = $l -split ' ', 2
        switch ($k) {
            'cls' { $c, $n, $at = $rest -split ' ', 3; $w.cls[$c] = @{ n = [int]$n; at = @(($at -split ';') | Where-Object { $_ }) } }
            'mat' { $c, $m = $rest -split ' ', 2; $w.mat[$c] = $m }
            default { $w[$k] = $rest }
        }
    }
    $w
}
# places of a that have no place of b within $tol metres
function Unmatched($a, $b, [double]$tol = 3) {
    $pb = @($b | ForEach-Object { , ([double[]]($_ -split ',')) })
    $miss = 0
    foreach ($s in $a) {
        $p = [double[]]($s -split ','); $hit = $false
        foreach ($q in $pb) { if ([math]::Abs($p[0] - $q[0]) -le $tol -and [math]::Abs($p[1] - $q[1]) -le $tol -and [math]::Abs($p[2] - $q[2]) -le $tol) { $hit = $true; break } }
        if (-not $hit) { $miss++ }
    }
    $miss
}
function CompareWorld($hf, $gf, [int]$max = 12) {
    $h = ReadWorld $hf; $g = ReadWorld $gf
    $out = @()
    $th = [double]$h.tod; $tg = [double]$g.tod; $dt = [math]::Abs($th - $tg); $dt = [math]::Min($dt, 1 - $dt)
    $out += [pscustomobject]@{ Name = 'time of day'; Ok = $dt -lt 0.003; Detail = "host $($h.tod) guest $($g.tod)" }
    $out += [pscustomobject]@{ Name = 'sun'; Ok = $h.sun -eq $g.sun; Detail = "host $($h.sun) guest $($g.sun)" }
    $out += [pscustomobject]@{ Name = 'weather event'; Ok = $h.event -eq $g.event; Detail = "host $($h.event) guest $($g.event)" }
    $count = @(); $place = @(); $looks = @()
    foreach ($c in (@($h.cls.Keys) + @($g.cls.Keys) | Sort-Object -Unique)) {
        if ($c -match $script:WorldMoving) { continue }
        $a = $h.cls[$c]; $b = $g.cls[$c]
        $na = if ($a) { $a.n } else { 0 }; $nb = if ($b) { $b.n } else { 0 }
        if ($na -ne $nb) { $count += "$c $na/$nb"; continue }
        $u = Unmatched $a.at $b.at
        if ($u -gt 0) { $place += "$c $u/$na" }
        if ($h.mat[$c] -ne $g.mat[$c]) { $looks += "$c host[$($h.mat[$c])] guest[$($g.mat[$c])]" }
    }
    $fmt = { param($l) (($l | Select-Object -First $max) -join ' | ') + $(if ($l.Count -gt $max) { " | +$($l.Count - $max) more" } else { '' }) }
    $out += [pscustomobject]@{ Name = 'actor counts by class'; Ok = $count.Count -eq 0; Detail = "$($count.Count) differ (host/guest): " + (& $fmt $count) }
    $out += [pscustomobject]@{ Name = 'actor places'; Ok = $place.Count -eq 0; Detail = "$($place.Count) classes with places only on the host (unmatched/all): " + (& $fmt $place) }
    $out += [pscustomobject]@{ Name = 'looks (abandoned cars, lamps)'; Ok = $looks.Count -eq 0; Detail = (& $fmt $looks) }
    $out
}
if ($HostFile -and $GuestFile) { CompareWorld $HostFile $GuestFile | ForEach-Object { "  [{0}] {1} -- {2}" -f $(if ($_.Ok) { 'PASS' } else { 'FAIL' }), $_.Name, $_.Detail } }
