# Automated test of the twins' part state (twin rework stage B): health / fuel / battery of the owner's parts reach
# its twin on the other side (ES lines); a repair / refuel there reaches the owner's real car (EY lines); damage on
# the twin is the owner's business (not sent, the owner's value comes back). Two instances over the test network.
#   1. host damages its own wheel, empties a fuel can by half -> the guest's twin shows it
#   2. guest repairs that wheel on the twin (the health component's SetHealth: where the game's repair ends) -> host
#   3. guest fills the twin's fuel can -> host's real can
#   4. guest's twin wheel damaged locally -> host keeps its value, the twin returns to it
#   5. guest's own car untouched, no errors
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function Probe($dir, [string]$pre, [string]$file) { Send $dir ($pre + " " + (Get-Content "$t\cmds\$file" -Raw)) }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function EqState($dir) { KV ((Send $dir "return CoopPlayers.ghostInfo()") -replace '.*?(twins=\S+).*?(broken_links=\S+).*?(equip_items=.*)', '$1 $2 $3') }
function RealSlot($dir, [string]$slot) { Send $dir "local sl = FindFirstOf('BP_InventoryManager_C').Inventory_CarEquipped:GetSlot(FName('$slot')) return sl.Items:GetArrayNum() > 0 and sl.Items[1].Archetype:GetFName():ToString() or '-'" }
function TwinSlot($dir, [string]$slot) { Send $dir "local T = CoopPlayers.twinModule() for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then return T.twinSlot(c, '$slot') end end return 'no twin'" }
function InvCount($dir, [string]$what) { Send $dir "local inv = FindFirstOf('BP_InventoryManager_C').Inventory_Player local n = 0 for i = 1, inv.Slots:GetArrayNum() do local sl = inv.Slots[i] for k = 1, sl.Items:GetArrayNum() do if sl.Items[k].Archetype:GetFName():ToString():find('$what', 1, true) then n = n + 1 end end end return tostring(n)" }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function PartState($dir, [string]$which, [string]$slot) {
    if ($which -eq 'twin') { Send $dir "local T = CoopPlayers.twinModule() for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then return T.partState(c, '$slot') end end return 'no twin'" }
    else { Send $dir "return CoopPlayers.twinModule().partState(nil, '$slot')" }
}
function SetPart($dir, [string]$which, [string]$slot, [string]$kv) { Probe $dir "STATE_CAR = '$which' STATE_SET = { slot = '$slot', $kv } STATE_SLOTS = {'$slot'}" "part-state.lua" }
function Num($s, [int]$i) { $p = $s -split ','; if ($p.Count -gt $i -and $p[$i] -ne '') { [double]$p[$i] } else { [double]::NaN } }
function StInfo($dir) { (Send $dir "return CoopPlayers.ghostInfo()") -replace '.*?(state_applied=.*)', '$1' }

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
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4

$w = 'Car.Equip.Essentials.WheelFL'; $can = 'Car.Equip.Attachments.FuelCan'
"=== 1. the host damages its own wheel, half-empties its fuel can"
"  host: " + (SetPart $hd 'own' $w 'health = 60')
"  host: " + (SetPart $hd 'own' $can 'fuel = 5')
Start-Sleep 4
$tw = PartState $cd 'twin' $w; $tc = PartState $cd 'twin' $can
Check "guest: the twin's wheel shows the damage" ([math]::Abs((Num $tw 0) - 60) -lt 1) "twin wheel=$tw"
Check "guest: the twin's fuel can shows the fuel" ([math]::Abs((Num $tc 1) - 5) -lt 0.2) "twin can=$tc"

"=== 1b. the host's wheel dented (its visual damage, what the player sees of wear: item 14)"
$hcOf = "local HC = StaticFindObject('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C') local function hcOf(cont) local sl = cont:GetSlot(FName('$w')) return sl.Items[1]:GetActorManifestation():GetComponentByClass(HC) end"
"  host: " + (Send $hd "$hcOf local hc = hcOf(FindFirstOf('BP_InventoryManager_C').Inventory_CarEquipped) local t = {} hc:GetVisualDamageValues(t) local s = {} for k, v in pairs(t) do s[k] = tostring(k):find('^Impact') and 0.7 or v end hc:SetVisualDamageValues(s) hc:UpdateDamageVisuals() return 'impact 0.7'")
Start-Sleep 4
$tw = PartState $cd 'twin' $w
$mat = Send $cd "$hcOf local T = CoopPlayers.twinModule() for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then local m = hcOf(T.twinContainer(c)).CachedMaterialList[1] local arr = m.ScalarParameterValues for j = 1, arr:GetArrayNum() do local e = arr[j] if e.ParameterInfo.Name:ToString() == 'Impact_Amount' then return string.format('%.2f', e.ParameterValue) end end end end return 'none'"
Check "guest: the twin's wheel shows the dents (value and material)" ([math]::Abs((Num $tw 3) - 0.7) -lt 0.02 -and $mat -match '^0\.7') "twin wheel=$tw material Impact_Amount=$mat"

"=== 2. the guest repairs the host car's wheel on its twin"
"  guest: " + (SetPart $cd 'twin' $w 'health = 175')
Start-Sleep 4
$hw = PartState $hd 'own' $w
Check "host: its real wheel is repaired" ([math]::Abs((Num $hw 0) - 175) -lt 1) "host wheel=$hw"
Start-Sleep 3
Check "guest: the twin keeps the repair" ([math]::Abs((Num (PartState $cd 'twin' $w) 0) - 175) -lt 1) "twin wheel=$(PartState $cd 'twin' $w)"

"=== 3. the guest fills the host car's fuel can on its twin"
"  guest: " + (SetPart $cd 'twin' $can 'fuel = 10')
Start-Sleep 4
$hc = PartState $hd 'own' $can
Check "host: its real fuel can is full" ([math]::Abs((Num $hc 1) - 10) -lt 0.2) "host can=$hc"

"=== 4. the twin's wheel damaged on the guest's side: the owner decides"
"  guest: " + (SetPart $cd 'twin' $w 'health = 20')
Start-Sleep 14
$hw = PartState $hd 'own' $w; $tw = PartState $cd 'twin' $w
Check "host: its wheel is not damaged by it" ([math]::Abs((Num $hw 0) - 175) -lt 1) "host wheel=$hw"
Check "guest: the twin's wheel back to the owner's value" ([math]::Abs((Num $tw 0) - 175) -lt 1) "twin wheel=$tw"

"=== 5. own cars untouched, no errors"
$gw = PartState $cd 'own' $w
Check "guest: its own wheel untouched" ([math]::Abs((Num $gw 0) - 175) -lt 1) "guest own wheel=$gw"
$g = StInfo $cd; $h = StInfo $hd
Check "no state errors, both sides sent and received" ($g -match 'state_errors=0' -and $h -match 'state_errors=0' -and $g -match 'es_recv=[1-9]' -and $h -match 'es_recv=[1-9]') "guest: $g | host: $h"

"  errors host: " + (Send $hd "return CoopPlayers.report()")
"  errors guest: " + (Send $cd "return CoopPlayers.report()")
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
