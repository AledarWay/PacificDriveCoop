# Semantic diff of two Run.carState() files: per car slot + archetype, the leaf values of the item's data
# block (JSON with "_t" type tags and "_v" values; the tags change form between a fresh and a loaded item,
# so only values are compared). Prints GONE / NEW items and changed values; exit code 0 = same.
param([string]$Before, [string]$After, [int]$Show = 30)
function Leaves($node, [string]$path, $acc) {
    if ($null -eq $node) { return }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq '_t' -or $p.Name -eq '_version' -or $p.Name -eq '_revision') { continue }
            $sub = if ($p.Name -eq '_v') { $path } else { "$path/$($p.Name)" }
            Leaves $p.Value $sub $acc
        }
    } elseif ($node -is [System.Array]) {
        # a tagged value can come as [tag, value] or as an array of entries
        $vals = @($node | Where-Object { -not ($_ -is [string] -and $_.Length -le 4 -and $_ -match '^[A-Z@:^*]+$') })
        $i = 0; foreach ($v in $vals) { Leaves $v "$path[$i]" $acc; $i++ }
    } else {
        $acc[$path] = "$node"
    }
}
function Load($f) {
    $h = @{}
    foreach ($l in (Get-Content $f | Where-Object { $_ })) {
        $p = $l -split "`t", 3
        $k = "$($p[0]) $($p[1])"; $n = 1; while ($h.ContainsKey($k)) { $n++; $k = "$($p[0]) $($p[1]) #$n" }
        $acc = @{}
        try { Leaves ($p[2] | ConvertFrom-Json) '' $acc } catch { $acc['<unparsed>'] = $p[2] }
        $h[$k] = $acc
    }
    $h
}
$A = Load $Before; $B = Load $After
$lines = @()
foreach ($k in ($A.Keys + $B.Keys | Sort-Object -Unique)) {
    if (-not $B.ContainsKey($k)) { $lines += "GONE  $k"; continue }
    if (-not $A.ContainsKey($k)) { $lines += "NEW   $k"; continue }
    $a = $A[$k]; $b = $B[$k]
    foreach ($f in ($a.Keys + $b.Keys | Sort-Object -Unique)) {
        if ($a[$f] -ne $b[$f]) { $lines += "CHG   $k $f : $($a[$f]) -> $($b[$f])" }
    }
}
"car items: before $($A.Count), after $($B.Count); differences: $($lines.Count)"
$lines | Select-Object -First $Show
if ($lines.Count -gt 0) { exit 1 } else { exit 0 }
