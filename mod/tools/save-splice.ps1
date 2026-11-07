# The zone of one save put into another (the "zone through the game's save" prototype, 2026-10-30): the guest's own
# save (its profile, garage, inventory, managers) with the root keys -Keys (default: Map = the zone) taken from the
# host's save, written as a new save file the guest's game can load (UserLoadGame).
# Format (save-dump.ps1): "SAVC" header (16 bytes), 16 chunk slots of 24 bytes (tag, offset, stored size, stored size,
# flags, unpacked size; unused slots point at the file's end), the chunks from byte 400. GAME is written as an LZ4
# block of literals only (valid LZ4, not compressed: ~4 MB).
param([Parameter(Mandatory)][string]$Guest, [Parameter(Mandatory)][string]$HostSave, [Parameter(Mandatory)][string]$Out,
    [string[]]$Keys = @('Map'))
& "$PSScriptRoot\save-dump.ps1" -Path $Guest | Out-Null # (loads SaveLz4 into the session; not dot-sourced: its $Out)
if (-not ('SaveTree' -as [type])) { Add-Type -Path "$PSScriptRoot\SaveTree.cs" }

function Read-Save([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    $slots = @()
    for ($i = 0; $i -lt 16; $i++) {
        $o = 16 + $i * 24
        $slots += [pscustomobject]@{ tag = [Text.Encoding]::ASCII.GetString($b, $o, 4); off = [BitConverter]::ToUInt32($b, $o + 4)
            len = [BitConverter]::ToUInt32($b, $o + 8); flags = [BitConverter]::ToUInt32($b, $o + 16); raw = [BitConverter]::ToUInt32($b, $o + 20) }
    }
    $game = $slots | Where-Object { $_.tag -eq 'GAME' }
    [pscustomobject]@{ bytes = $b; slots = $slots; game = [SaveLz4]::Block($b, $game.off, $game.len) }
}
function Lz4-Literals([byte[]]$d) {
    $ms = New-Object IO.MemoryStream
    $n = $d.Length
    if ($n -lt 15) { $ms.WriteByte([byte]($n -shl 4)) }
    else {
        $ms.WriteByte(0xF0)
        $rest = $n - 15
        while ($rest -ge 255) { $ms.WriteByte(255); $rest -= 255 }
        $ms.WriteByte([byte]$rest)
    }
    $ms.Write($d, 0, $n)
    , $ms.ToArray()
}

$g = Read-Save $Guest; $h = Read-Save $HostSave
$gr = [SaveTree]::RootRanges($g.game, 8); $hr = [SaveTree]::RootRanges($h.game, 8)
foreach ($k in $Keys) { if (-not $hr.ContainsKey($k)) { throw "root key '$k' missing in the host's save (host: $($hr.Keys -join ','))" } }
# (a key the guest's save lacks - the departure save the game writes on leaving the garage has no Map - is added at
# the root's end)
$added = @($Keys | Where-Object { -not $gr.ContainsKey($_) })
# the guest's GAME with the -Keys values replaced (same key order: the root keeps the guest's)
$ms = New-Object IO.MemoryStream
$pos = 0
foreach ($e in ($gr.GetEnumerator() | Where-Object { $Keys -contains $_.Key } | Sort-Object { $_.Value[0] })) {
    $ms.Write($g.game, $pos, $e.Value[0] - $pos)
    $src = $hr[$e.Key]
    $ms.Write($h.game, $src[0], $src[1] - $src[0])
    $pos = $e.Value[1]
    "  $($e.Key): guest $($e.Value[1] - $e.Value[0]) bytes -> host $($src[1] - $src[0]) bytes"
}
$rootEnd = $gr['(root)'][1]
$ms.Write($g.game, $pos, $rootEnd - $pos)
foreach ($k in $added) {
    $kb = [Text.Encoding]::ASCII.GetBytes($k + [char]0)
    $ms.Write([BitConverter]::GetBytes([int]$kb.Length), 0, 4); $ms.Write($kb, 0, $kb.Length)
    $src = $hr[$k]
    $ms.Write($h.game, $src[0], $src[1] - $src[0])
    "  $($k): added from the host ($($src[1] - $src[0]) bytes)"
}
$ms.Write($g.game, $rootEnd, $g.game.Length - $rootEnd)
$game = $ms.ToArray()
if ($added.Count) { [BitConverter]::GetBytes([BitConverter]::ToInt32($game, 9) + $added.Count).CopyTo($game, 9) } # (root map count: type byte at 8)
$check = [SaveTree]::RootRanges($game, 8) # (throws if the result does not parse)
$packed = Lz4-Literals $game

# the file: header, slots, chunks (OPTS / META / CHKP / others as the guest's, GAME new)
$body = New-Object IO.MemoryStream
$newSlots = @()
foreach ($s in $g.slots) {
    if ($s.off -ge $g.bytes.Length -or $s.tag -notmatch '^[A-Z0-9_]{4}$') { $newSlots += $null; continue }
    $off = 400 + $body.Length
    if ($s.tag -eq 'GAME') { $body.Write($packed, 0, $packed.Length); $newSlots += @{ s = $s; off = $off; len = $packed.Length; raw = $game.Length } }
    else { if ($s.len) { $body.Write($g.bytes, $s.off, $s.len) }; $newSlots += @{ s = $s; off = $off; len = $s.len; raw = $s.raw } }
}
$end = 400 + $body.Length
$file = New-Object byte[] $end
[Array]::Copy($g.bytes, 0, $file, 0, 16)
for ($i = 0; $i -lt 16; $i++) {
    $o = 16 + $i * 24
    [Array]::Copy($g.bytes, $o, $file, $o, 24)
    $n = $newSlots[$i]
    if ($n) {
        [BitConverter]::GetBytes([uint32]$n.off).CopyTo($file, $o + 4)
        [BitConverter]::GetBytes([uint32]$n.len).CopyTo($file, $o + 8)
        [BitConverter]::GetBytes([uint32]$n.len).CopyTo($file, $o + 12)
        [BitConverter]::GetBytes([uint32]$n.raw).CopyTo($file, $o + 20)
    } else { [BitConverter]::GetBytes([uint32]$end).CopyTo($file, $o + 4) }
}
$body.ToArray().CopyTo($file, 400)
[IO.File]::WriteAllBytes($Out, $file)
"written $Out ($end bytes; GAME $($game.Length) unpacked, root keys $($check.Count - 1))"
