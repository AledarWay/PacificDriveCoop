# The instability storm (owner's alpha 21 test: "at an unstable junction my siren started and the instability came,
# my friend's not"). Two headless instances from the advanced save, own-car mode, the in-game network's local test
# link: the lobby, the host leaves, the guest drives out after it (both in the same zone), then the host's instability
# timer runs out: the guest gets the same storm.
# -SetupOnly: the pair in the zone, nothing more (probes by hand).
param([switch]$Keep, [switch]$SetupOnly, [int]$Port = 47851, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav")
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

if ($SetupOnly) { "=== pair ready (probes by hand)"; return }

# this side's storm: "<storms> <spawned x,y or -> <state> <weak sky>"
$sr = "local m = FindFirstOf('BP_StormManager_C') local n = 0 for _, s in ipairs(FindAllOf('BP_ZoneStormRoyale_C') or {}) do if s:IsValid() then n = n + 1 end end " +
    "local s = m.SpawnedStormIfValid local at = '-' if s and s:IsValid() then local l = s:K2_GetActorLocation() at = string.format('%.0f,%.0f', l.X, l.Y) end " +
    "local it = {} m:GetCurrentInstabilityTime(it) return string.format('storms=%d at=%s state=%s weak=%.2f inst=%.0f tol=%.0f', n, at, tostring(m.CurrentStormState), FindFirstOf('BP_ToDManager_C').ToDSimulationActor.WeakStormOverride, it.CurrentInstabilityTime, m.FinalInstabilityTollerance)"
function Storm($dir) { KV (Send $dir $sr) }
function Near2($a, $b) { if ($a -eq '-' -or $b -eq '-') { return $false }; $x = $a -split ','; $y = $b -split ','; [Math]::Abs([double]$x[0] - [double]$y[0]) -lt 100 -and [Math]::Abs([double]$x[1] - [double]$y[1]) -lt 100 }

"=== 2. the guest's own timer cannot go first (a lower tolerance of its own, its instability racing ahead)"
"  guest: " + (Send $cd "local m = FindFirstOf('BP_StormManager_C') m.FinalInstabilityTollerance = 1000 return 'own tolerance 1000'")
"  host: " + (Send $hd "local m = FindFirstOf('BP_StormManager_C') m:IncrementStormInstability(3000) local it = {} m:GetCurrentInstabilityTime(it) return 'instability ' .. it.CurrentInstabilityTime")
# (up to 12 s: the host's line comes every 1 s, but one 4 s read under the full suite's load still had the guest's old
# instability - its tolerance had come, quick suite 2026-11-10)
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep 2
    $hs = Storm $hd; $cs = Storm $cd
    if ([Math]::Abs([double]$cs.inst - [double]$hs.inst) -lt 50 -and $cs.tol -eq $hs.tol) { break }
}
Check "the guest has the host's instability and tolerance" ([Math]::Abs([double]$cs.inst - [double]$hs.inst) -lt 50 -and $cs.tol -eq $hs.tol) "host $($hs.raw) | guest $($cs.raw)"
"  guest: " + (Send $cd "local m = FindFirstOf('BP_StormManager_C') m:IncrementStormInstability(100000) Dev.after(1500, function() m['Check Instability'](m) end) return 'own instability +100000, a check in 1.5 s'")
Start-Sleep 12
$hs = Storm $hd; $cs = Storm $cd
$st = (Status $cchan).storm
Check "the guest's racing timer is held under the tolerance, no storm of its own" ($cs.storms -eq '0' -and $hs.storms -eq '0' -and [double]$cs.inst -lt [double]$cs.tol -and [int](($st -split '/')[3]) -ge 1) "host $($hs.raw) | guest $($cs.raw) | storm=$st"

"=== 3. the host's instability timer runs out (its storm manager: the ARC's state, then the storm)"
$hs = Storm $hd; $cs = Storm $cd
"  before: host $($hs.raw) | guest $($cs.raw)"
"  host: " + (Send $hd ("local m = FindFirstOf('BP_StormManager_C') m:ChangeStormTimerState(2) local l = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorLocation() " +
    "m:SpawnRoyaleStorm({ X = l.X + 20000, Y = l.Y, Z = l.Z }, true, nil) local s = m.SpawnedStormIfValid return 'storm ' .. tostring(s and s:IsValid()) .. ' state ' .. tostring(m.CurrentStormState)"))
$end = (Get-Date).AddSeconds(20)
do { Start-Sleep 2; $cs = Storm $cd } while ($cs.storms -ne '1' -and (Get-Date) -lt $end)
$hs = Storm $hd
Check "the guest gets the host's storm, at the same spot" ($cs.storms -eq '1' -and $hs.storms -eq '1' -and (Near2 $hs.at $cs.at)) "host $($hs.raw) | guest $($cs.raw)"
Check "the guest's ARC storm state is the host's" ($cs.state -eq $hs.state -and $hs.state -eq '2') "host $($hs.state) | guest $($cs.state)"

"=== 4. the host's repeat (every 10 s: a guest that missed the line) reaches the guest, which keeps its one storm"
$end = (Get-Date).AddSeconds(30)
do { Start-Sleep 3; $st = (Status $cchan).storm } while ([int](($st -split '/')[2]) -lt 2 -and (Get-Date) -lt $end)
$cs = Storm $cd
$have = ($st -split '/')[2]
$done = ($st -split '/')[1]
Check "the host's repeats reach the guest, still one storm there" ([int]$have -ge 2 -and $done -eq '1' -and $cs.storms -eq '1') "ap_STORM_done=$done ap_STORM_have=$have | guest $($cs.raw)"
$hs = Storm $hd
Check "no echo: one storm on the host" ($hs.storms -eq '1') $hs.raw

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($rh, $rc)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}
