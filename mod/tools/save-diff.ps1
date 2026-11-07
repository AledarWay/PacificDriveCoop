# Compares the zone of two game saves (the game's own idea of a zone's state, 2026-10-30): the host's and the guest's
# save made in the same zone with the sync running (cmds/save-probe.lua SP_OP='save'). Every /Map object with a
# transform, by class + place (TolCm); prints per class: matched, host only, guest only, and the properties that differ
# on matched ones (first few).
#   -HostTree / -GuestTree: trees from save-dump.ps1 -Tree
param([Parameter(Mandatory)][string]$HostTree, [Parameter(Mandatory)][string]$GuestTree, [int]$TolCm = 50, [int]$Show = 6)

function Read-Zone([string]$file) {
    $objs = @{}
    foreach ($line in [IO.File]::ReadLines($file)) {
        if (-not $line.StartsWith('/Map/_objects/')) { continue }
        $t = $line.Split("`t")
        $path = $t[0].Substring(14)
        $s = $path.IndexOf('/')
        if ($s -lt 0) { continue }
        $id = $path.Substring(0, $s); $rest = $path.Substring($s + 1)
        $o = $objs[$id]
        if (-not $o) { $o = @{ props = @{} }; $objs[$id] = $o }
        if ($rest -eq '_class') { $o.cls = $t[2] -replace '^.*\.', '' }
        elseif ($rest -eq '_name') { $o.name = $t[2] }
        elseif ($rest -eq '_data/_transform') { $o.pos = $t[2] }
        elseif ($rest -eq '_data/_intrinsic') { $o.intr = $t[2] }
        elseif ($rest.StartsWith('_data/') -and $t.Count -ge 3 -and $rest -notmatch '^_data/_components/.*\._class$') {
            # (references hold per-save names / guids: compared by their class only)
            $v = if ($t[1] -eq 'ref') { ($t[2] -split ' \| ')[1] } else { $t[2] }
            $o.props[$rest.Substring(6)] = $v
        }
    }
    @($objs.Values | Where-Object { $_.pos })
}

$h = Read-Zone $HostTree; $g = Read-Zone $GuestTree
"host objects with a place: $($h.Count); guest: $($g.Count)"
$rows = @()
foreach ($cls in (@($h | ForEach-Object cls) + @($g | ForEach-Object cls) | Sort-Object -Unique)) {
    $hs = @($h | Where-Object { $_.cls -eq $cls }); $gs = [Collections.ArrayList]@($g | Where-Object { $_.cls -eq $cls })
    $matched = 0; $honly = @(); $diffs = @{}
    foreach ($a in $hs) {
        $ax, $ay, $az = $a.pos -split ',' | ForEach-Object { [double]$_ }
        $best = $null; $bd = [double]::MaxValue
        foreach ($b in $gs) {
            $bx, $by, $bz = $b.pos -split ',' | ForEach-Object { [double]$_ }
            $d = [Math]::Sqrt(($ax - $bx) * ($ax - $bx) + ($ay - $by) * ($ay - $by) + ($az - $bz) * ($az - $bz))
            if ($d -lt $bd) { $bd = $d; $best = $b }
        }
        if ($best -and $bd -le $TolCm) {
            $matched++; $gs.Remove($best)
            foreach ($k in $a.props.Keys) {
                if ($best.props[$k] -ne $a.props[$k] -and $k -notmatch 'Owner$|_transform') { $diffs[$k] = 1 + [int]$diffs[$k] }
            }
        } else { $honly += $a }
    }
    $rows += [pscustomobject]@{ cls = $cls; host = $hs.Count; matched = $matched; hostOnly = $honly.Count; guestOnly = $gs.Count
        diff = (($diffs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join '; ')
        hoAt = (($honly | Select-Object -First 2 | ForEach-Object { $_.pos }) -join ' ')
        goAt = (($gs | Select-Object -First 2 | ForEach-Object { $_.pos }) -join ' ') }
}
"== classes with a difference (host only / guest only / differing properties)"
$rows | Where-Object { $_.hostOnly -or $_.guestOnly -or $_.diff } | Sort-Object { $_.hostOnly + $_.guestOnly } -Descending |
    Format-Table cls, host, matched, hostOnly, guestOnly, diff, hoAt, goAt -AutoSize | Out-String -Width 400
"== totals: matched $(($rows | Measure-Object matched -Sum).Sum), host only $(($rows | Measure-Object hostOnly -Sum).Sum), guest only $(($rows | Measure-Object guestOnly -Sum).Sum)"
