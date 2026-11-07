# Automated "the exit home opens for both" test (owner, alpha 18 item 40: "the host opened the exit: not opened on the
# guest, the instability did not start closing"). Host: copy of the owner's save (a zone with exit portals); guest
# joins. State sync on both.
#   1. both have the same exit portals (spawn list)
#   2. the guest picks portal A: the host's storm manager picks the same portal, the closing storm spawns at it on both
#   3. the host picks portal B: the guest follows
# The pick is the end of the ARC's exit selection (the storm manager's "Select Exit Portal Actor").
param([switch]$Keep, [int]$GuestSeed = 777, [string]$HostSave = "C:\PacificDriveCoop\local\advsave\odsave9.sav", [int]$HostSlot = 9)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
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

# portals on this side: "<x>,<y>" sorted, and the picked exit / storm
$plist = "local o = {} for _, p in ipairs(FindAllOf('BP_LevelTransition_ExitPortal_C') or {}) do if p:IsValid() then local l = p:K2_GetActorLocation() o[#o + 1] = string.format('%.0f,%.0f', l.X, l.Y) end end table.sort(o) return #o .. ' ' .. table.concat(o, ' ')"
$st = "local m = FindFirstOf('BP_StormManager_C') local x = m.EvolvedGatewayExit local s = m.SpawnedStormIfValid local function at(a) if not (a and a:IsValid()) then return '-' end local l = a:K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y) end return 'exit=' .. at(x) .. ' storm=' .. at(s) .. ' state=' .. tostring(m.CurrentStormState)"
$hp = Send $hd $plist; $cp = Send $cd $plist
Check "both have the same exit portals" ($hp -eq $cp -and [int](($hp -split ' ')[0]) -ge 2) "host: $hp | guest: $cp"
# (2 of 3 full-suite runs on 2026-11-03 had 2 more on the guest at 0,0: their names, and whether they stay)
$pnames = "local o = {} for _, p in ipairs(FindAllOf('BP_LevelTransition_ExitPortal_C') or {}) do if p:IsValid() then local l = p:K2_GetActorLocation() o[#o + 1] = string.format('%s@%.0f,%.0f,%.0f', p:GetFName():ToString(), l.X, l.Y, l.Z) end end return table.concat(o, ' ')"
if ($hp -ne $cp) { "  guest portals: " + (Send $cd $pnames) }
$pick = Send $cd "local o = {} for key, path in pairs(CoopSyncMap or {}) do local a = CoopSync.deref(path) if a and CoopSync.clsName(a) == 'BP_LevelTransition_ExitPortal_C' then o[#o + 1] = key end end table.sort(o) return #o .. ' ' .. table.concat(o, ' ')"
$n, $ka, $kb = $pick -split ' '
$sel = "local m = FindFirstOf('BP_StormManager_C') local p = CoopSync.deref(PATH) m['Select Exit Portal Actor'](m, p) local l = p:K2_GetActorLocation() return string.format('picked %.0f,%.0f', l.X, l.Y)"
function Loc($s) { if ($s -match 'picked (\S+)') { $Matches[1] } }

"=== 2. the guest picks exit A"
$r = Send $cd ($sel.Replace('PATH', "CoopSyncMap['$ka']")); "  guest: $r"; $a = Loc $r
Start-Sleep 20
$h = Send $hd $st; $c = Send $cd $st; $hr = Send $hd "return CoopSyncState.report()"
Check "the host picked the same exit (EXIT)" ($h -match "exit=$a " -and $hr -match 'req_EXIT_done=1') "host: $h | host: $hr"
Check "the closing storm spawned at it on both" ($h -match "storm=$a " -and $c -match "storm=$a ") "host: $h | guest: $c"

"=== 3. the host picks exit B"
$r = Send $hd ($sel.Replace('PATH', "'$kb'")); "  host: $r"; $b = Loc $r
Start-Sleep 8
$h = Send $hd $st; $c = Send $cd $st; $cr = Send $cd "return CoopSyncState.report()"
Check "the guest follows the host's pick (no echo back)" ($c -match "exit=$b " -and $h -match "exit=$b " -and $cr -match 'ap_EXIT=1' -and $cr -notmatch 'rq_EXIT=[2-9]') "host: $h | guest: $c | guest: $cr"

if ($hp -ne $cp) { "  guest portals at the end: " + (Send $cd $pnames) }
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
