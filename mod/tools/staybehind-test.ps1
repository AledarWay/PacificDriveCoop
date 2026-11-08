# The guest left behind (found on the way, 2026-11-08: the host went on through a zone's exit gate while the guest
# played on in the old zone; the guest applied the host's next zone's lines there - 528 events at once, the host's
# twin at the new zone's spot - and crashed ~10 s later). Two headless instances from the advanced save, own-car mode,
# the in-game network's local test link:
#   1. the lobby, the host leaves, the guest drives out after it: both in the same zone;
#   2. the host drives into the exit gate and picks a junction, the guest stays: the guest's sync stops there, the
#      guest lives on (no crash) in the old zone;
#   3. the guest drives into the gate later: it follows the host to its zone, both see each other there.
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
$world1 = $h.world
Check "both in the same zone" ($c.state -eq 'playing' -and $c.world -eq $world1) "guest: $($c.raw) | host: $($h.raw)"

"=== 2. the host goes on through the exit gate, the guest stays"
$gate = Send $hd "for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.ExitActive and not e.IsGarageExit then return e:GetFName():ToString() end end return 'none'"
"  host's exit gate: $gate"
"  host: " + (DriveInto $hd $gate)
Start-Sleep 6
"  host: " + (Send $hd "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') EXITS_GO = 'travelto' EXITS_MAP = 'keep' EXITS_ANY_LEG = nil return dofile('$($t.Replace('\', '/'))/cmds/exits-probe.lua')")
$c = WaitFor $cchan { param($s) $s.note -match 'sync_stopped' } 60
Check "the guest's sync stops once the host left its zone" ($c.note -match 'sync_stopped' -and $c.world -eq $world1) "guest: $($c.raw)"
& "$t\wait-state.ps1" -State 5 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
$h = WaitFor $hchan { param($s) $s.state -eq 'hosting' -and $s.world -ne $world1 } 300
Check "the host is in its next zone" ($h.world -ne $world1 -and $h.state -eq 'hosting') $h.raw
# (the crash came ~10 s after the host's next zone's lines; 45 s with the host there)
Start-Sleep 45
$alive = @(Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue).Count
$fresh = ((Get-Date) - (Get-Item "$cchan\status.txt").LastWriteTime).TotalSeconds -lt 5
$c = Status $cchan
$w = Send $cd "local n = 0 for _, a in ipairs(FindAllOf('BP_PlayerCar_C') or {}) do pcall(function() if a:IsValid() then n = n + 1 end end) end return 'ok cars=' .. n"
Check "the guest left behind lives on in the old zone" ($alive -eq 2 -and $fresh -and $c.world -eq $world1 -and $w -match '^ok') "processes=$alive status fresh=$fresh $w | guest: $($c.raw)"

"=== 3. the guest drives into the gate later: it follows"
"  guest: " + (DriveInto $cd $gate)
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' -and $s.world -eq $h.world } 480
Check "the guest followed the host to its zone and plays" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
$end = (Get-Date).AddSeconds(40)
do { Start-Sleep 3; $h = Status $hchan; $c = Status $cchan } while (-not ($h.twins -eq '1' -and $c.twins -eq '1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') -and (Get-Date) -lt $end)
Check "both see each other and the other's car there" ($h.twins -eq '1' -and $c.twins -eq '1' -and $h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($rh, $rc)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}
