# One save's META chunk put into another (the guest's load straight into the host's zone, 2026-11-11): META is the
# slot's summary - Level, MapLocation, ShapeLeg, the run's stats - stored as it is in the file; the chunk is copied
# byte for byte (no unpacking), its slot's offset / sizes / flags taken over, every chunk after it moved.
#   -Into <save> (rewritten in place, a .metabak kept) -From <save whose META is taken>
param([Parameter(Mandatory)][string]$Into, [Parameter(Mandatory)][string]$From)
function Slots([byte[]]$b) {
    $r = @()
    for ($i = 0; $i -lt 16; $i++) {
        $o = 16 + $i * 24
        $r += [pscustomobject]@{ i = $i; tag = [Text.Encoding]::ASCII.GetString($b, $o, 4); off = [BitConverter]::ToUInt32($b, $o + 4); len = [BitConverter]::ToUInt32($b, $o + 8) }
    }
    $r
}
$a = [IO.File]::ReadAllBytes($Into); $h = [IO.File]::ReadAllBytes($From)
$as = Slots $a; $hs = Slots $h
$hm = $hs | Where-Object { $_.tag -eq 'META' }
if (-not $hm) { throw "no META in $From" }
Copy-Item $Into "$Into.metabak" -Force
$body = New-Object IO.MemoryStream
$new = @{}
foreach ($s in $as) {
    if ($s.off -ge $a.Length -or $s.tag -notmatch '^[A-Z0-9_]{4}$') { continue }
    $off = 400 + $body.Length
    if ($s.tag -eq 'META') { $body.Write($h, $hm.off, $hm.len); $new[$s.i] = @{ off = $off; meta = $true } }
    else { if ($s.len) { $body.Write($a, $s.off, $s.len) }; $new[$s.i] = @{ off = $off } }
}
$end = 400 + $body.Length
$f = New-Object byte[] $end
[Array]::Copy($a, 0, $f, 0, 16)
for ($i = 0; $i -lt 16; $i++) {
    $o = 16 + $i * 24
    if ($new[$i] -and $new[$i].meta) { [Array]::Copy($h, 16 + $hm.i * 24, $f, $o, 24) } else { [Array]::Copy($a, $o, $f, $o, 24) }
    if ($new[$i]) { [BitConverter]::GetBytes([uint32]$new[$i].off).CopyTo($f, $o + 4) } else { [BitConverter]::GetBytes([uint32]$end).CopyTo($f, $o + 4) }
}
$body.ToArray().CopyTo($f, 400)
[IO.File]::WriteAllBytes($Into, $f)
"META swapped: $($hm.len) bytes from $From; $Into now $end bytes"
