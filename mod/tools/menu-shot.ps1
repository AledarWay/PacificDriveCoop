# Screenshots of the co-op pages of the pause menu in a graphics instance (garage, lobby created over the local test
# link): for checking button widths and label sizes by eye. -> local\shots\menu-<page>.png
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1" | Out-Null
$chan = "$inst\host\chan-ms$(Get-Date -f HHmmss)"
New-Item -ItemType Directory -Force "$chan\inbox", "$chan\outbox", "$root\local\shots" | Out-Null
$env:COOPTEST_GRAPHICS = '1'; $env:COOPSYNC_CHAN = $chan.Replace('\', '/'); $env:COOPSYNC_NET = 'tcp:47891:Хост_с_длинным_именем'
$r = & "$t\start-zone.ps1" -Tag host -Seed 12345 -StopInGarage | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET, Env:COOPTEST_GRAPHICS -ErrorAction SilentlyContinue
$gamePid = [int]($r -replace 'PID ', '')
function Menu([string]$c) { Add-Content "$chan\control.txt" "menu $c" -Encoding utf8; Start-Sleep 3; (Get-Content "$chan\menu-status.txt" -Encoding utf8) -join ' | ' }
Start-Sleep 5
Add-Content "$chan\net-control.txt" "create" -Encoding ascii; Start-Sleep 2
# the pause menu opened the real way (Esc): opened by the mod's test command its items stay unfilled ("TEXT BLOCK")
& "$t\keys.ps1" -GamePid $gamePid -Key Escape -Seconds 0.15 -CornerClick | Out-Null; Start-Sleep 3
"open: " + (Menu "info")
& "$t\shot.ps1" -GamePid $gamePid -Out "$root\local\shots\menu-game.png"
"coop: " + (Menu "press Кооператив")
& "$t\shot.ps1" -GamePid $gamePid -Out "$root\local\shots\menu-coop.png"
if (-not $Keep) {
"friends: " + (Menu "press Пригласить")
& "$t\shot.ps1" -GamePid $gamePid -Out "$root\local\shots\menu-friends.png"
}
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
