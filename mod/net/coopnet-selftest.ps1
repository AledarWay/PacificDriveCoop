# CoopNet self-test without the game: two CoopNet processes in the local TCP mode, one channel directory each.
# Checks: lobby (create / join, both members, modes), lines both ways on both channels, a big file (chunks),
# the session commands (role host / role client / go on start) and leaving.
param([int]$Port = 47900, [string]$Exe = "C:\PacificDriveCoop\mod\net\CoopNet\bin\Release\net8.0\win-x64\CoopNet.exe")
$exe = $Exe
$base = "C:\PacificDriveCoop\local\coopnet-selftest"
Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
$a = "$base\host"; $b = "$base\guest"
New-Item -ItemType Directory -Force $a, $b | Out-Null
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Ctl($dir, [string]$line) { Add-Content "$dir\net-control.txt" $line -Encoding ascii }
function NetStatus($dir) { (Get-Content "$dir\net-status.txt" -ErrorAction SilentlyContinue) -join ' | ' }
function WaitFor([scriptblock]$cond, [int]$sec = 15) {
    $end = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }
    $false
}

$pa = Start-Process $exe -ArgumentList "--chan `"$a`" --tcp $Port --name Host --parent $PID" -PassThru
$pb = Start-Process $exe -ArgumentList "--chan `"$b`" --tcp $Port --name Guest --parent $PID" -PassThru
Start-Sleep 2
Ctl $a 'create'; Start-Sleep 1
Ctl $b 'mode car'; Ctl $b 'join 1'
$ok = WaitFor { (Get-Content "$a\net-status.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -like 'member*' }).Count -eq 2 }
Check "lobby: the host sees both members" $ok (NetStatus $a)
$ok = WaitFor { (Get-Content "$a\net-status.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -match "^member\t\d+\t0\t0\tcar" }) }
Check "lobby: the guest's mode reaches the host" $ok (NetStatus $a)
Check "session: host role for the owner" ((Get-Content "$a\control.txt" -ErrorAction SilentlyContinue) -contains 'role host') ((Get-Content "$a\control.txt") -join ',')
Check "session: client role + mode for the guest" ((Get-Content "$b\control.txt" -ErrorAction SilentlyContinue) -contains 'role client' -and (Get-Content "$b\control.txt") -contains 'mode car') ((Get-Content "$b\control.txt") -join ',')

# lines: host -> guest on both channels, guest -> host on both
Add-Content "$a\host.events" "E 1 hello-state" -Encoding ascii; Add-Content "$a\host.fast" "P 1 2 3" -Encoding ascii
Add-Content "$b\client.requests" "R 1 pick" -Encoding ascii; Add-Content "$b\client.fast" "P 4 5 6" -Encoding ascii
$ok = WaitFor { (Get-Content "$b\host.events" -ErrorAction SilentlyContinue) -contains 'E 1 hello-state' -and (Get-Content "$b\host.fast" -ErrorAction SilentlyContinue) -contains 'P 1 2 3' }
Check "lines host -> guest (both channels)" $ok "events: $(Get-Content "$b\host.events" -ErrorAction SilentlyContinue) fast: $(Get-Content "$b\host.fast" -ErrorAction SilentlyContinue)"
$ok = WaitFor { (Get-Content "$a\client.requests" -ErrorAction SilentlyContinue) -contains 'R 1 pick' -and (Get-Content "$a\client.fast" -ErrorAction SilentlyContinue) -contains 'P 4 5 6' }
Check "lines guest -> host (both channels)" $ok "requests: $(Get-Content "$a\client.requests" -ErrorAction SilentlyContinue)"

# a big file (several chunks), written the game's way (.tmp, then rename)
$big = New-Object byte[] (700 * 1024); (New-Object Random 7).NextBytes($big)
[IO.File]::WriteAllBytes("$a\outbox\host-spawnlist-1.tsv.tmp", $big); Move-Item "$a\outbox\host-spawnlist-1.tsv.tmp" "$a\outbox\host-spawnlist-1.tsv"
$ok = WaitFor { Test-Path "$b\inbox\host-spawnlist-1.tsv" }
$same = $ok -and ((Get-FileHash "$b\inbox\host-spawnlist-1.tsv").Hash -eq (Get-FileHash "$a\outbox\sent\host-spawnlist-1.tsv").Hash)
Check "a 700 KB file arrives whole" $same "arrived=$ok"

Ctl $a 'start'
$ok = WaitFor { (Get-Content "$b\control.txt" -ErrorAction SilentlyContinue) -contains 'go' }
Check "start: the guest gets go" $ok ((Get-Content "$b\control.txt") -join ',')
$ok = WaitFor { (Get-Content "$a\net-status.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) -notmatch 'ping=-1' }
Check "ping measured" $ok ((Get-Content "$a\net-status.txt" | Select-Object -First 1))

Ctl $b 'leave'
$ok = WaitFor { (Get-Content "$b\control.txt" -ErrorAction SilentlyContinue) -contains 'stop' }
Check "leave: the guest's session stops" $ok ((Get-Content "$b\control.txt") -join ',')

Stop-Process -Id $pa.Id, $pb.Id -Force -ErrorAction SilentlyContinue
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
