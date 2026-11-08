# The next zone together in own-car mode, the session's whole way (owner's alpha 20 test: "at the exit the guest got
# the map to pick the next junction again; it picked one, we split up on different junctions"; and at the start the
# guest's map stayed open through the load). Two headless instances from the advanced save (local/advsave, copied)
# sent home to their garages, the in-game network's local test link:
#   1. the lobby forms, the host leaves, the guest drives out after it: one travel, to the host's junction, no map;
#   2. the guest drives into the zone's exit gate first: no map, the screen dark, it waits for the host;
#   3. the host drives into the same gate and picks a junction: the guest follows it there - the same zone, the same
#      junction on both routes, one travel, no map, playing (screen clear), both cars there.
param([switch]$Keep, [int]$Port = 47851, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Status($chan) { KV ((Get-Content "$chan\status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]) }
function WaitFor($chan, [scriptblock]$cond, [int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    do { $s = Status $chan; if (& $cond $s) { return $s }; Start-Sleep 3 } while ((Get-Date) -lt $end)
    Status $chan
}
function NetCtl($chan, [string]$line) { Add-Content "$chan\net-control.txt" $line -Encoding ascii }
function ExitMap($chan) { $p = ((Status $chan).exitmap -split '/'); @{ closed = [int]$p[0]; exits = [int]$p[1]; follows = [int]$p[2] } }
# the junction (RouteShapeLeg) each side's run is on, from its own descriptor
function LegOf($dir) { $d = Send $dir "$run local d = Run.describe() return d and (d:match('[^\t]+$') or '-') or 'none'"; $d }
function Menus($dir) { Send $dir "local v = 0 for _, w in ipairs(FindAllOf('UMG_PlayerMenu_Main_C') or {}) do pcall(function() if w:IsInViewport() and w:IsVisible() then v = v + 1 end end) end return 'menus=' .. v" }
# the north (owner's alpha 21 test: the ARC map turned 90 degrees between the two; a quick suite's nextzone had the
# guest's sun yaw 180 off the host's): the manager's pick / the yaw in use, its true-north vector, the ToD actors'
# yaw - the same on both within 20 s
function NorthSame([string]$where) {
    $end = (Get-Date).AddSeconds(20)
    do {
        $a = KV (Send $hd $lr); $b = KV (Send $cd $lr)
        $same = $a.north -and $a.north -eq $b.north -and $a.truenorth -eq $b.truenorth -and $a.arcyaw -and $a.arcyaw -ne '-' -and $a.arcyaw -eq $b.arcyaw
        if ($same) { break }; Start-Sleep 3
    } while ((Get-Date) -lt $end)
    $wi = "guest weather=$((Status $cchan).weather) host weather=$((Status $hchan).weather)"
    Check "$($where): the same north on both (the ARC map's)" $same "host north=$($a.north) true=$($a.truenorth) arc=$($a.arcyaw) | guest north=$($b.north) true=$($b.truenorth) arc=$($b.arcyaw) | $wi"
    if ($where -eq 'first zone') {
        # (the guest's ARC map spawned with its own north: turned 90 off here, the host's view comes back to it)
        $tw = Send $cd "local w = FindFirstOf('PlayerController').Pawn:GetFullName():match('^%S+%s+/[^.]*%.([^:]+):PersistentLevel') local n = 0 for _, a in ipairs(FindAllOf('BP_GobblerMapview_C') or {}) do if a:IsValid() and a:GetFullName():find('.' .. w .. ':PersistentLevel', 1, true) then local r = a:K2_GetActorRotation() a:K2_SetActorRotation({ Pitch = 0, Yaw = r.Yaw + 90, Roll = 0 }, false) n = n + 1 end end return 'turned ' .. n"
        "  guest's ARC map view: $tw"
        $end = (Get-Date).AddSeconds(15)
        do { Start-Sleep 2; $a = KV (Send $hd $lr); $b = KV (Send $cd $lr) } while ($a.arcyaw -ne $b.arcyaw -and (Get-Date) -lt $end)
        Check "the guest's ARC map turned off the host's comes back to it" ($tw -match 'turned [1-9]' -and $a.arcyaw -eq $b.arcyaw) "$tw | host arc=$($a.arcyaw) guest arc=$($b.arcyaw) | guest weather=$((Status $cchan).weather)"
    }
}
function GuestTravels() {
    $lines = @(Get-Content "$inst\client\userdir\Saved\Logs\PenDriverPro.log" -ErrorAction SilentlyContinue)
    @{ travels = @($lines | Where-Object { $_ -match 'Traveling to level' }).Count; concurrent = @($lines | Where-Object { $_ -match 'concurrent save/load' }).Count }
}
# a side's car into the drive-through volume of an exit (the garage's, or the zone's exit gate named $gate), seated
function DriveInto($dir, [string]$gate) {
    $pick = if ($gate) { "e:GetFName():ToString() == '$gate'" } else { "e.IsGarageExit" }
    Send $dir ("local pc = FindFirstOf('PlayerController') local p = pc.Pawn local car = FindFirstOf('BP_CarManager_C').NewCarActor " +
        "local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end " +
        "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and $pick then ex = e end end " +
        "if not ex then return 'no such exit' end " +
        "local c = ex.Collision_Exit:K2_GetComponentLocation() local r = ex:K2_GetActorRotation() " +
        "Dev.after(1500, function() car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z + 100 }, { Pitch = 0, Yaw = r.Yaw, Roll = 0 }, false, {}, true) end) " +
        "return 'into ' .. ex:GetFName():ToString() .. ' (exit=' .. tostring(ex.ExitActive) .. ')'")
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-n$runId"; $cchan = "$inst\client\chan-n$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
. "$t\netlink.ps1"
$rh = NetExeStart $hchan Host
$rc = NetExeStart $cchan Guest

"=== 0. both from the advanced save, home to their garages"
foreach ($x in @(@{ tag = 'host'; chan = $hchan; dir = $hd }, @{ tag = 'client'; chan = $cchan; dir = $cd })) {
    $env:COOPSYNC_CHAN = $x.chan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec $(if ($x.tag -eq 'host') { 'Host' } else { 'Guest' }); & "$t\start-save.ps1" -Tag $x.tag -Save $Save -Slot 9 | Select-Object -Last 1
    "  $($x.tag): " + (Send $x.dir "$run return Run.goHome(false, 0)")
    & "$t\wait-state.ps1" -State 4 -Dir $x.dir -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  $($x.tag): $_" }
}
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
Start-Sleep 5

"=== 1. the lobby, the host leaves, the guest drives out after it"
NetCtl $hchan 'create'; Start-Sleep 2
NetCtl $cchan 'join 1'
$c = WaitFor $cchan { param($s) [int](($s.map -split '/')[1]) -ge 1 } 90
Check "lobby: the guest has the host's map" ([int](($c.map -split '/')[1]) -ge 1) $c.raw
Start-Sleep 4
"  host: " + (Send $hd 'local p = FindFirstOf("PlayerController").Pawn local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController")) return "host departs"')
& "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
$c = WaitFor $cchan { param($s) [int](($s.gate -split '/')[1]) -ge 1 } 60
"  guest: " + (DriveInto $cd '')
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
$h = Status $hchan
Check "the guest is in the host's zone and plays" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
$gt = GuestTravels
Check "the drive-out: one travel, no concurrent save/load" ($gt.travels -eq 1 -and $gt.concurrent -eq 0 -and $c.travels -eq '1') "game log travels=$($gt.travels) concurrent=$($gt.concurrent) mod travels=$($c.travels) | $($c.note)"
$hl = LegOf $hd; $cl = LegOf $cd
Check "both runs on the same junction" ($hl -match '^RouteShapeLeg_' -and $hl -eq $cl) "host $hl | guest $cl"
$m = Menus $cd
Check "no junction map open on the guest after the arrival" ($m -eq 'menus=0') "$m exitmap=$($c.exitmap)"
# (owner's alpha 17-20 tests: the guest's car twice, "EXTRA CAR: 2 cars, 0 twins" after the load - a short while in
# the owner's log, the whole stay in one nextzone run): own car + the other's twin on each side within a minute
$end = (Get-Date).AddSeconds(60)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.cars -eq '2/1' -and $c.cars -eq '2/1') -and (Get-Date) -lt $end)
Check "each side has its own car and the other's twin, nothing more" ($c.cars -eq '2/1' -and $h.cars -eq '2/1') "guest cars=$($c.cars) | host cars=$($h.cars)"
# (owner's alpha 20 test: "my zone looked brighter, the friend's darker")
$lr = Get-Content "$t\cmds\light-read.lua" -Raw
$hlt = KV (Send $hd $lr); $clt = KV (Send $cd $lr)
"  host light:  $($hlt.raw)"; "  guest light: $($clt.raw)"
$dt = [Math]::Abs([double]$hlt.tod - [double]$clt.tod); $dt = [Math]::Min($dt, 1 - $dt)
function Near($a, $b, [double]$rel) { $x = [double]($a -replace '[^\d.\-]', ''); $y = [double]($b -replace '[^\d.\-]', ''); [Math]::Abs($x - $y) -le [Math]::Max(0.01, [Math]::Abs($x) * $rel) }
$sunH = ($hlt.suns -split '/'); $sunC = ($clt.suns -split '/')
$sunOk = $sunH.Count -ge 4 -and $sunH[0] -eq $sunC[0] -and $sunH[1] -eq $sunC[1] -and (Near $sunH[2] $sunC[2] 0.05)
Check "the same light on both: time of day, sun direction and strength, sky, fog (5 %)" ($dt -lt 0.003 -and $sunOk -and (Near $hlt.sky $clt.sky 0.05) -and (Near $hlt.fog $clt.fog 0.05)) "tod $($hlt.tod)/$($clt.tod) sun $($hlt.suns) / $($clt.suns)"
NorthSame 'first zone'
$world1 = $h.world

"=== 2. the guest drives into the zone's exit gate first"
$gate = Send $hd "for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.ExitActive and not e.IsGarageExit then return e:GetFName():ToString() end end return 'none'"
"  host's exit gate: $gate"
$x0 = ExitMap $cchan
"  guest: " + (DriveInto $cd $gate)
$c = WaitFor $cchan { param($s) $s.state -eq 'zone:_at_the_exit' -and (ExitMap $cchan).closed -gt $x0.closed } 20
Start-Sleep 3
$c = Status $cchan; $x1 = ExitMap $cchan; $m = Menus $cd
Check "at the exit the guest waits for the host: no map, the screen dark" ($c.state -eq 'zone:_at_the_exit' -and $x1.exits -gt $x0.exits -and $m -eq 'menus=0' -and ($c.cover -split '/')[1] -eq '1') "$m exitmap=$($c.exitmap) cover=$($c.cover) | $($c.raw)"
Check "the guest did not travel by itself" ($c.world -eq $world1 -and (GuestTravels).travels -eq 1) "world=$($c.world) travels=$((GuestTravels).travels)"

"=== 3. the host drives into the gate and picks a junction"
"  host: " + (DriveInto $hd $gate)
Start-Sleep 6
"  host: " + (Send $hd "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') EXITS_GO = 'travelto' EXITS_MAP = 'keep' EXITS_ANY_LEG = nil return dofile('$($t.Replace('\', '/'))/cmds/exits-probe.lua')")
& "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
$h = WaitFor $hchan { param($s) $s.state -eq 'hosting' -and $s.world -ne $world1 } 300
Check "the host is in its next zone" ($h.world -ne $world1 -and $h.state -eq 'hosting') $h.raw
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' -and $s.world -eq $h.world } 480
Check "the guest followed the host to the same zone and plays" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
$gt = GuestTravels
Check "the follow: one travel more, no concurrent save/load" ($gt.travels -eq 2 -and $gt.concurrent -eq 0 -and (ExitMap $cchan).follows -ge 1) "game log travels=$($gt.travels) concurrent=$($gt.concurrent) exitmap=$($c.exitmap) | $($c.note)"
$hl = LegOf $hd; $cl = LegOf $cd
Check "both runs on the same junction again" ($hl -match '^RouteShapeLeg_' -and $hl -eq $cl) "host $hl | guest $cl"
Start-Sleep 2
$m = Menus $cd; $c = Status $cchan
Check "no map on the guest, its screen clear" ($m -eq 'menus=0' -and ($c.cover -split '/')[1] -eq '0') "$m cover=$($c.cover)"
$end = (Get-Date).AddSeconds(40)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.twins -eq '1' -and $c.twins -eq '1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
Check "both see each other and the other's car in the new zone" ($h.twins -eq '1' -and $c.twins -eq '1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
$end = (Get-Date).AddSeconds(60)
do { $h = Status $hchan; $c = Status $cchan; if ($h.cars -eq '2/1' -and $c.cars -eq '2/1') { break }; Start-Sleep 3 } while ((Get-Date) -lt $end)
Check "no extra car on either side in the new zone" ($h.cars -eq '2/1' -and $c.cars -eq '2/1') "host cars=$($h.cars) extra seen=$($h.extra) | guest cars=$($c.cars) extra seen=$($c.extra)"

NorthSame 'next zone'

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($rh, $rc)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}
