# The crash dumps of a tester's report, readable: each dump's error and call stack, with the symbols of the build the
# tester had (local\release\symbols\<version>, made by build-alpha.ps1; found by main.dll's hash in the report's
# info.txt, else by the version line; else the current build tree, with a warning).
#   crash-stack.ps1 -Report <report zip or unpacked folder> [-Frames 30]
param([Parameter(Mandatory = $true)][string]$Report, [int]$Frames = 30)
$root = "C:\PacificDriveCoop"
$cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
if (-not (Test-Path $cdb)) { throw "cdb.exe not found (Windows SDK debuggers): $cdb" }

$dir = $Report
if ($Report -like '*.zip') {
    $dir = "$root\local\reports\$([IO.Path]::GetFileNameWithoutExtension($Report))"
    if (-not (Test-Path $dir)) { Expand-Archive $Report $dir -Force }
}
$info = @(Get-Content "$dir\info.txt" -Encoding utf8 -ErrorAction SilentlyContinue)
"report: $dir"
$info | Where-Object { $_ -match 'CoopSync|dll ' } | ForEach-Object { "  $_" }

# the symbols: by main.dll's hash, else by the version
$sym = $null
$hash = ($info | Where-Object { $_ -match 'dll main\.dll sha256: (\w+)' } | ForEach-Object { $Matches[1] }) | Select-Object -First 1
foreach ($d in Get-ChildItem "$root\local\release\symbols" -Directory -ErrorAction SilentlyContinue) {
    if ($hash -and (Select-String -Path "$($d.FullName)\hashes.txt" -Pattern $hash -SimpleMatch -Quiet)) { $sym = $d.FullName }
}
if (-not $sym) {
    $ver = ($info | Where-Object { $_ -match 'CoopSync (\S+) installed' } | ForEach-Object { $Matches[1] }) | Select-Object -First 1
    if ($ver -and (Test-Path "$root\local\release\symbols\$ver")) { $sym = "$root\local\release\symbols\$ver" }
}
if (-not $sym) {
    $sym = "$root\local\native-build\Game__Shipping__Win64\bin;$root\local\native-build\CoopNative"
    "  WARNING: no symbols of the tester's build: the current build tree is used (frames of the mod may be wrong)"
}
"symbols: $sym"

$dumps = @(Get-ChildItem $dir -Recurse -Include *.dmp -ErrorAction SilentlyContinue)
if ($dumps.Count -eq 0) { "no dumps in the report"; return }
foreach ($d in $dumps) {
    ""
    "=== $($d.FullName.Substring($dir.Length + 1)) ($($d.LastWriteTime))"
    $ctx = Join-Path $d.DirectoryName 'CrashContext.runtime-xml'
    if (Test-Path $ctx) {
        $x = Get-Content $ctx -Raw
        foreach ($tag in 'ErrorMessage', 'EngineVersion') { if ($x -match "<$tag>([^<]*)") { "  ${tag}: $($Matches[1])" } }
    }
    $out = & $cdb -z $d.FullName -y $sym -i $sym -c ".ecxr; kn $Frames; q" 2>&1
    $out | Where-Object { $_ -match '^[0-9a-f]{2} ' } | ForEach-Object { "  " + ($_ -replace '^(\S+)\s+\S+\s+\S+\s+', '$1 ') }
}
