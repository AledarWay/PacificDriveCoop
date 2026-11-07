# Polls the game via CoopDev until EGameplayState == -State.
param([int]$State, [int]$TimeoutSec = 180, [string]$Dir = "C:\PacificDriveCoop\local\coopdev")
$t = "C:\PacificDriveCoop\mod\tools"; $end = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $end) {
    $r = (& "$t\send.ps1" -File "$t\cmds\st.lua" -Dir $Dir -TimeoutSec 20) -join ' '
    if ($r -match 'OK (seed=\S+ state=(\d+) world=\S+)') { $Matches[1]; if ([int]$Matches[2] -eq $State) { exit 0 } }
    else { 'no answer (loading?)' }
    Start-Sleep 5
}
'TIMEOUT'; exit 1
