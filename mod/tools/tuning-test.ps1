# Each car drives by its own parts (owner, 2026-11-09: "after we swapped cars the cars' characteristics swapped").
# The cars' handling writes into the context car's tuning graph with the local player's own parts; now each car has a
# graph of its own; the own car's part parameters stay its own, the other's car gets its owner's (TU lines, tuning.lua).
#   1. each side: both cars drive by a graph of their own (not the shared asset, not each other's)
#   2. the host's car on offroad tires: on both sides that car's graph has them, the guest's car's its basic ones
#   3. the guest at the wheel of the host's car (its context): still each car its own tires
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', '').Trim()
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
$look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
function Press($dir, [int]$ms = 100) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E'" }
function Twin() { "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end" }
$TU = "local TU = CoopSyncTuningModule or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/tuning.lua')"
# the graphs: own / twin / asset addresses, and a few part parameters of own and twin
function Graphs($dir) {
    Send $dir "$(Twin) $TU local VC = StaticFindObject('/Script/IWCarPhysics.VehicleControllerComponent') local own = T.ownCar() local a = StaticFindObject('/Game/Characters/PlayerCar/TuningProfiles/MainTuningGraph.MainTuningGraph') local function ad(c) local p = c:GetComponentByClass(VC).Profile return string.format('%X', p:GetAddress()) end local function pv(c, n) local v = TU.param(c, n) return v and string.format('%.3f', v) or '-' end return string.format('own=%s twin=%s asset=%X wo=%s/%s wr=%s/%s %s', ad(own), ad(tw), a:GetAddress(), pv(own, 'WheelOffroad'), pv(tw, 'WheelOffroad'), pv(own, 'WheelRoad'), pv(tw, 'WheelRoad'), TU.info())"
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }

& "$t\collide-test.ps1" -SetupOnly | Select-String 'arrived|RUNTIME'
Start-Sleep 5

"=== 1. each car drives by a graph of its own"
$h1 = KV (Graphs $hd); $c1 = KV (Graphs $cd)
"  host:  $($h1.raw)"; "  guest: $($c1.raw)"
$own3 = { param($g) $g.own -and $g.twin -and $g.own -ne $g.twin -and $g.own -ne $g.asset -and $g.twin -ne $g.asset }
Check "each side: own car, twin and the asset are three graphs" ((& $own3 $h1) -and (& $own3 $c1)) "host own=$($h1.own) twin=$($h1.twin) asset=$($h1.asset) | guest own=$($c1.own) twin=$($c1.twin) asset=$($c1.asset)"

"=== 2. the host's car on offroad tires"
# (the four wheels in the host's equipped inventory become IA_Attach_Wheel_Offroad, as fitting them does; back at the end)
function Wheels($dir, $arch) { Send $dir "local im = FindFirstOf('BP_InventoryManager_C') local c = im.Inventory_CarEquipped local L = StaticFindObject('/Script/PenDriverInventory.Default__InventoryBlueprintLibrary') local a = StaticFindObject('$arch') if not (a and a:IsValid()) then LoadAsset(('$arch'):gsub('%.[^.]+`$', '')) a = StaticFindObject('$arch') end local n = 0 for _, w in ipairs({ 'WheelFL', 'WheelFR', 'WheelRL', 'WheelRR' }) do local fn = FName('Car.Equip.Essentials.' .. w) local sl = c:FindOrCreateSlot(fn) for k = sl.Items:GetArrayNum(), 1, -1 do local it = sl.Items[k] pcall(function() c:RemoveItemFromSlot(fn, it) end) pcall(function() it:Remove(true) end) end local inst = L:CreateItemInstance(c, a, 0) if sl:AddItem(inst) ~= false then n = n + 1 end end return n .. ' wheels ' .. a:GetFName():ToString()" }
$off = '/Game/Gameplay/Inventory/Items/Car/Wheels/Wheel_Offroad_01/IA_Attach_Wheel_Offroad.IA_Attach_Wheel_Offroad'
$basic = '/Game/Gameplay/Inventory/Items/Car/Wheels/Wheel_Basic_01/IA_Attach_Wheel_Basic.IA_Attach_Wheel_Basic'
# (5 reads 0.3 s apart: a graph two handlings wrote showed their tires in turn)
function Reads($dir) { $r = @(); foreach ($k in 1..5) { $r += ,(KV (Graphs $dir)); Start-Sleep -Milliseconds 300 }; $r }
function Same5($reads, $field, [int]$idx, $want) { foreach ($g in $reads) { if ([math]::Abs((& $num (($g.$field -split '/')[$idx])) - $want) -ge 0.01) { return $false } }; $true }
function Seq($reads, $field) { ($reads | ForEach-Object { $_.$field }) -join ' ' }
$num = { param($s) $x = 0.0; [double]::TryParse("$s", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x) | Out-Null; $x }
$h0 = KV (Graphs $hd)
$basicWo = & $num (($h0.wo -split '/')[0])
"  host: " + (Wheels $hd $off)
Start-Sleep 8
$hr = Reads $hd; $cr = Reads $cd
$offWo = & $num (($hr[0].wo -split '/')[0])
"  host wo own/twin: $(Seq $hr 'wo') | $($hr[0].raw)"
"  guest wo own/twin: $(Seq $cr 'wo') | $($cr[0].raw)"
Check "the host's own car on its offroad tires, its twin of the guest's on the guest's basic ones (steady)" ([math]::Abs($offWo - $basicWo) -gt 0.01 -and (Same5 $hr 'wo' 0 $offWo) -and (Same5 $hr 'wo' 1 $basicWo)) "host $(Seq $hr 'wo') (basic $basicWo)"
Check "the guest: its twin of the host's car on the host's tires, its own on its own (steady)" ((Same5 $cr 'wo' 1 $offWo) -and (Same5 $cr 'wo' 0 $basicWo)) "guest $(Seq $cr 'wo')"
"=== 3. the guest at the wheel of the host's car"
"  host out: " + (Send $hd "CE_CAR = 'own' CE_HL = 'ExitDoor' $(Get-Content "$t\cmds\car-e.lua" -Raw)")
Start-Sleep 5
"  host steps away: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local l, r = car:K2_GetActorLocation(), car:GetActorRightVector() p:K2_SetActorLocation({ X = l.X - r.X * 500, Y = l.Y - r.Y * 500, Z = l.Z + 80 }, false, {}, true) return 'away'")
Start-Sleep 2
"  guest to the driver's door: " + (Send $cd "$(Twin) local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(tw:GetTransform(), { X = 100, Y = -230, Z = 0 }) local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
Start-Sleep 2
foreach ($dz in 0, 20, -20, 40) {
    Send $cd "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = 'DoorsFL' $look" | Out-Null; Start-Sleep -Milliseconds 700
    Send $cd "LOOK_OWN = false LOOK_DZ = $dz LOOK_SLOT = 'DoorsFL' $look" | Out-Null; Start-Sleep -Milliseconds 500
    if ((Send $cd "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)") -match '^1$') { break }
}
"  guest: " + (Press $cd)
Start-Sleep 6
$gi = KV (Send $cd "return CoopPlayers.ghostInfo()")
$c3 = Reads $cd
"  guest: in_ghost=$($gi.in_ghost) seat=$($gi.seat) | wo own/twin $(Seq $c3 'wo') | $($c3[0].raw)"
$ctx = Send $cd "$(Twin) local m = FindFirstOf('BP_CarManager_C') return tostring(m.NewCarActor:GetAddress() == tw:GetAddress())"
Check "the guest sits at the host car's wheel (its context)" ($gi.in_ghost -eq 'H' -and $gi.seat -eq '1' -and $ctx -eq 'true') "in_ghost=$($gi.in_ghost) seat=$($gi.seat) ctx=$ctx"
Check "the host's car drives by the host's tires there, the guest's own keeps the guest's (steady)" ((Same5 $c3 'wo' 1 $offWo) -and (Same5 $c3 'wo' 0 $basicWo)) "guest $(Seq $c3 'wo')"
"  guest out: " + (Send $cd "CE_CAR = 'twin' CE_HL = 'ExitDoor' $(Get-Content "$t\cmds\car-e.lua" -Raw)")
"  host: " + (Wheels $hd $basic)
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
