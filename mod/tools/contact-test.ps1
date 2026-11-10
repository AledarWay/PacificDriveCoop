# Automated test of the players' contact (two instances over the relays, own-car mode like ghostseat-test):
#   arms of the seated puppet (hands on the wheel in the driver seat, on the knees elsewhere), no driver seat in the
#   other's twin (a tap at its driver door = the door only), a back seat through a tap at its door,
#   the puppet's capsule blocks the local player, the game's kick next to the other player knocks it back.
# -Reuse: the two games are already in the zone with the sync running (pair set up by hand / an earlier -Keep).
param([switch]$Keep, [switch]$Reuse)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Dist2($a, $b) { $a = Vec $a; $b = Vec $b; [math]::Round([math]::Sqrt(($a.X - $b.X) * ($a.X - $b.X) + ($a.Y - $b.Y) * ($a.Y - $b.Y)), 1) }
function Puppet($dir) { KV (Send $dir "return CoopPlayers.puppetInfo()") }
function Ghost($dir) { KV (Send $dir "return CoopPlayers.ghostInfo()") }
function Kick($dir) { KV (Send $dir "return CoopPlayers.kickInfo()") }
function PawnAt($dir) { Send $dir "local l = FindFirstOf('PlayerController').Pawn:K2_GetActorLocation() return string.format('%.1f,%.1f,%.1f', l.X, l.Y, l.Z)" }
function InCar($dir) { Send $dir "local a = FindFirstOf('PlayerController').Pawn:GetAttachParentActor() return tostring(a ~= nil and a:IsValid())" }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# twin doors: look at door n of the other's twin until the game highlights it (as a player aims), E down, up again
# after $ms (100: a tap; 700: held - the door only)
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
function Interact($dir) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after(100, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'interact'" }
# stand outside door n of the own (real) car, look at it, press E (released after 0.3 s)
function DoorE($dir, [int]$door) {
    $look = (Get-Content "$t\cmds\look-at-door.lua" -Raw)
    "  " + (Send $dir "LOOK_DOOR = $door $look")
    Start-Sleep 2
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) Dev.after(300, function() local q = FindFirstOf('PlayerController').Pawn q['Command Interact'](q, false) end) return 'E at door $door'"
}
# put the character $d units in front of the other player's puppet, facing it
function Twin() { "local T = CoopPlayers.twinModule() local tw for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end" }
function FaceOther($dir, [double]$d) {
    Send $dir "local pc = FindFirstOf('PlayerController') local p = pc.Pawn local o = CoopPlayers.otherPawnAt() if not o then return 'no other' end local me = p:K2_GetActorLocation() local dx, dy = me.X - o.X, me.Y - o.Y local l = math.sqrt(dx * dx + dy * dy) if l < 1 then dx, dy, l = 1, 0, 1 end p:K2_SetActorLocation({ X = o.X + dx / l * $d, Y = o.Y + dy / l * $d, Z = o.Z + 20 }, false, {}, true) pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(-dy, -dx)), Roll = 0 }) return string.format('%.0f from the other', $d)"
}

if (-not $Reuse) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
    & "$t\deploy.ps1"
    "=== 0. the guest joins with its own car"
    & "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived|matched on client'
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    "  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
    Start-Sleep 3
    "host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
    "client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
    Start-Sleep 15 # the car layouts come every 10 s
}
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4

"=== 1. the host at its wheel: the guest sees its puppet seated, hands on the wheel"
"  host: " + (DoorE $hd 1); Start-Sleep 5
Check "host at its wheel" ((InCar $hd) -eq 'true') "in_car=$(InCar $hd)"
$p = Puppet $cd
Check "guest sees the host seated, hands on the wheel" ($p.state -eq 'sit' -and $p.arms -eq 'wheel' -and [double]$p.hand_fwd -gt 15 -and [double]$p.hand_out -lt 40) $p.raw

"=== 2. the guest cannot take the host's driver seat: a tap at the twin's driver door is the door only"
"  guest: " + (Tap $cd 1); Start-Sleep 4
$g = Ghost $cd
Check "guest not seated in the host's car" ($g.in_ghost -eq '-') $g.raw

"=== 3. the guest on the back seat: hands on the knees"
"  host: " + (Send $hd "return CoopPlayers.removeSeatDevice(3)")
Start-Sleep 12 # the host car's layout (device gone) reaches the guest's twin
"  guest: " + (Tap $cd 3); Start-Sleep 5
$g = Ghost $cd
Check "guest on the back left seat" ($g.in_ghost -eq 'H' -and $g.seat -eq '3') $g.raw
$p = Puppet $hd
Check "host sees the guest seated, hands on the knees" ($p.state -eq 'sit' -and $p.arms -eq 'lap' -and [double]$p.hand_knee -lt 25 -and [double]$p.hand_out -lt 40) $p.raw
Start-Sleep 3 # the entry's door shut
$d0 = KV (Send $hd "return CoopPlayers.doorInfo(3)")
# the host's door 3 sampled every 100 ms for 4 s (two fixed reads missed the open spell when the DR came late)
Send $hd "DOOR_LOG = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(100, function() local dt = os.clock() - t0 if dt > 4 then CancelDelayedAction(h) return end local o = tostring(CoopPlayers.doorInfo(3)):match('own_open=(%a+)') DOOR_LOG[#DOOR_LOG + 1] = string.format('%.1f:%s', dt, o == 'true' and 'O' or '-') end) return 'sampling'" | Out-Null
# (native cars: the game's exit - the passenger looks at its door, the ExitDoor spot moved there, and presses E)
"  guest: " + ((Send $cd ("CE_CAR = 'twin' CE_HL = 'ExitDoor' " + (Get-Content "$PSScriptRoot\cmds\car-e.lua" -Raw))) -split "`n" | Select-Object -Last 1); Start-Sleep 5
$dl = Send $hd "return table.concat(DOOR_LOG, ' ')"
$d2 = KV (Send $hd "return CoopPlayers.doorInfo(3)")
"  host door 3: $dl"
Check "the guest getting out opens the host's door 3, it shuts behind" ($d0.own_open -eq 'false' -and $dl -match ':O' -and $d2.own_open -eq 'false') "before $($d0.own_open), open while out: $($dl -match ':O'), after $($d2.own_open) | $($d2.raw)"
"  guest out: " + (Ghost $cd).in_ghost + " | host: " + (Send $hd "return CoopPlayers.botExitCar()"); Start-Sleep 4
"=== 3b. the guest on the host's back seat again: the host's door 3 still shows, opens, shuts - no way in (owner's alpha 19 item 14)"
$hBack = PawnAt $hd # (back there after: by its door 3 the guest walked into the car, not the host - step 4)
"  guest: " + (Tap $cd 3); Start-Sleep 5
$g = Ghost $cd
"  guest on seat: " + $g.in_ghost + $g.seat
"  host: " + (Send $hd "LOOK_DOOR = 3 $(Get-Content "$t\cmds\look-at-door.lua" -Raw)"); Start-Sleep 2
$hl = Send $hd "local h = FindFirstOf('BP_HighlightManager_C').CurrentHighlight return h and h:IsValid() and (h:GetFName():ToString() .. '@' .. h:GetOwner():GetClass():GetFName():ToString()) or 'none'"
"  host: " + (Interact $hd)
Start-Sleep 3
$o3 = KV (Send $hd "return CoopPlayers.doorInfo(3)")
$in3 = InCar $hd
Check "the host's door 3 of the taken seat: highlighted, opened by the host's E, the host stays outside" ($g.in_ghost -eq 'H' -and $g.seat -eq '3' -and $hl -match 'Door|Interactive' -and $o3.own_open -eq 'true' -and $in3 -eq 'false') "guest $($g.in_ghost)$($g.seat) | highlight $hl | host in car: $in3 | $($o3.raw)"
"  host shuts it: " + (Interact $hd); Start-Sleep 3
"  host door 3 open: " + (KV (Send $hd "return CoopPlayers.doorInfo(3)")).own_open
"  guest: " + ((Send $cd ("CE_CAR = 'twin' CE_HL = 'ExitDoor' " + (Get-Content "$PSScriptRoot\cmds\car-e.lua" -Raw))) -split "`n" | Select-Object -Last 1); Start-Sleep 5
"  guest out: " + (Ghost $cd).in_ghost
"  host back: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = $(($hBack -split ',')[0]), Y = $(($hBack -split ',')[1]), Z = $(($hBack -split ',')[2]) + 10 }, false, {}, true) return 'back'"); Start-Sleep 2

"=== 4. the host's character is solid for the guest"
"  guest: " + (FaceOther $cd 400); Start-Sleep 2
$before = Dist2 (PawnAt $cd) (PawnAt $hd)
"  guest: " + (Send $cd "return CoopPlayers.botWalk(4, 0.6)"); Start-Sleep 6
$after = Dist2 (PawnAt $cd) (PawnAt $hd)
$p = Puppet $cd
Check "guest walking into the host stops at its capsule" ($before -gt 300 -and $after -gt 45 -and $after -lt 150) "distance before $before, after $after; puppet: state=$($p.state)"

"=== 5. the guest kicks the host"
# (the host 5 m out from its car, the guest between them: the kick knocks the host away from the car - into it the host
# moved 53, quick suite 2026-11-10)
"  host: " + (Send $hd "local p = FindFirstOf('PlayerController').Pawn local c = CoopPlayers.twinModule().ownCar():K2_GetActorLocation() local l = p:K2_GetActorLocation() local dx, dy = l.X - c.X, l.Y - c.Y local n = math.sqrt(dx * dx + dy * dy) if n < 1 then dx, dy, n = 1, 0, 1 end p:K2_SetActorLocation({ X = c.X + dx / n * 500, Y = c.Y + dy / n * 500, Z = l.Z + 20 }, false, {}, true) return 'away from its car'")
Start-Sleep 3
$kd = Send $hd (Get-Content "$t\cmds\kick-dir.lua" -Raw)
"  host's clear way: $kd"
$kyaw = if ($kd -match '^(?:OK )?(-?\d+) ') { [int]$Matches[1] } else { 0 }
# (the guest behind the host on that way, facing it: the kick knocks the host along a flat, clear way - into the car or
# up a slope it moved 53-76 instead of ~290, quick suite 2026-11-10)
"  guest: " + (Send $cd "local pc = FindFirstOf('PlayerController') local p = pc.Pawn local o = CoopPlayers.otherPawnAt() if not o then return 'no other' end local dx, dy = math.cos(math.rad($kyaw)), math.sin(math.rad($kyaw)) p:K2_SetActorLocation({ X = o.X - dx * 110, Y = o.Y - dy * 110, Z = o.Z + 20 }, false, {}, true) pc:SetControlRotation({ Pitch = 0, Yaw = $kyaw, Roll = 0 }) return 'behind the host on its way, 110 from it'"); Start-Sleep 2
$h0 = PawnAt $hd
$hp = "local h = FindFirstOf('BP_ResourceManager_C').PlayerHealth return string.format('%.2f/%.2f', h.Current, h.Maximum)"
$hp0 = Send $hd $hp
# a timeline every 100 ms for 5 s on both sides: the host's own speed, the guest's puppet clip (owner: after a kick
# the kicked one's puppet kept walking a while, standing still)
$sampler = "KICK_LOG = {} local t0 = os.clock() local h h = LoopInGameThreadWithDelay(100, function() local dt = os.clock() - t0 if dt > 5 then CancelDelayedAction(h) return end KICK_LOG[#KICK_LOG + 1] = string.format('%.1f:%s', dt, KICK_SAMPLE()) end) return 'sampling'"
Send $hd "KICK_SAMPLE = function() local p = FindFirstOf('PlayerController').Pawn local v = p:GetVelocity() return string.format('%.0f', math.sqrt(v.X * v.X + v.Y * v.Y)) end $sampler" | Out-Null
Send $cd "KICK_SAMPLE = function() return CoopPlayers.puppetAnim() end $sampler" | Out-Null
"  guest: " + (Send $cd "return CoopPlayers.botKick()"); Start-Sleep 6
$h1 = PawnAt $hd
$kc = Kick $cd; $kh = Kick $hd
Check "the kick reaches the host and knocks it back" ([int]$kc.kicks_sent -ge 1 -and [int]$kh.kicks_taken -ge 1 -and (Dist2 $h0 $h1) -gt 80) "moved $(Dist2 $h0 $h1); guest: $($kc.raw) | host: $($kh.raw)"
$hp1 = Send $hd $hp; $c0, $mx = $hp0 -split '/'; $c1 = ($hp1 -split '/')[0]
Check "the kick took 1 % of the host's health (owner's alpha 19 item 17)" ([math]::Abs(([double]$c0 - [double]$c1) - 0.01 * [double]$mx) -lt 0.05) "host health $hp0 -> $hp1"
$hs = Send $hd "return table.concat(KICK_LOG, ' ')"; $gs = Send $cd "return table.concat(KICK_LOG, ' ')"
"  host speed:   $hs"; "  guest puppet: $gs"
# the host stood (speed < 15) from some time on: the puppet idle again within 0.6 s of it (the network's delay, the
# puppet's 120 ms interpolation, the 300 ms speed window, the 150 ms idle hold; it took 0.8 s before)
$stillAt = $null
foreach ($x in ($hs -split ' ')) { $tt, $v = $x -split ':'; if ([double]$v -ge 15) { $stillAt = $null } elseif ($stillAt -eq $null) { $stillAt = [double]$tt } }
$late = @(($gs -split ' ') | Where-Object { $tt, $a = $_ -split ':'; $stillAt -ne $null -and [double]$tt -gt $stillAt + 0.6 -and $a -ne 'idle' })
Check "the kicked host's puppet stops walking once it stands" ($stillAt -ne $null -and $stillAt -lt 4 -and $late.Count -eq 0) "host still from $stillAt s; puppet not idle after that + 0.6 s: $($late -join ' ')"
"  guest, kick from 600 away: " + (FaceOther $cd 600); Start-Sleep 1
$n0 = [int]$kc.kicks_sent
"  guest: " + (Send $cd "return CoopPlayers.botKick()"); Start-Sleep 2
$kc = Kick $cd
Check "a kick from afar reaches nobody" ([int]$kc.kicks_sent -eq $n0 -and [int]$kc.kick_tries -gt 1) $kc.raw

"  errors host: " + (Send $hd "return CoopPlayers.report()")
"  errors guest: " + (Send $cd "return CoopPlayers.report()")
"=== RESULT: $script:pass passed, $script:fail failed"
if (-not ($Keep -or $Reuse)) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    $sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
