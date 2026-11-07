# The alpha package's Install / Uninstall on a stand-in game folder (local\install-test): the shipping exe is a
# hard link of the test copy's (same hash, no 100+ MB copy), with a "previous UE4SS" of the player's own in
# place. Checks: files in place, only CoopSync enabled, consoles off, the previous UE4SS set aside and brought
# back, saves backed up (into the test folder, not Documents). Never touches the real install or the test copy.
param([string]$Zip = (Get-ChildItem C:\PacificDriveCoop\local\release\PacificDriveCoop-*.zip | Sort-Object LastWriteTime | Select-Object -Last 1).FullName)
$base = 'C:\PacificDriveCoop\local\install-test'
Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
$game = "$base\game"; $bin = "$game\PenDriverPro\Binaries\Win64"; $pkg = "$base\pkg"; $backup = "$base\backup"
New-Item -ItemType Directory -Force $bin, "$bin\ue4ss\Mods\TheirMod", $pkg | Out-Null
New-Item -ItemType HardLink -Path "$bin\PenDriverPro-Win64-Shipping.exe" -Target 'C:\PacificDriveCoop\testgame\PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe' | Out-Null
Set-Content "$bin\dwmapi.dll" 'their dwmapi' ; Set-Content "$bin\ue4ss\Mods\TheirMod\main.lua" '-- theirs'
Expand-Archive $Zip $pkg
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

"=== install"
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File "$pkg\install.ps1" -GameDir $game -BackupRoot $backup 2>&1
$o | Select-Object -Last 4
Check "installed (marker, loader, mod, its native half)" ((Test-Path "$bin\ue4ss\CoopSync-installed.txt") -and (Test-Path "$bin\ue4ss\UE4SS.dll") -and (Test-Path "$bin\ue4ss\Mods\CoopSync\Scripts\main.lua") -and (Test-Path "$bin\ue4ss\Mods\CoopSync\Scripts\link.lua") -and (Test-Path "$bin\ue4ss\Mods\CoopSync\dlls\main.dll")) ((Get-ChildItem $bin -Recurse -File).Count)
Check "only CoopSync enabled" (((Get-Content "$bin\ue4ss\Mods\mods.txt") -join '|') -eq 'CoopSync : 1') ((Get-Content "$bin\ue4ss\Mods\mods.txt") -join '|')
$ini = Get-Content "$bin\ue4ss\UE4SS-settings.ini"
Check "debug consoles off, no hot reload" (($ini -contains 'GuiConsoleEnabled = 0') -and ($ini -contains 'ConsoleEnabled = 0') -and ($ini -contains 'EnableHotReloadSystem = 0')) ''
Check "the previous UE4SS set aside" ((Test-Path "$bin\ue4ss.before-coopsync\Mods\TheirMod\main.lua") -and ((Get-Content "$bin\dwmapi.dll.before-coopsync") -eq 'their dwmapi')) ''
$saves = Join-Path $env:LOCALAPPDATA 'PenDriverPro\Saved\SaveGames'
if (Test-Path $saves) {
    $n0 = (Get-ChildItem $saves -Recurse -File).Count; $n1 = (Get-ChildItem $backup -Recurse -File -ErrorAction SilentlyContinue).Count
    Check "saves backed up (copy)" ($n1 -eq $n0 -and $n0 -gt 0) "$n1 of $n0 files"
}

"=== install again (update)"
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File "$pkg\install.ps1" -GameDir $game -BackupRoot $backup 2>&1
Check "an update keeps the set-aside UE4SS" ((Test-Path "$bin\ue4ss.before-coopsync\Mods\TheirMod\main.lua") -and (Test-Path "$bin\ue4ss\CoopSync-installed.txt")) ($o | Select-Object -Last 1)

"=== report"
$desk = [Environment]::GetFolderPath('Desktop')
$before = @(Get-ChildItem $desk -Filter 'CoopSync-report-*.zip' -ErrorAction SilentlyContinue).Count
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File "$bin\ue4ss\Mods\CoopSync\tools\collect-report.ps1" -Chan "$base\nochan" 2>&1
$rep = Get-ChildItem $desk -Filter 'CoopSync-report-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
Check "report zip on the desktop" ($rep -and @(Get-ChildItem $desk -Filter 'CoopSync-report-*.zip').Count -gt $before) "$o"
if ($rep) {
    $x = "$base\report"; Expand-Archive $rep.FullName $x
    $infoTxt = Get-Content "$x\info.txt" -Raw
    Check "report: info has the game hash and the install marker" ($infoTxt -match 'game exe sha256: 568BB634' -and $infoTxt -match 'CoopSync 0') $infoTxt
    Remove-Item $rep.FullName -Force # the test's own report: not left on the owner's desktop
}

"=== uninstall"
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File "$pkg\uninstall.ps1" -GameDir $game 2>&1
$o | Select-Object -Last 2
Check "the previous UE4SS is back, ours gone" ((Test-Path "$bin\ue4ss\Mods\TheirMod\main.lua") -and -not (Test-Path "$bin\ue4ss\Mods\CoopSync") -and ((Get-Content "$bin\dwmapi.dll") -eq 'their dwmapi') -and -not (Test-Path "$bin\ue4ss.before-coopsync")) ''
Check "the game exe untouched" ((Get-FileHash "$bin\PenDriverPro-Win64-Shipping.exe").Hash -eq '568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E') ''
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
