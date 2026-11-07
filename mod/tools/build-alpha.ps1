# Builds the alpha package: local\release\PacificDriveCoop-<version>.zip
#   Install.bat / Uninstall.bat / Report.bat + their scripts + README.txt + CHANGELOG.txt (versions, newest first)
#   files\dwmapi.dll + files\ue4ss\UE4SS.dll (our build of UE4SS 3.0.1 at the release's commit, mod\native: the
#   native half is compiled against it), the rest of files\ue4ss\ from the UE4SS release (mod\vendor\ue4ss) (consoles off, only
#   CoopSync enabled), files\ue4ss\Mods\CoopSync\ (Scripts, dlls\main.dll = the native half with the in-game
#   network, tools). CoopNet.exe is no longer packed (the network runs in the game since 0.1.0-alpha8).
# The PowerShell scripts get a UTF-8 BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI: Russian text breaks).
param([string]$Version = '0.1.0-alpha1')
$ErrorActionPreference = 'Stop'
$root = 'C:\PacificDriveCoop'; $rel = "$root\mod\release"
$ue4ss = "$root\mod\vendor"   # UE4SS-settings.ini, LICENSE, Mods\shared of the release UE4SS_v3.0.1-1181-g83330635
$native = "$root\local\native-build"
$name = "PacificDriveCoop-$Version"
$out = "$root\local\release\$name"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

& "$root\mod\tools\lua-lint.ps1" | Out-Null
if ($LASTEXITCODE) { throw "lua-lint failed" }

# the native half and our UE4SS: built fresh (mod\native\build.bat -> local\native-build, incremental)
& cmd /c "$root\mod\native\build.bat 2>&1" | Out-Null   # 2>&1 inside cmd: stderr would stop this script (Stop)
if ($LASTEXITCODE) { throw "native build failed (mod\native\build.bat)" }
foreach ($f in "$native\CoopNative\main.dll", "$native\Game__Shipping__Win64\bin\UE4SS.dll", "$native\Game__Shipping__Win64\bin\dwmapi.dll") {
    if (-not (Test-Path $f)) { throw "missing $f" }
}

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
$mod = "$out\files\ue4ss\Mods\CoopSync"
New-Item -ItemType Directory -Force "$mod\Scripts", "$mod\dlls", "$mod\tools", "$out\files\ue4ss\Mods" | Out-Null

function Ps1($from, $to) { [IO.File]::WriteAllText($to, [IO.File]::ReadAllText($from, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true))) }
function Bat($path, $script, $extra = '') {
    $s = "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0$script"" $extra %*`r`npause`r`n"
    [IO.File]::WriteAllText($path, $s, (New-Object Text.UTF8Encoding($false)))
}

# the package's top level
foreach ($f in 'install.ps1', 'uninstall.ps1', 'common.ps1', 'two-games.ps1') { Ps1 "$rel\$f" "$out\$f" }
Bat "$out\TwoGamesTest.bat" 'two-games.ps1'
Ps1 "$root\mod\CoopSync\tools\collect-report.ps1" "$out\collect-report.ps1"
Bat "$out\Install.bat" 'install.ps1'
Bat "$out\Uninstall.bat" 'uninstall.ps1'
Bat "$out\Report.bat" 'collect-report.ps1'
Bat "$out\ReportTwoGames.bat" 'collect-report.ps1' '-TwoGames'
Copy-Item "$rel\README.txt" "$out\README.txt"
Copy-Item "$rel\CHANGELOG.txt" "$out\CHANGELOG.txt"
Set-Content "$out\files\VERSION.txt" $Version -Encoding ascii

# UE4SS: our build of the binaries, the release's pristine settings (no debug consoles, no hot reload), only our mod
Copy-Item "$native\Game__Shipping__Win64\bin\dwmapi.dll" "$out\files\dwmapi.dll"
Copy-Item "$native\Game__Shipping__Win64\bin\UE4SS.dll" "$out\files\ue4ss\UE4SS.dll"
foreach ($f in 'UE4SS-settings.ini', 'LICENSE') { Copy-Item "$ue4ss\ue4ss\$f" "$out\files\ue4ss\$f" }
Copy-Item "$ue4ss\ue4ss\Mods\shared" "$out\files\ue4ss\Mods\shared" -Recurse
Set-Content "$out\files\ue4ss\Mods\mods.txt" "CoopSync : 1" -Encoding ascii
Set-Content "$out\files\ue4ss\Mods\mods.json" '[ { "mod_name": "CoopSync", "mod_enabled": true } ]' -Encoding ascii

# the mod
Copy-Item "$root\mod\CoopSync\Scripts\*.lua" "$mod\Scripts\"
New-Item -ItemType Directory -Force "$mod\Scripts\lang" | Out-Null
Copy-Item "$root\mod\CoopSync\Scripts\lang\*.lua" "$mod\Scripts\lang\"   # the texts, one file per language (loc.lua)
Copy-Item "$native\CoopNative\main.dll" "$mod\dlls\main.dll"
Ps1 "$root\mod\CoopSync\tools\collect-report.ps1" "$mod\tools\collect-report.ps1"
Ps1 "$rel\common.ps1" "$mod\tools\common.ps1"

# the symbols of this build's native parts, kept here (not packed): crash-stack.ps1 reads the testers' dumps with them
$sym = "$root\local\release\symbols\$Version"
New-Item -ItemType Directory -Force $sym | Out-Null
foreach ($f in "$native\CoopNative\main.dll", "$native\CoopNative\main.pdb", "$native\Game__Shipping__Win64\bin\UE4SS.dll",
               "$native\Game__Shipping__Win64\bin\UE4SS.pdb", "$native\Game__Shipping__Win64\bin\dwmapi.dll", "$native\Game__Shipping__Win64\bin\dwmapi.pdb") {
    Copy-Item $f $sym -Force
}
Get-ChildItem $sym -Filter *.dll | ForEach-Object { "$($_.Name) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" } | Set-Content "$sym\hashes.txt" -Encoding ascii

$zip = "$root\local\release\$name.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$out\*" -DestinationPath $zip
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
"alpha: $zip ($size MB)"
