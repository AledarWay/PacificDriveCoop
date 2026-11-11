# The zone's gates and the arrival place at both players (owner's real test: "different exits marked on the map,
# we appeared at different places"). Host from the advanced save (a zone with several gates), guest a new game in
# its garage, CoopNet over the local TCP link: the lobby forms, the host starts the run from its zone, the guest
# drives out through its garage exit and arrives on the host's map. Then:
#   the guest's transitions have the host's entrance / exits; the guest's car is near the host's (< 40 m).
# -Split: the host's config with entrance_split_chance = 1 (owner's two-games test 2026-11-11: a random zone where the
#   two come in by different entrances and have to find each other): the guest keeps its own entrance and place, the
#   exits are the host's.
param([switch]$Keep, [switch]$NetExe, [int]$Port = 47861, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav", [switch]$Split, [switch]$OldZone)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
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
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
$driveOut = "local pc = FindFirstOf('PlayerController') local p = pc.Pawn local car = FindFirstOf('BP_CarManager_C').NewCarActor " +
    "local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end " +
    "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.IsGarageExit then ex = e end end " +
    "local c = ex.Collision_Exit:K2_GetComponentLocation() " +
    "car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z - 150 }, { Pitch = 0, Yaw = -80, Roll = 0 }, false, {}, true) return 'drove out'"
# transitions as "name=E/X/-" (entrance / exit / closed) and the own car
$gates = "local r = {} for _, e in ipairs(FindAllOf('BP_LevelTransition_Base_C') or {}) do if e:IsValid() and not e:GetFullName():find('Default__', 1, true) then " +
    "r[#r + 1] = e:GetFName():ToString() .. '=' .. (e.ExitActive and 'X' or (e.EntranceActive and 'E' or '-')) end end table.sort(r) " +
    "local l = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorLocation() return table.concat(r, ',') .. string.format(' car=%.0f,%.0f', l.X, l.Y)"

Get-Process PenDriverPro-Win64-Shipping, CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$id = Get-Date -f HHmmss
$hchan = "$inst\host\chan-g$id"; $cchan = "$inst\client\chan-g$id"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
if ($Split) { Set-Content "$hchan\config.txt" "entrance_split_chance = 1" -Encoding ascii }
# -OldZone: the guest's own generated zone made the host's (config zone_from_save = 0; on by default: the host's
# exact zone from its save)
if ($OldZone) { foreach ($c in $hchan, $cchan) { Add-Content "$c\config.txt" "zone_from_save = 0" -Encoding ascii } }
. "$t\netlink.ps1"
$rh = NetExeStart $hchan Host
$rc = NetExeStart $cchan Guest

"=== 1. host in its zone (advanced save), guest in its garage (new game), lobby"
$env:COOPSYNC_CHAN = $hchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Host; & "$t\start-save.ps1" -Tag host -Save $Save -Slot 9 | Select-Object -Last 1
$env:COOPSYNC_CHAN = $cchan.Replace('\', '/'); $env:COOPSYNC_NET = NetSpec Guest; & "$t\start-zone.ps1" -Tag client -Seed 777 -StopInGarage | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
NetCtl $hchan 'create'; Start-Sleep 2; NetCtl $cchan 'join 1'
$h = WaitFor $hchan { param($s) $s.state -eq 'hosting' } 240
Check "host hosts its zone" ($h.state -eq 'hosting') $h.raw
"  host gates: " + (Send $hd $gates)

"=== 2. the host starts the run, the guest drives out and arrives"
NetCtl $hchan 'start'
$c = WaitFor $cchan { param($s) $s.gate -match '^\d+/[1-9]' } 60
"  guest: " + (Send $cd $driveOut)
$c = WaitFor $cchan { param($s) $s.state -eq 'playing' } 480
Check "the guest arrived on the host's map and syncs" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
# (the guest's game may shut an exit its own route lacks: the mod opens it again every 3 s)
$end = (Get-Date).AddSeconds(20)
do {
    Start-Sleep 3
    $hg = Send $hd $gates; $cg = Send $cd $gates
} while ((($hg -split ' car=')[0]) -ne (($cg -split ' car=')[0]) -and (Get-Date) -lt $end)
"  host:  $hg"; "  guest: $cg"
$hs = ($hg -split ' car=')[0]; $cs = ($cg -split ' car=')[0]
$note = (Get-Content (Get-ChildItem $cchan -Recurse -Filter hitches.log | Select-Object -First 1).FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match 'gates on arrival' } | Select-Object -Last 1)
"  guest: $note"
function Exits($s) { (($s -split ',') | Where-Object { $_ -match '=X$' }) -join ',' }
if ($Split) {
    Check "split: the guest kept its own entrance and place, the exits are the host's" ($note -match 'split' -and (Exits $hs) -eq (Exits $cs) -and (Exits $hs) -ne '') "host exits $(Exits $hs) | guest exits $(Exits $cs) | $note"
} else {
    Check "the guest's entrance and exits are the host's" ($hs -eq $cs -and $hs -ne '') "host $hs | guest $cs"
$hc = (($hg -split ' car=')[1] -split ','); $cc = (($cg -split ' car=')[1] -split ',')
$dist = [math]::Sqrt([math]::Pow([double]$hc[0] - [double]$cc[0], 2) + [math]::Pow([double]$hc[1] - [double]$cc[1], 2)) / 100
    Check "the guest's car is at the host's entrance, near the host's (owner: the same entrance, not a teleport to the host)" ($dist -lt 40 -and $note -match 'entrance|car stays') ("{0:N0} m apart | $note" -f $dist)
    # (owner 2026-11-11: "the guest's car came in sideways on the guardrail": a spot nothing stands on)
    Check "on a free spot (no guardrail, gate building or car under it)" ($note -match 'spot \d+ free|car stays') $note
}
$roll = Send $cd "local r = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorRotation() return string.format('pitch=%.1f roll=%.1f', r.Pitch, r.Roll)"
Check "and stands on its wheels" ($roll -match 'pitch=(-?[\d.]+) roll=(-?[\d.]+)' -and [math]::Abs([double]$Matches[1]) -lt 25 -and [math]::Abs([double]$Matches[2]) -lt 25) $roll

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    NetExeStop
}
