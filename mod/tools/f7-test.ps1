# The F7 panel with real keys, one graphics instance in its garage (owner, alpha 9: "after closing F7 the game hung,
# the pause stayed on"): F7 opens the panel (the pause menu under it, invisible), F7 closes it -> the game runs again,
# no cursor; the same after Esc first (the pause menu open, then F7, F7, Esc).
param([switch]$Keep)
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
$hd = "$inst\host\coopdev"
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Lua([string]$code) {
    $f = "$hd\_f.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $hd -TimeoutSec 30) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
$st = "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') local pc = FindFirstOf('PlayerController') " +
    "local v = '-' for _, m in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if m:GetFullName():find('/Engine/Transient', 1, true) then v = tostring(m:IsVisible()) end end " +
    "return 'paused=' .. tostring(GS:IsGamePaused(pc)) .. ' cursor=' .. tostring(pc.bShowMouseCursor) .. ' menu=' .. v"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1" | Out-Null
$chan = "$inst\host\chan-p$(Get-Date -f HHmmss)"; New-Item -ItemType Directory -Force $chan | Out-Null
$env:COOPTEST_GRAPHICS = '1'; $env:COOPSYNC_CHAN = $chan.Replace('\', '/')
$r = & "$t\start-zone.ps1" -Tag host -Seed 12345 -StopInGarage | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPTEST_GRAPHICS -ErrorAction SilentlyContinue
$gamePid = [int]($r -replace 'PID ', '')
Start-Sleep 5
function Key($k) { & "$t\keys.ps1" -GamePid $gamePid -Key $k -Seconds 0.15 -CornerClick | Out-Null; Start-Sleep 3 }
function Panel { ((Get-Content "$chan\panel-status.txt" -Encoding utf8 -ErrorAction SilentlyContinue) -join ' ') }

"=== 1. F7, F7"
$s0 = Lua $st
# (the first key after the start can miss the window: again until the panel's pause is there)
for ($i = 0; $i -lt 3; $i++) { Key F7; $s1 = Lua $st; if ($s1 -match 'paused=true') { break } }
Check "F7 opens the panel over an invisible pause menu (the game's UI input)" ($s1 -match 'paused=true' -and $s1 -match 'menu=true') "$s1 | before: $s0"
Key F7
Start-Sleep 1
$s2 = Lua $st
Check "F7 again closes it: the game runs, no cursor" ($s2 -match 'paused=false' -and $s2 -match 'cursor=false') $s2

"=== 2. Esc, F7, F7"
for ($i = 0; $i -lt 4; $i++) { Key Escape; $e = Lua $st; if ($e -match 'paused=true') { break } }
Check "Esc opens the pause menu" ($e -match 'paused=true') $e
Key F7
Key F7
Start-Sleep 1
$s3 = Lua $st
# (the pause menu may stay: it was the player's own; then Esc closes it)
if ($s3 -match 'menu=true') { Key Escape; Start-Sleep 1; $s3 = Lua $st }
Check "after Esc, F7, F7 (and Esc for the pause menu) the game runs again" ($s3 -match 'paused=false' -and $s3 -match 'cursor=false') $s3

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
