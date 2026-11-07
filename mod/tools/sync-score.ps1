# Scores spawn replication: for every class in the host's spawn list, how many host actors have a
# client actor of the same class within -Tol units. Prints per-class rows and a PASS/FAIL line.
# -ClientSnap: client snapshot right after import (positions are scored here).
# -ExtraSnap:  optional later client snapshot (after cleanup); extras = per-class count above the host's.
#              Positions are not scored there because physics/AI actors keep moving.
# -ShowMisses: also print the unmatched host / client positions of the classes that did not match.
param([string]$SpawnList, [string]$HostSnap, [string]$ClientSnap, [string]$ExtraSnap = "", [double]$Tol = 5, [double]$PassPct = 95, [string]$DynamicClasses = 'WorldItem', [double]$DynamicTol = 150, [string]$PhysicsClasses = '^BP_Destruct_', [double]$PhysicsTol = 25, [switch]$ShowMisses,
    [string]$ExtraClasses = '^BP_BuildingFrame_', [int]$ExtraTol = 0)
$misses = @()

function Load($f) {
    Get-Content $f | Select-Object -Skip 1 | ConvertFrom-Csv -Delimiter "`t" -Header C, X, Y, Z |
        ForEach-Object { [pscustomobject]@{ C = $_.C; X = [double]$_.X; Y = [double]$_.Y; Z = [double]$_.Z } }
}
# v1 list: ClassPath first; v2 list: Kind (L/R/D) first, then ClassPath (rows P - prefab dressing - are scored by the
# full snapshot comparison in sync-test, after the cleanup that aligns them)
$classes = Get-Content $SpawnList | Where-Object { $_ -notmatch "^P`t" } | ForEach-Object { $f = $_ -split "`t"; $cp = if ($f[0].Length -eq 1) { $f[1] } else { $f[0] }; ($cp -split '\.')[-1] } | Sort-Object -Unique
# also score classes that are not in the list but must match (buildings: built by replicated site spawners)
if ($ExtraClasses) { $classes = @($classes) + @(Load $HostSnap | Where-Object { $_.C -match $ExtraClasses } | ForEach-Object C) | Sort-Object -Unique }
$h = Load $HostSnap | Where-Object { $classes -contains $_.C } | Group-Object C -AsHashTable -AsString
$c = Load $ClientSnap | Where-Object { $classes -contains $_.C } | Group-Object C -AsHashTable -AsString

$rows = foreach ($cls in $classes) {
    $ha = @(); if ($h -and $h.ContainsKey($cls)) { $ha = @($h[$cls]) }
    $cb = [System.Collections.ArrayList]@(); if ($c -and $c.ContainsKey($cls)) { $cb = [System.Collections.ArrayList]@($c[$cls]) }
    $nb = $cb.Count; $m = 0
    # loose items roll (DynamicTol); physics props like traffic cones settle a few cm differently on
    # each machine (observed 15 units in Z), which is below the client snap-back threshold (20)
    $tl = if ($cls -match $DynamicClasses) { $DynamicTol } elseif ($cls -match $PhysicsClasses) { $PhysicsTol } else { $Tol }
    foreach ($p in $ha) {
        $hit = $false
        for ($i = 0; $i -lt $cb.Count; $i++) {
            $q = $cb[$i]
            if ([math]::Abs($p.X - $q.X) -le $tl -and [math]::Abs($p.Y - $q.Y) -le $tl -and [math]::Abs($p.Z - $q.Z) -le $tl) { $m++; $cb.RemoveAt($i); $hit = $true; break }
        }
        if (-not $hit) { $misses += "  miss host   $cls at $($p.X),$($p.Y),$($p.Z)" }
    }
    foreach ($q in $cb) { $misses += "  miss client $cls at $($q.X),$($q.Y),$($q.Z)" }
    [pscustomobject]@{ Class = $cls; Host = $ha.Count; Client = $nb; Matched = $m; Extra = $nb - $m }
}
if ($ExtraSnap) {
    $x = Load $ExtraSnap | Where-Object { $classes -contains $_.C } | Group-Object C -AsHashTable -AsString
    foreach ($r in $rows) {
        $n = 0; if ($x -and $x.ContainsKey($r.Class)) { $n = @($x[$r.Class]).Count }
        $r.Extra = [math]::Max(0, $n - $r.Host)
    }
}
$H = ($rows | Measure-Object Host -Sum).Sum; $M = ($rows | Measure-Object Matched -Sum).Sum; $E = ($rows | Measure-Object Extra -Sum).Sum
$rows | Where-Object { $_.Matched -lt $_.Host -or $_.Extra -gt 0 } | Sort-Object { ($_.Host - $_.Matched) + $_.Extra } -Descending |
    Format-Table -AutoSize | Out-String -Width 200
if ($ShowMisses -and $misses.Count -gt 0) { $misses | Select-Object -First 20 }
$pct = [math]::Round(100 * $M / [math]::Max($H, 1), 1)
"replicated classes: $($classes.Count); host actors: $H; matched on client: $M ($pct%); extra on client: $E"
if ($pct -ge $PassPct -and $E -le $ExtraTol) { "PASS" } else { "FAIL (need >= $PassPct% matched and <= $ExtraTol extra)" }

