# Automated test of the music in the garage lobby (playersync garage mode, "Radio music"): the garage stereo plays the
# music manager's radio, so in the lobby the guest's radio follows the host's track and place in it. Two instances in
# their garages over the test relays, with sound (the music manager plays only then); playersync started as the
# session does in the lobby ({ garage = true }).
#   1. host's garage stereo on -> the guest plays the host's track, in step (its clocks within 700 ms)
#   2. the game's random seek on the host (RandomSeekMusic, as when a radio turns on) -> replaced by a known one, the
#      guest still in step
#   3. the host's track near its end -> the host picks the next one (RN), both queue it: both change to it at its
#      natural end within 0.8 s, the guest without a switch of its own
#   4. the host's channel -> the guest follows; the guest's channel (its stereo) -> the host's radio skips (RK)
#   5. the guest's playlist whole; no errors
param([switch]$Keep, [int]$Port = 27530)
$env:COOPTEST_SOUND = '1'
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
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
function TrackSoon($dir) { for ($i = 0; $i -lt 10; $i++) { $x = Track $dir; if ($x -ne 'nil') { return $x }; Start-Sleep -Milliseconds 500 }; 'nil' }
function Drift($dir) { $g = Ghost $dir; if ($g.track_drift -match '^-?\d+$') { [int]$g.track_drift } else { 99999 } }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. both in their garages (sound on), the relays, the lobby's player sync"
. "$t\boot-lib.ps1" # (the two games boot side by side)
$boot0 = BootBg start-zone.ps1 "-Tag host -Seed 12345 -StopInGarage"
$boot1 = BootBg start-zone.ps1 "-Tag client -Seed 777 -StopInGarage"
BootWait $boot0 | Select-Object -Last 1; BootWait $boot1 | Select-Object -Last 1
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-g$runId"; $cchan = "$inst\client\chan-g$runId"
New-Item -ItemType Directory -Force $hchan, $cchan | Out-Null
$relay = "$root\mod\net\relay.ps1"; $token = [guid]::NewGuid().ToString("N")
$rh = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role host -Dir `"$hchan`" -Port $Port -Token $token" -WindowStyle Hidden -PassThru
$rc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role client -Dir `"$cchan`" -Port $Port -Token $token" -WindowStyle Hidden -PassThru
Start-Sleep 5
"host: " + (Send $hd "$lib return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)', { garage = true })")
"client: " + (Send $cd "$lib return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)', { garage = true })")
Start-Sleep 8

"=== 1. host's garage stereo on"
"  guest stereo stays as it is: " + (Send $cd "return tostring(FindFirstOf('BP_MusicManager_C').radioOn)")
"  host: " + (Send $hd "FindFirstOf('BP_Garage_Stereo_01_C').BP_RadioComponent:TogglePlayback() return tostring(FindFirstOf('BP_MusicManager_C').radioOn)")
Start-Sleep 10
$ht = TrackSoon $hd; $gt = TrackSoon $cd; $hi = Ghost $hd; $gi = Ghost $cd
Check "guest: plays the host's track (RT)" ($ht -ne 'nil' -and $gt -eq $ht -and [int]$gi.rt_recv -ge 1) "host=$ht guest=$gt rt_sent=$($hi.rt_sent) rt_recv=$($gi.rt_recv) rt_played=$($gi.rt_played)"
$d = Drift $cd
Check "guest: in step with the host (|drift| < 700 ms)" ([math]::Abs($d) -lt 700) "drift=$d ms track_seeks=$($gi.track_seeks)"

"=== 2. the game's random seek on the host"
"  host: " + (Send $hd "FindFirstOf('BP_MusicManager_C'):RandomSeekMusic() return 'random seek'")
Start-Sleep 8
$hi = Ghost $hd; $gi = Ghost $cd; $d = Drift $cd
Check "host: the random seek replaced by a known one" ([int]$hi.random_seeks -ge 1) "random_seeks=$($hi.random_seeks)"
Check "guest: still in step after it" ([math]::Abs($d) -lt 700 -and (Track $cd) -eq (Track $hd)) "drift=$d ms track_seeks=$($gi.track_seeks)"

"=== 3. the host's track near its end: both change to the same next track together"
$played = [int]$gi.rt_played
"  host: " + (Send $hd "local T = CoopPlayers.twinModule() local id, pos, len = T.trackPos() return tostring(T.seekTrack(len - 9000)) .. ' len=' .. tostring(len)")
$before = Track $hd
$drifts = @()
for ($i = 0; $i -lt 30 -and (Track $hd) -eq $before; $i++) { Start-Sleep 1; $drifts += (Ghost $cd).track_drift }
"  guest drift while the track ends: $($drifts -join ' ')"
Start-Sleep 4
$hi = Ghost $hd; $gi = Ghost $cd; $ht = Track $hd; $gt = Track $cd
$dt = if ($hi.track_changed -match '^\d+$' -and $gi.track_changed -match '^\d+$') { [math]::Abs([int64]$hi.track_changed - [int64]$gi.track_changed) } else { 99999 }
Check "host: picked and sent the next track (RN), guest queued it" ([int]$hi.rn_sent -ge 1 -and [int]$gi.rn_queued -ge 1) "rn_sent=$($hi.rn_sent) rn_recv=$($gi.rn_recv) rn_queued=$($gi.rn_queued)"
Check "both on the same new track, changed together (< 800 ms), no switch on the guest" ($ht -ne $before -and $gt -eq $ht -and $dt -lt 800 -and [int]$gi.rt_played -eq $played) "before=$before host=$ht guest=$gt changed host/guest $($hi.track_changed)/$($gi.track_changed) (diff $dt ms) rt_played $played -> $($gi.rt_played)"

"=== 4. channel changes"
$before = Track $hd
"  host: " + (Send $hd "FindFirstOf('BP_Garage_Stereo_01_C').BP_RadioComponent:ChangeChannel(1) return 'channel +1'"); Start-Sleep 6
$ht = TrackSoon $hd; $gt = TrackSoon $cd
Check "guest: follows the host's channel change" ($ht -ne $before -and $gt -eq $ht) "before=$before host=$ht guest=$gt"
$before = $ht
"  guest: " + (Send $cd "FindFirstOf('BP_Garage_Stereo_01_C').BP_RadioComponent:ChangeChannel(1) return 'channel +1'"); Start-Sleep 7
$ht = TrackSoon $hd; $gt = TrackSoon $cd; $hi = Ghost $hd; $gi = Ghost $cd
Check "guest's channel: the host's radio skips, the guest plays it" ($ht -ne $before -and $gt -eq $ht -and [int]$gi.rk_sent -ge 1 -and $hi.last_rk_done -eq 'true') "before=$before host=$ht guest=$gt rk_sent=$($gi.rk_sent) last_rk_done=$($hi.last_rk_done)"

"=== 5. the guest's playlist, errors"
Start-Sleep 3
$pn = Send $cd "return #FindFirstOf('BP_MusicManager_C').RadioPlaylist .. ' ' .. #FindFirstOf('BP_MusicManager_C').DefaultRadioPlaylist"
Check "guest: its playlist whole again" (($pn -split ' ')[0] -eq ($pn -split ' ')[1]) "playlist / default: $pn"
$eh = Send $hd "return CoopPlayers.report()"; $eg = Send $cd "return CoopPlayers.report()"
Check "no errors on either side" ($eh -notmatch 'errors=[1-9]|ERR' -and $eg -notmatch 'errors=[1-9]|ERR') "host: $eh | guest: $eg"

$env:COOPTEST_SOUND = $null
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id $rh.Id, $rc.Id -Force -ErrorAction SilentlyContinue
}
