# Runs each bot action alone on a fresh headless host to find the one that crashes the game.
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $hd = "$root\local\instances\host\coopdev"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3
& "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
Start-Sleep 35
Remove-Item "$hd\bot-crumbs.txt" -ErrorAction SilentlyContinue
$lib = "CoopSync = CoopSync or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = CoopSyncState or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
$bot = Get-Content "$t\cmds\bot-actions.lua" -Raw
foreach ($act in 'open', 'take', 'pick', 'detach') {
    "$lib BOT_SKIP = 0 BOT_ONLY = '$act' $bot" | Set-Content "$hd\..\bot-$act.lua" -Encoding ascii
    $r = (& "$t\send.ps1" -File "$hd\..\bot-$act.lua" -Dir $hd -TimeoutSec 60) -join ' '
    "[$act] " + $r.Substring(0, [math]::Min(400, $r.Length))
    Start-Sleep 4
    if (-not (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue)) { "GAME DIED after $act"; break }
}
"--- crumbs"; Get-Content "$hd\bot-crumbs.txt" -ErrorAction SilentlyContinue
"DONE"
