# A TCP link like the internet between the two test games on the in-game network's local test link (the native
# tcp:<port>:<name>: the host listens on <port>, the guest connects to its own <port>). The guest gets -Listen as its
# port, this proxy forwards it to the host's -Target with each chunk held -DelayMs plus up to -JitterMs (in order: TCP
# never reorders), and -LossPct of the chunks held 3 x the delay more (a lost segment resent). Runs until its parent
# (-ParentPid) exits or it is killed. Stats every 10 s into -Log.
#   lag-proxy.ps1 -Listen 47852 -Target 47851 -DelayMs 80 -JitterMs 40 -LossPct 1 [-ParentPid n] [-Log file]
param([int]$Listen, [int]$Target, [int]$DelayMs = 60, [int]$JitterMs = 30, [double]$LossPct = 0, [int]$ParentPid = 0, [string]$Log = "")
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
public static class LagProxy {
    public static long Bytes0, Bytes1, Chunks, Lost, MaxHeldMs;
    static Random rng = new Random();
    static long Now() { return Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency; }
    static void Pump(Socket from, Socket to, int dir, int delay, int jitter, double loss) {
        var q = new Queue<KeyValuePair<long, byte[]>>();
        var sig = new AutoResetEvent(false);
        bool done = false;
        long last = 0;
        var sender = new Thread(() => {
            try {
                while (true) {
                    KeyValuePair<long, byte[]> e;
                    lock (q) {
                        if (q.Count == 0) { if (done) break; e = default(KeyValuePair<long, byte[]>); }
                        else e = q.Peek();
                    }
                    if (e.Value == null) { sig.WaitOne(20); continue; }
                    long wait = e.Key - Now();
                    if (wait > 0) { Thread.Sleep((int)Math.Min(wait, 20)); continue; }
                    lock (q) q.Dequeue();
                    int off = 0;
                    while (off < e.Value.Length) off += to.Send(e.Value, off, e.Value.Length - off, SocketFlags.None);
                }
            } catch { }
            try { to.Shutdown(SocketShutdown.Send); } catch { }
        });
        sender.IsBackground = true;
        sender.Start();
        var buf = new byte[65536];
        try {
            while (true) {
                int n = from.Receive(buf);
                if (n <= 0) break;
                var b = new byte[n];
                Buffer.BlockCopy(buf, 0, b, 0, n);
                long hold = delay;
                lock (rng) {
                    hold += (long)(rng.NextDouble() * jitter);
                    if (rng.NextDouble() * 100 < loss) { hold += 3L * Math.Max(delay, 50); Interlocked.Increment(ref Lost); }
                }
                long at = Math.Max(last, Now() + hold);
                last = at;
                if (at - Now() > MaxHeldMs) MaxHeldMs = at - Now();
                if (dir == 0) Interlocked.Add(ref Bytes0, n); else Interlocked.Add(ref Bytes1, n);
                Interlocked.Increment(ref Chunks);
                lock (q) q.Enqueue(new KeyValuePair<long, byte[]>(at, b));
                sig.Set();
            }
        } catch { }
        lock (q) done = true;
        sig.Set();
    }
    public static void Start(int listen, int target, int delay, int jitter, double loss) {
        var t = new Thread(() => Run(listen, target, delay, jitter, loss)); t.IsBackground = true; t.Start();
    }
    public static void Run(int listen, int target, int delay, int jitter, double loss) {
        var l = new TcpListener(IPAddress.Loopback, listen);
        l.Start();
        while (true) {
            var a = l.AcceptSocket();
            a.NoDelay = true;
            var b = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            b.NoDelay = true;
            try { b.Connect(IPAddress.Loopback, target); } catch { try { a.Close(); } catch { } continue; }
            var t1 = new Thread(() => Pump(a, b, 0, delay, jitter, loss)); t1.IsBackground = true; t1.Start();
            var t2 = new Thread(() => Pump(b, a, 1, delay, jitter, loss)); t2.IsBackground = true; t2.Start();
        }
    }
}
"@
[LagProxy]::Start($Listen, $Target, $DelayMs, $JitterMs, $LossPct)
while ($true) {
    Start-Sleep 10
    if ($Log) {
        "{0:HH:mm:ss} guest->host {1} B, host->guest {2} B, chunks {3}, lost {4}, max held {5} ms" -f (Get-Date), [LagProxy]::Bytes0, [LagProxy]::Bytes1, [LagProxy]::Chunks, [LagProxy]::Lost, [LagProxy]::MaxHeldMs | Set-Content $Log
    }
    if ($ParentPid -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
}
