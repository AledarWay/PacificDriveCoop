# The in-game network on real Steam, one game (one Steam account: the P2P part needs a second player and stays for
# the owner's real test): the game's Steam is found (my id, name, the friends list), a lobby is created and left.
# Started without COOPSYNC_NET (= Steam), commands through CoopDev into the same native module.
param([switch]$Keep)
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
$hd = "$inst\host\coopdev"
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Lua([string]$code) {
    $f = "$hd\_n.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $hd -TimeoutSec 30) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
function Head($chan) { (Get-Content "$chan\net-status.txt" -TotalCount 1 -ErrorAction SilentlyContinue) -as [string] }
Get-Process PenDriverPro-Win64-Shipping, CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
$chan = "$inst\host\chan-n$(Get-Date -f HHmmss)"
New-Item -ItemType Directory -Force "$chan\inbox", "$chan\outbox" | Out-Null
Remove-Item Env:COOPSYNC_NET -ErrorAction SilentlyContinue
$env:COOPSYNC_CHAN = $chan.Replace('\', '/')
& "$t\start-zone.ps1" -Tag host -Seed 12345 -StopInGarage | Select-Object -Last 1
Remove-Item Env:COOPSYNC_CHAN
Start-Sleep 3
$log = (Get-Content "$chan\net.log" -ErrorAction SilentlyContinue) -join ' | '
Check "the in-game network found the game's Steam" ($log -match 'steam: me \d{17} app 1458140') $log
$h = Head $chan
$friends = @(Get-Content "$chan\net-status.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -like 'friend*' }).Count
Check "status: idle, my name, the friends list" ($h -match '^state=idle' -and $h -match 'net=native') "$h | friends=$friends"
"  create: " + (Lua "CoopNative_NetCmd('create') return 'sent'")
$end = (Get-Date).AddSeconds(20)
do { Start-Sleep 1; $h = Head $chan } while ($h -notmatch 'state=lobby' -and (Get-Date) -lt $end)
Check "a Steam lobby is created (the call result came back)" ($h -match 'state=lobby' -and $h -match 'lobby=\d{15,}' -and $h -match 'owner=1') $h
$members = @(Get-Content "$chan\net-status.txt" | Where-Object { $_ -like 'member*' })
Check "the lobby lists me as its owner" ($members.Count -eq 1 -and $members[0] -match "^member\t\d+\t1\t1\t") ($members -join ' | ')
$st = (Get-Content "$chan\status.txt" -TotalCount 1) -as [string]
Check "the session got the host role from the network" ($st -match 'role=host') $st
"  leave: " + (Lua "CoopNative_NetCmd('leave') return 'sent'")
Start-Sleep 3
$h = Head $chan; $st = (Get-Content "$chan\status.txt" -TotalCount 1) -as [string]
Check "left: idle again, the session stopped" ($h -match '^state=idle' -and $st -match 'role=nil') "$h | $st"
"  net.log: " + ((Get-Content "$chan\net.log") -join ' | ')
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
