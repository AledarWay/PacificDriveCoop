# Automated session test: the mod runs the co-op session by itself (session.lua), driven only through the
# control files a Steam helper writes - no CoopDev commands for the session. Two headless instances, each with
# its own channel directory ($env:COOPSYNC_CHAN), two TCP relays between them (in place of the Steam helper).
#   host:  "role host" -> in its zone it publishes the zone and starts the sync by itself
#   guest: "role client", "mode foot", "go" in its garage -> joins the host's zone, imports, syncs by itself
# Then the host goes home with the guest on foot outside its car (left behind: the game's death, home).
# -CoopNet: no relays and no session commands from the test - the in-game network (its local test link; with -NetExe
# two CoopNet.exe) carries the channel and the test only does what the menu does (net-control.txt: create / mode /
# join / start); the network gives the roles.
param([switch]$Keep, [int]$Port = 47811, [switch]$CoopNet, [switch]$NetExe)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$run = "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function KV($s) { $h = @{}; foreach ($kv in ($s -split ' ')) { $k, $v = $kv -split '=', 2; if ($v -ne $null) { $h[$k] = $v } }; $h['raw'] = $s; $h }
function Status($chan) { KV ((Get-Content "$chan\status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]) }
# (the game reads these files on its own; a write that meets its read is refused: try again)
function AddRetry([string]$file, [string]$text) {
    for ($i = 0; $i -lt 20; $i++) { try { Add-Content $file $text -Encoding ascii -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 100 } }
    "  WARNING: could not write $file"
}
function Control($chan, [string[]]$lines) { AddRetry "$chan\control.txt" ($lines -join "`r`n") }
function WaitState($chan, [string]$state, [int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    do { $s = Status $chan; if ($s.state -eq $state) { return $s }; Start-Sleep 3 } while ((Get-Date) -lt $end)
    Status $chan
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$runId = Get-Date -f HHmmss
$hchan = "$inst\host\chan-s$runId"; $cchan = "$inst\client\chan-s$runId"
New-Item -ItemType Directory -Force "$hchan\outbox", "$hchan\inbox", "$cchan\outbox", "$cchan\inbox" | Out-Null
$relay = "$root\mod\net\relay.ps1"; $token = [guid]::NewGuid().ToString("N")
function NetCtl($chan, [string]$line) { AddRetry "$chan\net-control.txt" $line }
. "$t\netlink.ps1"
if ($CoopNet) {
    $rh = NetExeStart $hchan Host
    $rc = NetExeStart $cchan Guest
} else {
    $rh = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role host -Dir `"$hchan`" -Port $Port -Token $token" -WindowStyle Hidden -PassThru
    $rc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role client -Dir `"$cchan`" -Port $Port -Token $token" -WindowStyle Hidden -PassThru
}

"=== 1. host into its zone, guest into its garage (each game gets its channel directory)"
. "$t\boot-lib.ps1" # (the two games boot side by side)
$env:COOPSYNC_CHAN = $hchan.Replace('\', '/'); if ($CoopNet) { $env:COOPSYNC_NET = NetSpec Host }; $boot0 = BootBg start-zone.ps1 "-Tag host -Seed 12345"
$env:COOPSYNC_CHAN = $cchan.Replace('\', '/'); if ($CoopNet) { $env:COOPSYNC_NET = NetSpec Guest }; $boot1 = BootBg start-zone.ps1 "-Tag client -Seed 777 -StopInGarage"
BootWait $boot0 | Select-Object -Last 1; BootWait $boot1 | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN, Env:COOPSYNC_NET -ErrorAction SilentlyContinue
Start-Sleep 3
$h = Status $hchan; $c = Status $cchan
Check "both sessions are up and idle (status files)" ($h.state -eq 'idle' -and $c.state -eq 'idle') "host: $($h.raw) | guest: $($c.raw)"

$pauseCmd = "local ui = FindFirstOf('BP_UIManager_C') local ok = {} ui:PauseGame(FName('CoopTest'), true, ok)"
$pauseCheck = "local GS = StaticFindObject('/Script/Engine.Default__GameplayStatics') local pc = FindFirstOf('PlayerController') return 'paused=' .. tostring(GS:IsGamePaused(pc))"
$unpauseCmd = "local ui = FindFirstOf('BP_UIManager_C') local ok = {} ui:PauseGame(FName('CoopTest'), false, ok) return 'unpaused'"
"  solo pause: " + (Send $hd "$pauseCmd return 'paused'"); Start-Sleep 2
$p = KV (Send $hd $pauseCheck); "  " + (Send $hd $unpauseCmd)
Check "single-player pause still stops the game (no session yet)" ($p.paused -eq 'true') $p.raw

"=== 2. the host takes the host role"
if ($CoopNet) {
    NetCtl $hchan 'create'; Start-Sleep 2
    NetCtl $cchan 'mode foot'; NetCtl $cchan 'join 1'; Start-Sleep 3
    Check "lobby: both members (CoopNet)" (@(Get-Content "$hchan\net-status.txt" | Where-Object { $_ -like 'member*' }).Count -eq 2) ((Get-Content "$hchan\net-status.txt") -join ' | ')
} else { Control $hchan @('role host') }
$h = WaitState $hchan 'hosting' 180
Check "host published its zone and started the sync by itself" ($h.state -eq 'hosting' -and [int]$h.seq -ge 1) $h.raw
Start-Sleep 5
$hs = if ($CoopNet) { Send $cd "local s = CoopNative_DocGet('host-session.txt') return tostring(s)" } else { (Get-Content "$cchan\inbox\host-session.txt" -ErrorAction SilentlyContinue) -join ' ' }
Check "the zone went to the guest (the host-session document / inbox file)" ($hs -match 'seq=\d+ world=') $hs

"=== 3. the guest goes (on foot)"
if ($CoopNet) { NetCtl $hchan 'start' } else { Control $cchan @('role client', 'mode foot', 'go') }
# the guest drives out through its garage exit once it opens (the guest no longer travels by itself on "go")
$end = (Get-Date).AddSeconds(60)
do { Start-Sleep 3 } while ((Status $cchan).gate -notmatch '^\d+/[1-9]' -and (Get-Date) -lt $end)
$driveOut = "local p = FindFirstOf('PlayerController').Pawn local car = FindFirstOf('BP_CarManager_C').NewCarActor " +
        "local par = p:GetAttachParentActor() if not (par and par:IsValid()) then p:CommandEnterCar(true, nil, false) end " +
        "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.IsGarageExit then ex = e end end " +
        "local c = ex.Collision_Exit:K2_GetComponentLocation() " +
        "car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z - 150 }, { Pitch = 0, Yaw = -80, Roll = 0 }, false, {}, true) return 'drove out'"
"  guest: " + (Send $cd $driveOut)
$c = WaitState $cchan 'playing' 420
Check "guest joined, imported and syncs by itself" ($c.state -eq 'playing' -and $c.world -eq $h.world) "guest: $($c.raw) | host: $($h.raw)"
Start-Sleep 10
$h = Status $hchan; $c = Status $cchan
Check "both see each other (puppets)" ($h.puppet -eq 'yes' -and $c.puppet -eq 'yes') "host: $($h.raw) | guest: $($c.raw)"
$w1 = ([string](Status $hchan).weather) -split '/'; $w2 = ([string](Status $cchan).weather) -split '/'
Check "weather: the host sends, the guest applies" ([int]$w1[0] -ge 1 -and [int]$w2[1] -ge 1) "host sent/applied $((Status $hchan).weather) | guest $((Status $cchan).weather)"
"  co-op pause: " + (Send $hd "$pauseCmd return 'paused'"); Start-Sleep 2
$p = KV (Send $hd $pauseCheck); "  " + (Send $hd $unpauseCmd)
Check "co-op pause does not stop the host's world" ($p.paused -eq 'false' -and [int](Status $hchan).unpaused -ge 1) "$($p.raw) | $((Status $hchan).raw)"

"=== 4. the host goes home; the guest, on foot outside the car, is left behind (its game's death, home)"
"  guest: " + (& "$t\trace-on.ps1" -Dir $cd -Sec 150)
"  host: " + (Send $hd "$run return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  host: $_" }
& "$t\wait-state.ps1" -State 4 -Dir $cd -TimeoutSec 240 | Select-Object -Last 1 | ForEach-Object { "  guest: $_" }
Start-Sleep 5
$w = KV (Send $hd "$run return Run.where()"); $g = KV (Send $cd "$run return Run.where()")
Check "host is home" ($w.state -eq '4') $w.raw
Check "guest went home too (left behind)" ($g.state -eq '4' -and $g.world -eq 'RB_Garage') "$($g.raw) | $((Status $cchan).raw)"
Start-Sleep 30
$g = KV (Send $cd "$run return Run.where()"); $c = Status $cchan
Check "guest stays home (no join into the closed zone)" ($g.state -eq '4' -and $c.state -eq 'garage') "$($g.raw) | $($c.raw)"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    NetExeStop
}
