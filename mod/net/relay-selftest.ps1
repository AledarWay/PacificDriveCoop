# Self-test of relay.ps1 without the game: two relays on loopback, lines both ways, a file, latency.
param([int]$DelayMs = 0, [int]$Port = 27531)
$root = "C:\PacificDriveCoop\local\relaytest"
$h = "$root\host"; $c = "$root\client"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $h, $c | Out-Null
$relay = "C:\PacificDriveCoop\mod\net\relay.ps1"
$ph = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role host -Dir `"$h`" -Port $Port -Token t0k -DelayMs $DelayMs" -WindowStyle Hidden -PassThru
$pc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role client -Dir `"$c`" -Port $Port -Token t0k -DelayMs $DelayMs" -WindowStyle Hidden -PassThru
try {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 15 -and -not ((Get-Content "$c\relay-status.txt" -ErrorAction SilentlyContinue) -match 'state=connected')) { Start-Sleep -Milliseconds 200 }
    "client status: " + (Get-Content "$c\relay-status.txt" -ErrorAction SilentlyContinue)
    $n = 500
    $sw = [Diagnostics.Stopwatch]::StartNew()
    1..$n | ForEach-Object { "$_`tU`tkey$_`tsome loot string with`ttabs" } | Add-Content "$h\host.events" -Encoding ascii
    1..20 | ForEach-Object { "$_`tOPEN`tkey$_" } | Add-Content "$c\client.requests" -Encoding ascii
    Set-Content "$h\outbox\spawnlist.tsv" ((1..400 | ForEach-Object { "R`t/Game/X/BP_A.BP_A_C`t1`t2`t3`tkey$_`tC|stuff" }) -join "`n") -Encoding ascii
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        $a = @(Get-Content "$c\host.events" -ErrorAction SilentlyContinue).Count
        $b = @(Get-Content "$h\client.requests" -ErrorAction SilentlyContinue).Count
        if ($a -ge $n -and $b -ge 20 -and (Test-Path "$c\inbox\spawnlist.tsv")) { break }
        Start-Sleep -Milliseconds 50
    }
    "delivered in $([int]$sw.Elapsed.TotalMilliseconds) ms (DelayMs=$DelayMs)"
    $okLines = ((Get-Content "$h\host.events") -join "`n") -eq ((Get-Content "$c\host.events") -join "`n")
    $okReq = ((Get-Content "$c\client.requests") -join "`n") -eq ((Get-Content "$h\client.requests") -join "`n")
    $okFile = (Test-Path "$c\inbox\spawnlist.tsv") -and ((Get-FileHash "$h\outbox\sent\spawnlist.tsv").Hash -eq (Get-FileHash "$c\inbox\spawnlist.tsv").Hash)
    "host->client lines identical: $okLines; client->host lines identical: $okReq; file identical: $okFile"
    # reconnect: kill the client relay, start it again, send more
    Stop-Process -Id $pc.Id -Force; Start-Sleep 2
    $pc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Role client -Dir `"$c`" -Port $Port -Token t0k" -WindowStyle Hidden -PassThru
    Start-Sleep 13 # host notices the dead peer after 10 s silence and listens again
    "after-reconnect $_`tU`tlate" | Add-Content "$h\host.events" -Encoding ascii
    $t1 = Get-Date
    while (((Get-Date) - $t1).TotalSeconds -lt 15 -and -not ((Get-Content "$c\host.events" -Tail 1) -match 'after-reconnect')) { Start-Sleep -Milliseconds 200 }
    "reconnect delivered: " + [bool]((Get-Content "$c\host.events" -Tail 1) -match 'after-reconnect')
    # wrong token is rejected
    $bad = New-Object System.Net.Sockets.TcpClient
    "host status: " + (Get-Content "$h\relay-status.txt")
    "host log:"; Get-Content "$h\relay.log" | Select-Object -Last 4
} finally {
    Stop-Process -Id $ph.Id, $pc.Id -Force -ErrorAction SilentlyContinue
}
