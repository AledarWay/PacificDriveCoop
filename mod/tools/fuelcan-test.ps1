# Fuel canisters on the ground (owner, 2026-11-09: "I dropped a full canister, the friend's was empty"): the fuel of a
# canister put down on one side is the same on the other (statesync FUEL for BP_WorldItem_Fuelable_C, DROP's fuel).
#   1. the host puts one down with fuel A -> the guest's copy has A
#   2. the guest puts a carried one down with fuel B -> the host's (the one it spawned for the drop) has B
#   3. the host's level changes (C) -> the guest's follows
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function Share($dir, [string]$role, [string]$code) { Send $dir "LS_ROLE = '$role' $code return dofile('$(P $t)/cmds/loot-share.lua')" }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Near($dir, $at) { Share $dir '' "LS_OP = 'fuelnear' LS_ARCH = '$can' LS_X = $($at[0]) LS_Y = $($at[1]) LS_Z = $($at[2])" }
function Same($a, $b) {
    $x = 0.0; $y = 0.0; $inv = [Globalization.CultureInfo]::InvariantCulture; $f = [Globalization.NumberStyles]::Float
    [double]::TryParse("$a", $f, $inv, [ref]$x) -and [double]::TryParse("$b", $f, $inv, [ref]$y) -and [math]::Abs($x - $y) -lt 0.02
}
function At($s) { if ($s -match 'dropped at (-?\d+),(-?\d+),(-?\d+)') { @($Matches[1], $Matches[2], $Matches[3]) } else { @(0, 0, 0) } }
$can = '/Game/Gameplay/Inventory/Items/Tools/FuelCan/IA_Tool_Target_FuelCan.IA_Tool_Target_FuelCan'

& "$t\sync-test.ps1" -KeepHost -KeepClient -Net | Select-String 'net:|network|import:|matched on client|^PASS|^FAIL|LOOT P|LOOT F'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"=== start sync (state + players)"
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $cchan)')")
Start-Sleep 8

"=== 1. the host puts a canister down with 3.5 in it"
$d1 = Share $hd 'host' "LS_OP = 'dropfuel' LS_ARCH = '$can' LS_FUEL = 3.5"
"  host: $d1"
$at1 = At $d1
Start-Sleep 12
$h1 = Near $hd $at1; $c1 = Near $cd $at1
Check "the guest's copy has the host's fuel" ((Same $h1 '3.5') -and (Same $c1 $h1)) "host $h1 | guest $c1 | guest: $(Send $cd 'return CoopSyncState.report()')"

"=== 2. the guest puts a carried canister down with 1.75 in it"
"  guest gets one: " + (Share $cd 'client' "LS_OP = 'give' LS_ARCH = '$can'")
Start-Sleep 4
$d2 = Share $cd 'client' "LS_OP = 'dropfuel' LS_ARCH = '$can' LS_FUEL = 1.75 LS_DX = 120"
"  guest: $d2"
$at2 = At $d2
Start-Sleep 12
$h2 = Near $hd $at2; $c2 = Near $cd $at2
$crep = Send $cd 'return CoopSyncState.report()'
Check "the host's has the guest's fuel (the drop asked once)" ((Same $c2 '1.75') -and (Same $h2 $c2) -and $crep -match 'rq_DROP=1\b') "host $h2 | guest $c2 | guest: $crep"

"=== 3. the host's first canister goes down to 0.5"
"  host: " + (Share $hd 'host' "LS_OP = 'setfuelnear' LS_ARCH = '$can' LS_X = $($at1[0]) LS_Y = $($at1[1]) LS_Z = $($at1[2]) LS_FUEL = 0.5")
Start-Sleep 5
$h3 = Near $hd $at1; $c3 = Near $cd $at1
Check "the guest's follows" ((Same $h3 '0.5') -and (Same $c3 '0.5')) "host $h3 | guest $c3"

"host state: " + (Send $hd "return CoopSyncState.report()")
"client state: " + (Send $cd "return CoopSyncState.report()")
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
