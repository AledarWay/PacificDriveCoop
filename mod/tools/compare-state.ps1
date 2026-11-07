# The shared state comparison: two digests (cmds/digest.lua: one per side) compared each car against its twin on the
# other side, and each character against its puppet there. Dot-source it for CompareState, or run it on two files:
#   compare-state.ps1 <host digest> <guest digest>
# CompareState returns one object per item: Name, Ok, Detail ("H car" = the host's car: its own state on the host
# against its twin on the guest; "G car" the other way round).
param([string]$HostFile, [string]$GuestFile)

function ReadDigest($f) {
    $h = @{}
    foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) { $k, $v = $l -split ' ', 2; if ($k) { $h[$k] = "$v" } }
    $h
}
# "a=x;b=y" -> @{ a = x; b = y }
function SemiMap([string]$s) {
    $m = @{}
    if ($s -and $s -ne '-') { foreach ($p in ($s -split ';')) { $k, $v = $p -split '=', 2; if ($k) { $m[$k] = $v } } }
    $m
}
function Short([string]$s) { ($s -replace '/Game/[^@,;~{}|=\t]*?/([^/.@,;~{}|=\t]+)\.[^@,;~{}|=\t]+', '$1') }
# the differing keys of two maps, at most $max of them, through $same (a scriptblock: $a, $b -> bool)
function MapDiff($a, $b, [scriptblock]$same, [int]$max = 4) {
    $keys = @($a.Keys) + @($b.Keys) | Sort-Object -Unique
    $bad = @()
    foreach ($k in $keys) { if (-not (& $same $a[$k] $b[$k])) { $bad += "$(Short $k): $(Short "$($a[$k])") <> $(Short "$($b[$k])")" } }
    @{ n = $bad.Count; text = (($bad | Select-Object -First $max) -join ' | ') + $(if ($bad.Count -gt $max) { " | +$($bad.Count - $max) more" } else { '' }) }
}
function Vec([string]$s) { if (-not $s -or $s -eq '-') { return $null }; $p = $s -split ','; @{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2]; V = $(if ($p.Count -gt 3 -and $p[3] -match '^[\d.]+$') { [double]$p[3] } else { 0 }); W = $p[3] } }
function Dist($a, $b) { [math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y) + ($a.Z - $b.Z) * ($a.Z - $b.Z)) }

$sameStr = { param($x, $y) "$x" -eq "$y" }
# parts: "h,f,b" each within 1 (a twin's part change under 0.5 is not applied: STATE_EPS)
$sameState = { param($x, $y)
    $p = "$x" -split ','; $q = "$y" -split ','
    if ($p.Count -ne $q.Count) { return $false }
    for ($i = 0; $i -lt $p.Count; $i++) {
        if ($p[$i] -eq '' -and $q[$i] -eq '') { continue }
        if ($p[$i] -eq '' -or $q[$i] -eq '') { return $false }
        if ([math]::Abs([double]$p[$i] - [double]$q[$i]) -gt 1.0) { return $false }
    }
    $true }
# lights: "<intensity>[h]": hidden alike, intensity within 5 % (+1)
$sameLight = { param($x, $y)
    if ($null -eq $x -or $null -eq $y) { return $false }
    if ("$x".EndsWith('h') -ne "$y".EndsWith('h')) { return $false }
    $a = [double]("$x".TrimEnd('h')); $b = [double]("$y".TrimEnd('h'))
    [math]::Abs($a - $b) -le 0.05 * [math]::Max($a, $b) + 1 }

# a container string "<layout>!<tile>=<items>;..." with its tiles sorted (the same contents can list the slots in
# another order: the twin's slots are made in the fill's order)
function SortTiles([string]$c) {
    $i = $c.IndexOf('!')
    if ($i -lt 0) { return $c }
    $parts = @(); $depth = 0; $cur = New-Object System.Text.StringBuilder
    foreach ($ch in $c.Substring($i + 1).ToCharArray()) {
        if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- }
        if ($ch -eq ';' -and $depth -eq 0) { $parts += $cur.ToString(); [void]$cur.Clear() } else { [void]$cur.Append($ch) }
    }
    if ($cur.Length) { $parts += $cur.ToString() }
    $c.Substring(0, $i + 1) + (($parts | Sort-Object) -join ';')
}
function TabMap([string]$s) {
    $m = @{}
    if ($s -and $s -ne '-') { $f = $s -split "`t"; for ($i = 0; $i + 1 -lt $f.Count; $i += 2) { $m[$f[$i]] = SortTiles $f[$i + 1] } }
    $m
}

function CompareState($hd, $gd) {
    $out = @()
    foreach ($side in @(@{ n = 'H'; own = $hd; other = $gd }, @{ n = 'G'; own = $gd; other = $hd })) {
        $o = $side.own; $t = $side.other
        $car = "$($side.n) car"
        if ($t['twin.equip'] -eq '-' -or -not $t['twin.equip']) { $out += [pscustomobject]@{ Name = "$car twin"; Ok = $false; Detail = 'no twin on the other side' }; continue }
        $d = MapDiff (SemiMap $o['own.equip']) (SemiMap $t['twin.equip']) $sameStr
        $out += [pscustomobject]@{ Name = "$car equipment"; Ok = $d.n -eq 0; Detail = $d.text }
        $d = MapDiff (SemiMap $o['own.state']) (SemiMap $t['twin.state']) $sameState
        $out += [pscustomobject]@{ Name = "$car parts"; Ok = $d.n -eq 0; Detail = $d.text }
        # (the computer's danger light: the twin's computer shows the LOCAL car's state every frame, like its screens -
        # accepted by the owner for the gauges; NOTES "Screens")
        $ol = SemiMap $o['own.lights']; $tl = SemiMap $t['twin.lights']
        foreach ($m in $ol, $tl) { foreach ($k in @($m.Keys)) { if ($k -like '*|DangerLight_Computer') { $m.Remove($k) } } }
        $d = MapDiff $ol $tl $sameLight
        $out += [pscustomobject]@{ Name = "$car lights"; Ok = $d.n -eq 0; Detail = $d.text }
        $d = MapDiff (TabMap $o['own.store']) (TabMap $t['twin.store']) $sameStr 2
        $out += [pscustomobject]@{ Name = "$car storages"; Ok = $d.n -eq 0; Detail = $d.text }
        # where the car stands (both still: the twin follows ~100 ms behind a moving car)
        $a = Vec $o['own.car']; $b = Vec $t['twin.car']
        if ($a -and $b) {
            $dist = Dist $a $b
            $still = $a.V -lt 30
            $out += [pscustomobject]@{ Name = "$car position"; Ok = (-not $still) -or $dist -lt 100; Detail = "{0:N0} apart, speed {1:N0}{2}" -f $dist, $a.V, $(if ($still) { '' } else { ' (moving: not judged)' }) }
        }
        # the character: on foot against its puppet there (in a car the puppet sits: seat offsets)
        $s = Vec $o['self']; $p = Vec $t['puppet']
        if ($s -and $p) {
            $dist = Dist $s $p
            $foot = $s.W -eq 'foot'
            $out += [pscustomobject]@{ Name = "$($side.n) player"; Ok = $dist -lt $(if ($foot) { 150 } else { 400 }); Detail = "{0:N0} from its puppet ({1})" -f $dist, $s.W }
        }
    }
    $out
}

if ($HostFile -and $GuestFile) {
    CompareState (ReadDigest $HostFile) (ReadDigest $GuestFile) | ForEach-Object { "  [{0}] {1} -- {2}" -f $(if ($_.Ok) { 'OK' } else { 'DIFF' }), $_.Name, $_.Detail }
}
