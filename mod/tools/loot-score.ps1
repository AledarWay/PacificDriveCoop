# Scores loot replication: every host actor with loot is matched to a client actor of the same class
# within -Tol units; its loot string must be identical. Prints mismatches and a PASS/FAIL line.
# -TolW: position tolerance for world items (W|), which fall and roll with physics after spawning.
param([string]$HostLoot, [string]$ClientLoot, [double]$Tol = 5, [double]$TolW = 150, [double]$PassPct = 95, [int]$Show = 8)

function Load($f) {
    Get-Content $f | ForEach-Object {
        $p = $_ -split "`t", 5
        [pscustomobject]@{ C = $p[0]; X = [double]$p[1]; Y = [double]$p[2]; Z = [double]$p[3]; L = $p[4] }
    }
}
# short form for display: keep only asset names
function Short($s) { ($s -replace '/Game/[^@,;~{}|=]*?/([^/.@,;~{}|=]+)\.[^@,;~{}|=]+', '$1') }

$h = @(Load $HostLoot); $c = [System.Collections.ArrayList]@(Load $ClientLoot)
$found = 0; $same = 0; $bad = @()
$kinds = @{ C = @(0, 0); T = @(0, 0); W = @(0, 0); R = @(0, 0) }
foreach ($e in $h) {
    $k = $e.L.Substring(0, 1)
    if (-not $kinds.ContainsKey($k)) { $kinds[$k] = @(0, 0) } # a new lootsync kind must not abort every test
    $kinds[$k][0]++
    $hit = $null
    $tl = if ($k -eq 'W') { $TolW } else { $Tol }
    # world items lie in clusters (e.g. a cabinet drops several): prefer an identical item nearby
    foreach ($needSame in @($true, $false)) {
        if ($hit) { break }
        for ($i = 0; $i -lt $c.Count; $i++) {
            $q = $c[$i]
            if ($needSame -and $q.L -ne $e.L) { continue }
            if ($q.C -eq $e.C -and [math]::Abs($q.X - $e.X) -le $tl -and [math]::Abs($q.Y - $e.Y) -le $tl -and [math]::Abs($q.Z - $e.Z) -le $tl) { $hit = $q; $c.RemoveAt($i); break }
        }
    }
    if ($hit) {
        $found++
        if ($hit.L -eq $e.L) { $same++; $kinds[$k][1]++ } else { $bad += [pscustomobject]@{ Class = $e.C; Host = (Short $e.L); Client = (Short $hit.L) } }
    } else { $bad += [pscustomobject]@{ Class = $e.C; Host = (Short $e.L); Client = '<no actor at this position>' } }
}
$bad | Select-Object -First $Show | ForEach-Object { "--- $($_.Class)`n  host:   $($_.Host)`n  client: $($_.Client)" }
"containers identical: $($kinds.C[1]) / $($kinds.C[0]); templates identical: $($kinds.T[1]) / $($kinds.T[0]); world items identical: $($kinds.W[1]) / $($kinds.W[0]); resources (anchors) identical: $($kinds.R[1]) / $($kinds.R[0])"
$extra = @($c | Where-Object { $_.L })
"client loot actors with no host counterpart: $($extra.Count)"
$extra | Select-Object -First $Show | ForEach-Object { "  client-only: $($_.C) $(Short $_.L) at $([int]$_.X),$([int]$_.Y),$([int]$_.Z)" }
$pct = [math]::Round(100 * $same / [math]::Max($h.Count, 1), 1)
"loot actors on host: $($h.Count); matched by position: $found; identical contents: $same ($pct%)"
if ($pct -ge $PassPct -and $extra.Count -eq 0) { "LOOT PASS" } else { "LOOT FAIL (need >= $PassPct% identical and 0 client-only)" }

