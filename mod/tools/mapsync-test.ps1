# The host's garage map at the guest (mapsync.lua via session.lua), two headless instances from the advanced save
# (local/advsave, copied) sent home to their garages (their maps differ: the trip home rerolls the conditions),
# CoopNet over the local TCP link:
#   1. the lobby forms: the guest's route map becomes the host's (rows equal: legs, modifiers, whiteboards);
#   2. the host scans junctions: the guest's map follows;
#   3. the guest leaves the lobby: its own map is back (rows equal to before the lobby);
#   4. the guest drives out on its own: the backup of its map is dropped (that departure saved its own map).
# Also the garage sky: in the lobby the guest's garage gets the host's time of day and weather (weathersync).
param([switch]$Keep, [switch]$NetExe, [int]$Port = 47831, [string]$Save = "C:\PacificDriveCoop\local\advsave\odsave9.sav")
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$map = "Map = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/mapsync.lua')"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Status($chan) { KV ((Get-Content "$chan\status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]) }
function MapN($chan, [int]$i) { $m = (Status $chan).map; if ($m) { [int](($m -split '/')[$i]) } else { 0 } }
function WaitMap($chan, [int]$i, [int]$atLeast, [int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $end) { if ((MapN $chan $i) -ge $atLeast) { return $true }; Start-Sleep 2 }
    $false
}
function NetCtl($chan, [string]$line) { Add-Content "$chan\net-control.txt" $line -Encoding ascii }
# the rows of a game's route map into a file (the same export the host sends)
function Rows($dir, [string]$file) { Send $dir "$map return tostring(Map.export('$($file.Replace('\', '/'))', true))" | Out-Null; Get-Content $file }
function Same($a, $b) { $d = @(Compare-Object $a $b); @{ ok = ($d.Count -eq 0 -and $a.Count -gt 100); n = $d.Count; first = ($d | Select-Object -First 2 | ForEach-Object { "$($_.SideIndicator) $("$($_.InputObject)".Substring(0, [Math]::Min(120, "$($_.InputObject)".Length)))" }) -join ' | ' } }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-m$runId"; $cchan = "$inst\client\chan-m$runId"; $tmp = "$inst\host\maptest-$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox", $tmp | Out-Null
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
# the guest's own map made surely different: other junctions scanned than the host will scan
"  guest: " + (Send $cd "$map local n = 0 Map.route().LegStates:ForEach(function(k, v) local key = k:get():GetFName():ToString() if key == 'RouteShapeLeg_2' or key == 'RouteShapeLeg_10' then v:get():RevealLeg(2, false) n = n + 1 end end) return 'scanned ' .. n .. ' ' .. Map.summary()")
$own = Rows $cd "$tmp\guest-own.tsv"
$host0 = Rows $hd "$tmp\host-0.tsv"
$d = Same $own $host0
Check "the maps differ before the lobby (a real test)" (-not $d.ok -and $d.n -gt 0) "$($d.n) different rows"

$tod = "local m = FindFirstOf('BP_ToDManager_C') local t = {} m['Get Current Time Of Day'](m, t) return string.format('tod=%.4f', t['Returned Time Of Day'])"
function Tod($dir) { $r = Send $dir $tod; if ($r -match 'tod=([\d.]+)') { [double]$Matches[1] } else { -1 } }
"  guest: " + (Send $cd "local m = FindFirstOf('BP_ToDManager_C') local t = {} m['Get Current Time Of Day'](m, t) local x = (t['Returned Time Of Day'] + 0.4) % 1 m['Set Current Time Of Day'](m, x) return 'tod set to ' .. x")
$th = Tod $hd; $tg = Tod $cd
Check "the garages' clocks differ before the lobby" ([Math]::Min([Math]::Abs($th - $tg), 1 - [Math]::Abs($th - $tg)) -gt 0.1) "host $th guest $tg"

"=== 1. the lobby forms: the guest gets the host's map"
NetCtl $hchan 'create'; Start-Sleep 2
NetCtl $cchan 'join 1'
$ok = WaitMap $cchan 1 1 90
$g = Rows $cd "$tmp\guest-1.tsv"; $h = Rows $hd "$tmp\host-1.tsv"; $d = Same $g $h
Check "the guest's map is the host's" ($ok -and $d.ok) "applied=$ok diff=$($d.n) $($d.first) | host: $((Status $hchan).raw) | guest: $((Status $cchan).raw)"
Check "the guest's own map is kept (backup)" (Test-Path "$cchan\map-backup.tsv") ""
Start-Sleep 6
$th = Tod $hd; $tg = Tod $cd; $w = (Status $cchan).weather
Check "the guest's garage has the host's time of day and weather" ([Math]::Min([Math]::Abs($th - $tg), 1 - [Math]::Abs($th - $tg)) -lt 0.003 -and [int](($w -split '/')[1]) -ge 1) "host $th guest $tg weather(sent/applied) host $((Status $hchan).weather) guest $w"

# the guest's map is look only (owner, alpha 18: the guest could still pick a junction): with the map open, the guest's
# junction nodes have no click bindings left, the host's keep theirs
$openMap = "local p = FindFirstOf('BP_ProgressionManager_C') p['Open Map UI'](p) return 'map opened'"
$nodes = "local n, b = 0, 0 for _, w in ipairs(FindAllOf('UMG_PlannerInteraction_Base_C') or {}) do if w:IsValid() and w:GetFullName():find('/Engine/Transient', 1, true) then n = n + 1 b = b + #(w.OnPlannerInteractionClicked:GetBindings() or {}) end end return string.format('nodes=%d bound=%d', n, b)"
"  host: " + (Send $hd $openMap); "  guest: " + (Send $cd $openMap)
Start-Sleep 6
$hn = KV (Send $hd $nodes); $gn = KV (Send $cd $nodes)
Check "the guest's map takes no junction clicks, the host's does" ([int]$gn.nodes -gt 0 -and [int]$gn.bound -eq 0 -and [int]$hn.bound -gt 0 -and [int]((Status $cchan).mapblock) -gt 0) "host: $($hn.raw) | guest: $($gn.raw) mapblock=$((Status $cchan).mapblock)"
Send $hd "pcall(function() FindFirstOf('BP_ProgressionManager_C'):CloseMapUI() end) return 'closed'" | Out-Null
Send $cd "pcall(function() FindFirstOf('BP_ProgressionManager_C'):CloseMapUI() end) return 'closed'" | Out-Null

"=== 2. the host scans junctions"
$scan = Send $hd "$map local n = 0 Map.route().LegStates:ForEach(function(k, v) local key = k:get():GetFName():ToString() if key == 'RouteShapeLeg_1' or key == 'RouteShapeLeg_5' or key == 'RouteShapeLeg_7' then v:get():RevealLeg(2, false) n = n + 1 end end) return 'scanned ' .. n .. ' ' .. Map.summary()"
"  host: $scan"
$ok = WaitMap $cchan 1 2 60
# (the second map applied may be one the host sent before its scans were in: the rows are compared until they match,
# 30 s at most)
$end = (Get-Date).AddSeconds(30)
do {
    Start-Sleep 2
    $g = Rows $cd "$tmp\guest-2.tsv"; $h = Rows $hd "$tmp\host-2.tsv"; $d = Same $g $h
} while (-not $d.ok -and (Get-Date) -lt $end)
Check "the host's scans reach the guest's map" ($ok -and $d.ok -and ($g -match "`t2`t").Count -ge 3) "applied=$ok diff=$($d.n) $($d.first) | guest $(Send $cd "$map return Map.summary()")"

"=== 3. the guest leaves the lobby: its own map back"
NetCtl $cchan 'leave'
$ok = WaitMap $cchan 2 1 60
Start-Sleep 2
$g = Rows $cd "$tmp\guest-3.tsv"; $d = Same $g $own
Check "the guest's own map is back" ($ok -and $d.ok) "restored=$ok diff=$($d.n) $($d.first) | $((Status $cchan).raw)"
$ev = Send $cd "local d = FindFirstOf('BP_ToDDirector_C') local ok, p = pcall(function() return d.bWeatherEventsPaused end) local m = FindFirstOf('BP_ToDManager_C') return 'paused=' .. tostring(ok and p)"
"  guest after leaving: $ev"

"=== 4. the guest drives out on its own: the backup goes"
Send $cd 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
& "$t\wait-state.ps1" -State 5 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Check "the backup is dropped at the guest's own departure" (-not (Test-Path "$cchan\map-backup.tsv")) ""

"=== 5. after its own run the guest comes home and joins again: the host's map again"
"  guest: " + (Send $cd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Start-Sleep 5
$applied = MapN $cchan 1
NetCtl $cchan 'join 1'
$ok = WaitMap $cchan 1 ($applied + 1) 90
Start-Sleep 2
$g = Rows $cd "$tmp\guest-5.tsv"; $h = Rows $hd "$tmp\host-5.tsv"; $d = Same $g $h
Check "after a run of its own the guest gets the host's map again" ($ok -and $d.ok) "applied=$ok diff=$($d.n) $($d.first) | guest: $((Status $cchan).raw)"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    NetExeStop
}
