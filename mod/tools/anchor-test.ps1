# Automated "anchors are taken for both" test (owner, alpha 18 item 39: "the guest took an anchor - not taken on the
# host (duplicated)"). Host: copy of the owner's save (a zone with anchors); guest joins. State sync on both.
#   1. the guest grabs anchor A on its copy: the host's anchor A is taken too (GRAB), nobody on the host gets an item
#   2. the host grabs anchor B: the guest's copy is taken too (U R|1)
#   (then the ARC deposits, and the fuel barrels: item 37)
# The grab is the game's own end of a long grab ("Long Grab Complete", the player standing at it).
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

# an anchor's state on this side: got (SuccessfullyGrabbed) and how many anchor items exist (the spawners' own ones
# plus any a player holds)
$st = "local function st(p) local a = CoopSync.deref(p) if not a then return 'gone' end return tostring(a.SuccessfullyGrabbed) end local items = 0 for _, i in ipairs(FindAllOf('ItemInstance') or {}) do if i:IsValid() and i:GetFName():ToString():find('^IA_Resource_Anchor') then items = items + 1 end end"
$pick = Send $cd "local o = {} for key, path in pairs(CoopSyncMap or {}) do local a = CoopSync.deref(path) if a and CoopSync.clsName(a):find('^BP_Spawn_Anchor_') then o[#o + 1] = key end end table.sort(o) return #o .. ' ' .. table.concat(o, ' ')"
"  anchors: $pick"
$n, $ka, $kb = $pick -split ' '
Check "the guest has two mapped anchors to test with" ([int]$n -ge 2) $pick
$grab = "local a = CoopSync.deref(PATH) local p = FindFirstOf('PlayerController').Pawn local l = a:K2_GetActorLocation() p:K2_SetActorLocation({ X = l.X + 150, Y = l.Y, Z = l.Z + 100 }, false, {}, true) a['Long Grab Complete'](a) return 'grabbed: ' .. tostring(a.SuccessfullyGrabbed)"
$hItems0 = Send $hd "$st return items"

"=== 2. the guest grabs anchor A"
"  client: " + (Send $cd ($grab.Replace('PATH', "CoopSyncMap['$ka']")))
Start-Sleep 6
$h = Send $hd "$st return st('$ka') .. ' items=' .. items"
$c = Send $cd "$st return st(CoopSyncMap['$ka'])"
$hr = Send $hd "return CoopSyncState.report()"
Check "the host's anchor A is taken too (GRAB)" ($h -match '^true' -and $hr -match 'req_GRAB_done=1') "host A: $h | client A: $c | host: $hr"
Check "nobody on the host got an anchor item from it" ($h -match "items=$hItems0$") "host items before $hItems0, now: $h"

"=== 3. the host grabs anchor B"
"  host: " + (Send $hd ($grab.Replace('PATH', "'$kb'")))
Start-Sleep 6
$c = Send $cd "$st return st(CoopSyncMap['$kb'])"
$cr = Send $cd "return CoopSyncState.report()"
Check "the guest's anchor B is taken too (U R|1)" ($c -eq 'true') "client B: $c | client: $cr"
Start-Sleep 4
$c = Send $cd "$st return st(CoopSyncMap['$ka']) .. '/' .. st(CoopSyncMap['$kb'])"
$h = Send $hd "$st return st('$ka') .. '/' .. st('$kb')"
Check "both anchors stay taken on both sides (no revert)" ($c -eq 'true/true' -and $h -eq 'true/true') "host $h | client $c"

"=== 4. anchors into the ARC (the Gobbler): a deposit on one side charges the other side's ARC too"
# (the deposit's end, the game's AddingAnchorCompleteLogic with a new anchor of the zone's kind)
$chg = "local s = FindFirstOf('BP_Carpart_Internal_GobblerScreen_C') local a, b = {}, {} s:GetAnchorCharge(a, b) return string.format('%.3f', a.CurrentCharge)"
$dep = "local L = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/lootsync.lua') local arch = FindFirstOf('BP_Spawn_Anchor_Unstable_M_C').ItemToGrab:GetFullName():gsub('^%S+ ', '') local g = FindFirstOf('BP_Carpart_Internal_Gobbler_C') g:AddingAnchorCompleteLogic(L.newItem(arch)) return 'deposited ' .. arch:match('[^.]+$')"
$h0 = [double](Send $hd $chg); $c0 = [double](Send $cd $chg)
"  guest: " + (Send $cd $dep)
Start-Sleep 4
$h1 = [double](Send $hd $chg); $c1 = [double](Send $cd $chg)
$hr = Send $hd "return CoopSyncState.report()"
# (an anchor's charge is rolled per anchor: the other side's repeat charges about as much, not exactly)
Check "the guest's deposit charged its ARC and the host's too" (($c1 - $c0) -gt 0.1 -and ($h1 - $h0) -gt 0.1 -and $hr -match 'req_GOB_done=1') "host $h0 -> $h1 | guest $c0 -> $c1 | host: $hr"
"  host: " + (Send $hd $dep)
Start-Sleep 4
$h2 = [double](Send $hd $chg); $c2 = [double](Send $cd $chg)
$cr = Send $cd "return CoopSyncState.report()"
Check "the host's deposit charged the guest's ARC too, once (no echo of the guest's)" (($h2 - $h1) -gt 0.1 -and ($c2 - $c1) -gt 0.1 -and $cr -match 'ap_GOB=1' -and $hr -notmatch 'ev_GOB') "host $h1 -> $h2 | guest $c1 -> $c2 | guest: $cr"

"=== 5. fuel barrels (item 37: a barrel's level differed): both start at the host's level, a change goes both ways"
$fu = "local o = {} for _, a in ipairs(FindAllOf('BP_Spawn_GasBarrel_C') or {}) do local t = { {}, {}, {}, {}, {}, {}, {} } if not a.BP_FuelableComponent:IsValid() then local l = a:K2_GetActorLocation() o[#o + 1] = string.format('%.0f,%.0f=no-fuel-component:%s', l.X, l.Y, a:GetFullName()) goto next end a.BP_FuelableComponent:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7]) local l = a:K2_GetActorLocation() o[#o + 1] = string.format('%.0f,%.0f=%.2f', l.X, l.Y, t[1].Fuel) ::next:: end table.sort(o) return table.concat(o, ' ')"
$setF = "local a = FindAllOf('BP_Spawn_GasBarrel_C')[1] local fc = a.BP_FuelableComponent fc['Set Fuel'](fc, VAL) return 'set VAL'"
Start-Sleep 2
$h = Send $hd $fu; $c = Send $cd $fu
Check "the barrels' fuel is the host's on the guest" ($h -and $h -eq $c) "host: $h | guest: $c"
"  host: " + (Send $hd $setF.Replace('VAL', '1.25'))
Start-Sleep 4
$h = Send $hd $fu; $c = Send $cd $fu
Check "the host's change reached the guest" ($h -match '=1\.25' -and $h -eq $c) "host: $h | guest: $c"
"  guest: " + (Send $cd $setF.Replace('VAL', '0.5'))
Start-Sleep 4
$h = Send $hd $fu; $c = Send $cd $fu; $hr = Send $hd "return CoopSyncState.report()"
Check "the guest's change reached the host" ($c -match '=0\.50' -and $h -eq $c -and $hr -match 'req_FUEL_done=') "host: $h | guest: $c | host: $hr"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
