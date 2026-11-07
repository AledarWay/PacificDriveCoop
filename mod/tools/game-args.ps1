# Command line of a test game instance. Headless by default (-nullrhi: no rendering, the tests' normal mode);
# with $env:COOPTEST_GRAPHICS=1 the game renders in a small window (DX11; DX12 failed on the first PC).
# -UserDir: the instance's profile; its Game.ini gets the startup movies (logos, ~15 s with graphics) switched off.
param([string]$UserDir)
if ($UserDir) {
    $cfg = "$UserDir\Saved\Config\WindowsNoEditor"
    New-Item -ItemType Directory -Force $cfg | Out-Null
    $ini = "$cfg\Game.ini"
    $have = if (Test-Path $ini) { Get-Content $ini -Raw } else { "" }
    if ($have -notmatch 'MoviePlayerSettings') {
        Add-Content $ini "`r`n[/Script/MoviePlayer.MoviePlayerSettings]`r`nbWaitForMoviesToComplete=False`r`n!StartupMovies=ClearArray`r`n" -Encoding ascii
    }
}
# $env:COOPTEST_SOUND=1 keeps the sound on (the radio's music plays only with sound).
$snd = if ($env:COOPTEST_SOUND -eq '1') { @() } else { @('-nosound') }
# $env:COOPTEST_FPS=15 caps the game at that many frames per second (a slow friend's PC): session.lua reads it from
# the environment and sets t.MaxFPS in every world (-ExecCmds on the command line did not hold).
if ($env:COOPTEST_GRAPHICS -eq '1') { @('-dx11', '-windowed', '-ResX=960', '-ResY=540') + $snd }
else { @('-dx11', '-nullrhi') + $snd }
