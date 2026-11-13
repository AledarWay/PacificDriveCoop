# Boots a test game in a process of its own (start-zone.ps1 / start-save.ps1), so the host's and the guest's games
# boot side by side: neither waits for the other (~45-65 s of each test before, one after the other). The process
# takes the environment as it is at the call (COOPSYNC_CHAN, COOPSYNC_NET, COOPTEST_FPS...): set it before each.
#   $h = BootBg start-save.ps1 "-Tag host -Save `"$Save`" -Slot 9"; $g = BootBg start-zone.ps1 "-Tag client -Seed 777 -StopInGarage"
#   BootWait $h | Select-Object -Last 1; BootWait $g | Select-Object -Last 1     (their output, "PID <n>" last)
function BootBg([string]$Script, [string]$ArgLine) {
    $tag = if ($ArgLine -match '-Tag\s+(\S+)') { $Matches[1] } else { 'game' }
    $o = "C:\PacificDriveCoop\local\instances\$tag-boot.txt"; Remove-Item $o -ErrorAction SilentlyContinue
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"C:\PacificDriveCoop\mod\tools\$Script`" $ArgLine"
    @{ p = (Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $o); o = $o }
}
function BootWait($b) {
    $b.p.WaitForExit()
    @(Get-Content $b.o -ErrorAction SilentlyContinue)
}
