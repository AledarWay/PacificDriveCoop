# Two copies of the game on one PC - try the co-op without a friend (run from TwoGamesTest.bat).
#   * both copies take your saves, but as COPIES: Documents\PacificDriveCoop\two-games\player1 and player2
#     (the real saves do not change; -Fresh copies them there again);
#   * the copies connect to each other directly on this PC (no Steam lobby needed);
#   * 1280x720 windows, DirectX 11.
# In the game: in copy 1 Esc -> Co-op -> Create lobby (it is the host),
#              in copy 2 Esc -> Co-op -> Join lobby: the second copy of the game on this PC.
param([string]$GameDir, [switch]$Fresh, [int]$Port = 47811)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\common.ps1"

function Say($s) { Write-Host $s }
function Fail($s) { Write-Host ""; Write-Host "ERROR: $s" -ForegroundColor Red; exit 1 }

Say "=== Two copies of Pacific Drive to try the co-op ==="
if (-not $GameDir) { $GameDir = Find-Game }
$bin = if ($GameDir) { Game-Bin $GameDir } else { $null }
if (-not $bin -or -not (Test-Path "$bin\PenDriverPro-Win64-Shipping.exe")) { Fail "The game was not found through Steam. Give its folder: TwoGamesTest.bat ""<game folder>""" }
if (-not (Test-Path "$bin\ue4ss\Mods\CoopSync")) { Fail "The mod is not installed: run Install.bat first." }
if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Fail "Start Steam and sign in, then run this script again." }
if (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue) { Fail "The game is already running: close it and run the script again." }

# without this file a game started outside Steam restarts through Steam (and loses the copy's settings)
$appid = "$bin\steam_appid.txt"
if (-not (Test-Path $appid)) {
    Set-Content $appid "$AppId" -Encoding ascii
    Set-Content "$bin\steam_appid.txt.coopsync" "made by two-games.ps1" -Encoding ascii # (Uninstall.bat removes it)
}

$saved = Game-Saved
$root = TwoGames-Root
# The game still restarted through Steam at start (the owner, alpha 17: "Restarting within steam, exiting..." in the
# log, the "launch with custom parameters" window, one copy opened) - neither steam_appid.txt nor starting through a
# link to the folder helped. With COOPSYNC_TWO_GAMES=1 the mod (CoopNative) tells the game "no restart needed".
$exe = "$bin\PenDriverPro-Win64-Shipping.exe"
# (the link to the game folder from an earlier version of this script: rmdir removes only the link itself)
$li = Get-Item "$root\game" -Force -ErrorAction SilentlyContinue
if ($li -and $li.LinkType -eq 'Junction') { cmd /c rmdir "$root\game" | Out-Null }
$env:COOPSYNC_TWO_GAMES = '1'
foreach ($n in 1, 2) {
    $u = "$root\player$n"
    $sg = "$u\Saved\SaveGames"
    if ($Fresh -or -not (Test-Path $sg)) {
        Say "Copying the saves for copy $n..."
        Remove-Item $sg -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $sg | Out-Null
        if (Test-Path "$saved\SaveGames") { Copy-Item "$saved\SaveGames\*" $sg -Recurse -Force }
        $cfg = "$u\Saved\Config\WindowsNoEditor"
        New-Item -ItemType Directory -Force $cfg | Out-Null
        foreach ($f in 'GameUserSettings.ini', 'Input.ini') {
            if (Test-Path "$saved\Config\WindowsNoEditor\$f") { Copy-Item "$saved\Config\WindowsNoEditor\$f" "$cfg\$f" -Force }
        }
    }
    # each copy with its own side of the local link (the name shows in the lobby)
    $env:COOPSYNC_NET = "tcp:${Port}:player$n"
    $gameArgs = @('-dx11', '-windowed', '-ResX=1280', '-ResY=720', "-WinX=$(40 + ($n - 1) * 660)", '-WinY=40', "-userdir=`"$u`"")
    Start-Process $exe -ArgumentList $gameArgs -WorkingDirectory $bin | Out-Null
    Say "Copy $n started (saves: $u)."
    if ($n -eq 1) { Start-Sleep 8 } # (two at once load longer and get in each other's way)
}
$env:COOPSYNC_NET = $null; $env:COOPSYNC_TWO_GAMES = $null
Say ""
Say "Next, in the game:"
Say "  copy 1: Esc -> Co-op -> Create lobby - it is the host;"
Say "  copy 2: Esc -> Co-op -> Join lobby: the second copy of the game on this PC."
Say "A report after the test: ReportTwoGames.bat (both copies in one zip on the desktop)."
