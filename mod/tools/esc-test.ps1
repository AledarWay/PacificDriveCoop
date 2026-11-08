# The pause menu with real keys (owner's real test: "the pause menu sometimes sticks and does not answer Esc"), one
# graphics instance hosting a zone (the co-op pause is on: the world keeps running under the menu):
#   Esc opens / Esc closes, several times; Esc while our "Кооператив" page shows; F7 panel then Esc; after all of
#   it the pause menu opens and closes normally, is opaque, and holds the game's items once.
param([switch]$Keep, [switch]$NoDeploy)
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
$hd = "$inst\host\coopdev"
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Lua([string]$code) {
    $f = "$hd\_e.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $hd -TimeoutSec 30) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
Get-Process PenDriverPro-Win64-Shipping, CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
if (-not $NoDeploy) { & "$t\deploy.ps1" }
$chan = "$inst\host\chan-e$(Get-Date -f HHmmss)"
New-Item -ItemType Directory -Force "$chan\inbox", "$chan\outbox" | Out-Null
$env:COOPTEST_GRAPHICS = '1'
$env:COOPSYNC_CHAN = $chan.Replace('\', '/')
$r = & "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN
$gamePid = [int]($r -replace 'PID ', '')
Add-Content "$chan\control.txt" "role host" -Encoding ascii
$end = (Get-Date).AddSeconds(180)
do { Start-Sleep 3; $st = (Get-Content "$chan\status.txt" -TotalCount 1 -ErrorAction SilentlyContinue) } while ($st -notmatch 'state=hosting' -and (Get-Date) -lt $end)
Check "hosting (the co-op pause is on)" ($st -match 'state=hosting') $st
$state = "local m for _, x in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if x:GetFullName():find('/Engine/Transient', 1, true) then m = x end end " +
    "if not m then return 'vis=nil' end local b = m.MenuItemBox local n, v = 0, 0 for i = 0, b:GetChildrenCount() - 1 do n = n + 1 if b:GetChildAt(i):IsVisible() then v = v + 1 end end " +
    "return string.format('vis=%s opacity=%.1f items=%d visible=%d', tostring(m:IsVisible()), m:GetRenderOpacity(), n, v)"
function Pause { $s = Lua $state; @{ raw = $s; vis = ($s -match 'vis=true'); opaque = ($s -match 'opacity=1.0') } }
function Key([string]$k) { & "$t\keys.ps1" -GamePid $gamePid -Key $k -Seconds 0.15 -CornerClick | Out-Null; Start-Sleep 1.5 }

# (the first key after the window got the focus can be lost: Esc until the menu opens, then close it - a start
# from a known state)
for ($w = 0; $w -lt 3 -and -not (Pause).vis; $w++) { Key 'Escape' }
if ((Pause).vis) { Key 'Escape' }
"=== 1. Esc open / close, 4 times"
$ok = $true; $log = @()
for ($i = 1; $i -le 4; $i++) {
    Key 'Escape'; $a = Pause
    Key 'Escape'; $b = Pause
    $log += "open:$($a.vis) closed:$(-not $b.vis)"
    if (-not $a.vis -or $b.vis) { $ok = $false }
}
Check "Esc opens and closes the pause menu every time" $ok ($log -join ' | ')

"=== 2. Esc while the co-op page shows"
Key 'Escape'
Add-Content "$chan\control.txt" "menu press Кооператив" -Encoding utf8; Start-Sleep 2
$m = (Get-Content "$chan\menu-status.txt" -Encoding utf8) -join ' '
Key 'Escape'; $b = Pause
Check "Esc closes the pause menu from the co-op page" (-not $b.vis) "$($b.raw) | $m"
Key 'Escape'; $c = Pause
Key 'Escape'; $d = Pause
Check "after it Esc opens (game items back, opaque) and closes again" ($c.vis -and $c.opaque -and -not $d.vis) "open: $($c.raw) | closed: $($d.raw)"

"=== 3. the F7 panel, then Esc"
Key 'F7'; Start-Sleep 1; $p = Pause
Key 'Escape'; $q = Pause
Key 'Escape'; $r1 = Pause
Key 'Escape'; $r2 = Pause
Check "F7 panel then Esc: closed; the next Esc opens an opaque pause menu, Esc closes it" (-not $q.vis -and $r1.vis -and $r1.opaque -and -not $r2.vis) "panel: $($p.raw) | esc: $($q.raw) | open: $($r1.raw) | close: $($r2.raw)"

"=== 4. the world keeps running in the co-op pause, single Esc"
Key 'Escape'
$w = Lua "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') return 'paused=' .. tostring(GS:IsGamePaused(FindFirstOf('PlayerController')))"
Key 'Escape'
Check "co-op pause leaves the world running" ($w -match 'paused=false') $w

"=== 5. the session ends while the pause menu is open (owner's alpha 21 test: after leaving the lobby the game paused and"
"       the pause menu no longer closed - neither Esc nor Continue)"
$gp = "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') return 'paused=' .. tostring(GS:IsGamePaused(FindFirstOf('PlayerController')))"
Key 'Escape'; $o = Pause
Add-Content "$chan\control.txt" "stop" -Encoding ascii; Start-Sleep 3
$w1 = Lua $gp
Key 'Escape'; $c1 = Pause; $w2 = Lua $gp
Key 'Escape'; $o2 = Pause; $w3 = Lua $gp
Key 'Escape'; $c2 = Pause; $w4 = Lua $gp
Check "out of the session the open pause menu closes with Esc, opens and closes again (a real pause again)" ($o.vis -and -not $c1.vis -and $w2 -match 'paused=false' -and $o2.vis -and $w3 -match 'paused=true' -and -not $c2.vis -and $w4 -match 'paused=false') "open: $($o.raw) | stop: $w1 | esc: $($c1.raw) $w2 | esc: $($o2.raw) $w3 | esc: $($c2.raw) $w4"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
