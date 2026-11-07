# Unpacks a Pacific Drive save (odsave<N>.sav) and prints what its scene holds.
# Format (2026-10-29): "SAVC" + a table of chunks at 16: tag(4) offset(4) stored(4) size(4) flags(8); flags 6 = an LZ4
# block (no frame), 2 = stored. Chunks: OPTS, META, GAME (the game's objects: _objects / _class / _name / _outer /
# _data, properties by name), CHKP (a checkpoint, empty in a garage save).
#   -Out <dir>: also writes each chunk unpacked (<tag>.bin)
#   -Tree <file>: the GAME chunk as a tree, one line per value ("path<TAB>type<TAB>value"; SaveTree.cs)
param([Parameter(Mandatory)][string]$Path, [string]$Out, [string]$Tree)
if (-not ('SaveLz4' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Collections.Generic;
public static class SaveLz4 {
  public static byte[] Block(byte[] s, int pos, int len) {
    int end = pos + len; var d = new List<byte>(len * 4);
    while (pos < end) {
      int t = s[pos++]; int lit = t >> 4;
      if (lit == 15) { int b; do { b = s[pos++]; lit += b; } while (b == 255); }
      for (int i = 0; i < lit; i++) d.Add(s[pos++]);
      if (pos >= end) break;
      int off = s[pos] | (s[pos + 1] << 8); pos += 2;
      if (off == 0 || off > d.Count) throw new Exception("bad LZ4 offset " + off + " at " + pos);
      int ml = t & 15;
      if (ml == 15) { int b; do { b = s[pos++]; ml += b; } while (b == 255); }
      ml += 4; int st = d.Count - off;
      for (int i = 0; i < ml; i++) d.Add(d[st + i]);
    }
    return d.ToArray();
  }
}
"@
}
$b = [IO.File]::ReadAllBytes($Path)
if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'SAVC') { throw "not a SAVC file: $Path" }
if ($Out) { New-Item -ItemType Directory -Force $Out | Out-Null }
$chunks = @{}
$o = 16
while ($o + 24 -le $b.Length) {
    $tag = [Text.Encoding]::ASCII.GetString($b, $o, 4)
    if ($tag -notmatch '^[A-Z0-9_]{4}$') { break }
    $off = [BitConverter]::ToUInt32($b, $o + 4); $len = [BitConverter]::ToUInt32($b, $o + 8); $fl = [BitConverter]::ToUInt32($b, $o + 16)
    $data = if ($len -eq 0) { [byte[]]@() } elseif ($fl -eq 6) { [SaveLz4]::Block($b, $off, $len) } else { $b[$off..($off + $len - 1)] }
    "chunk {0}: stored {1}, unpacked {2} (flags {3})" -f $tag, $len, $data.Length, $fl
    $chunks[$tag] = $data
    if ($Out -and $data.Length) { [IO.File]::WriteAllBytes("$Out\$tag.bin", [byte[]]$data) }
    $o += 24
}
foreach ($tag in 'GAME', 'CHKP') {
    $d = $chunks[$tag]
    if (-not $d -or $d.Length -eq 0) { continue }
    $g = [Text.Encoding]::ASCII.GetString($d)
    "== $tag"
    $i = $g.IndexOf('PlayerTransform')
    if ($i -ge 0) {
        $m = [regex]::Match($g.Substring($i, 600), 'Level[\x00-\x1f]{1,8}([\x20-\x7E]+)')
        "scene level: " + $(if ($m.Success) { $m.Groups[1].Value } else { '?' })
    }
    # every level state: its level and how many of its placed actors are gone
    foreach ($m in [regex]::Matches($g, 'SaveGameLevelState_\d+[\s\S]{0,160}?_data[\s\S]{0,4}?Level[\s\S]{1,4}?(/Game/[\w/]+)')) {
        "  level state: $($m.Groups[1].Value)"
    }
    $di = [regex]::Matches($g, 'DestroyedIntrinsicActors')
    "destroyed-intrinsic lists: $($di.Count)"
    $cl = [regex]::Matches($g, '_class[\s\S]{1,12}?(/[\w/]+\.(\w+))') | ForEach-Object { $_.Groups[2].Value }
    "objects: $($cl.Count); intrinsic (placed in a level, with a transform): $(([regex]::Matches($g, '_intrinsic')).Count)"
    "classes: " + (($cl | Group-Object | Sort-Object Count -Descending | Select-Object -First 40 | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')
}
if ($Tree -and $chunks['GAME']) {
    if (-not ('SaveTree' -as [type])) { Add-Type -Path "$PSScriptRoot\SaveTree.cs" }
    $w = New-Object IO.StreamWriter($Tree)
    [SaveTree]::Walk([byte[]]$chunks['GAME'], 8, $w, [int]::MaxValue)
    $w.Close()
    "tree: $Tree ($([SaveTree]::Stop))"
}
