# Every text the mod shows through loc.lua's L("...") has its English line in loc.lua's EN table, and no Russian text
# is left in the code outside L() and comments (owner, alpha 18: every in-game text of the mod in the localization
# file). Run by lua-lint.ps1. Exit code 1 on a problem.
$s = "C:\PacificDriveCoop\mod\CoopSync\Scripts"
$utf8 = New-Object Text.UTF8Encoding($false)
$loc = [IO.File]::ReadAllText("$s\loc.lua", $utf8)
$keys = @{}
foreach ($m in [regex]::Matches($loc, '\["((?:[^"\\]|\\.)*)"\]\s*=')) { $keys[$m.Groups[1].Value] = 1 }
$bad = @()
foreach ($f in Get-ChildItem "$s\*.lua") {
    if ($f.Name -eq 'loc.lua') { continue }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName, $utf8)) {
        $n++
        $code = $line
        if ($line -match 'loc: test label') { continue } # (a Russian label the tests send, compared as it is)
        if ($code.TrimStart().StartsWith('--')) { continue }
        $i = $code.IndexOf(' -- '); if ($i -ge 0 -and (($code.Substring(0, $i).Split('"').Count - 1) % 2) -eq 0) { $code = $code.Substring(0, $i) }
        foreach ($m in [regex]::Matches($code, 'L\("((?:[^"\\]|\\.)*)"\)')) {
            if (-not $keys[$m.Groups[1].Value]) { $bad += "NO ENGLISH $($f.Name):$n $($m.Groups[1].Value)" }
        }
        $rest = [regex]::Replace($code, 'L\("((?:[^"\\]|\\.)*)"\)', '')
        foreach ($m in [regex]::Matches($rest, '"([^"]*[Ѐ-ӿ][^"]*)"')) { $bad += "NOT LOCALIZED $($f.Name):$n $($m.Groups[1].Value)" }
    }
}
$bad | ForEach-Object { $_ }
if ($bad.Count) { "loc-check: $($bad.Count) problem(s)"; exit 1 } else { "loc-check: OK ($($keys.Count) texts)" }
