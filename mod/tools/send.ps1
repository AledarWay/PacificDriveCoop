# Sends a Lua snippet to the CoopDev mod and prints its output.
# Usage: send.ps1 -File cmd.lua [-Dir C:\PacificDriveCoop\local\coopdev] [-TimeoutSec 30]
# Fails fast when the game of this instance is gone (pid from the dir's start.log): throws "GAME DEAD", so a test
# stops at once instead of sitting out every timeout (a hung or crashed client cost ~40 min in one full run).
param(
    [Parameter(Mandatory)] [string] $File,
    [string] $Dir = "C:\PacificDriveCoop\local\coopdev",
    [int] $TimeoutSec = 30
)
$log = Join-Path $Dir "start.log"
$gamePid = $null
if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern '\] pid (\d+) ' | Select-Object -Last 1
    if ($m) { $gamePid = [int]$m.Matches[0].Groups[1].Value }
}
function Alive { (-not $gamePid) -or [bool](Get-Process -Id $gamePid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'PenDriverPro*' }) }
if (-not (Alive)) { throw "GAME DEAD: pid $gamePid of $Dir is not running" }
$out = Join-Path $Dir "out.txt"
$start = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Copy-Item $File (Join-Path $Dir "cmd.lua.tmp") -Force
Move-Item (Join-Path $Dir "cmd.lua.tmp") (Join-Path $Dir "cmd.lua") -Force
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$n = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if (Test-Path $out) {
        $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($start, 'Begin') | Out-Null
            $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
        } finally { $fs.Close() }
        if ($text -match '=== end') { $text; exit 0 }
    }
    $n++
    if ($n % 7 -eq 0 -and -not (Alive)) { throw "GAME DEAD: pid $gamePid of $Dir exited while waiting" }
}
"TIMEOUT (game not polling? state: cmd.lua exists = $(Test-Path (Join-Path $Dir 'cmd.lua')))"
exit 1
