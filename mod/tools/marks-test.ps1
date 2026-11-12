# Map marks (alpha 22 item 4, owner: "the other player green; each one's own marks seen by both, one's own blue, the
# other's green"). marksync.lua on both sides of cars-test's pair (-Reuse: one already set up by cars-test -SetupOnly):
#   1. the other's car (the twin) green on the map, the own car the game's blue - on both sides
#   2. a host waypoint (the game's BP_WaypointActor_C) comes to the guest as a green one at its spot; the host's stays
#      its own color; a guest waypoint likewise to the host
#   3. the host's waypoint moved -> the guest's copy at the new spot; removed -> the guest's copy gone
#   4. the game takes a green one for its own (UMG_GobblerScreen.FindExistingWaypoint did: the player's next pin moves
#      it): moved on the guest -> let go (its color back), sent as the guest's; the host's mark comes back green
#   5. stop: the other's marks gone
param([switch]$Keep, [switch]$Reuse)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
if (-not $Reuse) { & "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 3 }
$mk = "C:/PacificDriveCoop/mod/CoopSync/Scripts/marksync.lua"
# icon colors: own car, twin(s); waypoints: own (o) / the other's (r), each x,y and green or not
$cars = "local own = FindFirstOf('BP_CarManager_C').NewCarActor local o = {} for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() then local k = c:GetAddress() == own:GetAddress() and 'own' or 'twin' local col = c.MapIcon.IconDrawColor o[#o + 1] = string.format('%s=%.2f/%.2f/%.2f', k, col.R, col.G, col.B) end end return table.concat(o, ' ')"
$wps = "local o = {} for _, a in ipairs(FindAllOf('BP_WaypointActor_C') or {}) do if a:IsValid() then local l, col = a:K2_GetActorLocation(), a.MapIcon.IconDrawColor if l.X ~= 0 or l.Y ~= 0 or l.Z ~= 0 then o[#o + 1] = string.format('%.0f,%.0f:%s', l.X, l.Y, (col.G > 0.9 and col.R < 0.2) and 'green' or 'own') end end end table.sort(o) return #o .. ' ' .. table.concat(o, ';') .. ' | ' .. CoopSyncMarks.info()"
$place = "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') local KML = StaticFindObject('/Script/Engine.Default__KismetMathLibrary') local c = StaticFindObject('/Game/UI/CarEquipment/Internal/Gobbler/BP_WaypointActor.BP_WaypointActor_C') local p = FindFirstOf('BP_CarManager_C').NewCarActor:K2_GetActorLocation() local l = { X = p.X + MK_DX, Y = p.Y + MK_DY, Z = p.Z } local xf = KML:MakeTransform(l, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }) local a = GS:FinishSpawningActor(GS:BeginDeferredActorSpawnFromClass(FindFirstOf('PlayerController'), c, xf, 1, nil), xf) MK_MINE = a return string.format('placed %.0f,%.0f', l.X, l.Y)"
function Green($s) { ([regex]::Matches(($s -split ' \| ')[0], ':green')).Count }
function Own($s) { ([regex]::Matches(($s -split ' \| ')[0], ':own')).Count }

"=== 0. marks on both"
"  host: " + (Send $hd "CoopSyncMarks = nil local M = dofile('$mk') return M.start(CoopPlayers, 'host')")
"  guest: " + (Send $cd "CoopSyncMarks = nil local M = dofile('$mk') return M.start(CoopPlayers, 'client')")

"=== 1. the other's car green, the own blue"
foreach ($s in @(@{ n = 'host'; d = $hd }, @{ n = 'guest'; d = $cd })) {
    Send $s.d "local own = FindFirstOf('BP_CarManager_C').NewCarActor for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c:GetAddress() ~= own:GetAddress() then CoopSyncMarks.paintTwin(c) end end return 'ok'" | Out-Null
    $c = Send $s.d $cars
    Check "$($s.n): the twin green, the own car blue" ($c -match 'twin=0\.10/1\.00/0\.20' -and $c -match 'own=0\.04/0\.15/0\.46') $c
}

"=== 2. a mark each way"
"  host: " + (Send $hd "MK_DX = 3000 MK_DY = 0 $place")
Start-Sleep 3
$g = Send $cd $wps; $h = Send $hd $wps
Check "the host's mark came to the guest, green" ((Green $g) -eq 1 -and (Own $g) -eq 0) "guest: $g"
Check "the host's own stays its own color" ((Own $h) -eq 1 -and (Green $h) -eq 0) "host: $h"
"  guest: " + (Send $cd "MK_DX = -3000 MK_DY = 1000 $place")
Start-Sleep 3
$g = Send $cd $wps; $h = Send $hd $wps
Check "the guest's mark came to the host, green; each sees both" ((Green $h) -eq 1 -and (Own $h) -eq 1 -and (Green $g) -eq 1 -and (Own $g) -eq 1) "host: $h | guest: $g"

"=== 3. the host's mark moved, then removed"
"  host moves it: " + (Send $hd "local l = MK_MINE:K2_GetActorLocation() MK_MINE:K2_SetActorLocation({ X = l.X + 2000, Y = l.Y, Z = l.Z }, false, {}, true) local n = MK_MINE:K2_GetActorLocation() return string.format('%.0f,%.0f', n.X, n.Y)")
$hl = Send $hd "local l = MK_MINE:K2_GetActorLocation() return string.format('%.0f,%.0f', l.X, l.Y)"
Start-Sleep 3
$g = Send $cd $wps
Check "the guest's copy at the new spot" ($g -match [regex]::Escape($hl) + ':green' -and (Green $g) -eq 1) "host's at $hl | guest: $g"
"  host removes it: " + (Send $hd "MK_MINE:K2_DestroyActor() return 'gone'")
Start-Sleep 3
$g = Send $cd $wps
Check "the guest's copy gone, its own kept" ((Green $g) -eq 0 -and (Own $g) -eq 1) "guest: $g"

"=== 4. the game takes a green one (moved on the guest)"
"  host: " + (Send $hd "MK_DX = 3000 MK_DY = -1500 $place")
Start-Sleep 3
"  guest's game moves the green one: " + (Send $cd "for _, a in ipairs(FindAllOf('BP_WaypointActor_C') or {}) do if a:IsValid() and a:K2_GetActorLocation().X ~= 0 and a.MapIcon.IconDrawColor.G > 0.9 and a.MapIcon.IconDrawColor.R < 0.2 then local l = a:K2_GetActorLocation() a:K2_SetActorLocation({ X = l.X, Y = l.Y + 5000, Z = l.Z }, false, {}, true) return 'moved' end end return 'none green'")
Start-Sleep 4
$g = Send $cd $wps; $h = Send $hd $wps
Check "guest: the taken one its own (color back), the host's mark green again" ((Own $g) -eq 2 -and (Green $g) -eq 1 -and $g -match 'taken=1') "guest: $g"
Check "host: its own mark + the guest's two green" ((Own $h) -eq 1 -and (Green $h) -eq 2) "host: $h"

"=== 5. stop: the other's marks gone"
Send $hd "CoopSyncMarks.stop() return 'stopped'" | Out-Null
$h = Send $hd $wps
Check "host: only its own left" ((Green $h) -eq 0 -and (Own $h) -eq 1) "host: $h"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
