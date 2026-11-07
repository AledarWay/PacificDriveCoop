# After a trip home (the game's rinse, Run.goHome) where is the car, and does a teleport stick? (startflow's late
# join: the guest's drive-out did not count for a while after coming home). One headless instance.
param([int]$Seconds = 90)
$t = "C:\PacificDriveCoop\mod\tools"; $hd = "C:\PacificDriveCoop\local\instances\host\coopdev"
function Lua([string]$code) {
    $f = "$hd\_h.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $hd -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME)' }) -join ' ') -replace '^OK ', ''
}
Get-Process PenDriverPro-Win64-Shipping, CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1" | Out-Null
& "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
"enter car: " + (Lua "local p = FindFirstOf('PlayerController').Pawn p:CommandEnterCar(true, nil, false) return 'in'")
Start-Sleep 3
"home: " + (Lua "Run = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua') return Run.goHome(false, 0)")
& "$t\wait-state.ps1" -State 4 -Dir $hd -TimeoutSec 240 | Select-Object -Last 1
$probe = "local car = FindFirstOf('BP_CarManager_C').NewCarActor local l = car:K2_GetActorLocation() " +
    "local ex for _, e in ipairs(FindAllOf('BP_LevelTransition_EnterExit_C') or {}) do if e:IsValid() and e.IsGarageExit then ex = e end end " +
    "local c = ex.Collision_Exit:K2_GetComponentLocation() " +
    "car:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z - 150 }, { Pitch = 0, Yaw = -80, Roll = 0 }, false, {}, true) " +
    "HomeProbeAfter = nil Dev.after(500, function() local x = car:K2_GetActorLocation() HomeProbeAfter = string.format('%.0f,%.0f,%.0f', x.X, x.Y, x.Z) end) " +
    "return string.format('before=%.0f,%.0f,%.0f sim=%s', l.X, l.Y, l.Z, tostring(car.RootComponent:IsSimulatingPhysics(FName('None'))))"
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
    $b = Lua $probe; Start-Sleep 1
    $a = Lua "return tostring(HomeProbeAfter)"
    "{0,3:N0}s  {1}  after0.5s={2}" -f ((Get-Date) - $t0).TotalSeconds, $b, $a
    Start-Sleep 2
}
