# Compares two actor snapshots: per class, how many actors match by position (within -Tol units).
# Usage: compare-snapshots.ps1 A.txt B.txt [-Tol 50] [-Top 25]
param([string]$A, [string]$B, [double]$Tol = 50, [int]$Top = 25)

function Load($f) {
    Get-Content $f | Select-Object -Skip 1 | ConvertFrom-Csv -Delimiter "`t" -Header C, X, Y, Z |
        ForEach-Object { [pscustomobject]@{ C = $_.C; X = [double]$_.X; Y = [double]$_.Y; Z = [double]$_.Z } }
}
$ra = Load $A; $rb = Load $B
"A: $(Get-Content $A -TotalCount 1)  ($($ra.Count) actors)"
"B: $(Get-Content $B -TotalCount 1)  ($($rb.Count) actors)"

$ga = $ra | Group-Object C -AsHashTable -AsString
$gb = $rb | Group-Object C -AsHashTable -AsString
$classes = @($ga.Keys) + @($gb.Keys) | Sort-Object -Unique
$rows = foreach ($c in $classes) {
    $la = @($ga[$c]); $lb = [System.Collections.ArrayList]@($gb[$c])
    if ($null -eq $ga[$c]) { $la = @() }
    if ($null -eq $gb[$c]) { $lb = [System.Collections.ArrayList]@() }
    $matched = 0
    foreach ($p in $la) {
        for ($i = 0; $i -lt $lb.Count; $i++) {
            $q = $lb[$i]
            if ([math]::Abs($p.X - $q.X) -le $Tol -and [math]::Abs($p.Y - $q.Y) -le $Tol -and [math]::Abs($p.Z - $q.Z) -le $Tol) {
                $matched++; $lb.RemoveAt($i); break
            }
        }
    }
    [pscustomobject]@{ Class = $c; A = $la.Count; B = @($gb[$c]).Count * [int]($null -ne $gb[$c]); Matched = $matched;
        Pct = if ([math]::Max($la.Count, 1) -gt 0) { [int](100 * $matched / [math]::Max([math]::Max($la.Count, @($gb[$c]).Count * [int]($null -ne $gb[$c])), 1)) } else { 0 } }
}
$tot = ($rows | Measure-Object A -Sum).Sum; $m = ($rows | Measure-Object Matched -Sum).Sum
"TOTAL matched $m of $tot in A ($([int](100*$m/[math]::Max($tot,1)))%)"
"--- classes that differ most (A count / B count / matched) ---"
$rows | Where-Object { $_.Pct -lt 100 } | Sort-Object { $_.A + $_.B - 2 * $_.Matched } -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 200
"--- gameplay-relevant classes ---"
$rows | Where-Object { $_.Class -match 'Spawn|Loot|WorldItem|Item|Resource|Template|Hazard|Anomal|Trunk' } | Sort-Object Class | Format-Table -AutoSize | Out-String -Width 200
