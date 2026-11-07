# The mod's texts (loc.lua + Scripts\lang\<code>.lua): run by lua-lint.ps1, exit code 1 on a problem.
#   - every L("key") in the code has its text in lang\en.lua (the reference language);
#   - every other language file has only keys of en.lua, with the same %-codes in the same order; a key it lacks is
#     listed (it shows in English) and is a problem only for ru.lua (kept complete: the tests run in Russian);
#   - no Russian text is left in the code outside the lang files and comments (owner, alpha 18).
$s = "C:\PacificDriveCoop\mod\CoopSync\Scripts"
$utf8 = New-Object Text.UTF8Encoding($false)
function Texts($path) {
    $t = [ordered]@{}
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($path, $utf8), '\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"')) { $t[$m.Groups[1].Value] = $m.Groups[2].Value }
    $t
}
function Codes($text) { ([regex]::Matches($text, '%[-+ #0]*\d*(?:\.\d+)?[a-zA-Z%]') | ForEach-Object { $_.Value }) -join ' ' }
$en = Texts "$s\lang\en.lua"
$bad = @(); $info = @()
foreach ($f in Get-ChildItem "$s\lang\*.lua") {
    if ($f.Name -eq 'en.lua') { continue }
    $t = Texts $f.FullName
    foreach ($k in $t.Keys) {
        if (-not $en.Contains($k)) { $bad += "UNKNOWN KEY $($f.Name): $k"; continue }
        if ((Codes $t[$k]) -ne (Codes $en[$k])) { $bad += "%-CODES $($f.Name): $k ('$(Codes $t[$k])', en '$(Codes $en[$k])')" }
    }
    $missing = @($en.Keys | Where-Object { -not $t.Contains($_) })
    if ($missing.Count) {
        $line = "MISSING $($f.Name) ($($missing.Count), shown in English): $($missing -join ', ')"
        if ($f.Name -eq 'ru.lua') { $bad += $line } else { $info += $line }
    }
}
$used = @{}
foreach ($f in Get-ChildItem "$s\*.lua") {
    if ($f.Name -eq 'loc.lua') { continue }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName, $utf8)) {
        $n++
        $code = $line
        if ($line -match 'loc: test label') { continue } # (a Russian label the tests send, compared as it is)
        if ($code.TrimStart().StartsWith('--')) { continue }
        $i = $code.IndexOf(' -- '); if ($i -ge 0 -and (($code.Substring(0, $i).Split('"').Count - 1) % 2) -eq 0) { $code = $code.Substring(0, $i) }
        foreach ($m in [regex]::Matches($code, '\bL\("((?:[^"\\]|\\.)*)"')) {
            $k = $m.Groups[1].Value; $used[$k] = 1
            if (-not $en.Contains($k)) { $bad += "NO TEXT $($f.Name):$n L(""$k"") (not in lang\en.lua)" }
        }
        foreach ($m in [regex]::Matches($code, '"([^"]*[\u0400-\u04FF][^"]*)"')) { $bad += "NOT LOCALIZED $($f.Name):$n $($m.Groups[1].Value)" }
    }
}
$unused = @($en.Keys | Where-Object { -not $used[$_] })
if ($unused.Count) { $info += "UNUSED in en.lua: $($unused -join ', ')" }
$info | ForEach-Object { "loc-check: $_" }
$bad | ForEach-Object { $_ }
if ($bad.Count) { "loc-check: $($bad.Count) problem(s)"; exit 1 } else { "loc-check: OK ($($en.Count) texts, $((Get-ChildItem "$s\lang\*.lua").Count) languages)" }
