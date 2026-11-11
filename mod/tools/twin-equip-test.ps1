# Automated test of the twins' parts (twin rework stage A): each side's twin of the other's car carries the owner's
# equipment (EQ lines) in a container of its own; parts taken off / put on there with the game's own action go to the
# owner's real car (EX lines). Two instances over the test network, own-car mode.
#   1. twins spawned from EQ, the own cars' item links whole
#   2. guest takes the host car's wheel off its twin (SwapEquipment held, the game's action) -> host's real slot empty
#   3. guest puts it back (the inventory item moved into the twin's slot, as the game's attach) -> host's slot has it
#   4. host takes the guest car's wheel off its twin -> guest's real slot empty
#   5. host takes a device off its own seat 3 -> the guest's twin follows
#   6. host takes parts off its own car and puts them back, the guest's car beside it -> the guest's car stands still
param([switch]$Keep, [switch]$OldZone)
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
# look at the twin's part in slot $slot until the game highlights that slot, then hold SwapEquipment 3 s
function TakeOff($dir, [string]$short, [string]$full) {
    $h = ''
    # (the part's middle, then the slot's point - where the game's spot for it is - at a few heights, as a player moves
    # the mouse until the prompt shows)
    foreach ($try in 'false 0', 'false -25', 'false 25', 'true 0', 'true -25', 'true 25', 'false -45', 'false 45') {
        $atSlot, $dz = $try -split ' '
        $lk = (Probe $dir "LOOK_AT_SLOT = $atSlot LOOK_DZ = $dz LOOK_SLOT = '$short'" "twin-parts-look.lua") -split "`n" | Select-Object -Last 1
        Start-Sleep 1
        $h = Probe $dir "" "highlight-now.lua"
        if ($h -match "car=TWIN slot=$([regex]::Escape($full))") {
            Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command SwapEquipment'](p, true) Dev.after(3000, function() local q = FindFirstOf('PlayerController').Pawn q['Command SwapEquipment'](q, false) end) return 'swap held'" | Out-Null
            Start-Sleep 6
            return "aimed dz=$dz, swap held"
        }
    }
    $why = Send $dir "local hm = FindFirstOf('BP_HighlightManager_C') local m = FindFirstOf('BP_CarManager_C') local p = FindFirstOf('PlayerController').Pawn local a = p:GetAttachParentActor() return 'hm_enabled=' .. tostring(hm.Enabled) .. ' item=' .. tostring(hm.ItemEquipped) .. ' parts_disabled=' .. tostring(m['Car Parts Interaction Disabled Queue']) .. ' attached=' .. tostring(a and a:IsValid() and a:GetFName():ToString()) .. ' ' .. CoopPlayers.nativeInfo():match('ctx=%S+') .. ' twin_ctx=' .. tostring(CoopPlayers.twinModule().isTwin(m.NewCarActor)) .. ' ' .. (CoopPlayers.nativeInfo():match('reach_denied=%S+') or '')"
    $spot = Send $dir "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local att = {} tw:GetAttachedActors(att, true) local hm = FindFirstOf('BP_HighlightManager_C') for i = 1, #att do local a = att[i]:get() if a:IsValid() and a:GetClass():GetFName():ToString() == 'BP_CarPart_Interactive_C' then local out = {} pcall(function() a:GetSlotComponent(out) end) local sc = out.SlotSceneComponent if sc and sc:IsValid() and sc.SlotName.TagName:ToString() == '$full' then local r1, r2 = {}, {} pcall(function() hm['Should Allow Highlight'](hm, a.Highlight, r1, r2) end) local ok, sh = pcall(function() return a:K2_ShouldHighlight() end) return 'spot allow=' .. tostring(r1.Allow) .. ' why=' .. tostring(r2['Fail Reason'] and r2['Fail Reason']:ToString()) .. ' should=' .. tostring(sh) .. ' hidden=' .. tostring(a.bHidden) .. ' active=' .. tostring(a.Highlight:IsActive()) end end end return 'no spot'"
    $where = Send $dir "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local function rel(a) local l = KML:InverseTransformLocation(tw:GetTransform(), a) return string.format('%.0f,%.0f,%.0f', l.X, l.Y, l.Z) end local pc = FindFirstOf('PlayerController') local pup = CoopPlayers.puppetParts() local own = T.ownCar() return 'me=' .. rel(pc.Pawn:K2_GetActorLocation()) .. ' cam=' .. rel(pc.PlayerCameraManager:GetCameraLocation()) .. ' puppet=' .. (pup and rel(pup:K2_GetActorLocation()) or '-') .. ' own_car=' .. rel(own:K2_GetActorLocation()) .. ' twin_up=' .. string.format('%.2f', tw:GetActorUpVector().Z) .. ' twin_doors_sim=' .. (function() local o = '' for n = 1, 5 do o = o .. (T.doorOpen(tw, n) and n or '-') end return o end)() .. ' ' .. CoopPlayers.nativeInfo():match('opened_here=%S+') .. ' ' .. CoopPlayers.nativeInfo():match('doors_local=%S*')"
    return "NOT aimed: $h | look: $lk | $why | $spot | $where"
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -OldZone:$OldZone | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4

"=== 1. twins from the owners' equipment"
$g = EqState $cd; $h = EqState $hd
Check "guest: the host car's twin carries its equipment" ($g.twins -eq '1' -and [int]$g.equip_items -gt 30 -and $g.broken_links -eq '0') $g.raw
Check "host: the guest car's twin carries its equipment" ($h.twins -eq '1' -and [int]$h.equip_items -gt 30 -and $h.broken_links -eq '0') $h.raw

"=== 2. the guest takes the host car's rear left wheel off (its twin, the game's SwapEquipment)"
$w = 'Car.Equip.Essentials.WheelRL'
"  host real before: " + (RealSlot $hd $w)
"  guest: " + (TakeOff $cd 'WheelRL' $w)
Check "guest: the twin's slot is empty, the wheel in its inventory" ((TwinSlot $cd $w) -eq '-' -and [int](InvCount $cd 'Wheel') -ge 1) "twin=$(TwinSlot $cd $w) wheels=$(InvCount $cd 'Wheel')"
Check "host: its real car lost that wheel" ((RealSlot $hd $w) -eq '-') "host real=$(RealSlot $hd $w)"

"=== 3. the guest puts the wheel back on"
"  guest: " + (Probe $cd "PUT_SLOT = '$w'" "twin-put-on.lua")
Start-Sleep 5
Check "host: its real car has the wheel again" ((RealSlot $hd $w) -eq 'IA_Attach_Wheel_Basic') "host real=$(RealSlot $hd $w)"
Check "guest: the twin keeps it, the inventory gave it" ((TwinSlot $cd $w) -match 'IA_Attach_Wheel_Basic' -and [int](InvCount $cd 'Wheel') -eq 0) "twin=$(TwinSlot $cd $w) wheels=$(InvCount $cd 'Wheel')"

"=== 4. the host takes the guest car's front left wheel off (its twin)"
# (native cars: the guest car's doors as its owner left them - the bot's exit leaves its driver's door open; the twin's
# door opens on the host's side too, a real door in front of that wheel: shut first, as a player would)
"  guest's doors: " + (Send $cd "local T = CoopPlayers.twinModule() local own = T.ownCar() local o = {} for n = 1, 5 do if T.doorOpen(own, n) then o[#o + 1] = n .. ':' .. T.setDoor(own, n, 'shut') end end return #o == 0 and 'all shut' or table.concat(o, ' ')")
Start-Sleep 5
$w2 = 'Car.Equip.Essentials.WheelFL'
"  host: " + (TakeOff $hd 'WheelFL' $w2)
Check "host: the twin's slot is empty, the wheel in its inventory" ((TwinSlot $hd $w2) -eq '-' -and [int](InvCount $hd 'Wheel') -ge 1) "twin=$(TwinSlot $hd $w2) wheels=$(InvCount $hd 'Wheel')"
Check "guest: its real car lost that wheel" ((RealSlot $cd $w2) -eq '-') "guest real=$(RealSlot $cd $w2)"

"=== 5. the host takes the device off its own seat 3: the guest's twin follows"
"  host: " + (Send $hd "return CoopPlayers.removeSeatDevice(3)")
Start-Sleep 5
Check "guest: the host car's twin seat frame is empty" ((TwinSlot $cd 'Car.Equip.Attachments.BackSeatLeft') -eq '-') "twin=$(TwinSlot $cd 'Car.Equip.Attachments.BackSeatLeft')"
"=== 6. the host takes parts off its own car and puts them back, the guest's car right beside it (owner's two-games test 2026-11-11: the guest's car jerked, it even turned over)"
"  guest's car beside the host's: " + (Send $cd "local own = CoopPlayers.twinModule().ownCar() own:K2_SetActorLocationAndRotation($(Send $hd "local c = CoopPlayers.twinModule().ownCar() local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(c:GetTransform(), { X = 0, Y = 330, Z = 60 }) local r = c:K2_GetActorRotation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}, { Pitch = 0, Yaw = %.1f, Roll = 0 }', w.X, w.Y, w.Z, r.Yaw)"), false, {}, true) own.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) return 'beside'")
Start-Sleep 6
# (the guest's car every 50 ms: its largest move and turn from where it stood)
Send $cd "JW = { d = 0, r = 0 } local own = CoopPlayers.twinModule().ownCar() local l0, r0 = own:K2_GetActorLocation(), own:K2_GetActorRotation() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > 24 then CancelDelayedAction(h) return end local l, r = own:K2_GetActorLocation(), own:K2_GetActorRotation() JW.d = math.max(JW.d, math.sqrt((l.X - l0.X) ^ 2 + (l.Y - l0.Y) ^ 2 + (l.Z - l0.Z) ^ 2)) JW.r = math.max(JW.r, math.abs(r.Pitch - r0.Pitch) + math.abs(r.Roll - r0.Roll) + math.abs(((r.Yaw - r0.Yaw) % 360 + 540) % 360 - 180)) end) return 'watching'" | Out-Null
# (and the host's twin of the guest's car - it follows the guest's car, kinematic: it must not move either)
Send $hd "JW = { d = 0, r = 0 } local T = CoopPlayers.twinModule() local own for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then own = c end end local l0, r0 = own:K2_GetActorLocation(), own:K2_GetActorRotation() local t0 = os.clock() local h h = LoopInGameThreadWithDelay(50, function() if os.clock() - t0 > 24 or not own:IsValid() then CancelDelayedAction(h) return end local l, r = own:K2_GetActorLocation(), own:K2_GetActorRotation() JW.d = math.max(JW.d, math.sqrt((l.X - l0.X) ^ 2 + (l.Y - l0.Y) ^ 2 + (l.Z - l0.Z) ^ 2)) JW.r = math.max(JW.r, math.abs(r.Pitch - r0.Pitch) + math.abs(r.Roll - r0.Roll) + math.abs(((r.Yaw - r0.Yaw) % 360 + 540) % 360 - 180)) end) return 'watching'" | Out-Null
$slots = @('Car.Equip.Body.DoorsFR', 'Car.Equip.Body.BumperFront', 'Car.Equip.Essentials.WheelRR')
$have = @{}; foreach ($sl in $slots) { $have[$sl] = Send $hd "local line = CoopPlayers.twinModule().equipLine() or '' return line:match('$($sl.Replace('.', '%.'))=([^;]+)') or '-'" }
"  host's parts: " + (($slots | ForEach-Object { "$_=$($have[$_])" }) -join ' ')
foreach ($round in 1..3) {
    foreach ($sl in $slots) {
        if ($have[$sl] -eq '-') { continue }
        Send $hd "return CoopPlayers.twinModule().ownerEquip('$sl', '-')" | Out-Null; Start-Sleep 1
        Send $hd "return CoopPlayers.twinModule().ownerEquip('$sl', '$($have[$sl])')" | Out-Null; Start-Sleep 1
    }
}
Start-Sleep 6
$jw = Send $cd "return string.format('moved=%.0f turned=%.1f', JW.d, JW.r)"
"  guest's car while the host's parts went off and on: $jw"
$jk = KV $jw
Check "the guest's car stood still (moved < 15, turned < 2 deg)" ([double]$jk.moved -lt 15 -and [double]$jk.turned -lt 2) $jw
$jh = Send $hd "return string.format('moved=%.0f turned=%.1f', JW.d, JW.r)"; $jhk = KV $jh
Check "the host's twin of it stood still too" ([double]$jhk.moved -lt 15 -and [double]$jhk.turned -lt 2) $jh
$on = ($slots | Where-Object { $have[$_] -ne '-' } | ForEach-Object { "'$_'" }) -join ', '
$hp = Send $hd "local line = CoopPlayers.twinModule().equipLine() or '' local o = {} for _, s in ipairs({ $on }) do o[#o + 1] = (line:find(s:gsub('%.', '%%.') .. '=', 1) and 'on' or 'off') end return table.concat(o, ' ')"
Check "the host's parts back on" ($hp -notmatch 'off') $hp
$g = EqState $cd; $h = EqState $hd
Check "no equipment errors, own items' links whole on both sides" ($g.equip_errors -eq '0' -and $h.equip_errors -eq '0' -and $g.broken_links -eq '0' -and $h.broken_links -eq '0') "guest: $($g.raw) | host: $($h.raw)"

"  errors host: " + (Send $hd "return CoopPlayers.report()")
"  errors guest: " + (Send $cd "return CoopPlayers.report()")
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
