# Automated test of the cars' storages (carstore.lua, own-car mode): the other's twin's trunk is the owner's trunk
# (not the local player's own), what the visitor puts / takes there changes the owner's real trunk, the owner's own
# changes reach the twin. Two instances over the test relays.
#   1. the host's trunk gets 3 fabric -> the guest's twin of the host's car shows them; the guest's own trunk untouched
#   2. the guest takes 1 from the twin's trunk -> the host's real trunk has 2
#   3. the guest puts 2 steel scrap into the twin's trunk -> the host's real trunk has them
#   4. the host takes 1 fabric itself -> the twin shows 1
#   4b. the guest moves an item to another tile / puts one on a tile -> on the same tile in the host's trunk
#   4c. the guest takes while the host puts at the same moment -> the taken item never back in the twin, both alike
#   5. a small storage attachment on the host's car (an empty window slot): its contents in the guest's twin
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$FAB = '/Game/Gameplay/Inventory/Items/Resources/Basic/RawFabric/IA_Resource_Raw_Fabric.IA_Resource_Raw_Fabric'
$STEEL = '/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel'
$STORE = '/Game/Gameplay/Inventory/Items/Car/Storage/Storage_Attach_Small/IA_Attach_Util_Storage_Small.IA_Attach_Util_Storage_Small'
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Op($dir, [string]$op, [string]$arch, [int]$n = 1, [string]$extra = '') { Send $dir "ST_OP = '$op' ST_ARCH = '$arch' ST_N = $n $extra $(Get-Content "$t\cmds\store-ops.lua" -Raw)" }
function Count($dir, [string]$arch) { KV (Op $dir 'count' $arch) }
# the guest's count of arch (twin / own / player field) until it equals want (max ~8 s)
function WaitCount($dir, [string]$arch, [string]$field, [int]$want) {
    for ($i = 0; $i -lt 16; $i++) { $c = Count $dir $arch; if ([int]$c[$field] -eq $want) { return $c }; Start-Sleep -Milliseconds 500 }
    $c
}
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 3

"=== 1. the host's trunk gets 3 fabric"
"  host: " + (Op $hd 'add' $FAB 3)
$g = WaitCount $cd $FAB 'twin' 3
Check "guest: the twin's trunk is a container of its own (not the guest's trunk)" ($g.twin_is_own -eq 'false') $g.raw
Check "guest: the twin's trunk shows the host's 3 fabric, the own trunk none" ([int]$g.twin -eq 3 -and [int]$g.own -eq 0) $g.raw

"=== 1b. the game's RefreshTrunkInventory on the twin's trunk storage (it runs on trunk changes): still the host's"
# (owner, alpha 16: "the friend opened the box in my trunk: his own loot" - the game's refresh pointed the twin's box at
# the local player's own trunk; checked in the same call, before any periodic fix-up)
$g = KV (Send $cd "local T = CoopPlayers.twinModule() for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then local att = {} c:GetAttachedActors(att, true) for i = 1, #att do local a = att[i]:get() if a:GetClass():GetFName():ToString():find('Storage_Trunk', 1, true) then a:RefreshTrunkInventory() end end end end ST_OP = 'count' ST_ARCH = '$FAB' ST_N = 1 $(Get-Content "$t\cmds\store-ops.lua" -Raw)")
Check "guest: right after the game's refresh the twin's box is still its own, with the host's 3 fabric" ($g.twin_is_own -eq 'false' -and [int]$g.twin -eq 3) $g.raw

"=== 2. the guest takes 1 fabric from the twin's trunk"
$p0 = [int]$g.player
"  guest: " + (Op $cd 'twintake' $FAB 1)
$h = WaitCount $hd $FAB 'own' 2
$g = Count $cd $FAB
Check "host: its real trunk has 2 left" ([int]$h.own -eq 2) "host $($h.raw)"
Check "guest: the fabric in its inventory, the twin shows 2" ([int]$g.player -eq $p0 + 1 -and [int]$g.twin -eq 2) "guest $($g.raw)"

"=== 3. the guest puts 2 steel scrap into the twin's trunk"
"  guest gets 2 steel: " + (Send $cd "local im = FindFirstOf('BP_InventoryManager_C') local L = StaticFindObject('/Script/PenDriverInventory.Default__InventoryBlueprintLibrary') local a = StaticFindObject('$STEEL') if not (a and a:IsValid()) then LoadAsset('$($STEEL -replace '\.[^.]+$', '')') a = StaticFindObject('$STEEL') end for i = 1, 2 do im.Inventory_Player:AddItem(L:CreateItemInstance(FindFirstOf('PlayerController'), a, 4), true) end return 'ok'")
"  guest: " + (Op $cd 'twinput' $STEEL 2)
$h = WaitCount $hd $STEEL 'own' 2
$g = Count $cd $STEEL
Check "host: the 2 steel in its real trunk" ([int]$h.own -eq 2) "host $($h.raw)"
Check "guest: the twin shows them, its own trunk none" ([int]$g.twin -eq 2 -and [int]$g.own -eq 0) "guest $($g.raw)"

"=== 4. the host takes 1 fabric itself"
"  host: " + (Op $hd 'take' $FAB 1)
$g = WaitCount $cd $FAB 'twin' 1
Check "guest: the twin shows 1 fabric" ([int]$g.twin -eq 1) $g.raw
$h = Count $hd $FAB
Check "host: 1 fabric (no echo of the guest's view back)" ([int]$h.own -eq 1) $h.raw

"=== 4b. tiles: the guest moves the steel to the twin trunk's last free tile, puts its fabric on another"
function SameTiles() { for ($i = 0; $i -lt 16; $i++) { $h = (Op $hd 'tiles' $FAB) -replace '^own=(\S*) .*', '$1'; $g = (Op $cd 'tiles' $FAB) -replace '.* twin=(\S*)$', '$1'; if ($h -eq $g) { return @($true, $h, $g) }; Start-Sleep -Milliseconds 500 }; @($false, $h, $g) }
$mv = Op $cd 'twinmove' $STEEL 1
"  guest: $mv"
$r = SameTiles
Check "host: the steel moved to the same tile in its real trunk (same layout on both)" ($mv -match '^tile=' -and $r[0] -and $r[1] -match ($mv -replace '^tile=', '')) "host $($r[1]) | twin $($r[2])"
$pt = Op $cd 'twinputat' $FAB 1
"  guest: $pt"
$r = SameTiles
Check "host: the guest's fabric on the same tile in its real trunk" ($pt -match '^tile=' -and $r[0] -and $r[1] -match ($pt -replace '^tile=', '')) "host $($r[1]) | twin $($r[2])"

"=== 4c. a race: the guest takes a steel while the host puts 2 fabric at the same moment"
$s0 = Count $cd $STEEL
"  guest: " + (Op $cd 'twintake' $STEEL 1) + " | host: " + (Op $hd 'add' $FAB 2)
# the twin must not show the taken steel again meanwhile (an owner's line sent before the take reached it)
$back = $false
for ($i = 0; $i -lt 12; $i++) { $c = Count $cd $STEEL; if ([int]$c.twin -gt [int]$s0.twin - 1) { $back = $true }; Start-Sleep -Milliseconds 250 }
Check "guest: the taken steel never came back in the twin's trunk" (-not $back) "twin steel before $($s0.twin), last $($c.twin)"
$r = SameTiles
Check "both trunks alike after it (every item on the same tile)" $r[0] "host $($r[1]) | twin $($r[2])"

"=== 5. a storage attachment on the host's car"
$slot = 'Car.Equip.Attachments.LeftRearWindowBack' # (an empty slot that takes a small storage)
"  host: " + (Op $hd 'equip' $STORE 1 "ST_SLOT = '$slot'")
Start-Sleep 4
$e = Op $hd 'slotadd' $FAB 2 "ST_SLOT = '$slot'"
"  host: $e"
if ($e -match 'added [1-9]') {
    $ok = $false
    for ($i = 0; $i -lt 16; $i++) { $sc = KV (Op $cd 'slotcount' $FAB 1 "ST_SLOT = '$slot'"); if ([int]$sc.twin -eq 2) { $ok = $true; break }; Start-Sleep -Milliseconds 500 }
    Check "guest: the twin's storage attachment holds the host's 2 fabric" $ok $sc.raw
    "  guest puts the steel it took there: " + (Op $cd 'slotput' $STEEL 1 "ST_SLOT = '$slot'")
    $ok = $false
    for ($i = 0; $i -lt 16; $i++) { $sc = KV (Op $hd 'slotcount' $STEEL 1 "ST_SLOT = '$slot'"); if ([int]$sc.own -eq 1) { $ok = $true; break }; Start-Sleep -Milliseconds 500 }
    Check "host: its storage attachment got the guest's steel" $ok $sc.raw
} else { Check "host: the storage attachment on its car" $false $e }

$hi = Ghost $hd; $gi = Ghost $cd
"  host: cs_sent=$($hi.cs_sent) cx_done=$($hi.cx_done) cx_put=$($hi.cx_put) cx_take=$($hi.cx_take) errors=$($hi.store_errors)"
"  guest: cs_recv=$($gi.cs_recv) cs_applied=$($gi.cs_applied) cx_sent=$($gi.cx_sent) pointed=$($gi.trunk_pointed) errors=$($gi.store_errors)"
Check "no storage errors" ([int]$hi.store_errors -eq 0 -and [int]$gi.store_errors -eq 0) "host $($hi.store_errors) guest $($gi.store_errors)"
$eh = Send $hd "return CoopPlayers.report()"; $eg = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($eh -notmatch 'errors=[1-9]|ERR' -and $eg -notmatch 'errors=[1-9]|ERR') "host: $eh | guest: $eg"
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
