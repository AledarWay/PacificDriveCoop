# Graphic demo of own-car mode for watching by hand: two game windows side by side (host left, guest right).
# The guest comes with its own car; each sees the other's car as a ghost. Then, slowly, with pauses:
#   1. the guest gets out, walks to the host's car, gets in at the driver door and drives it (W), handbrake, out
#   2. the host gets into the guest's car and drives it the same way, out
# The windows stay open at the end (-Close closes them). Run from a PowerShell window:
#   powershell -ExecutionPolicy Bypass -File C:\PacificDriveCoop\mod\tools\demo-owncar.ps1
param([switch]$Close, [int]$Pause = 4)
$env:COOPTEST_GRAPHICS = '1'
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua') CoopWeather = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/weathersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function P($p) { $p.Replace('\', '/') }
function Say($m) { Write-Host ""; Write-Host ">>> $m" -ForegroundColor Cyan }
function Vec($s) { $p = "$s" -split ','; [pscustomobject]@{ X = [double]$p[0]; Y = [double]$p[1]; Z = [double]$p[2] } }
function Board($dir, [int]$door) {
    $at = Send $dir "return CoopPlayers.ghostDoor($door)"
    if ($at -eq 'none' -or -not $at) { return "no ghost to get into ($at)" }
    $v = Vec $at
    Send $dir "local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = $($v.X), Y = $($v.Y), Z = $($v.Z + 100) }, false, {}, true) p['Command Interact'](p, true) return 'interact at door $door'"
}
function Interact($dir) { Send $dir "local p = FindFirstOf('PlayerController').Pawn p['Command Interact'](p, true) return 'interact'" }
# W for 6 s with a little steering, then the handbrake (space) for 3 s; the loop cancels itself
function DriveGhost($dir) {
    Send $dir "local p = FindFirstOf('PlayerController').Pawn local t0 = os.clock() local h h = LoopInGameThreadWithDelay(1, function() local dt = os.clock() - t0 if dt > 9 then CancelDelayedAction(h) return end if dt > 6 then p['Command Move Forward/Backward'](p, 0) p['Command Move Left/Right'](p, 0) p['Command Jump'](p, 0) return end p['Command Move Forward/Backward'](p, 1.0) p['Command Move Left/Right'](p, (dt > 2 and dt < 4) and 0.4 or 0) end) return 'driving'"
}

# windows side by side (the game opens 960x540 windowed)
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class DemoWin { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f); }
'@
function PlaceWindow([int]$gamePid, [int]$x) {
    $p = Get-Process -Id $gamePid -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne 0) { [DemoWin]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, $x, 40, 960, 560, 0x0040) | Out-Null }
}
function GamePid($dir) { $m = Select-String -Path "$dir\start.log" -Pattern '\] pid (\d+) ' | Select-Object -Last 1; [int]$m.Matches[0].Groups[1].Value }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
Say "Запускаю хоста (левое окно) и гостя (правое окно); гость приезжает в зону хоста на своей машине. Это займёт несколько минут."
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
PlaceWindow (GamePid $hd) 0; PlaceWindow (GamePid $cd) 965
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car next to the host's: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"guest: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
"host: " + (Send $hd "return CoopWeather.start(CoopPlayers, 'host')") + " | guest: " + (Send $cd "return CoopWeather.start(CoopPlayers, 'client')")
Say "Оба игрока сидят в своих машинах. В каждом окне чужая машина — призрак (появляется примерно за 10 с). Погода и время суток у гостя — как у хоста."
Start-Sleep 15

Say "Оба выходят из своих машин."
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep $Pause
Say "Гость (справа) подходит к машине хоста и садится через водительскую дверь (обычная клавиша взаимодействия)."
"  guest: " + (Board $cd 1); Start-Sleep $Pause
"  " + (Send $cd "return CoopPlayers.ghostInfo()")
Say "Гость ведёт машину хоста: W 6 с, немного руля, потом ручник. Машина хоста едет в обоих окнах."
"  guest: " + (DriveGhost $cd); Start-Sleep 11
Say "Гость выходит."
"  guest: " + (Interact $cd); Start-Sleep $Pause

Say "Хост (слева) садится в машину гостя через водительскую дверь и ведёт её."
"  host: " + (Board $hd 1); Start-Sleep $Pause
"  " + (Send $hd "return CoopPlayers.ghostInfo()")
"  host: " + (DriveGhost $hd); Start-Sleep 11
Say "Хост выходит."
"  host: " + (Interact $hd); Start-Sleep $Pause

if ($Close) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
    Say "Готово, окна закрыты."
} else {
    Say "Готово. Игры остаются открытыми: можно осмотреться, потом закройте оба окна (или запускайте скрипт с -Close)."
}
