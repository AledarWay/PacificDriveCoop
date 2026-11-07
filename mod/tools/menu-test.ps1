# The co-op menu (menu.lua) in one headless game in its garage, driven through <chan>/control.txt
# ("menu open" / "menu press <label start>" -> <chan>/menu-status.txt): the pause menu opens with one
# "Кооператив" item, its pages replace the game's items, "Назад" brings them back, the pause stays a real pause
# outside a session. (Mouse clicks and the look: checked with graphics + shot.ps1, see NOTES.)
param([switch]$Keep)
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$chan = "$inst\host\chan-m$(Get-Date -f HHmmss)"
New-Item -ItemType Directory -Force "$chan\inbox", "$chan\outbox" | Out-Null
$env:COOPSYNC_CHAN = $chan.Replace('\', '/'); & "$t\start-zone.ps1" -Tag host -Seed 12345 -StopInGarage | Select-Object -Last 1; Remove-Item Env:COOPSYNC_CHAN
Start-Sleep 3
function Menu([string]$c) {
    Add-Content "$chan\control.txt" "menu $c" -Encoding utf8; Start-Sleep 2
    $l = @(Get-Content "$chan\menu-status.txt" -Encoding utf8)
    @{ result = $l[0]; info = $l[1]; rows = if ($l[1] -match 'rows=(\d+)') { [int]$Matches[1] } else { -1 }; page = if ($l[1] -match 'page=(\S+)') { $Matches[1] } else { '' }; hidden = if ($l[1] -match 'hidden=(\d+)') { [int]$Matches[1] } else { -1 } }
}
$end = (Get-Date).AddSeconds(60)
while (-not (Test-Path "$chan\status.txt") -and (Get-Date) -lt $end) { Start-Sleep 2 }
for ($i = 0; $i -lt 5; $i++) { $m = Menu "open"; Start-Sleep 3; $m = Menu "info"; if ($m.info -match 'visible=true item=true') { break } }
Check "the pause menu opens with our item" ($m.info -match 'visible=true item=true') $m.info
Start-Sleep 3; $m2 = Menu "info"
Check "the item is added once (not every refresh)" ($m2.info -eq $m.info) $m2.info
$m = Menu "press Кооператив"
Check "co-op page replaces the game's items" ($m.page -eq 'coop' -and $m.rows -ge 2 -and $m.hidden -ge 5) $m.info
# (owner, alpha 19: the rows that do nothing - lobby state, players - back in the column, as text headers; no ping)
# (no lobby here: the rows that are text - if any - must all be headers in the column; startflow checks a lobby's)
$hn = if ($m.info -match 'headers=(\d+)') { [int]$Matches[1] } else { -1 }
$hl = if ($m.info -match 'headers: (.*)$') { @($Matches[1] -split ' / ' | Where-Object { $_ }).Count } else { -1 }
Check "the page's state rows are headers in our column (not buttons, no ping)" ($hn -eq $hl -and $m.info -notmatch 'пинг') $m.info
Check "no debug items in the pause menu (they are on the F7 panel)" ($m.info -notmatch 'Отладка|Пересинхронизировать') $m.info
$m = Menu "press Назад"
Check "back to the game's own items" ($m.page -eq 'nil' -and $m.rows -eq 0 -and $m.hidden -eq 0) $m.info
Check "there our item is in the game's list and visible (alpha 9 lost it)" ($m.info -match 'shown=true') $m.info
function Lua([string]$code) {
    (& "$t\send.ps1" -File (New-Item -Force "$inst\host\coopdev\_m.lua" -Value $code).FullName -Dir "$inst\host\coopdev" -TimeoutSec 30) -join ' '
}
$p = Lua "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') return 'paused=' .. tostring(GS:IsGamePaused(FindFirstOf('PlayerController')))"
Check "outside a session the pause menu pauses the game" ($p -match 'paused=true') $p
# the pause menu closed while a co-op page shows: the next pause shows the game's items once, no rows of ours
$items = "local n, v = 0, 0 for _, m in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if m:GetFullName():find('/Engine/Transient', 1, true) then local b = m.MenuItemBox for i = 0, b:GetChildrenCount() - 1 do n = n + 1 if b:GetChildAt(i):IsVisible() then v = v + 1 end end end end return 'items=' .. n .. ' visible=' .. v"
function Items { if ((Lua $items) -match 'items=\d+ visible=\d+') { $Matches[0] } else { 'none' } }
$before = Items
$m = Menu "press Кооператив"
Lua "FindFirstOf('PDP_Game_Hud_C'):SetPauseMenuWidgetVisible(false) return 'closed'" | Out-Null
Start-Sleep 2
$m = Menu "info"
Check "closing the pause on a co-op page clears it" ($m.page -eq 'nil' -and $m.rows -eq 0 -and $m.hidden -eq 0) $m.info
$m = Menu "open"; Start-Sleep 2; $m = Menu "press Назад"; Start-Sleep 1
$after = Items
Check "the next pause has the same items (no duplicates)" ($after -eq $before -and $before -match 'items=\d') "before: $before | after: $after"
Lua "FindFirstOf('PDP_Game_Hud_C'):SetPauseMenuWidgetVisible(false) return 'closed'" | Out-Null
Start-Sleep 2

# the F7 panel (control "panel ..." -> panel-status.txt)
function Panel([string]$c) {
    Add-Content "$chan\control.txt" "panel $c" -Encoding utf8; Start-Sleep 2
    $l = @(Get-Content "$chan\panel-status.txt" -Encoding utf8)
    @{ result = $l[0]; info = $l[1] }
}
$pn = Panel "open"; Start-Sleep 2; $pn = Panel "info"
Check "the panel opens with the lobby and debug rows" ($pn.info -match 'shown=true vis=0' -and $pn.info -match 'Пересинхронизировать' -and $pn.info -match 'Собрать отчёт') $pn.info
$p = Lua "local m for _, x in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if x:GetFullName():find('/Engine/Transient', 1, true) then m = x end end return 'pause_vis=' .. tostring(m and m:IsVisible()) .. ' opacity=' .. tostring(m and m:GetRenderOpacity())"
Check "the pause menu under the panel is open but transparent" ($p -match 'pause_vis=true opacity=0') $p
$pn = Panel "press Пересинхронизировать"
Check "a panel action answers (no session: nothing to resync)" ($pn.result -match 'нечего синхронизировать') "$($pn.result) | $($pn.info)"
$pn = Panel "press Состояние"
Check "panel state page" ($pn.info -match 'page=state' -and $pn.info -match 'Сессия: role=') $pn.info
$pn = Panel "press Назад"
Check "panel back to its main page" ($pn.info -match 'page=main') $pn.info
$pn = Panel "close"; Start-Sleep 1
$p = Lua "local m for _, x in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if x:GetFullName():find('/Engine/Transient', 1, true) then m = x end end return 'pause_vis=' .. tostring(m and m:IsVisible()) .. ' opacity=' .. tostring(m and m:GetRenderOpacity())"
Check "the panel closes with the pause menu, its opacity back" ($pn.info -match 'shown=false vis=1' -and $p -match 'pause_vis=false opacity=1') "$($pn.info) | $p"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
