# The own car's back seat in the garage lobby (owner's alpha 21 test): "on my own car's back seat I had all the driver's
# controls, and only the driver's door to get out by; after that, getting in at the wheel put me on that back seat again"
# (the host) and "the friend could not get onto his own back seat in the garage, the door just opened" (the guest).
# One headless game from the advanced save sent home, the player sync started in garage mode as each role in turn:
#   in by the back left door -> on seat 3; the key / lever / driver's door out of reach; the exit outlines the back
#   door; out again; in at the wheel -> the driver's seat (the seat socket back), the controls there.
param([switch]$Keep, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
$carE = Get-Content "$t\cmds\car-e.lua" -Raw
function E([string]$pre) { Send $hd "$pre $carE" }
$att = "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a and a:IsValid() and a:GetAddress() == CoopPlayers.twinModule().ownCar():GetAddress())"
$sock = "local car = CoopPlayers.twinModule().ownCar() local r = car.TempSocket_Seat.RelativeLocation return string.format('%.0f,%.0f', r.X, r.Y)"

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the advanced save, home to the garage"
& "$t\start-save.ps1" -Tag host -Save $Save -Slot 9 | Select-Object -Last 1
"  " + (Send $hd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1
Start-Sleep 5
$chan = "$inst\host\chan-gs$(Get-Date -f HHmmss)"
New-Item -ItemType Directory -Force "$chan\inbox", "$chan\outbox" | Out-Null
$home0 = Send $hd "local c = CoopPlayers and CoopPlayers.twinModule and CoopPlayers.twinModule().ownCar() or FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y)"

foreach ($role in 'host', 'client') {
    "=== $role in the garage lobby"
    "  start: " + (Send $hd "$lib return CoopPlayers.start(CoopSync, '$role', '$($chan.Replace('\', '/'))', { garage = true })")
    Start-Sleep 3
    if ((Send $hd $att) -match 'true') { "  out: " + (E "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 5 }
    # (a back seat with no device on it - the friend's car had none there: the advanced save's car has a fuel tank on
    # each, the right one taken off for the test)
    if ($role -eq 'host') { "  free the back right seat: " + (Send $hd "local sl = CoopPlayers.twinModule().ownCar().SLOT_BackSeatRight.ItemSlot local n = sl.Items:GetArrayNum() if n > 0 then sl:RemoveItem(sl.Items[1]) end return n .. ' -> ' .. sl.Items:GetArrayNum()") }
    $dev3 = Send $hd "return CoopPlayers.ownSeatDevice(3)"; $dev4 = Send $hd "return CoopPlayers.ownSeatDevice(4)"
    $bn = if ($dev3 -eq 'nil') { 3 } else { 4 }
    "  devices: 3=$dev3 4=$dev4 -> door $bn"
    "  to back door $($bn): " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local car = CoopPlayers.twinModule().ownCar() local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local w = KML:TransformLocation(car:GetTransform(), { X = 0, Y = $(if ($bn -eq 3) { -260 } else { 260 }), Z = 0 }) p:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 100 }, false, {}, true) return 'there'")
    Start-Sleep 2
    "  E at door $($bn): " + (E "CE_CAR = 'own' CE_HL = 'door$bn'")
    Start-Sleep 6
    "  door $($bn): " + (Send $hd "return CoopPlayers.doorInfo($bn)")
    $a = Send $hd $att; $n = Send $hd "return CoopPlayers.seatNowN()"
    Check "$($role): in by the back door, on the back seat" ($a -match 'true' -and $n -eq "$bn") "attached: $a seat: $n socket $(Send $hd $sock)"
    $r = @(); foreach ($h in 'Highlight_Key', 'Highlight_Gearbox', 'Highlight_EnterDoor', 'Highlight_ExitDoor') { $r += "$h=" + (Send $hd "return CoopPlayers.mayReachOwn('$h')") }
    Check "$($role): from the back seat no key / lever / driver's door, its exit yes" (($r -join ' ') -match 'Highlight_Key=false' -and ($r -join ' ') -match 'Highlight_ExitDoor=true' -and ($r -join ' ') -notmatch 'Gearbox=true') ($r -join ' ')
    $xh = Send $hd (Get-Content "$t\cmds\exit-highlight.lua" -Raw)
    Check "$($role): the exit outlines the back door, not the driver's" ($xh -match 'Door_Base') $xh
    # (which door opens on the way out - owner's two-games test 2026-11-11: the driver's door opened, the player went
    # through the back door; only "out" was checked here)
    "  watch: " + (Send $hd "EW_S = 7 return dofile('$($t.Replace('\', '/'))/cmds/exit-watch.lua')")
    "  out: " + (E "CE_CAR = 'own' CE_HL = 'ExitDoor'"); Start-Sleep 8
    $w = Send $hd "return EW_READ()"
    "  exit: $w"
    $op = if ($w -match 'opened=(\S+)') { $Matches[1] } else { '?' }
    Check "$($role): out by its back door: that door opened, the driver's did not" ($op -match "$bn" -and $op -notmatch '1') "opened $op"
    $ey = if ($w -match 'end=-?\d+,(-?\d+)') { [double]$Matches[1] } else { 0 }
    Check "$($role): it stands on that door's side of the car" ($(if ($bn -eq 3) { $ey -lt -80 } else { $ey -gt 80 })) "end y $ey (door $bn)"
    $a = Send $hd $att; $s = Send $hd $sock
    Check "$($role): out again, the seat socket back at the wheel" ($a -match 'false') "attached: $a socket $s"
    "  in at the wheel: " + (E "CE_CAR = 'own' CE_HL = 'EnterDoor'"); Start-Sleep 7
    $a = Send $hd $att; $n = Send $hd "return CoopPlayers.seatNowN()"; $k = Send $hd "return CoopPlayers.mayReachOwn('Highlight_Key')"
    $rel = Send $hd "local p = FindFirstOf('PlayerController').Pawn local r = p.RootComponent.RelativeLocation return string.format('%.0f,%.0f', r.X, r.Y)"
    Check "$($role): in at the wheel it is the driver's seat (not the back seat again), the key in reach" ($a -match 'true' -and $n -eq '1' -and $k -eq 'true') "attached: $a seat: $n key: $k at $rel socket $(Send $hd $sock)"
    "  stop: " + (Send $hd "CoopPlayers.stop() return 'stopped'")
    Start-Sleep 2
}

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
