# Automated puppet animation + seat test over the network relays (two headless instances on this PC).
# Phases: both in the car -> both get out -> host walks -> client walks -> both get back in.
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function Info($dir) { $s = Send $dir "return CoopPlayers.puppetInfo()"; $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Self($dir) { $s = Send $dir "return CoopPlayers.selfInfo()"; $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# expected car-local X,Y per seat (1 driver, 4 back right; BACK_X = -60 in playersync.lua)
$SEAT = @{ 1 = @(46.2, -45.8); 2 = @(46.2, 45.8); 3 = @(-60, -45.8); 4 = @(-60, 45.8) }
function SeatedChecks($who, $info, [int]$n) {
    $rel = Vec $info.rel
    Check "$who puppet sits" ($info.state -eq 'sit' -and $info.poseVisible -eq 'true' -and $info.skVisible -eq 'false') $info.raw
    Check "$who puppet attached to the car" ($info.attached -eq 'BP_PlayerCarNew_C') "attached=$($info.attached)"
    Check "$who puppet on its seat $n (car-relative X,Y)" ([math]::Abs($rel.X - $SEAT[$n][0]) -lt 2 -and [math]::Abs($rel.Y - $SEAT[$n][1]) -lt 2) "rel=$($info.rel), want $($SEAT[$n][0]),$($SEAT[$n][1])"
    Check "$who sitting pose: knee in front of hip, foot below knee" ([double]$info.sit_knee_forward -ge 25 -and [double]$info.sit_foot_below_knee -ge 25) "knee_forward=$($info.sit_knee_forward) foot_below_knee=$($info.sit_foot_below_knee)"
}

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 6

"=== 1. both in the car (host = driver; the client frees the back right seat and gets in there)"
"  client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)")
Start-Sleep 3
"  client: " + (Send $cd "return CoopPlayers.botEnterAt('RR')")
Start-Sleep 5
$self = Self $cd
Check "client's own character on the back right seat" ($self.in_car -eq 'True' -and $self.seat -eq '4' -and [math]::Abs((Vec $self.rel).Y - $SEAT[4][1]) -lt 2 -and [math]::Abs((Vec $self.rel).X - $SEAT[4][0]) -lt 2) $self.raw
SeatedChecks "host's (on client)" (Info $cd) 1
SeatedChecks "client's (on host)" (Info $hd) 4

"=== 2. both get out"
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | client: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 5
foreach ($side in @(@('host''s (on client)', $cd), @('client''s (on host)', $hd))) {
    $i = Info $side[1]
    Check "$($side[0]) puppet stands (idle clip, not attached)" ($i.state -eq 'idle' -and $i.anim -eq 'ALS_N_Idle_Pose' -and $i.attached -eq 'no' -and $i.skVisible -eq 'true') $i.raw
}

function WalkPhase($walker, $wdir, $odir, [string]$scale, [string]$state, [string]$clip) {
    "=== $walker $($state)s (input $scale)"
    # facing away from the car (and the other's solid puppet next to it): a walk into the car went nowhere
    "  " + (Send $wdir "local pc = FindFirstOf('PlayerController') local me = pc.Pawn:K2_GetActorLocation() local c = CoopPlayers.ownCarActor():K2_GetActorLocation() pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(me.Y - c.Y, me.X - c.X)), Roll = 0 }) return 'facing away from the car'")
    "  " + (Send $wdir "return CoopPlayers.botWalk(5, $scale)")
    Start-Sleep 3
    $i = Info $odir
    Check "$walker's puppet plays the $state clip while moving" ($i.state -eq $state -and $i.anim -eq $clip) $i.raw
    Start-Sleep 1
    $i = Info $odir
    Check "$walker's puppet feet really move (foot_l moved >= 10 units vs the puppet)" ([double]$i.foot_motion -ge 10) "foot_motion=$($i.foot_motion)"
    Start-Sleep 4
    $i = Info $odir
    Check "$walker's puppet back to idle after stopping" ($i.state -eq 'idle') $i.raw
}
WalkPhase "host" $hd $cd 0.4 walk ALS_N_Walk_F
WalkPhase "client" $cd $hd 0.4 walk ALS_N_Walk_F
WalkPhase "host" $hd $cd 1.0 run ALS_N_Run_F

"=== 5. both get back in"
"  host: " + (Send $hd "return CoopPlayers.botEnterAt('FL')")
Start-Sleep 4
"  client: " + (Send $cd "return CoopPlayers.botEnterAt('RR')")
Start-Sleep 6
$self = Self $cd
Check "client's own character back on the back right seat" ($self.in_car -eq 'True' -and $self.seat -eq '4' -and [math]::Abs((Vec $self.rel).Y - $SEAT[4][1]) -lt 2) $self.raw
SeatedChecks "host's (on client)" (Info $cd) 1
SeatedChecks "client's (on host)" (Info $hd) 4

"host players: " + (Send $hd "return CoopPlayers.report()")
"client players: " + (Send $cd "return CoopPlayers.report()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
