# The other's car's gas cap (owner, 2026-11-09: "the friend's car's fuel tank does nothing - let us siphon from it and
# fill it"): its cap shows its own tanks, and a canister fills it / siphons it the game's way (the fuelable component's
# TransferFuel, as holding a canister at a cap ends in) - the owner's real tank changes, the player's own car's not.
#   1. the guest looks at the host's car's cap: the host's fuel (not its own), and it can be siphoned
#   2. the guest pours 3 from a canister into the host's car: the host's tank +3, the guest's own unchanged
#   3. the guest siphons 2 from the host's car into the canister: the host's tank -2, the guest's own unchanged
#   4. the host pours 2 into the guest's car: the guest's tank +2, the host's own unchanged
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
$num = { param($s) $x = 0.0; [double]::TryParse("$s", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x) | Out-Null; $x }
$FC = "StaticFindObject('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C')"
# the own car's back seat tank (the save's one tank with fuel in it)
function Tank($dir) { Send $dir "local im = FindFirstOf('BP_InventoryManager_C') local sl = im.Inventory_CarEquipped:GetSlot(FName('Car.Equip.Attachments.BackSeatLeft')) local fc = sl.Items[1]:GetActorManifestation():GetComponentByClass($FC) local t = { {}, {}, {}, {}, {}, {}, {} } fc:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7]) return string.format('%.2f', t[1].Fuel)" }
function SetTank($dir, $v) { Send $dir "local im = FindFirstOf('BP_InventoryManager_C') local sl = im.Inventory_CarEquipped:GetSlot(FName('Car.Equip.Attachments.BackSeatLeft')) local fc = sl.Items[1]:GetActorManifestation():GetComponentByClass($FC) fc['Set Fuel'](fc, $v) return 'tank $v'" }
$Cap = "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local cap for _, g in ipairs(FindAllOf('BP_FuelableComponent_GasCap_C') or {}) do if g.CarActor:IsValid() and g.CarActor:GetAddress() == tw:GetAddress() then cap = g end end"
# a canister on the ground next to the player with $f in it (its component kept in GC_CAN)
function Can($dir, $f) { Send $dir "local Loot = CoopSync.Loot local p = FindFirstOf('PlayerController').Pawn local l = p:K2_GetActorLocation() local w = Loot.spawnWorldItem('W|/Game/Gameplay/Inventory/Items/Tools/FuelCan/IA_Tool_Target_FuelCan.IA_Tool_Target_FuelCan', { Translation = { X = l.X + 100, Y = l.Y, Z = l.Z }, Rotation = CoopSync.quat(0, 0, 0), Scale3D = { X = 1, Y = 1, Z = 1 } }) GC_CAN = w.BP_FuelableComponent GC_CAN['Set Fuel'](GC_CAN, $f) return 'canister $f'" }
# TransferFuel in steps of 0.5 until $amount moved (from = 'can' or 'cap'); the moved total
function Pour($dir, $from, $amount) { Send $dir "$Cap local src, dst = GC_CAN, cap if '$from' == 'cap' then src, dst = cap, GC_CAN end local moved = 0 for i = 1, 40 do if moved >= $amount - 0.001 then break end local o1, o2 = {}, {} src:TransferFuel(src, dst, 1.0, o1, o2) local n = tonumber(o1.Transferred) or 0 if n <= 0 then break end moved = moved + n end return string.format('%.2f', moved)" }
function CapState($dir) { Send $dir "$Cap local t = { {}, {}, {}, {}, {}, {}, {} } cap:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7]) local a = { {}, {}, {}, {}, {}, {} } cap:GetFuelableActions(a[1], a[2], a[3], a[4], a[5], a[6]) return string.format('%.2f %s', t[1].Fuel, tostring(a[3]['Can Be Siphoned']))" }

& "$t\collide-test.ps1" -SetupOnly | Select-String 'arrived|RUNTIME'
Start-Sleep 5
"  host: " + (SetTank $hd 10) + " | guest: " + (SetTank $cd 4)
Start-Sleep 5

"=== 1. the guest looks at the host's car's cap"
$cs = CapState $cd
$capFuel, $sip = $cs -split ' '
$h1 = Tank $hd; $g1 = Tank $cd
Check "the cap shows the host's fuel, not the guest's own; it can be siphoned" ([math]::Abs((& $num $capFuel) - (& $num $h1)) -lt 0.3 -and [math]::Abs((& $num $capFuel) - (& $num $g1)) -gt 3 -and $sip -eq 'true') "cap $capFuel siphon=$sip | host's tank $h1, guest's own $g1"

"=== 2. the guest pours 3 from a canister into the host's car"
"  guest: " + (Can $cd 8)
$g0 = Tank $cd; $h0 = Tank $hd
$moved = Pour $cd 'can' 3
Start-Sleep 5
$g2 = Tank $cd; $h2 = Tank $hd
"  moved $moved | host $h0 -> $h2 | guest's own $g0 -> $g2"
Check "the host's tank +3, the guest's own not" ((& $num $moved) -ge 2.9 -and [math]::Abs((& $num $h2) - (& $num $h0) - 3) -lt 0.4 -and [math]::Abs((& $num $g2) - (& $num $g0)) -lt 0.4) "moved $moved | host $h0 -> $h2 | guest's own $g0 -> $g2"

"=== 3. the guest siphons 2 from the host's car into the canister"
$g0 = Tank $cd; $h0 = Tank $hd
$moved = Pour $cd 'cap' 2
Start-Sleep 5
$g3 = Tank $cd; $h3 = Tank $hd
"  moved $moved | host $h0 -> $h3 | guest's own $g0 -> $g3"
Check "the host's tank -2, the guest's own not" ((& $num $moved) -ge 1.9 -and [math]::Abs((& $num $h0) - (& $num $h3) - 2) -lt 0.4 -and [math]::Abs((& $num $g3) - (& $num $g0)) -lt 0.4) "moved $moved | host $h0 -> $h3 | guest's own $g0 -> $g3"

"=== 4. the host pours 2 into the guest's car"
"  host: " + (Can $hd 8)
$g0 = Tank $cd; $h0 = Tank $hd
$moved = Pour $hd 'can' 2
Start-Sleep 5
$g4 = Tank $cd; $h4 = Tank $hd
"  moved $moved | guest $g0 -> $g4 | host's own $h0 -> $h4"
Check "the guest's tank +2, the host's own not" ((& $num $moved) -ge 1.9 -and [math]::Abs((& $num $g4) - (& $num $g0) - 2) -lt 0.4 -and [math]::Abs((& $num $h4) - (& $num $h0)) -lt 0.4) "moved $moved | guest $g0 -> $g4 | host's own $h0 -> $h4"

"  host: " + (Send $hd "return dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/gascap.lua').info()")
"  guest: " + (Send $cd "return dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/gascap.lua').info()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
