# On the running host: detach test, then host sync with breadcrumbs + full bot run, to find the crash.
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $hd = "$root\local\instances\host\coopdev"; $chan = "$root\local\instances\channel"
New-Item -ItemType Directory -Force $chan | Out-Null
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = CoopSyncState or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
$bot = Get-Content "$t\cmds\bot-actions.lua" -Raw
function Run($name, $code) {
    Set-Content "$hd\..\hunt-$name.lua" $code -Encoding ascii
    $r = (& "$t\send.ps1" -File "$hd\..\hunt-$name.lua" -Dir $hd -TimeoutSec 60) -join ' '
    "[$name] " + $r.Substring(0, [math]::Min(500, $r.Length))
}
Remove-Item "$hd\bot-crumbs.txt", "$hd\sync-crumbs.txt" -ErrorAction SilentlyContinue
Run "detach" "$lib BOT_SKIP = 0 BOT_ONLY = 'detach' $bot"
Start-Sleep 4
if (-not (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue)) { "GAME DIED after detach"; "DONE"; exit }
Run "sync" "$lib CoopSyncDebug = '$($hd.Replace('\','/'))/sync-crumbs.txt' return CoopSyncState.start(CoopSync, 'host', '$($chan.Replace('\','/'))')"
Start-Sleep 5
Run "bot-all" "$lib BOT_SKIP = 1 BOT_ONLY = nil $bot"
Start-Sleep 8
Run "report" "return CoopSyncState.report()"
if (-not (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue)) { "GAME DIED" }
"--- bot crumbs"; Get-Content "$hd\bot-crumbs.txt" -ErrorAction SilentlyContinue
"--- sync crumbs (last 12)"; Get-Content "$hd\sync-crumbs.txt" -ErrorAction SilentlyContinue | Select-Object -Last 12
"DONE"
