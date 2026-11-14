# Automated own-car mode test, step 1 (two headless instances over the relays): the guest joins with its own
# car; each side shows a copy of the other's car (spawned BP_PlayerCarNew_C, vehicle controller stopped,
# moved by the stream: host car on C lines, guest car on G lines). Copies are removed before any travel.
#   -Scenario guestLeaves: guest home first (the host's copy of its car goes after 5 s without G), then host home
#   -Scenario hostLeaves:  host home first (the guest stays in the zone with its own car: split), then guest home
param([switch]$Keep, [ValidateSet('guestLeaves', 'hostLeaves')] [string]$Scenario = 'guestLeaves', [switch]$Diag)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Cars($dir) { KV (Send $dir "return CoopPlayers.carsInfo()") }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist($a, $b) { if ($a -eq '-' -or $b -eq '-' -or -not $a -or -not $b) { return 1e9 }; $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
function Place($dir) { KV (Send $dir "$run return Run.where()") }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# drive a car: throttle 4 s, then brake + handbrake, left held (the car must stand still for the comparison;
# released, it rolled on downhill; and parked: a zone start runs the engine, left in drive the car crept away ~50 m
# after the loop let go - 2026-11-14). Time-based (headless runs
# at hundreds of fps); the loop cancels its own delayed action: UE4SS ignores the callback's return value, and a
# loop left running wrote into the car after its map was gone - the game crashed on the next travel.
function Shift($dir, [string]$carExpr) {
    Send $dir "local c = $carExpr local m = FindFirstOf('BP_CarManager_C') m.MyCarGearBox = 0 local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 10 then CancelDelayedAction(h) return end if dt > 4 then m.MyCarGearBox = 1 c.UserThrottleInput = 0 c.RawThrottle = 0 c.ThrottleTarget = 0 c.ThrottleCurrent = 0 c.UserBrakeInput = 1 c.BrakeTarget = 1 c.BrakeCurrent = 1 c.UserHandBrakeInput = 1 return end c.UserThrottleInput = 1 c.RawThrottle = 1 c.ThrottleTarget = 1 c.ThrottleCurrent = 1 c.UserBrakeInput = 0 c.BrakeTarget = 0 c.BrakeCurrent = 0 c.UserHandBrakeInput = 0 end) return 'driving'"
}
function CopiesMatch($label) {
    $h = Cars $hd; $c = Cars $cd
    $e1 = Dist $c.copy $h.own; $e2 = Dist $h.copy $c.own
    Check "$label guest's copy of the host's car on it (<= 30)" ($e1 -le 30) "host car $($h.own) | guest copy $($c.copy) | error $e1"
    Check "$label host's copy of the guest's car on it (<= 30)" ($e2 -le 30) "guest car $($c.own) | host copy $($h.copy) | error $e2"
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 1. the guest joins the host's zone with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived|host is at|matched on client'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
# both cars come in at the zone's entry: put the guest's car 8 m to the side of the host's
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)', { ownCar = true })")
Start-Sleep 15 # the car layouts come every 10 s
$h = Cars $hd; $c = Cars $cd
Check "host: its own car + a copy (twin) of the guest's car" ($h.cars -eq '1' -and $h.copy -ne '-' -and ($h.copy_kind -eq 'twin' -or [int]$h.ghost_meshes -ge 50)) $h.raw
Check "guest: its own car + a copy (twin) of the host's car" ($c.cars -eq '1' -and $c.copy -ne '-' -and ($c.copy_kind -eq 'twin' -or [int]$c.ghost_meshes -ge 50)) $c.raw
CopiesMatch "standing:"

"=== 2. the host drives its car"
"  host: " + (Shift $hd "CoopPlayers.ownCarActor()"); Start-Sleep 13
CopiesMatch "host car moved:"

"=== 3. the guest drives its own car"
"  guest: " + (Shift $cd "CoopPlayers.ownCarActor()"); Start-Sleep 13
CopiesMatch "guest car moved:"

if ($Scenario -eq 'guestLeaves') {
    "=== 4. the guest goes home (its car with it); the host's copy of it goes"
    if ($Diag) { "  guest pre-clean: " + (Send $cd "CoopSyncLeaveHooks.notify('garage') return CoopPlayers.carsInfo()"); Start-Sleep 3 }
    "  guest: " + (Send $cd "$run return Run.goHome(false, 0)"); Start-Sleep 25
    $g = Place $cd
    Check "guest is home in its garage (no crash with the copy)" ($g.state -eq '4' -and $g.world -eq 'RB_Garage') $g.raw
    Start-Sleep 5
    $h = Cars $hd
    Check "host: the guest's car copy is gone" ($h.cars -eq '1' -and $h.copy -eq '-' -and [int]$h.other_gone -ge 1) $h.raw
    "=== 5. the host goes home"
    "  host: " + (Send $hd "$run return Run.goHome(false, 0)"); Start-Sleep 25
    $w = Place $hd
    Check "host is home in its garage" ($w.state -eq '4' -and $w.world -eq 'RB_Garage') $w.raw
} else {
    "=== 4. the host goes home; the guest stays with its own car (split)"
    "  host: " + (Send $hd "$run return Run.goHome(false, 0)"); Start-Sleep 25
    $w = Place $hd
    Check "host is home in its garage (no crash with the copy)" ($w.state -eq '4' -and $w.world -eq 'RB_Garage') $w.raw
    $g = Place $cd; $c = Cars $cd
    Check "guest stays in the zone (split, not a failed run)" ($g.state -eq '5' -and $c.split -eq 'True') "$($g.raw) | $($c.raw)"
    Check "guest: the host's car copy is gone, its own car still there" ($c.cars -eq '1' -and $c.copy -eq '-' -and $c.own -ne '-') $c.raw
    "=== 5. the guest goes home"
    "  guest: " + (Send $cd "$run return Run.goHome(false, 0)"); Start-Sleep 25
    $g = Place $cd
    Check "guest is home in its garage" ($g.state -eq '4' -and $g.world -eq 'RB_Garage') $g.raw
}

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
