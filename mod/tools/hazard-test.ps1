# Automated "hazards go off through the host" test (two headless instances over the relays).
# Host: copy of the owner's save (a zone with hundreds of landmines); guest joins. State sync on both.
#   1. a mine the guest sets off (StartExplode on its copy, as stepping on it does) goes off on the host too
#      (BOOM request) and the guest does not put it back (no hazard respawn)
#   2. a mine the host sets off goes off on the guest too (X event)
param([switch]$Keep, [int]$GuestSeed = 777, [string]$HostSave = "C:\PacificDriveCoop\local\advsave\odsave9.sav", [int]$HostSlot = 9)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 1. host in its run (owner's save copy), the guest joins"
$log = & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin -GuestSeed $GuestSeed -HostSave $HostSave -HostSlot $HostSlot
$log | Select-String 'arrived|matched on client'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
$hchan = $sess.hchan; $cchan = $sess.cchan
"host: " + (Send $hd "$lib return CoopSyncState.start(CoopSync, 'host', '$(P $hchan)', '$(P $hd)/spawnlist.tsv')")
"client: " + (Send $cd "$lib return CoopSyncState.start(CoopSync, 'client', '$(P $cchan)', '$(P "$cchan\inbox\host-spawnlist.tsv")')")
Start-Sleep 8

# two mapped landmines far apart from each other (one goes off per step, no chain reaction between them)
$pick = Send $cd @'
local mines = {}
for key, path in pairs(CoopSyncMap or {}) do
    -- by class: in a zone restored from a save the actor names are GUIDs
    local a = CoopSync.deref(path)
    if a and CoopSync.clsName(a):find("^BP_Hazard_Landmine") then mines[#mines + 1] = { key = key, l = a:K2_GetActorLocation() } end
end
if #mines < 2 then return "mines=" .. #mines end
local a, b = mines[1], nil
for i = 2, #mines do
    local m = mines[i]
    if (m.l.X - a.l.X) ^ 2 + (m.l.Y - a.l.Y) ^ 2 > 10000 ^ 2 then b = m break end
end
b = b or mines[#mines]
return "mines=" .. #mines .. " a=" .. a.key .. " b=" .. b.key
'@
"  picked: $pick"
$m = KV $pick
Check "the guest has mapped landmines to test with" ([int]$m.mines -ge 2) $pick

"=== 2. the guest sets off mine A"
"  client: " + (Send $cd "local a = CoopSync.deref(CoopSyncMap['$($m.a)']) a:StartExplode() return 'StartExplode called'")
Start-Sleep 10
$hostA = Send $hd "local a = CoopSync.deref('$($m.a)') return a and 'alive' or 'gone'"
$hr = Send $hd "return CoopSyncState.report()"
$cr = Send $cd "return CoopSyncState.report()"
$clientA = Send $cd "local p = CoopSyncMap['$($m.a)'] local a = p and CoopSync.deref(p) return a and 'alive' or 'gone'"
Check "the host's mine A went off too (BOOM)" ($hostA -eq 'gone' -and $hr -match 'req_BOOM_done=1') "host mine A: $hostA | host: $hr"
# (other mines may be put back: the blast took neighbours on the guest that the host still has)
Check "the guest did not put mine A back" ($clientA -eq 'gone') "client mine A: $clientA | client: $cr"

"=== 3. the host sets off mine B"
"  host: " + (Send $hd "local a = CoopSync.deref('$($m.b)') a:StartExplode() return 'StartExplode called'")
Start-Sleep 10
$cr = Send $cd "return CoopSyncState.report()"
$clientB = Send $cd "local p = CoopSyncMap['$($m.b)'] local a = p and CoopSync.deref(p) return a and 'alive' or 'gone'"
# (ap_X can be more than 1: the host's chain reaction sends X for each neighbour it took)
Check "the guest's mine B went off too (X)" ($cr -match 'ap_X=[1-9]' -and $clientB -eq 'gone') "client mine B: $clientB | client: $cr"

"=== 4. both have the same landmines afterwards"
Start-Sleep 8
$mineCode = "local n = 0 for _, c in ipairs({'BP_Hazard_Landmine_C','BP_Hazard_Landmine_Electric_C'}) do for _, a in ipairs(FindAllOf(c) or {}) do if CoopSyncUsable(a) and a:GetFullName():find(':PersistentLevel.', 1, true) and not CoopSync.inPool(a) then local l = a:K2_GetActorLocation() if not (l.X == 0 and l.Y == 0) then n = n + 1 end end end end return 'mines=' .. n"
$hm = KV (Send $hd $mineCode); $cm = KV (Send $cd $mineCode)
Check "the guest has as many landmines as the host" ($hm.mines -and $hm.mines -eq $cm.mines) "host $($hm.raw) | client $($cm.raw)"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
