# Why a host actor is missing on the client (or a client actor is extra): classifies every unmatched actor of
# the replicated classes against the host's spawn list and the client's snapshots before / after import / after
# cleanup. Groups by reason and class, with a few positions each.
#   not-in-list     host actor of a replicated class that the export did not list (not a root, or appeared later)
#   lost-at-import  listed, the client had it before import (same class+spot), gone after import
#   not-spawned     listed, never on the client after import
#   gone-by-cleanup on the client after import, gone after cleanup
#   moved           same class on the client within -Near units (physics settled / rolled differently)
#   at-origin       host actor at 0,0,0 (being placed / parked)
param([string]$Dir = "C:\PacificDriveCoop\local\instances", [string]$SpawnList = "host\coopdev\spawnlist2.tsv",
    [string]$HostSnap = "host\coopdev\snapshot2.txt", [string]$Before = "client\coopdev\snapshot2-before.txt",
    [string]$After = "client\coopdev\snapshot2-after.txt", [string]$Cleanup = "client\coopdev\snapshot2-cleanup.txt",
    [double]$Near = 300, [int]$Show = 3)
function Rows($f) {
    Get-Content (Join-Path $Dir $f) | Select-Object -Skip 1 | ForEach-Object {
        $c = $_ -split "`t"; [pscustomobject]@{ C = $c[0]; X = [double]$c[1]; Y = [double]$c[2]; Z = [double]$c[3] } }
}
function Tol($cls) { if ($cls -match 'WorldItem') { 150 } elseif ($cls -match '^BP_Destruct_') { 25 } else { 5 } }
function Index($rows) { $h = @{}; foreach ($r in $rows) { if (-not $h.ContainsKey($r.C)) { $h[$r.C] = [System.Collections.ArrayList]@() }; [void]$h[$r.C].Add($r) }; $h }
function Find($idx, $p, $tl) {
    if (-not $idx.ContainsKey($p.C)) { return $null }
    foreach ($q in $idx[$p.C]) { if ([math]::Abs($p.X - $q.X) -le $tl -and [math]::Abs($p.Y - $q.Y) -le $tl -and [math]::Abs($p.Z - $q.Z) -le $tl) { return $q } }
    $null
}
$list = Get-Content (Join-Path $Dir $SpawnList) | ForEach-Object { $f = $_ -split "`t"
    [pscustomobject]@{ K = $f[0]; C = ($f[1] -split '\.')[-1]; X = [double]$f[2]; Y = [double]$f[3]; Z = [double]$f[4] } }
$classes = @{}; foreach ($e in $list) { $classes[$e.C] = $true }
$hostRows = Rows $HostSnap | Where-Object { $classes.ContainsKey($_.C) }
$li = Index $list; $bi = Index (Rows $Before | Where-Object { $classes.ContainsKey($_.C) })
$ai = Index (Rows $After | Where-Object { $classes.ContainsKey($_.C) }); $ci = Index (Rows $Cleanup | Where-Object { $classes.ContainsKey($_.C) })
# one-to-one matching against the after-import snapshot, like sync-score
$used = @{}
$out = foreach ($p in $hostRows) {
    $tl = Tol $p.C; $hit = $null
    if ($ai.ContainsKey($p.C)) { foreach ($q in $ai[$p.C]) { if (-not $used[$q] -and [math]::Abs($p.X - $q.X) -le $tl -and [math]::Abs($p.Y - $q.Y) -le $tl -and [math]::Abs($p.Z - $q.Z) -le $tl) { $hit = $q; break } } }
    if ($hit) { $used[$hit] = $true; continue }
    $why = if ($p.X -eq 0 -and $p.Y -eq 0 -and $p.Z -eq 0) { 'at-origin' }
        elseif (-not (Find $li $p ([math]::Max($tl, 5)))) { 'not-in-list' }
        elseif (Find $ai $p $Near) { 'moved' }
        elseif (Find $bi $p $tl) { 'lost-at-import' }
        else { 'not-spawned' }
    [pscustomobject]@{ Why = $why; C = $p.C; At = "{0:0},{1:0},{2:0}" -f $p.X, $p.Y, $p.Z }
}
$extra = foreach ($cls in $ai.Keys) { foreach ($q in $ai[$cls]) { if (-not $used[$q]) {
    $why = if (Find $ci $q (Tol $q.C)) { 'extra-kept' } else { 'extra-cleaned' }
    [pscustomobject]@{ Why = $why; C = $q.C; At = "{0:0},{1:0},{2:0}" -f $q.X, $q.Y, $q.Z } } } }
"host actors: $($hostRows.Count); unmatched: $(@($out).Count); client unmatched after import: $(@($extra).Count)"
foreach ($g in (@($out) + @($extra) | Group-Object Why | Sort-Object Count -Descending)) {
    "== $($g.Name): $($g.Count)"
    foreach ($c in ($g.Group | Group-Object C | Sort-Object Count -Descending)) {
        "   {0,4} {1}  e.g. {2}" -f $c.Count, $c.Name, (($c.Group | Select-Object -First $Show | ForEach-Object At) -join ' ')
    }
}
