# Automated "range-started hazards and tourists" test (owner, alpha 18 item 23: "the saw lags on the guest", "the geyser
# fires later on the guest", "the mannequin is in other poses, it does not sway on a kick"). Host: local\advsave\swamp14.sav
# (Wilderness_Swamp_14 with saw blades and tourists, made by zone-census.ps1 + cmds/save-probe.lua 'save'); guest joins.
#   1. every mapped tourist's body has the host's pose on the guest (mesh, yaw)
#   2. the guest's car by a saw far from the host: the host's copy starts too (the host runs it by the nearer player)
#      and both copies run in step (the same timeline, the same direction, within half a second)
#   3. the guest's car far again: both copies stop
#   4. a tourist's body set swaying on one side sways the other side's copy (both ways)
param([switch]$Keep, [int]$GuestSeed = 777, [string]$HostSave = "C:\PacificDriveCoop\local\advsave\swamp14.sav", [int]$HostSlot = 9)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h }
function Stat($report, $name) { if ($report -match "\b$name=(\d+)") { [int]$Matches[1] } else { 0 } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. host in its run (Wilderness_Swamp_14 save), the guest joins with its own car"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed -HostSave $HostSave -HostSlot $HostSlot
$log | Select-String 'arrived|matched on client'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)', '$(P $hd)/spawnlist.tsv') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
$hostRun = "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') local pc = FindFirstOf('PlayerController') return string.format('paused=%s t=%.1f', tostring(GS:IsGamePaused(pc)), GS:GetTimeSeconds(FindFirstOf('World')))"
"  host after the starts: " + (Send $hd $hostRun)
Start-Sleep 20
"  host 20 s later: " + (Send $hd $hostRun)

# the north (owner, alpha 19 item 9: the ARC map's compass points differed): Wilderness zones pick a random one. This
# save's load leaves the host's pick unapplied (a fresh zone applies it): RandomizeNorth applies it here; the guest
# follows through the weather lines (weathersync)
$north = "local m = FindFirstOf('BP_ToDManager_C') return string.format('%d/%.1f/%.1f', m.DataBlock_IsUsingRandomNorth and 1 or 0, m.DataBlock_PickedRandomNorth.Yaw, m['Current North As Rotator'].Yaw)"
"  north before: host " + (Send $hd $north) + " | guest " + (Send $cd $north)
"  host: " + (Send $hd "local m = FindFirstOf('BP_ToDManager_C') m:RandomizeNorth(true) CoopDevW = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/weathersync.lua') return CoopDevW.start(CoopPlayers, 'host')")
"  guest: " + (Send $cd "CoopDevW = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/weathersync.lua') return CoopDevW.start(CoopPlayers, 'client')")
Start-Sleep 8
$nh = Send $hd $north; $ng = Send $cd $north
Check "the guest's north is the host's (item 9)" ($nh -match '^1/' -and $nh -eq $ng) "host $nh | guest $ng | guest $(Send $cd 'return CoopDevW.info()' | Select-String -Pattern 'north=\d+' | ForEach-Object { $_.Matches[0].Value })"

# the gameplay events (owner, alpha 19 items 10 / 15: anomaly clouds at different places, the guest's own radiation
# event): this save's host is in a GEV_WindSquall with its cloud; the guest runs the host's events only (statesync GE)
$ev = "local o = {} for name, e in pairs(CoopSyncEvent.live()) do local a = e.LocationEventActor local s = e:GetClass():GetFName():ToString() if a and a:IsValid() then local l = a:K2_GetActorLocation() s = s .. string.format('@%.0f,%.0f', l.X, l.Y) end o[#o + 1] = s end table.sort(o) return table.concat(o, ' ')"
$eh = Send $hd $ev; $eg = Send $cd $ev
function EvNames($s) { (($s -split ' ') | ForEach-Object { ($_ -split '@')[0] }) -join ' ' }
function EvAt($s) { $m = [regex]::Match($s, '@(-?\d+),(-?\d+)'); if ($m.Success) { @([double]$m.Groups[1].Value, [double]$m.Groups[2].Value) } else { $null } }
$ph = EvAt $eh; $pg = EvAt $eg
$near = $ph -and $pg -and [math]::Sqrt(($ph[0] - $pg[0]) * ($ph[0] - $pg[0]) + ($ph[1] - $pg[1]) * ($ph[1] - $pg[1])) -lt 1500
$cr = Send $cd "return CoopSyncState.report()"
# (the guest copies the host's main event - the one with a cloud: a second one started would end the first; a
# GEV_HeavyFog alongside has no cloud, its fog comes with the weather lines)
$extra = @(($eg -split ' ') | ForEach-Object { ($_ -split '@')[0] } | Where-Object { $_ -and (" $(EvNames $eh) " -notmatch " $_ ") })
Check "the guest's gameplay events are the host's, the cloud where the host's is (items 10 / 15)" ($eh -match 'GEV_\w+@' -and $extra.Count -eq 0 -and $near) "host: $eh | guest: $eg | guest ap_GE=$(Stat $cr 'ap_GE') moved=$(Stat $cr 'ap_GE_moved') ended=$(Stat $cr 'ap_GE_ended')"

# stray hazards (owner, alpha 19 item 11: a pillar anomaly on the guest the host has not): a bollard spawned by the
# guest's game after the import goes within STRAY.EVERY_S + GRACE_S; the hazards (BP_Hazard*) in the level are the same
$hzN = "local c = {} for _, a in ipairs(FindAllOf('BP_Base_Hazard_C') or {}) do local l = a:K2_GetActorLocation() if a:GetFullName():find(':PersistentLevel.', 1, true) and not (math.abs(l.X) < 1 and math.abs(l.Y) < 1) then local n = a:GetClass():GetFName():ToString() if n:find('^BP_Hazard') then c[n] = (c[n] or 0) + 1 end end end local o = {} for n, k in pairs(c) do o[#o + 1] = n .. '=' .. k end table.sort(o) return table.concat(o, ' ')"
function HzSum($s) { $n = 0; foreach ($kv in ($s -split ' ')) { if ($kv -match '=(\d+)$') { $n += [int]$Matches[1] } }; $n }
function HzDiff($a, $b) { $ha = KV $a; $hb = KV $b; (@($ha.Keys) + @($hb.Keys) | Where-Object { $_ -ne 'raw' } | Sort-Object -Unique | Where-Object { $ha[$_] -ne $hb[$_] } | ForEach-Object { "$_ $($ha[$_])/$($hb[$_])" }) -join ', ' }
$h0 = Send $hd $hzN; $g0 = Send $cd $hzN
$plant = "local b = FindFirstOf('BP_Hazard_Bollard_C') local p = FindFirstOf('PlayerController').Pawn:K2_GetActorLocation() local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') local tf = { Translation = { X = p.X + 600, Y = p.Y, Z = p.Z }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } } local a = GS:BeginDeferredActorSpawnFromClass(b:GetWorld(), b:GetClass(), tf, 1, nil) GS:FinishSpawningActor(a, tf) CoopDevStray = a:GetFullName() return 'planted'"
$alive = "local a = StaticFindObject((CoopDevStray or ''):gsub('^%S+ ', '')) if not (a and a:IsValid()) then return 'gone' end local l = a:K2_GetActorLocation() return (math.abs(l.X) < 1 and math.abs(l.Y) < 1) and 'parked' or 'standing'"
"  guest: " + (Send $cd $plant); Start-Sleep 16
$st = Send $cd $alive; $h1 = Send $hd $hzN; $g1 = Send $cd $hzN; $cr = Send $cd "return CoopSyncState.report()"
$nh = HzSum $h1; $ng = HzSum $g1
# (the guest's unmapped hazards in the level: where, pooled, a root - a run had 3 bollards more than the host, quick
# suite 2026-11-10)
if ($nh -ne $ng) {
    "  guest's unmapped: " + (Send $cd "local mapped = {} for _, p in pairs(CoopSyncMap or {}) do mapped[p] = true end local o = {} for _, a in ipairs(FindAllOf('BP_Base_Hazard_C') or {}) do local p = a:GetFullName():gsub('^%S+ ', '') if p:find(':PersistentLevel.', 1, true) and not mapped[p] then local l = a:K2_GetActorLocation() if not (math.abs(l.X) < 1 and math.abs(l.Y) < 1) then o[#o + 1] = string.format('%s@%.0f,%.0f pool=%s root=%s', a:GetFName():ToString(), l.X, l.Y, tostring(CoopSync.inPool(a)), tostring(CoopSync.isRoot(a))) end end end return #o .. ': ' .. table.concat(o, ' ')")
}
Check "a hazard only the guest's game spawned goes, the hazards are the host's (item 11)" ($st -ne 'standing' -and $nh -eq $ng -and (Stat $cr 'stray_hazard') -ge 1) "planted bollard: $st; hazards host $nh / guest $ng (before: $(HzSum $h0) / $(HzSum $g0); host/guest differ: $(HzDiff $h1 $g1)); guest stray_hazard=$(Stat $cr 'stray_hazard')"

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

"=== 1. the tourists' poses"
$poses = "local o = {} for _, a in ipairs(FindAllOf('BP_Hazard_Landmine_C') or {}) do if a:IsValid() then local key = CoopSync.ref(a) if CoopSyncMap then key = nil for k, p in pairs(CoopSyncMap) do if p == CoopSync.ref(a) then key = k break end end end if key then local b = a.Body local r = b:K2_GetComponentRotation() o[#o + 1] = key .. '|' .. b.StaticMesh:GetFName():ToString() .. '|' .. string.format('%.0f', r.Yaw) end end end return table.concat(o, ' ')"
# (the guest takes its event lines a few per frame: the poses can take a while after the start)
for ($try = 0; $try -lt 7; $try++) {
    $hp = @{}; foreach ($x in ((Send $hd $poses) -split ' ')) { $k, $m, $y = $x -split '\|'; if ($k) { $hp[$k] = @($m, [double]$y) } }
    $gp = @{}; foreach ($x in ((Send $cd $poses) -split ' ')) { $k, $m, $y = $x -split '\|'; if ($k) { $gp[$k] = @($m, [double]$y) } }
    $same = 0; $diff = @()
    foreach ($k in $gp.Keys) {
        if (-not $hp.ContainsKey($k)) { continue }
        $dy = [math]::Abs((($gp[$k][1] - $hp[$k][1]) % 360 + 540) % 360 - 180)
        if ($gp[$k][0] -eq $hp[$k][0] -and $dy -lt 3) { $same++ } else { $diff += "$($hp[$k][0])/$($hp[$k][1]) vs $($gp[$k][0])/$($gp[$k][1])" }
    }
    if ($same -ge 0.9 * ($same + $diff.Count)) { break }
    Start-Sleep 10
}
$both = $same + $diff.Count
# (a tourist creeping toward a player's camera turns on that side alone - the next pose line puts it back: a few
# differ at any time)
Check "the mapped tourists have the host's pose on the guest (90 %+)" ($both -ge 10 -and $same -ge 0.9 * $both) "same $same of $both (host $($hp.Count), guest mapped $($gp.Count)) $($diff | Select-Object -First 3)"

$hp0 = Send $hd $hostRun
"  host after the poses: $hp0"
# (3 of 4 runs on 2026-11-02 found the headless host's world paused by its own pause menu - PDP_PauseMenu_Main_C,
# UMG_PlayerMenu_Main_C in the viewport, the pauser its own player state - from about the sync's start on: the saw and
# the sway stood still there. Cause not found (no window, no key; NOTES); not this test's matter - the menu closed)
if ($hp0 -match 'paused=true') { "  host was paused by its pause menu - closed: " + (Send $hd "FindFirstOf('PDP_Game_Hud_C'):SetPauseMenuWidgetVisible(false) StaticFindObject('/Script/Engine.Default__GameplayStatics'):SetGamePaused(FindFirstOf('PlayerController'), false) return 'closed'"); Start-Sleep 3; "  host now: " + (Send $hd $hostRun) }
"=== 2. the guest by a saw far from the host: both copies run, in step"
# a mapped saw at least 25000 from both players
$pick = Send $cd @"
local function at(a) return a:K2_GetActorLocation() end
local me = at(FindFirstOf('BP_CarManager_C').NewCarActor)
local best, bk, bd
for key, path in pairs(CoopSyncMap or {}) do
    local a = CoopSync.deref(path)
    if a and CoopSync.clsName(a) == 'BP_Hazard_SawBlade_C' then
        local l = at(a) local d = math.sqrt((l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2)
        if d > 25000 and (not bd or d < bd) then best, bk, bd = a, key, d end
    end
end
if not best then return 'none' end
local l = at(best)
return string.format('key=%s at=%.0f,%.0f,%.0f d=%.0f', bk, l.X, l.Y, l.Z, bd)
"@
"  picked: $pick"
$m = KV $pick
Check "a mapped saw far from both players" ([bool]$m.key) $pick
if (-not $m.key) { Finish; return }
$key = $m.key
$get = "local a = CoopSync.deref(CoopSyncMap and CoopSyncMap['$key'] or '$key')"
# where this side's copy is in its run: <direction> <timeline> <seconds into it> (pre = the rise, move = the run, idle)
$sawT = "$get local s = 'idle' local p = 0 if a.PreMoveTimeline:IsPlaying() then s = 'pre' p = a.PreMoveTimeline:GetPlaybackPosition() elseif a.MovingTimeline:IsPlaying() then s = 'move' p = a.MovingTimeline:GetPlaybackPosition() / a.DataBlock_TimelinePlayRate end return string.format('%s %s %.2f t=%.1f', tostring(a.Direction), s, p, FindFirstOf('GameStateBase'):GetServerWorldTimeSeconds())"
$hostState0 = Send $hd $sawT
"  host copy before: $hostState0"
"  guest: " + (Send $cd "$get local l = a:K2_GetActorLocation() local car = FindFirstOf('BP_CarManager_C').NewCarActor car:K2_SetActorLocationAndRotation({ X = l.X - 8000, Y = l.Y, Z = l.Z + 300 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) car.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) return 'car by the saw'")
Start-Sleep 4
$ran = 0; $inStep = 0; $samples = @()
for ($i = 0; $i -lt 14; $i++) {
    $h1 = Send $hd $sawT; $g = Send $cd $sawT; $h2 = Send $hd $sawT
    "    host $h1 / $h2 | guest $g"
    $a1 = $h1 -split ' '; $a2 = $h2 -split ' '; $b = $g -split ' '
    if ($i -eq 0) { $hT0 = $a1[3] }; $hT1 = $a2[3]
    if ($a1[1] -ne 'idle') { $ran++ }
    # the guest read between the host's two: in step when it is on the same timeline in the same direction as
    # either host read, within half a second of the host's time then
    $ok = ($b[0] -eq $a1[0] -and $b[1] -eq $a1[1] -and $b[1] -ne 'idle' -and [math]::Abs([double]$b[2] - ([double]$a1[2] + $(if ($a2[1] -eq $a1[1]) { [double]$a2[2] } else { [double]$a1[2] })) / 2) -lt 0.5) -or
           ($b[0] -eq $a2[0] -and $b[1] -eq $a2[1] -and $b[1] -ne 'idle' -and [math]::Abs([double]$b[2] - [double]$a2[2]) -lt 0.5) -or
           ($b[1] -eq 'idle' -and ($a1[1] -eq 'idle' -or $a2[1] -eq 'idle'))
    if ($ok) { $inStep++ }
    Start-Sleep -Milliseconds 300
}
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "the host's copy runs for the guest (the host far)" ($ran -ge 6 -and (Stat $hr 'range_in') -ge 1) "host running in $ran of 14 samples; host range_in=$(Stat $hr 'range_in') range_taken=$(Stat $hr 'range_taken') | guest ap_RG=$(Stat $cr 'ap_RG') range_taken=$(Stat $cr 'range_taken')"
# (the host's world time over the samples: a stopped clock = the host's game paused)
Check "both copies run in step (the same timeline and direction, within 0.5 s)" ($inStep -ge 11) "$inStep of 14 samples in step; host world time $hT0 -> $hT1"

"=== 3. the guest far from it again: both stop"
"  guest: " + (Send $cd "$get local l = a:K2_GetActorLocation() local car = FindFirstOf('BP_CarManager_C').NewCarActor car:K2_SetActorLocationAndRotation({ X = l.X - 30000, Y = l.Y, Z = l.Z + 300 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) return 'car away'")
Start-Sleep 14 # (a run under way ends first)
$h = Send $hd $sawT; $g = Send $cd $sawT
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "both copies stopped" (($h -split ' ')[1] -eq 'idle' -and ($g -split ' ')[1] -eq 'idle' -and (Stat $hr 'range_out') -ge 1) "host $h | guest $g | host range_out=$(Stat $hr 'range_out') guest ap_RG=$(Stat $cr 'ap_RG')"

"=== 4. a tourist set swaying on one side sways on the other"
# a mapped tourist by this side's car (the car put 2000 from it: nearer, it set tourists off), its body pushed at the tip as a kick would; the other side's
# copy: its body's tilt from its rest pose over the next 1.5 s. (Its tilt fuse held off for 7 s: something re-armed it
# mid-sway - armed for 1 s of it, 2026-11-10 - and a run's pushed mine went off instead, req_TS=0)
$near = @"
local far = FAR_FROM and CoopSync.deref(CoopSyncMap[FAR_FROM])
local fl = far and far:K2_GetActorLocation()
for key, path in pairs(CoopSyncMap or {}) do
    local a = CoopSync.deref(path)
    if a and CoopSync.clsName(a) == 'BP_Hazard_Landmine_C' and not CoopSync.inPool(a) and key ~= FAR_FROM then
        local l = a:K2_GetActorLocation()
        local alone = true -- (one in a heap set its neighbours off)
        for _, b in ipairs(FindAllOf('BP_Hazard_Landmine_C') or {}) do
            if b ~= a and b:IsValid() then local m = b:K2_GetActorLocation() if (l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2 < 800 ^ 2 then alone = false break end end
        end
        if alone and (not fl or (l.X - fl.X) ^ 2 + (l.Y - fl.Y) ^ 2 > 15000 ^ 2) then return key end
    end
end
return 'none'
"@
function Spin($dir, $k) {
    Send $dir "local a = CoopSync.deref(CoopSyncMap and CoopSyncMap['$k'] or '$k') local l = a:K2_GetActorLocation() local car = FindFirstOf('BP_CarManager_C').NewCarActor car:K2_SetActorLocationAndRotation({ X = l.X - 2000, Y = l.Y, Z = l.Z + 300 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) car.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName('None')) local T = CoopSyncTour or {} local function fuseOff() a.PreventExplodeOnAngle = true if T.fuse then T.fuse[a] = nil end end fuseOff() local fn = 0 local fh fh = LoopInGameThreadWithDelay(100, function() fn = fn + 1 if fn > 70 or not a:IsValid() then CancelDelayedAction(fh) return end pcall(fuseOff) end) Dev.after(1500, function() fuseOff() SW_INLIST = 'no' for _, x in ipairs(T.list or {}) do if x == a then SW_INLIST = 'yes' end end SW_INNEAR = 'no' for _, x in ipairs(T.near or {}) do if x == a then SW_INNEAR = 'yes' end end local b = a.Body b:AddImpulseAtLocation({ X = 300 * b:GetMass(), Y = 0, Z = 0 }, a.TipScene:K2_GetComponentLocation(), FName('None')) end) return 'pushed'"
}
$tilt = "local a = CoopSync.deref(CoopSyncMap and CoopSyncMap['KEY'] or 'KEY') local r0 = a.Body:K2_GetComponentRotation() SW_MAX = 0 SW_W = 0 SW_ARMED = 0 SW_GONE = nil local n = 0 local h h = LoopInGameThreadWithDelay(50, function() n = n + 1 if n > 120 or not a:IsValid() then if not a:IsValid() then SW_GONE = n * 50 end CancelDelayedAction(h) return end local r = a.Body:K2_GetComponentRotation() SW_MAX = math.max(SW_MAX, math.abs(r.Pitch - r0.Pitch) + math.abs(r.Roll - r0.Roll)) pcall(function() local w = a.Body:GetPhysicsAngularVelocityInDegrees(FName('None')) SW_W = math.max(SW_W or 0, math.sqrt(w.X ^ 2 + w.Y ^ 2 + w.Z ^ 2)) end) pcall(function() if not a.PreventExplodeOnAngle then SW_ARMED = (SW_ARMED or 0) + 1 end end) end) return 'watching'"
$k1 = Send $cd "FAR_FROM = nil $near"
"  host spins $k1`: " + (Spin $hd $k1) + " | guest " + (Send $cd $tilt.Replace('KEY', $k1))
Start-Sleep 7
$gMax = Send $cd "return string.format('%.1f', SW_MAX or -1)"
$cr = Send $cd "return CoopSyncState.report()"
Check "the host's sway reached the guest's copy" ([double]$gMax -gt 3 -and (Stat $cr 'ap_TS') -ge 1) "guest body tilted $gMax deg; guest ap_TS=$(Stat $cr 'ap_TS') TS_already=$(Stat $cr 'ap_TS_already')"
$k2 = Send $cd "FAR_FROM = '$k1' $near"
"  guest spins $k2`: " + (Spin $cd $k2) + " | host " + (Send $hd $tilt.Replace('KEY', $k2)) + " | guest " + (Send $cd $tilt.Replace('KEY', $k2).Replace('SW_MAX', 'SW2_MAX'))
Start-Sleep 7
$hMax = Send $hd "return string.format('%.1f', SW_MAX or -1)"
$hr = Send $hd "return CoopSyncState.report()"
# (the guest's own: did its mine sway, did it send - a miss had req_TS=0 on the host, quick suite 2026-11-10)
$g2 = Send $cd "local a = CoopSync.deref(CoopSyncMap['$k2']) local l = a and a:K2_GetActorLocation() local p = FindFirstOf('PlayerController').Pawn:K2_GetActorLocation() local car = FindFirstOf('BP_CarManager_C').NewCarActor local c = car:K2_GetActorLocation() local function d(x) return l and math.floor(math.sqrt((x.X - l.X) ^ 2 + (x.Y - l.Y) ^ 2)) or -1 end return string.format('tilted=%.1f rq_TS=%s pawn_d=%s car_d=%s car=%s w=%.0f armed=%s gone_ms=%s inlist=%s innear=%s', SW2_MAX or -1, CoopSyncState.report():match('rq_TS=(%d+)') or '0', d(p), d(c), car:GetFName():ToString(), SW_W or -1, tostring(SW_ARMED), tostring(SW_GONE), tostring(SW_INLIST), tostring(SW_INNEAR))"
Check "the guest's sway reached the host's copy" ([double]$hMax -gt 3 -and (Stat $hr 'req_TS') -ge 1) "host body tilted $hMax deg; host req_TS=$(Stat $hr 'req_TS') | guest: $g2"
Finish
