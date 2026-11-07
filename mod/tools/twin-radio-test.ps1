# Automated test of the radio's music in the twins (twincar "Radio music"): RT lines carry the track the owner's own
# radio plays; in the other's twin with the radio on the local radio plays it; the twin's channel button changes the
# owner's real radio (RK). Two instances over the test network, with sound (the music manager plays only then).
#   1. host's radio on -> RT lines reach the guest
#   2. guest gets in the host car's twin (back door): its radio on, playing the host's track
#   2b. a DJ break on the host's radio -> the guest plays the same one; its own breaks held off / stopped
#   3. guest changes channel on the twin's radio -> the host's real radio skips, the guest follows the new track
#   4. host changes channel itself -> the guest follows
#   5. guest gets out; no errors
param([switch]$Keep)
$env:COOPTEST_SOUND = '1'
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split '\s+')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Track($dir) { Send $dir "return tostring(CoopPlayers.twinModule().currentTrack())" }
# the DJ break playing now: "<event> <sequence>" or none
function Dj($dir) { Send $dir "local dm = FindFirstOf('BP_DialogueManager_C') if not dm:IsAnyoneTalking() then return 'none' end local s = dm:GetCurrentlyPlayingSequence() return s.DialogueEvent.Name:ToString() .. ' ' .. s:GetFName():ToString()" }
function RadioOn($dir) { Send $dir "local r = {} FindFirstOf('BP_CarManager_C'):GetCarRadioOnOffState(r) return tostring(r.CarState_Radio)" }
# the track as soon as one plays (between tracks / a channel change it is nil for a moment)
function TrackSoon($dir) { for ($i = 0; $i -lt 10; $i++) { $x = Track $dir; if ($x -ne 'nil') { return $x }; Start-Sleep -Milliseconds 500 }; 'nil' }
# twin doors: look at door n of the other's twin until the game highlights it, E down, up again after $ms
function Tap($dir, [int]$door, [int]$ms = 100) {
    $slot = @{ 1 = 'DoorsFL'; 2 = 'DoorsFR'; 3 = 'DoorsRL'; 4 = 'DoorsRR'; 5 = 'DoorsTrunk' }[$door]
    $look = Get-Content "$t\cmds\twin-parts-look.lua" -Raw
    $h = ''
    foreach ($dz in 0, 20, -20, 40, -40) {
        Send $dir "LOOK_DZ = $dz LOOK_SLOT = '$slot' $look" | Out-Null
        Start-Sleep 1
        $h = Send $dir "local g, n = CoopPlayers.twinModule().highlightedDoor() return tostring(n)"
        if ($h -match "^(OK )?$door\s*$") { break }
    }
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after($ms, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E at door $door for $ms ms (highlighted door: $($h.Trim()))'"
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car (sound on)"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4

"=== 1. host's radio on"
"  guest radio off: " + (Send $cd "FindFirstOf('BP_CarManager_C'):SetCarRadioOnOffState(false, true) return 'off'")
"  host: " + (Send $hd "FindFirstOf('BP_CarManager_C'):SetCarRadioOnOffState(true, true) return 'on'"); Start-Sleep 5
$ht = TrackSoon $hd
$hi = Ghost $hd; $gi = Ghost $cd
Check "host: its radio plays, RT lines reach the guest" ($ht -ne 'nil' -and [int]$hi.rt_sent -ge 1 -and [int]$gi.rt_recv -ge 1) "host track=$ht rt_sent=$($hi.rt_sent) guest rt_recv=$($gi.rt_recv)"
Check "guest: outside, its own radio stays off" ((RadioOn $cd) -eq 'false') "guest radio=$(RadioOn $cd) track=$(Track $cd)"

"=== 2. guest gets in the twin through the back door"
"  host shuts its door: " + (Send $hd "local c = CoopPlayers.twinModule().ownCar() return CoopPlayers.twinModule().setDoor(c, 1, 'shut')")
"  host: " + (Send $hd "return CoopPlayers.removeSeatDevice(3)"); Start-Sleep 3
"  guest: " + (Tap $cd 3); Start-Sleep 8
$gi = Ghost $cd; $ht = TrackSoon $hd; $gt = TrackSoon $cd
Check "guest: in the twin, its radio on with the host's track" ($gi.in_ghost -eq 'H' -and (RadioOn $cd) -eq 'true' -and $gt -eq $ht -and [int]$gi.rt_played -ge 1) "in_ghost=$($gi.in_ghost) host=$ht guest=$gt rt_played=$($gi.rt_played) last_track=$($gi.last_track)"

"=== 2b. a DJ break on the host's radio (RequestInterstitial: natural ones need story progress the test save lacks)"
"  host: " + (Send $hd "FindFirstOf('BP_MusicManager_C'):RequestInterstitial() return 'break asked'"); Start-Sleep 3
$hs = Dj $hd; $gs = Dj $cd; $gi = Ghost $cd; $hi = Ghost $hd
Check "guest: plays the host's DJ break (RI)" ($hs -match 'Ambient' -and $gs -eq $hs -and [int]$hi.dj_sent -ge 1 -and [int]$gi.dj_played -ge 1) "host=$hs guest=$gs dj_sent=$($hi.dj_sent) dj_recv=$($gi.dj_recv) dj_played=$($gi.dj_played)"
Check "guest: its own breaks held off while following" ((Send $cd "local m = FindFirstOf('BP_MusicManager_C') return m.NextNaturalInterstitialCounter .. ' ' .. m.NextManualInterstitialCounter") -eq '99 99') "counters held at 99"
"  host stops its break: " + (Send $hd "FindFirstOf('BP_DialogueManager_C'):StopCurrentSequence() return 'stopped'")
"  guest stops its break: " + (Send $cd "FindFirstOf('BP_DialogueManager_C'):StopCurrentSequence() return 'stopped'"); Start-Sleep 2
"  guest: its own break (as the game's random one) " + (Send $cd "FindFirstOf('BP_MusicManager_C'):RequestInterstitial() return 'asked'"); Start-Sleep 2
$gs = Dj $cd; $gi = Ghost $cd
Check "guest: its own break stopped (only the host's play)" ($gs -eq 'none' -and [int]$gi.dj_stopped -ge 1) "guest now=$gs dj_stopped=$($gi.dj_stopped)"

"=== 3. guest changes channel on the twin's radio"
$before = $ht
"  guest: " + (Send $cd "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end local r = tw and T.radioOf(tw) if not r then return 'no twin radio' end r.BP_RadioComponent:ChangeChannel(1) return 'channel +1'"); Start-Sleep 6
$ht = TrackSoon $hd; $gt = TrackSoon $cd; $gi = Ghost $cd; $hi = Ghost $hd
Check "host: its real radio changed channel" ($ht -ne $before -and $ht -ne 'nil' -and [int]$gi.rk_sent -ge 1 -and $hi.last_rk_done -eq 'true') "before=$before host now=$ht rk_sent=$($gi.rk_sent) last_rk_done=$($hi.last_rk_done)"
Check "guest: plays the host's new track" ($gt -eq $ht) "host=$ht guest=$gt last_track=$($gi.last_track)"

"=== 4. host changes channel itself"
$before = $ht
"  host: " + (Send $hd "local T = CoopPlayers.twinModule() return tostring(T.changeChannel(T.ownCar(), 1))"); Start-Sleep 6
$ht = TrackSoon $hd; $gt = TrackSoon $cd; $gi = Ghost $cd
Check "guest: follows the host's own channel change" ($ht -ne $before -and $gt -eq $ht) "before=$before host=$ht guest=$gt last_track=$($gi.last_track)"
$pn = Send $cd "return #FindFirstOf('BP_MusicManager_C').RadioPlaylist .. ' ' .. #FindFirstOf('BP_MusicManager_C').DefaultRadioPlaylist"
Check "guest: its playlist whole again" (($pn -split ' ')[0] -eq ($pn -split ' ')[1]) "playlist / default: $pn"

"=== 5. guest gets out"
# (native cars: the game's exit - the passenger looks at its door, the ExitDoor spot moved there, and presses E)
"  guest: " + ((Send $cd ("CE_CAR = 'twin' CE_HL = 'ExitDoor' " + (Get-Content "$t\cmds\car-e.lua" -Raw))) -split "`n" | Select-Object -Last 1); Start-Sleep 5
$gi = Ghost $cd
Check "guest: out, its own radio off again" ($gi.in_ghost -eq '-' -and (RadioOn $cd) -eq 'false') "in_ghost=$($gi.in_ghost) radio=$(RadioOn $cd)"
$cn = Send $cd "local m = FindFirstOf('BP_MusicManager_C') return m.NextNaturalInterstitialCounter .. ' ' .. m.NextManualInterstitialCounter"
Check "guest: its own DJ breaks' counters back" ($cn -ne '99 99' -and $cn -match '^\d+ \d+$') "counters $cn"
$eh = Send $hd "return CoopPlayers.report()"; $eg = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($eh -notmatch 'errors=[1-9]|ERR' -and $eg -notmatch 'errors=[1-9]|ERR') "host: $eh | guest: $eg"

$env:COOPTEST_SOUND = $null # (the next test in the same process: silent again)
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
