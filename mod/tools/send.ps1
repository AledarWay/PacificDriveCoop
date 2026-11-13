# Sends a Lua snippet to the CoopDev mod and prints its output.
# Usage: send.ps1 -File cmd.lua [-Dir C:\PacificDriveCoop\local\coopdev] [-TimeoutSec 30]
# Fails fast when the game of this instance is gone (pid from the dir's start.log): throws "GAME DEAD", so a test
# stops at once instead of sitting out every timeout (a hung or crashed client cost ~40 min in one full run).
param(
    [Parameter(Mandatory)] [string] $File,
    [string] $Dir = "C:\PacificDriveCoop\local\coopdev",
    [int] $TimeoutSec = 30,
    [switch] $Session
)
$log = Join-Path $Dir "start.log"
$gamePid = $null
if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern '\] pid (\d+) ' | Select-Object -Last 1
    if ($m) { $gamePid = [int]$m.Matches[0].Groups[1].Value }
}
function Alive { (-not $gamePid) -or [bool](Get-Process -Id $gamePid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'PenDriverPro*' }) }
if (-not (Alive)) { throw "GAME DEAD: pid $gamePid of $Dir is not running" }
# -Session: into the CoopSync mod's own Lua state (the running session: main.lua's scmd.lua / sout.txt)
$cn, $on = if ($Session) { "scmd.lua", "sout.txt" } else { "cmd.lua", "out.txt" }
$out = Join-Path $Dir $on
$start = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Copy-Item $File (Join-Path $Dir "$cn.tmp") -Force
Move-Item (Join-Path $Dir "$cn.tmp") (Join-Path $Dir $cn) -Force
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
"TIMEOUT (game not polling? state: $cn exists = $(Test-Path (Join-Path $Dir $cn)))"
exit 1
