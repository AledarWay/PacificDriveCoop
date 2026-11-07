# Automated "guest with its own save joins the host's run" test (two headless instances over the relays).
# Host: new game seed 12345 -> its zone. Guest: own new game seed $GuestSeed -> own garage -> gets the host's
# run descriptor over the network -> drives out to the host's map -> spawn/loot sync -> picks up items
# (host decides) -> goes home to its own garage (the game saves) -> restart + load its save: the items
# and its own seed are still there, the host is still in its zone.
# -Outcome death: instead of going home the guest dies (the game's KillPlayer): the game sends it home and
# takes part of what it carries (the game's own random retention); the reload shows the post-death inventory.
# Both outcomes: the guest's own car comes home unchanged; the host hides the guest's puppet and frees its seat.
param([switch]$Keep, [int]$GuestSeed = 777, [ValidateSet('success', 'death')] [string]$Outcome = 'success')
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"; $cu = "$inst\client\userdir"
$w = "$root\testgame\PenDriverPro\Binaries\Win64"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code, [int]$Timeout = 120) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec $Timeout) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Items($s) { if ($s -eq 'empty' -or -not $s) { @{} } else { $h = @{}; foreach ($x in ($s -split ',')) { if ($x -match '^(.*)x(\d+)$') { $h[$Matches[1]] = [int]$Matches[2] } }; $h } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# what is installed where + what lies in the trunk (slot/container + archetype; the item data dumps change
# form between a fresh and a loaded item, so they are not compared): lines of car-before.txt missing from /
# new in another car state file
function CarDiff($other) {
    $a = @(Get-Content "$cd\car-before.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { ($_ -split "`t")[0..1] -join " " })
    $b = @(Get-Content $other -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { ($_ -split "`t")[0..1] -join " " })
    $gone = @(); $rest = [System.Collections.ArrayList]@($b)
    foreach ($x in $a) { $i = $rest.IndexOf($x); if ($i -ge 0) { $rest.RemoveAt($i) } else { $gone += $x } }
    return [pscustomobject]@{ Before = $a.Count; After = $b.Count; Gone = $gone; New = @($rest) }
}
function ShowDiff($d) { ($d.Gone | Select-Object -First 4 | ForEach-Object { "    - $_".Substring(0, [math]::Min(220, "    - $_".Length)) }) + ($d.New | Select-Object -First 4 | ForEach-Object { "    + $_".Substring(0, [math]::Min(220, "    + $_".Length)) }) }
function SaveInfo() { $s = Get-Item "$cu\Saved\SaveGames\odsave1.sav" -ErrorAction SilentlyContinue; if ($s) { "$($s.LastWriteTime.ToString('HH:mm:ss.fff')) $($s.Length)" } else { "none" } }

# a guest profile from scratch every run (the host profile is reset by start-zone's new game anyway)
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
if (Test-Path "$cu\Saved\SaveGames") { Remove-Item "$cu\Saved\SaveGames\*" -Force -ErrorAction SilentlyContinue }
# an insurance record from an earlier run would be applied to this new game's car by the CoopSync mod
Remove-Item "$cu\Saved\CoopSyncGuestCar.tsv*" -Force -ErrorAction SilentlyContinue
& "$t\deploy.ps1"

"=== 1. host in its zone, guest joins from its own garage"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed
$log | Select-String 'net:|network|descriptor|garage:|join|arrived|host is at|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
$arr = ($log | Select-String 'guest arrived: (.*)' | Select-Object -First 1).Matches.Groups[1].Value
$hat = ($log | Select-String 'host is at: (?:OK )?(.*)' | Select-Object -First 1).Matches.Groups[1].Value
$ga = KV $arr; $ha = KV $hat
Check "guest arrived in a zone with its own seed ($GuestSeed)" ($ga.state -eq '5' -and $ga.seed -eq "$GuestSeed") $arr
Check "guest is on the host's map" ($ga.world -and $ga.world -eq $ha.world) "guest $($ga.world), host $($ha.world)"
$afterLines = $log | Select-String '^(PASS|FAIL|LOOT PASS|LOOT FAIL)' | ForEach-Object { $_.Line }
Check "spawn replication on the joined map" ($afterLines.Count -ge 2 -and $afterLines[1] -eq 'PASS') ($afterLines -join ' / ')
Check "loot replication on the joined map" ($afterLines.Count -ge 4 -and $afterLines[3] -eq 'LOOT PASS') ($afterLines -join ' / ')

"=== 2. state + player sync, the guest picks up 2 items"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 8
$before = Send $cd "$run return Run.inventory()"
"  guest carries before: $before"
"  guest picks: " + (Send $cd "BOT_ONLY='pick' BOT_SKIP=0 return dofile('C:/PacificDriveCoop/mod/tools/cmds/bot-actions.lua')")
Start-Sleep 8
$after = Send $cd "$run return Run.inventory()"
$hostRep = Send $hd "return CoopSyncState.report()"
$b = Items $before; $a = Items $after
$gained = @(); foreach ($k in $a.Keys) { $d = $a[$k] - [int]$b[$k]; if ($d -gt 0) { $gained += "$k+$d" } }
Check "the picked items are in the guest's inventory" ($gained.Count -ge 1) "gained: $($gained -join ', ') | after: $after"
Check "the host removed the items from its world (it decides)" ($hostRep -match 'req_PICK_done=2') $hostRep
$pickedNames = @($a.Keys | Where-Object { $a[$_] -gt [int]$b[$_] })

$save0 = SaveInfo
if ($Outcome -eq 'death') {
    "=== 3. the guest dies in the host's zone (carrying 30 more items so a loss is practically certain)"
    "  give: " + (Send $cd "local im = FindFirstOf('BP_InventoryManager_C') local a = im.Inventory_Player.Slots[1].Items[1].Archetype for i = 1, 30 do pcall(function() im:GiveItemToPlayer(a) end) end return a:GetFName():ToString()")
    $beforeDeath = Send $cd "$run return Run.inventory()"
    "  guest carries before dying: $beforeDeath"
    "  guest: " + (Send $cd "FindFirstOf('BP_MainCharacterManager_C'):KillPlayer() return 'KillPlayer called'")
} else {
    "=== 3. the guest goes home to its own garage"
    "  guest: " + (Send $cd "$run return Run.goHome(false, 0)")
}
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Start-Sleep 5
$homeAt = KV (Send $cd "$run return Run.where()")
Check "guest is back in its garage with its own seed" ($homeAt.state -eq '4' -and $homeAt.world -eq 'RB_Garage' -and $homeAt.seed -eq "$GuestSeed") $homeAt.raw
$save1 = SaveInfo
Check "the game saved the guest's profile on arrival" ($save1 -ne $save0 -and $save1 -ne 'none') "save before: $save0, after: $save1"
$atHome = Send $cd "$run return Run.inventory()"
"  guest carries at home: $atHome"
if ($Outcome -eq 'death') {
    $bd = Items $beforeDeath; $ah = Items $atHome
    $n0 = 0; foreach ($v in $bd.Values) { $n0 += $v }; $n1 = 0; foreach ($v in $ah.Values) { $n1 += $v }
    Check "dying cost the guest part of what it carried (the game's penalty)" ($n1 -lt $n0 -and $n1 -ge 0) "carried $n0 before dying, $n1 at home"
}
Start-Sleep 3
$hp = KV (Send $hd "return CoopPlayers.puppetInfo()"); $hs = KV (Send $hd "return CoopPlayers.seatInfo()")
Check "the host hid the guest's puppet and freed its seat" ($hp.gone -eq 'true' -and $hp.hidden -eq 'true' -and $hs.client_seat -eq '0') "$($hp.raw) | client_seat=$($hs.client_seat)"
Start-Sleep 6 # the CoopSync mod checks the car ~6 s after the garage entry
"  guest car at home: " + (Send $cd "$run return Run.carState('$(P $cd)/car-home.txt')")
$d = CarDiff "$cd\car-home.txt"
"  car insurance: " + (Send $cd "$run return Run.lastRestore()")
Check "the guest's own car came home with everything installed and in the trunk as it left" ($d.Before -gt 0 -and $d.Gone.Count -eq 0 -and $d.New.Count -eq 0) "items before $($d.Before), after $($d.After), changed $($d.Gone.Count)/$($d.New.Count)"
ShowDiff $d
$hw = KV (Send $hd "$run return Run.where()")
Check "the host is still in its zone" ($hw.state -eq '5' -and $hw.world -eq $ha.world) $hw.raw

function RestartGuest($label) {
    $gp = Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $script:gpid }
    if ($gp) { Stop-Process -Id $script:gpid -Force -ErrorAction SilentlyContinue; Start-Sleep 3 }
    if (Test-Path "$cd\cmd.lua") { Remove-Item "$cd\cmd.lua" }
    $env:COOPDEV_DIR = $cd.Replace('\', '/')
    $p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $cu) + "-userdir=`"$cu`"") -WorkingDirectory $w -PassThru
    $script:gpid = $p.Id
    # send.ps1 checks this pid (start.log) to fail fast when the game dies
    Add-Content "$cd\start.log" "[client $(Get-Date -f HH:mm:ss)] pid $($p.Id) dir $cd (restart $label)"
    & "$t\wait-state.ps1" -State 1 -Dir $cd -TimeoutSec 120 | Select-Object -Last 1 | ForEach-Object { "  guest restarted ($label): $_" }
    "  load: " + (Send $cd "FindFirstOf('BP_SaveGameManager_C'):UserLoadGame(1, 1, 0) return 'UserLoadGame(1, 1, 0) called'")
    & "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { "  guest loaded ($label): $_" }
    Start-Sleep 12 # the CoopSync mod completes the car ~6 s after the garage entry
}
"=== 4. restart the guest and load its save"
$script:gpid = [int](($log | Select-String '\[client [0-9:]+\] pid (\d+)' | Select-Object -First 1).Matches.Groups[1].Value)
RestartGuest "1st"
$loaded = KV (Send $cd "$run return Run.where()")
Check "guest's own save loads into its garage with its own seed" ($loaded.state -eq '4' -and $loaded.world -eq 'RB_Garage' -and $loaded.seed -eq "$GuestSeed") $loaded.raw
$inv = Send $cd "$run return Run.inventory()"
$l = Items $inv
if ($Outcome -eq 'death') {
    Check "the reload shows the inventory the guest came home with after dying" ($inv -eq $atHome) "at home: $atHome | loaded: $inv"
} else {
    $kept = @($pickedNames | Where-Object { [int]$l[$_] -ge [int]$a[$_] })
    Check "the items picked up in the host's zone are still in the guest's inventory after the reload" ($pickedNames.Count -ge 1 -and $kept.Count -eq $pickedNames.Count) "picked: $($pickedNames -join ',') | loaded inventory: $inv"
}
"  guest car after the reload: " + (Send $cd "$run return Run.carState('$(P $cd)/car-loaded.txt')")
$d2 = CarDiff "$cd\car-loaded.txt"
Check "the guest's own car is unchanged after the reload too" ($d2.Before -gt 0 -and $d2.Gone.Count -eq 0 -and $d2.New.Count -eq 0) "items before $($d2.Before), after $($d2.After), changed $($d2.Gone.Count)/$($d2.New.Count)"
ShowDiff $d2
"  car insurance: " + (Send $cd "$run return Run.lastRestore()") + " | record: " + (Send $cd "$run return Run.insured()")
Check "the insurance record stays armed until the guest drives out again (the game re-takes the lost parts on every load)" ((Send $cd "$run return Run.insured()") -eq 'armed') (Send $cd "$run return Run.lastRestore()")

"=== 5. restart + load once more: the completed car stays"
RestartGuest "2nd"
"  guest car after the 2nd reload: " + (Send $cd "$run return Run.carState('$(P $cd)/car-loaded2.txt')")
$d3 = CarDiff "$cd\car-loaded2.txt"
Check "the guest's own car is complete after a second reload" ($d3.Before -gt 0 -and $d3.Gone.Count -eq 0 -and $d3.New.Count -eq 0) "items before $($d3.Before), after $($d3.After), changed $($d3.Gone.Count)/$($d3.New.Count)"
ShowDiff $d3

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
