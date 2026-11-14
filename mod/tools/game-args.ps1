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
# Sound on by default (owner, 2026-11-14: a garage dialogue never advanced, no subtitles either, in a manual
# quick-start test - the dialogue system waits for its line's voice-over to finish playing, which never happens
# with -nosound). $env:COOPTEST_SOUND=0 goes back to -nosound for a test that doesn't need audio and wants the
# small startup cost back.
$snd = if ($env:COOPTEST_SOUND -eq '0') { @('-nosound') } else { @() }
# $env:COOPTEST_FPS=15 caps the game at that many frames per second (a slow friend's PC): session.lua reads it from
# the environment and sets t.MaxFPS in every world (-ExecCmds on the command line did not hold).
if ($env:COOPTEST_GRAPHICS -eq '1') { @('-dx11', '-windowed', '-ResX=960', '-ResY=540') + $snd }
else { @('-dx11', '-nullrhi') + $snd }
