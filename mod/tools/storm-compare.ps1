# storm-read + light-read on both instances of a running pair (probes by hand), after -WaitSec
param([int]$WaitSec = 0)
if ($WaitSec -gt 0) { Start-Sleep $WaitSec }
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
function Probe($dir, $file) { ((& "$t\send.ps1" -File $file -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ' }
foreach ($s in 'host', 'client') {
    "$s storm: " + (Probe "$inst\$s\coopdev" "$t\cmds\storm-read.lua")
    "$s light: " + (Probe "$inst\$s\coopdev" "$t\cmds\light-read.lua")
}
