# Scores how well an observer's copy follows an owner's actor, from two position traces
# (lines: <ms>\t<kind>\tx\ty\tz; both processes on one PC share the wall clock).
#   final error : last observer sample vs last owner sample in the window (after the motion settled)
#   on-path     : share of observer samples during the motion that lie within -PathTol of the owner's path
#   lag         : median of (observer time - owner time at the nearest owner sample), motion samples only
param([string]$OwnerTrace, [string]$OwnerKind, [string]$ObsTrace, [string]$ObsKind, [long]$From, [long]$To, [string]$Name,
      [double]$FinalTol = 15, [double]$PathTol = 50, [double]$PathPct = 90, [double]$MaxLagMs = 600)
function Load($f, $kind) {
    Get-Content $f | ForEach-Object { $p = $_ -split "`t"; if ($p[1] -eq $kind) { [pscustomobject]@{ T = [long]$p[0]; X = [double]$p[2]; Y = [double]$p[3]; Z = [double]$p[4] } } } |
        Where-Object { $_.T -ge $From -and $_.T -le $To }
}
$o = @(Load $OwnerTrace $OwnerKind); $b = @(Load $ObsTrace $ObsKind)
if ($o.Count -lt 2 -or $b.Count -lt 2) { "[$Name] FAIL: not enough samples (owner $($o.Count), observer $($b.Count))"; return }
function D($p, $q) { [math]::Sqrt(($p.X - $q.X) * ($p.X - $q.X) + ($p.Y - $q.Y) * ($p.Y - $q.Y) + ($p.Z - $q.Z) * ($p.Z - $q.Z)) }
$final = D $o[-1] $b[-1]
# motion window: from the first owner sample that left the start to the last one that changed
$moving = @(for ($i = 1; $i -lt $o.Count; $i++) { if ((D $o[$i] $o[$i - 1]) -gt 1) { $o[$i] } })
$travel = D $o[0] $o[-1]
if ($moving.Count -eq 0) { "[$Name] FAIL: owner did not move"; return }
$m0 = $moving[0].T; $m1 = $moving[-1].T
$bm = @($b | Where-Object { $_.T -ge $m0 -and $_.T -le ($m1 + 500) })
$onPath = 0; $lags = @()
foreach ($q in $bm) {
    $best = $null; $bd = 1e12
    foreach ($p in $o) { $d = D $p $q; if ($d -lt $bd) { $bd = $d; $best = $p } }
    if ($bd -le $PathTol) { $onPath++ }
    $lags += ($q.T - $best.T)
}
$pct = if ($bm.Count) { [math]::Round(100 * $onPath / $bm.Count, 1) } else { 0 }
$lag = if ($lags.Count) { ($lags | Sort-Object)[[int]($lags.Count / 2)] } else { 0 }
$ok = $final -le $FinalTol -and $pct -ge $PathPct -and $lag -le $MaxLagMs
"[{0}] owner travelled {1:N0}; final error {2:N1} (<= {3}); on path {4}% of {5} samples (>= {6}%); median lag {7} ms (<= {8}) -> {9}" -f $Name, $travel, $final, $FinalTol, $pct, $bm.Count, $PathPct, $lag, $MaxLagMs, $(if ($ok) { 'PASS' } else { 'FAIL' })
