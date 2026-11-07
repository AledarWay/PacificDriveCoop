# A problem report for the co-op mod's developer: CoopSync-report-<date>.zip on the desktop.
# Run from the game's menu (Debug -> Collect report), from Report.bat next to the installer, or for the two copies
# of TwoGamesTest.bat from ReportTwoGames.bat (-TwoGames: both copies' files in one zip, player1\ and player2\).
# Inside: the UE4SS and game logs, the mod's state files and its network's (the channel), the latest crash dumps,
# versions. No saves or personal files.
param([string]$Chan, [string]$GameDir, [switch]$TwoGames)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\common.ps1"

# where the game is: this script lies in <game>\PenDriverPro\Binaries\Win64\ue4ss\Mods\CoopSync\tools, or through Steam
$bin = $null
$up = Resolve-Path "$here\..\..\..\.." -ErrorAction SilentlyContinue
if ($up -and (Test-Path "$up\PenDriverPro-Win64-Shipping.exe")) { $bin = $up.Path }
elseif ($GameDir) { $bin = Game-Bin $GameDir }
else { $g = Find-Game; if ($g) { $bin = Game-Bin $g } }

$stamp = Get-Date -f 'yyyy-MM-dd_HH-mm-ss'
$name = if ($TwoGames) { "CoopSync-report-two-games-$stamp" } else { "CoopSync-report-$stamp" }
$work = Join-Path $env:TEMP $name
New-Item -ItemType Directory -Force $work | Out-Null
function Take($from, $to, [int]$tailLines = 0) {
    if (-not (Test-Path $from)) { return }
    $dst = Join-Path $work $to
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    if ($tailLines -gt 0) { Get-Content $from -Tail $tailLines | Set-Content $dst -Encoding utf8 }
    else { Copy-Item $from $dst -Force }
}

# versions and the environment
$info = @("report $stamp", "computer: $([Environment]::OSVersion.VersionString)")
if ($bin) {
    $info += "game bin: $bin"
    $exe = "$bin\PenDriverPro-Win64-Shipping.exe"
    if (Test-Path $exe) { $info += "game exe sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash)" }
    $info += (Get-Content "$bin\ue4ss\CoopSync-installed.txt" -ErrorAction SilentlyContinue)
    # the builds of the native parts (crash-stack.ps1 finds their symbols by these)
    foreach ($d in "$bin\ue4ss\UE4SS.dll", "$bin\ue4ss\Mods\CoopSync\dlls\main.dll") {
        if (Test-Path $d) { $info += "dll $(Split-Path $d -Leaf) sha256: $((Get-FileHash $d -Algorithm SHA256).Hash)" }
    }
} else { $info += "game: not found" }
$info += "processes: " + ((Get-Process PenDriverPro-Win64-Shipping, CoopNet -ErrorAction SilentlyContinue | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ' ')
$info | Set-Content (Join-Path $work 'info.txt') -Encoding utf8

# UE4SS's own log and dumps (one folder for both copies of the two-games test)
if ($bin) {
    Take "$bin\ue4ss\UE4SS.log" 'logs\UE4SS.log'
    Take "$bin\ue4ss\UE4SS-settings.ini" 'logs\UE4SS-settings.ini'
    Get-ChildItem "$bin\ue4ss" -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
        ForEach-Object { Take $_.FullName "dumps\$($_.Name)" }
}

# one game's files: its logs, crashes and the mod's channel (state, network logs - net.log the in-game network,
# coopnet.log the old CoopNet -, the sync streams' tails, the mod's own log)
function TakeGame($saved, $chan, $pre) {
    Take "$saved\Logs\PenDriverPro.log" "${pre}logs\PenDriverPro.log"
    Get-ChildItem "$saved\Logs" -Filter 'PenDriverPro-backup-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
        ForEach-Object { Take $_.FullName "${pre}logs\$($_.Name)" }
    Get-ChildItem "$saved\Crashes" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
        ForEach-Object { $c = $_; Get-ChildItem $c.FullName -File | Where-Object { $_.Length -lt 200MB } | ForEach-Object { Take $_.FullName "${pre}crashes\$($c.Name)\$($_.Name)" } }
    foreach ($f in 'status.txt', 'net-status.txt', 'menu-status.txt', 'control.txt', 'net-control.txt', 'net.log', 'coopnet.log', 'relay.log', 'hitches.log', 'coopsync.log') { Take "$chan\$f" "${pre}channel\$f" }
    foreach ($f in 'host.events', 'client.requests', 'host.fast', 'client.fast') { Take "$chan\$f" "${pre}channel\$f.tail" 2000 }
    Get-ChildItem "$chan\inbox", "$chan\outbox\sent", $chan -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'host-session*' -or $_.Name -like 'host-run*' -or $_.Name -like 'host-gates*' } |
        ForEach-Object { Take $_.FullName "${pre}channel\$($_.Directory.Name)-$($_.Name)" }
}
if ($TwoGames) {
    $root = TwoGames-Root
    foreach ($n in 1, 2) { $s = "$root\player$n\Saved"; TakeGame $s "$s\CoopSync" "player$n\" }
} else {
    $saved = Game-Saved
    if (-not $Chan) { $Chan = Join-Path $saved 'CoopSync' }
    # (a copy of the two-games test passes its own channel: its Saved folder is the channel's parent)
    $cs = Split-Path $Chan -Parent
    if ($cs -and (Test-Path "$cs\Logs")) { $saved = $cs }
    TakeGame $saved $Chan ''
}

$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.zip"
Compress-Archive -Path "$work\*" -DestinationPath $zip -Force
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
"report: $zip"
