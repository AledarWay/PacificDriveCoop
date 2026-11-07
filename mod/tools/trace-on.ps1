# Switch on the crash trace (CoopSync trace.lua) in one game for -Sec seconds. Light (default): each game-thread loop
# callback run and each CoopSyncAfter call, one flushed line each, to <coopdev>/trace-sync.txt (the mod's own state)
# and trace-dev.txt (the test's CoopDev state) - the last line names the loop a crash was in. -Full: every mod function
# entered and every UObject call site (slow: it hid the going-home crash).
param([Parameter(Mandatory)][string]$Dir, [int]$Sec = 120, [switch]$Full)
Remove-Item "$Dir\trace-sync.txt", "$Dir\trace-dev.txt" -ErrorAction SilentlyContinue
$mode = if ($Full) { 'full' } else { 'light' }
Set-Content "$Dir\trace-until.txt" @(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $Sec), $mode) -Encoding ascii
"trace ($mode) on for $Sec s"
