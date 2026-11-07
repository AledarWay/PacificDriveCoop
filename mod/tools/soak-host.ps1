# Host only: start zone, run host sync with deep breadcrumbs, wait up to 6 min for a crash.
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $hd = "$root\local\instances\host\coopdev"; $chan = "$root\local\instances\channel"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3
& "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
Start-Sleep 35
Set-Content "$hd\sync-crumbs.txt" "" -Encoding ascii
$code = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopSyncDebug = '$($hd.Replace('\','/'))/sync-crumbs.txt' CoopSyncDebugDeep = true return CoopSyncState.start(CoopSync, 'host', '$($chan.Replace('\','/'))')"
Set-Content "$hd\..\soak.lua" $code -Encoding ascii
& "$t\send.ps1" -File "$hd\..\soak.lua" -Dir $hd -TimeoutSec 60
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 360) {
    Start-Sleep 10
    if (-not (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue)) { "CRASHED after $([int]((Get-Date) - $t0).TotalSeconds) s"; break }
}
"--- last crumbs"; Get-Content "$hd\sync-crumbs.txt" | Select-Object -Last 15
"DONE"
