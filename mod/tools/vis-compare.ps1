# Real car vs its ghost, from the same seat: run after demo-owncar.ps1 (both games still open). The host sits at
# the wheel of its own (real) car - shots - and gets out; then the guest sits at the wheel of that car's ghost
# (the only free seat: devices take the others) - shots. Each looks ahead and down at the dash.
# Screenshots: local\vis-<host|guest>-<ahead|dash>.png; then the weather lines of both.
param([string]$Out = "C:\PacificDriveCoop\local")
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    [IO.File]::WriteAllText("$dir\_v.lua", $code, (New-Object Text.UTF8Encoding($false)))
    (((& "$t\send.ps1" -File "$dir\_v.lua" -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function GamePid($dir) { $m = Select-String -Path "$dir\start.log" -Pattern '\] pid (\d+) ' | Select-Object -Last 1; [int]$m.Matches[0].Groups[1].Value }
# the view along the car the player sits in (the ghost root for the guest); -creplace: PITCH, not the key Pitch
$look = "local pc = FindFirstOf('PlayerController') local p = pc.Pawn local c = p:GetAttachParentActor() if not (c and c:IsValid()) then return 'not seated' end local r = c:K2_GetActorRotation() pc:SetControlRotation({ Pitch = PITCH, Yaw = r.Yaw, Roll = 0 }) return string.format('yaw %.0f', r.Yaw)"
function Shots($dir, $who) {
    foreach ($v in @(@{ n = 'ahead'; pitch = -5 }, @{ n = 'dash'; pitch = -35 })) {
        "  ${who}: " + (Send $dir ($look -creplace 'PITCH', $v.pitch))
        Start-Sleep 2
        & "$t\shot.ps1" -GamePid (GamePid $dir) -Out "$Out\vis-$who-$($v.n).png" | Out-Null
    }
}

"host:  " + (Send $hd "return CoopPlayers.botEnterAt('FL')"); Start-Sleep 4
Shots $hd 'host'
"host:  " + (Send $hd "return CoopPlayers.botExitCar()"); Start-Sleep 4
$at = (Send $cd "return CoopPlayers.ghostDoor(1)") -split ','
"guest: " + (Send $cd "local p = FindFirstOf('PlayerController').Pawn p:K2_SetActorLocation({ X = $($at[0]), Y = $($at[1]), Z = $([double]$at[2] + 100) }, false, {}, true) p['Command Interact'](p, true) return 'board'")
Start-Sleep 4
"guest: " + (Send $cd "return CoopPlayers.ghostInfo()")
Shots $cd 'guest'
"weather host:  " + (Send $hd "return CoopWeather.info()")
"weather guest: " + (Send $cd "return CoopWeather.info()")
"cars guest:    " + (Send $cd "return CoopPlayers.carsInfo()")
"shots: $Out\vis-*.png"
