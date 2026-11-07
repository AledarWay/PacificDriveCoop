# Automated test of the moving hazards (anomaly sync): the side whose player is nearer runs a hazard, the other's
# copy follows its pose. Host in the owner's save zone, the guest joins with its own car, state + player sync on both.
# The hazard's own chase is scripted (a loop moving it toward a car, as its AI would): the supercharger mines of that
# save stand locked (bLockMovement) even in a single game (cmds/mine-chase.lua).
#   1. the guest's car next to a hazard far from the host: its copy moves -> the host grants it (HCLAIM / HGRANT), the
#      host's copy follows the guest's pose (HM)
#   2. the host's car comes nearer: the host takes it back (HREVOKE), moves it -> the guest's copy follows
#   3. the guest's car nearer again, the guest runs it, then it dies on the guest (HDEAD): gone on the host too
# -Real: the hazard's own AI instead (a physics grabber, which flies about a car near it: a save in a zone with
# grabbers, local\advsave\forest15.sav - Wilderness_Forest_15, made by zone-census.ps1): the guest's car by it, far
# from the host - the guest runs it, the host's copy follows the real flight.
param([switch]$Keep, [int]$GuestSeed = 777, [string]$HostSave = "C:\PacificDriveCoop\local\advsave\odsave9.sav", [int]$HostSlot = 9,
    [string]$Class = "BP_Hazard_MalfunctionMine_SuperCharger_C", [switch]$Real)
if ($Real) {
    if (-not $PSBoundParameters.ContainsKey('HostSave')) { $HostSave = "C:\PacificDriveCoop\local\advsave\forest15.sav" }
    if (-not $PSBoundParameters.ContainsKey('Class')) { $Class = "BP_Hazard_PhysicsGrabber_C" }
}
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Stat($r, $k) { if ($r -match "\b$k=(\d+)") { [int]$Matches[1] } else { 0 } }
function Pos($s) { if ($s -match '^(-?\d+),(-?\d+),(-?\d+)') { @([double]$Matches[1], [double]$Matches[2], [double]$Matches[3]) } }
function Dist($a, $b) { [Math]::Sqrt(($a[0] - $b[0]) * ($a[0] - $b[0]) + ($a[1] - $b[1]) * ($a[1] - $b[1]) + ($a[2] - $b[2]) * ($a[2] - $b[2])) }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. host in its run, the guest joins with its own car"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed -HostSave $HostSave -HostSlot $HostSlot
$log | Select-String 'arrived|matched on client'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)', '$(P $hd)/spawnlist.tsv') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 12

# a mapped hazard of that class on the guest
$pick = Send $cd @"
for key, path in pairs(CoopSyncMap or {}) do
    local a = CoopSync.deref(path)
    if a and CoopSync.clsName(a) == '$Class' and not CoopSync.inPool(a) then
        local l = a:K2_GetActorLocation()
        return string.format('key=%s at=%.0f,%.0f,%.0f', key, l.X, l.Y, l.Z)
    end
end
return 'none'
"@
"  picked: $pick"
$m = KV $pick
Check "a mapped $Class to test with" ([bool]$m.key) $pick
if (-not $m.key) { return }
$key = $m.key
$x, $y, $z = $m.at -split ','
# Lua: that hazard on this side (the host by its key, the guest by its map)
$get = "local a = CoopSync.deref(CoopSyncMap and CoopSyncMap['$key'] or '$key') if a and CoopSync.inPool(a) then a = nil end"
$at = "$get if not a then return 'gone' end local l = a:K2_GetActorLocation() return string.format('%.0f,%.0f,%.0f', l.X, l.Y, l.Z)"
# a car (with its driver) put $1 units west of the hazard's spot
function CarTo($dir, [int]$back, [int]$dy = 0) {
    Send $dir "$get local l = a and a:K2_GetActorLocation() or { X = $x, Y = $y, Z = $z } local car = FindFirstOf('BP_CarManager_C').NewCarActor car:K2_SetActorLocationAndRotation({ X = l.X - $back, Y = l.Y + $dy, Z = l.Z + 150 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) return 'car moved'"
}
# the hazard's own chase, scripted: toward this side's car at 300 u/s, stopping 10 m short (a real one reaching the car goes off) for $sec seconds (its AI would move it so)
function Chase($dir, [int]$sec) {
    Send $dir "$get if not a then return 'no hazard' end local car = FindFirstOf('BP_CarManager_C').NewCarActor local n = 0 local h h = LoopInGameThreadWithDelay(50, function() n = n + 1 if n > $($sec * 20) or not a:IsValid() then CancelDelayedAction(h) return end local l, c = a:K2_GetActorLocation(), car:K2_GetActorLocation() local dx, dy = c.X - l.X, c.Y - l.Y local d = math.sqrt(dx * dx + dy * dy) if d < 1000 then return end a:K2_SetActorLocation({ X = l.X + dx / d * 15, Y = l.Y + dy / d * 15, Z = l.Z }, false, {}, true) end) return 'chasing'"
}
function Watch([int]$n) {
    $r = @()
    for ($i = 0; $i -lt $n; $i++) {
        $hs = Send $hd $at; $gs = Send $cd $at
        "    host: $hs | guest: $gs" | Out-Host
        $r += , @($hs, $gs)
        Start-Sleep -Milliseconds 500
    }
    , $r
}

function Finish {
    $hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
    "  host state: $hr"
    "  guest state: $cr"
    Check "no errors" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') ""
    "=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
    if (-not $Keep) {
        Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
        Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
    }
}

if ($Real) {
    "=== R. the guest's car by a $Class far from the host: its own AI"
    "  guest: " + (CarTo $cd 1500)
    $h0 = Pos (Send $hd $at)
    $gaps = @(); $hostPath = 0; $hPrev = $h0; $gone = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 400
        $hs = Send $hd $at; $gs = Send $cd $at
        "    host: $hs | guest: $gs"
        $hp = Pos $hs; $gp = Pos $gs
        if ($hs -eq 'gone' -or $gs -eq 'gone') { $gone = $true }
        if ($hp -and $hPrev) { $hostPath += Dist $hp $hPrev }
        if ($hp) { $hPrev = $hp }
        if ($hp -and $gp -and $i -ge 4) { $gaps += [int](Dist $hp $gp) }
    }
    $hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
    $sorted = $gaps | Sort-Object
    $med = if ($sorted.Count) { $sorted[[int]($sorted.Count / 2)] } else { -1 }
    $max = if ($sorted.Count) { $sorted[-1] } else { -1 }
    Check "the host gave it to the guest (the nearer player)" ((Stat $hr 'hz_grant') -ge 1 -and (Stat $cr 'hz_granted') -ge 1) "host hz_grant=$(Stat $hr 'hz_grant') deny=$(Stat $hr 'hz_deny') | guest hz_claim=$(Stat $cr 'hz_claim') granted=$(Stat $cr 'hz_granted')"
    Check "the host's copy flew the guest's flight" ($hostPath -gt 1500) "host copy path $([int]$hostPath) over 12 s"
    Check "the copies stay together while it flies" ($sorted.Count -gt 10 -and $med -lt 250 -and $max -lt 700) "gap median $med max $max over $($sorted.Count) samples (gone: $gone)"
    Finish
    return
}

"=== 1. the guest's car by the hazard, the hazard goes for it"
"  guest: " + (CarTo $cd 2500)
Start-Sleep 2
$h0 = Pos (Send $hd $at)
"  guest: " + (Chase $cd 5)
$w = Watch 12
# (settled first: the last watch sample can catch it still moving - one run read a 200 gap there, a pose's lag)
Start-Sleep 2; $hEnd = Pos (Send $hd $at); $gEnd = Pos (Send $cd $at)
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "the host gave it to the guest (the nearer player)" ((Stat $hr 'hz_grant') -ge 1 -and (Stat $cr 'hz_granted') -ge 1) "host hz_grant=$(Stat $hr 'hz_grant') deny=$(Stat $hr 'hz_deny') | guest hz_claim=$(Stat $cr 'hz_claim') granted=$(Stat $cr 'hz_granted')"
Check "the host's copy followed the guest's" ($h0 -and $hEnd -and (Dist $h0 $hEnd) -gt 800) "host copy moved $(if ($h0 -and $hEnd) { [int](Dist $h0 $hEnd) })"
Check "both copies in the same place after" ($hEnd -and $gEnd -and (Dist $hEnd $gEnd) -lt 150) "gap $(if ($hEnd -and $gEnd) { [int](Dist $hEnd $gEnd) })"

"=== 2. the host's car comes nearer: the host takes it back and moves it"
"  guest: " + (CarTo $cd 3000 1500)
"  host: " + (CarTo $hd 2500)
Start-Sleep 4
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "the host took it back" ((Stat $hr 'hz_revoke') -ge 1 -and (Stat $cr 'hz_revoked') -ge 1) "host hz_revoke=$(Stat $hr 'hz_revoke') | guest hz_revoked=$(Stat $cr 'hz_revoked')"
$g0 = Pos (Send $cd $at)
"  host: " + (Chase $hd 4)
$w = Watch 10
# (settled first: the last watch sample can catch it still moving - one run read a 200 gap there, a pose's lag)
Start-Sleep 2; $hEnd = Pos (Send $hd $at); $gEnd = Pos (Send $cd $at)
Check "the guest's copy followed the host's" ($g0 -and $gEnd -and (Dist $g0 $gEnd) -gt 600) "guest copy moved $(if ($g0 -and $gEnd) { [int](Dist $g0 $gEnd) })"
Check "both copies in the same place after" ($hEnd -and $gEnd -and (Dist $hEnd $gEnd) -lt 150) "gap $(if ($hEnd -and $gEnd) { [int](Dist $hEnd $gEnd) })"

"=== 3. the guest runs it again, it dies on the guest's side"
"  host: " + (CarTo $hd 4000 2000)
"  guest: " + (CarTo $cd 2200)
Start-Sleep 3
"  guest: " + (Chase $cd 3)
Start-Sleep 5
$cr = Send $cd "return CoopSyncState.report()"
"  guest granted: $(Stat $cr 'hz_granted') | this one: $(Send $cd "return CoopSyncState.hzInfo('$key')")"
"  guest: " + (Send $cd "$get if not a then return 'no hazard' end a:K2_DestroyActor() return 'destroyed'")
Start-Sleep 6
$hs = Send $hd $at; $gs = Send $cd $at
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "gone on the host too (HDEAD), not put back on the guest" ($hs -eq 'gone' -and $gs -eq 'gone' -and (Stat $hr 'hz_dead_in') -ge 1) "host: $hs guest: $gs | host hz_dead_in=$(Stat $hr 'hz_dead_in') | guest hz_died=$(Stat $cr 'hz_died') hazard_respawned=$(Stat $cr 'hazard_respawned')"

"  host state: $hr"
"  guest state: $cr"
Check "no errors" ($hr -notmatch 'ERRORS' -and $cr -notmatch 'ERRORS') ""
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
