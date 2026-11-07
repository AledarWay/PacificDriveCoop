# CoopSync network relay: runs next to the game and moves the mod's channel lines between two PCs over TCP.
# The game side keeps using local files (UE4SS Lua has no sockets). Two line channels:
#   0 (state):  host sends <Dir>\host.events -> client <Dir>\host.events;  client <Dir>\client.requests -> host
#   1 (fast):   host sends <Dir>\host.fast   -> client <Dir>\host.fast;    client <Dir>\client.fast     -> host
#               (player and car transforms, ~10/s)
# Files dropped into <Dir>\outbox\ are sent whole and appear in the peer's <Dir>\inbox\.
#
# Host:   relay.ps1 -Role host   -Dir <dir> -Port 27520 [-Bind 0.0.0.0] -Token <secret>
# Client: relay.ps1 -Role client -Dir <dir> -HostAddr <ip or name> -Port 27520 -Token <secret>
# Test only: -DelayMs / -JitterMs delay every received line (one-way latency emulation); -LossPct: that share of the
# lines is lost once and sent again (Steam's reliable messages: the game sees no loss, only a stall of -ResendMs plus
# up to as much again, and every later line waits behind it, then all come at once).
param(
    [ValidateSet('host', 'client')] [string]$Role,
    [string]$Dir,
    [int]$Port = 27520,
    [string]$Bind = '127.0.0.1',
    [string]$HostAddr = '127.0.0.1',
    [string]$Token = 'change-me',
    [int]$DelayMs = 0,
    [int]$JitterMs = 0,
    [double]$LossPct = 0,
    [int]$ResendMs = 200
)
$ErrorActionPreference = 'Stop'
# (tests: COOPTEST_NET="<delay>,<jitter>,<loss %>" puts every test's relays on such a link: run-all-tests.ps1 -Lag)
if ($env:COOPTEST_NET -and $DelayMs -eq 0 -and $JitterMs -eq 0 -and $LossPct -eq 0) {
    $n = $env:COOPTEST_NET -split ','
    $DelayMs = [int]$n[0]; if ($n.Count -gt 1) { $JitterMs = [int]$n[1] }; if ($n.Count -gt 2) { $LossPct = [double]$n[2] }
}
$Version = 'coopsync-relay/1'
$outFiles = if ($Role -eq 'host') { @((Join-Path $Dir 'host.events'), (Join-Path $Dir 'host.fast')) } else { @((Join-Path $Dir 'client.requests'), (Join-Path $Dir 'client.fast')) }
$inFiles = if ($Role -eq 'host') { @((Join-Path $Dir 'client.requests'), (Join-Path $Dir 'client.fast')) } else { @((Join-Path $Dir 'host.events'), (Join-Path $Dir 'host.fast')) }
$outbox = Join-Path $Dir 'outbox'; $inbox = Join-Path $Dir 'inbox'; $sent = Join-Path $outbox 'sent'
New-Item -ItemType Directory -Force $Dir, $outbox, $inbox, $sent | Out-Null
$statusFile = Join-Path $Dir 'relay-status.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$rand = New-Object System.Random
$stats = @{ resent = 0; sentLines = 0; recvLines = 0; sentFiles = 0; recvFiles = 0; sentBytes = 0; recvBytes = 0; connects = 0; lastError = '' }

function Log($msg) { Add-Content -Path (Join-Path $Dir 'relay.log') -Value "$(Get-Date -f 'HH:mm:ss.fff') [$Role] $msg" }
function Status($state) {
    $s = "state=$state " + (($stats.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ')
    try { [IO.File]::WriteAllText($statusFile, $s, $utf8) } catch {}
}

# read new complete lines appended to a file since $offset (handles truncation by the game)
function ReadNewLines([string]$path, [ref]$offset) {
    if (-not (Test-Path $path)) { return @() }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $offset.Value) { $offset.Value = 0 } # file was truncated (new session)
        if ($fs.Length -eq $offset.Value) { return @() }
        $fs.Seek($offset.Value, 'Begin') | Out-Null
        $buf = New-Object byte[] ($fs.Length - $offset.Value)
        $n = $fs.Read($buf, 0, $buf.Length)
        $text = $utf8.GetString($buf, 0, $n)
        $last = $text.LastIndexOf("`n")
        if ($last -lt 0) { return @() }
        $offset.Value += $utf8.GetByteCount($text.Substring(0, $last + 1))
        return $text.Substring(0, $last).Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
    } finally { $fs.Close() }
}

function AppendLine([string]$path, [string]$line) {
    $fs = [IO.File]::Open($path, 'Append', 'Write', 'ReadWrite')
    try { $b = $utf8.GetBytes($line + "`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
}

function Connect() {
    if ($Role -eq 'host') {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Bind), $Port)
        $listener.Start()
        Log "listening on ${Bind}:$Port"
        Status 'listening'
        while (-not $listener.Pending()) { Start-Sleep -Milliseconds 100 }
        $c = $listener.AcceptTcpClient()
        $listener.Stop()
        return $c
    }
    while ($true) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect($HostAddr, $Port)
            return $c
        } catch { $stats.lastError = $_.Exception.Message; Status 'connecting'; Start-Sleep -Seconds 1 }
    }
}

# start after what is already in the outgoing files: old lines belong to an earlier session
$outOffsets = @(0, 0)
for ($i = 0; $i -lt 2; $i++) { if (Test-Path $outFiles[$i]) { $outOffsets[$i] = (Get-Item $outFiles[$i]).Length } }

while ($true) {
    $client = Connect
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, $utf8)
    $writer = New-Object System.IO.StreamWriter($stream, $utf8); $writer.AutoFlush = $false; $writer.NewLine = "`n"
    $stats.connects++
    try {
        # handshake: the client proves it knows the token; both check the protocol version
        if ($Role -eq 'client') { $writer.WriteLine("HELLO`t$Version`t$Token"); $writer.Flush() }
        $stream.ReadTimeout = 10000
        $first = $reader.ReadLine()
        $stream.ReadTimeout = -1
        if ($Role -eq 'host') {
            $p = "$first".Split("`t")
            if ($p.Count -ne 3 -or $p[0] -ne 'HELLO' -or $p[1] -ne $Version -or $p[2] -ne $Token) { Log "rejected handshake"; throw "bad handshake" }
            $writer.WriteLine("WELCOME`t$Version"); $writer.Flush()
        } elseif ("$first" -ne "WELCOME`t$Version") { throw "host refused: $first" }
        Log "connected ($($client.Client.RemoteEndPoint)), link: delay $DelayMs ms, jitter $JitterMs ms, loss $LossPct %"
        Status 'connected'
        $lastRx = Get-Date; $lastPing = Get-Date; $lastStatus = Get-Date
        $pending = New-Object System.Collections.Generic.List[object] # delayed incoming lines (latency emulation)
        $rxBuf = New-Object System.Text.StringBuilder
        $byteBuf = New-Object byte[] 65536
        while ($client.Connected) {
            $busy = $false
            # 1) outgoing channel lines ("L" = channel 0, "L1" = channel 1)
            for ($ch = 0; $ch -lt 2; $ch++) {
                $o = $outOffsets[$ch]
                $lines = ReadNewLines $outFiles[$ch] ([ref]$o)
                $outOffsets[$ch] = $o
                $tag = if ($ch -eq 0) { "L" } else { "L1" }
                foreach ($l in $lines) { if ($l -ne '') { $writer.WriteLine("$tag`t$l"); $stats.sentLines++; $stats.sentBytes += $l.Length; $busy = $true } }
            }
            # 2) outgoing files
            # *.tmp = still being written by the game (it writes <name>.tmp, then renames)
            foreach ($f in Get-ChildItem $outbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.tmp' }) {
                $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
                $writer.WriteLine("F`t$($f.Name)`t$data"); $stats.sentFiles++; $stats.sentBytes += $data.Length
                Move-Item $f.FullName (Join-Path $sent $f.Name) -Force
                $busy = $true
            }
            if (((Get-Date) - $lastPing).TotalSeconds -ge 2) { $writer.WriteLine("P"); $lastPing = Get-Date }
            $writer.Flush()
            # 3) incoming (non-blocking: only read what is available)
            while ($stream.DataAvailable) {
                $n = $stream.Read($byteBuf, 0, $byteBuf.Length)
                if ($n -le 0) { break }
                [void]$rxBuf.Append($utf8.GetString($byteBuf, 0, $n))
                $stats.recvBytes += $n
                $lastRx = Get-Date
            }
            $text = $rxBuf.ToString()
            $cut = $text.LastIndexOf("`n")
            if ($cut -ge 0) {
                [void]$rxBuf.Remove(0, $cut + 1)
                foreach ($msg in $text.Substring(0, $cut).Split("`n")) {
                    $ms = $DelayMs + $(if ($JitterMs -gt 0) { $rand.Next(0, $JitterMs) } else { 0 })
                    if ($LossPct -gt 0 -and $rand.NextDouble() * 100 -lt $LossPct) { $ms += $ResendMs + $rand.Next(0, $ResendMs + 1); $stats.resent++ }
                    $due = (Get-Date).AddMilliseconds($ms)
                    $pending.Add(@($due, $msg))
                }
            }
            # deliver due messages in order (jitter never reorders: a message waits for the ones before it)
            while ($pending.Count -gt 0 -and $pending[0][0] -le (Get-Date)) {
                $msg = $pending[0][1]; $pending.RemoveAt(0)
                if ($msg.StartsWith("L`t")) { AppendLine $inFiles[0] $msg.Substring(2); $stats.recvLines++; $busy = $true }
                elseif ($msg.StartsWith("L1`t")) { AppendLine $inFiles[1] $msg.Substring(3); $stats.recvLines++; $busy = $true }
                elseif ($msg.StartsWith("F`t")) {
                    $p = $msg.Split("`t", 3)
                    $tmp = Join-Path $inbox ($p[1] + '.part')
                    [IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($p[2]))
                    Move-Item $tmp (Join-Path $inbox $p[1]) -Force
                    $stats.recvFiles++; $busy = $true
                }
            }
            if (((Get-Date) - $lastRx).TotalSeconds -gt 10) { throw "peer silent for 10 s" }
            if (((Get-Date) - $lastStatus).TotalSeconds -ge 1) { Status 'connected'; $lastStatus = Get-Date }
            if (-not $busy) { Start-Sleep -Milliseconds 20 }
        }
    } catch {
        $stats.lastError = $_.Exception.Message
        Log "connection lost: $($stats.lastError)"
    } finally {
        try { $client.Close() } catch {}
        Status 'disconnected'
    }
    Start-Sleep -Seconds 1
}
