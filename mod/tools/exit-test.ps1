# Automated "the host leaves the zone" test (guest mode, two headless instances over the relays). The guest joins
# with its own save, picks up items, then the host goes home (the game's own return, which the mod sees through
# its TravelToGarage hook and announces as "L garage").
#   -Scenario seated: the guest sits in the host's car -> it goes home too, keeping what it carries
#   -Scenario behind: the guest stands outside -> left behind = failed run (the game's death: random loss, home)
param([switch]$Keep, [ValidateSet('seated', 'behind')] [string]$Scenario = 'seated', [int]$GuestSeed = 777)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"; $cu = "$inst\client\userdir"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Total($s) { $n = 0; if ($s -and $s -ne 'empty') { foreach ($x in ($s -split ',')) { if ($x -match 'x(\d+)$') { $n += [int]$Matches[1] } } }; $n }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
if (Test-Path "$cu\Saved\SaveGames") { Remove-Item "$cu\Saved\SaveGames\*" -Force -ErrorAction SilentlyContinue }
Remove-Item "$cu\Saved\CoopSyncGuestCar.tsv*" -Force -ErrorAction SilentlyContinue
& "$t\deploy.ps1"

"=== 1. the guest joins the host's zone ($Scenario)"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed
$log | Select-String 'join|arrived|host is at|matched on client|^PASS|^FAIL'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)')")
Start-Sleep 8
"  guest picks: " + (Send $cd "BOT_ONLY='pick' BOT_SKIP=0 return dofile('C:/PacificDriveCoop/mod/tools/cmds/bot-actions.lua')")
if ($Scenario -eq 'behind') {
    "  give: " + (Send $cd "local im = FindFirstOf('BP_InventoryManager_C') local a = im.Inventory_Player.Slots[1].Items[1].Archetype for i = 1, 30 do pcall(function() im:GiveItemToPlayer(a) end) end return 'gave 30'")
}
Start-Sleep 6
if ($Scenario -eq 'seated') {
    "  client: " + (Send $cd "return CoopPlayers.removeSeatDevice(4)"); Start-Sleep 3
    "  client: " + (Send $cd "return CoopPlayers.botEnterAt('RR')"); Start-Sleep 5
} else {
    "  client: " + (Send $cd "return CoopPlayers.botExitCar()"); Start-Sleep 3
}
$self = KV (Send $cd "return CoopPlayers.selfInfo()")
$want = if ($Scenario -eq 'seated') { 'True' } else { 'False' }
Check "the guest is $(if ($Scenario -eq 'seated') { 'in the host''s car' } else { 'outside the car' })" ($self.in_car -eq $want) $self.raw
$before = Send $cd "$run return Run.inventory()"
"  guest carries: $before"

"=== 2. the host goes home"
"  host: " + (Send $hd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Start-Sleep 5
$hl = KV (Send $hd "return CoopPlayers.leaveInfo()")
$cl = KV (Send $cd "return CoopPlayers.leaveInfo()")
Check "the host announced leaving for home" ($hl.leave_sent -eq 'garage') $hl.raw
$g = KV (Send $cd "$run return Run.where()")
Check "the guest is home in its own garage" ($g.state -eq '4' -and $g.world -eq 'RB_Garage' -and $g.seed -eq "$GuestSeed") $g.raw
$after = Send $cd "$run return Run.inventory()"
if ($Scenario -eq 'seated') {
    Check "the guest left with the host (not left behind)" ($cl.went_home_with_host -eq 'true' -and $cl.left_behind -eq 'false') $cl.raw
    Check "the guest kept what it carried" ((Total $after) -ge (Total $before) -and (Total $before) -ge 1) "before: $before | after: $after"
} else {
    Check "the guest was left behind (failed run)" ($cl.left_behind -eq 'true') $cl.raw
    Check "the guest lost part of what it carried (the game's death penalty)" ((Total $after) -lt (Total $before)) "before $(Total $before) | after $(Total $after)"
}

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
