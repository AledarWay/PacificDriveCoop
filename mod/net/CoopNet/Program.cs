using System.Diagnostics;
using System.Text;

namespace CoopNet;

// CoopNet: runs hidden next to the game (the CoopSync mod starts it), one per game.
//   - moves the mod's channel lines and files to the other player (relay.ps1's protocol, over Steam P2P)
//   - runs the Steam lobby for the in-game co-op menu
// The menu talks to it through two files in the channel directory:
//   net-control.txt (menu -> CoopNet, appended lines):
//     create | join <lobby> | leave | invite <steamid> | mode foot|car | ready 0|1 | start | runend
//   net-status.txt (CoopNet -> menu, rewritten twice a second):
//     state=<offline|lobby|...> lobby=<id> owner=<0|1> me=<name> peer=<0|1> ping=<ms> err=<text>
//     then tab-separated lines:
//     member <id> <owner 0/1> <me 0/1> <mode> <ready 0/1> <name>
//     friend <id> <online 0/1> <ingame 0/1> <lobby> <name>
//     invite <lobby> <from id> <from name>
// and it drives the session (session.lua) through control.txt: lobby owner -> "role host"; a guest -> "role
// client" + "mode <m>"; the owner's start -> every guest "go"; leaving the lobby -> "stop".
//
//   CoopNet.exe --chan <dir> [--tcp <port> --name <n>] [--parent <pid>]
//     --tcp: the local test link instead of Steam (two games on one PC)
//     --parent: exit when this process ends (default: the game, PenDriverPro-Win64-Shipping, once seen)
static class Program
{
    const string Version = "coopsync-net/1";
    const int FileChunk = 256 * 1024;
    static readonly UTF8Encoding Utf8 = new(false);
    static Channel chan;
    static ILink link;
    static string logPath;

    static int Main(string[] argv)
    {
        var opt = new Dictionary<string, string>();
        for (int i = 0; i + 1 < argv.Length; i += 2) opt[argv[i].TrimStart('-')] = argv[i + 1];
        if (!opt.TryGetValue("chan", out var dir)) return 2;
        Directory.SetCurrentDirectory(AppContext.BaseDirectory); // steam_appid.txt
        chan = new Channel(dir);
        logPath = chan.Local("coopnet.log");
        // one CoopNet per channel: the lock file stays open while it runs
        FileStream lockFile;
        try { lockFile = new FileStream(chan.Local("coopnet.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return 3; }
        Log($"start {Version} chan={dir}");
        try
        {
            link = opt.TryGetValue("tcp", out var port) ? new TcpLink(int.Parse(port), opt.GetValueOrDefault("name", "tcp-" + Environment.ProcessId))
                                                      : new SteamLink(Version);
        }
        catch (Exception e)
        {
            Log("link failed: " + e.Message);
            WriteStatus("offline", e.Message);
            return 4;
        }
        Process parent = null;
        if (opt.TryGetValue("parent", out var ppid)) try { parent = Process.GetProcessById(int.Parse(ppid)); } catch { return 5; }
        try { Run(parent); }
        catch (Exception e) { Log("crash: " + e); WriteStatus("offline", "crash: " + e.Message); }
        finally { link.Shutdown(); lockFile.Dispose(); }
        return 0;
    }

    static void Log(string s)
    {
        try { File.AppendAllText(logPath, $"{DateTime.Now:HH:mm:ss.fff} {s}\n"); } catch { }
    }

    // incoming file chunks: name -> parts
    static readonly Dictionary<string, byte[][]> partial = new();
    static long ctlOff;
    static double pingMs = -1;
    static readonly Stopwatch clock = Stopwatch.StartNew();
    static double lastRx, lastPing, lastStatus, lastParentCheck;
    static string sessionRole = ""; // what we told session.lua
    static string myMode = "car"; // the role's default (owner, 2026-10-24): with the own car
    // the host's run: its id, whether it runs, who was in the lobby when it started
    static int runId;
    static bool runActive, hadPeer;
    static readonly HashSet<ulong> runMembers = new();

    static void Run(Process parent)
    {
        var ctl = chan.Local("net-control.txt");
        ctlOff = File.Exists(ctl) ? new FileInfo(ctl).Length : 0; // older commands belong to an earlier game
        bool sawGame = false;
        while (true)
        {
            double now = clock.Elapsed.TotalSeconds;
            if (now - lastParentCheck > 2)
            {
                lastParentCheck = now;
                if (parent != null) { if (parent.HasExited) { Log("parent gone"); return; } }
                else
                {
                    bool game = Process.GetProcessesByName("PenDriverPro-Win64-Shipping").Length > 0;
                    if (game) sawGame = true; else if (sawGame) { Log("game gone"); return; }
                }
            }
            bool busy = false;
            // one bad turn (a file the game holds open, a Steam call failing) must not end the link: before, an
            // UnauthorizedAccessException from the status file's rename killed CoopNet (owner's real test)
            try
            {
                link.Pump();
                ReadControl(ctl);
                UpdateSession();
                busy = Exchange(now);
                busy |= Flush();
                RetryIncoming();
            }
            catch (Exception e) { LogOnce("loop: " + e.GetType().Name + ": " + e.Message); }
            if (now - lastStatus > 0.5) { lastStatus = now; WriteStatus(link.InLobby ? "lobby" : "idle", link.Error); }
            if (!busy) Thread.Sleep(15);
        }
    }

    static void ReadControl(string path)
    {
        if (!File.Exists(path)) return;
        string data;
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            if (fs.Length < ctlOff) ctlOff = 0;
            if (fs.Length == ctlOff) return;
            fs.Seek(ctlOff, SeekOrigin.Begin);
            var buf = new byte[fs.Length - ctlOff]; int n = fs.Read(buf, 0, buf.Length);
            int last = Array.LastIndexOf(buf, (byte)'\n', n - 1);
            if (last < 0) return;
            ctlOff += last + 1;
            data = Utf8.GetString(buf, 0, last);
        }
        foreach (var raw in data.Split('\n'))
        {
            var line = raw.Trim(); if (line == "") continue;
            var p = line.Split(' ', 2); var arg = p.Length > 1 ? p[1].Trim() : "";
            Log("cmd " + line);
            switch (p[0])
            {
                case "create": link.Create(); break;
                case "join": if (ulong.TryParse(arg, out var lid)) link.Join(lid); break;
                case "leave": link.Leave(); break;
                case "invite": if (ulong.TryParse(arg, out var fid)) link.InviteFriend(fid); break;
                case "mode": if (arg == "foot" || arg == "car") { myMode = arg; link.SetMine("mode", arg); Session("mode " + arg); } break;
                case "ready": link.SetMine("ready", arg == "1" ? "1" : "0"); break;
                case "start":
                    // the host left its garage for a run (session.lua, automatic): who is in the lobby now may join this run
                    // later too (owner: only those present at the start; a newcomer waits for the next run)
                    if (link.IsOwner)
                    {
                        runId++; runActive = true;
                        runMembers.Clear();
                        foreach (var m in link.Members()) if (!m.Me) runMembers.Add(m.Id);
                        if (link.HasPeer) Queue(Proto.Text('S', runId.ToString()));
                        Log($"start run {runId}: {runMembers.Count} member(s)");
                    }
                    break;
                case "runend": runActive = false; Log("run over"); break;
            }
        }
    }

    // the lobby decides the session role
    static void UpdateSession()
    {
        // a member of the running run (re)joined the lobby: it goes to the host's zone at once
        bool peer = link.HasPeer;
        if (peer && !hadPeer && link.IsOwner && runActive)
        {
            foreach (var m in link.Members())
                if (!m.Me && runMembers.Contains(m.Id)) { Queue(Proto.Text('R', runId.ToString())); Log($"run {runId}: member back, sent R"); }
        }
        hadPeer = peer;
        string want = !link.InLobby ? "" : link.IsOwner ? "host" : "client";
        if (want == sessionRole) return;
        if (want == "") Session("stop");
        else if (want == "host") Session("role host");
        else { Session("role client"); Session("mode " + myMode); }
        sessionRole = want;
        chan.SetRole(want == "" ? chan.Role : want);
        link.SetMine("mode", myMode);
    }

    static void Session(string line)
    {
        Log("session " + line);
        for (int i = 0; i < 20; i++)
        {
            try { File.AppendAllText(chan.Local("control.txt"), line + "\r\n"); return; }
            catch (Exception) { Thread.Sleep(25); } // the game reads it right now
        }
        Log("session line lost: " + line);
    }

    static bool Exchange(double now)
    {
        bool busy = false;
        if (link.HasPeer && chan.Role != "")
        {
            for (int ch = 0; ch < 2; ch++)
                foreach (var l in chan.ReadLines(ch)) { Queue(Proto.Text(ch == 0 ? 'L' : 'M', l)); busy = true; }
            foreach (var f in chan.OutgoingFiles())
            {
                byte[] data;
                try { data = File.ReadAllBytes(f); } catch (IOException) { continue; } // still being renamed
                SendFile(Path.GetFileName(f), data);
                chan.MarkSent(f);
                busy = true;
            }
            if (now - lastPing > 2 && outQ.Count < 4) { lastPing = now; Queue(Proto.Text('P', now.ToString("R"))); }
        }
        foreach (var m in link.Receive())
        {
            lastRx = now; busy = true;
            switch ((char)m[0])
            {
                case 'L': chan.AppendLine(0, Proto.TextOf(m)); break;
                case 'M': chan.AppendLine(1, Proto.TextOf(m)); break;
                case 'F': ReceiveChunk(m); break;
                case 'P': Queue(Proto.Text('Q', Proto.TextOf(m))); break;
                case 'Q': if (double.TryParse(Proto.TextOf(m), out var t0)) pingMs = (now - t0) * 1000; break;
                case 'S': case 'R':
                    if (!link.IsOwner) { Log((char)m[0] == 'S' ? "start received" : "back into the running run"); Session("mode " + myMode); Session("go"); }
                    break;
            }
        }
        return busy;
    }

    // Outgoing messages in order; the Steam send buffer can be full (LimitExceeded): they wait for the next turn.
    static readonly Queue<byte[]> outQ = new();
    static void Queue(byte[] m) => outQ.Enqueue(m);
    static bool Flush()
    {
        if (!link.HasPeer) { if (!link.InLobby) outQ.Clear(); return false; }
        bool sent = false;
        while (outQ.Count > 0)
        {
            if (link.Send(outQ.Peek())) { outQ.Dequeue(); sent = true; continue; }
            if (link.SendBufferFull) break; // later
            outQ.Dequeue(); // another error (link.Error says which): this one is lost
        }
        return sent;
    }
    static readonly Dictionary<string, byte[]> pendingIn = new();
    static void RetryIncoming()
    {
        foreach (var name in pendingIn.Keys.ToList())
        {
            try { chan.WriteIncomingFile(name, pendingIn[name]); pendingIn.Remove(name); Log($"file in {name} (retried)"); } catch (Exception) { }
        }
    }
    static readonly HashSet<string> logged = new();
    static void LogOnce(string s) { if (logged.Add(s)) Log(s); }

    // F <name>\t<index>\t<count>\n<bytes>
    static void SendFile(string name, byte[] data)
    {
        int count = Math.Max(1, (data.Length + FileChunk - 1) / FileChunk);
        for (int i = 0; i < count; i++)
        {
            int off = i * FileChunk, len = Math.Min(FileChunk, data.Length - off);
            var head = Utf8.GetBytes($"F{name}\t{i}\t{count}\n");
            var msg = new byte[head.Length + len];
            head.CopyTo(msg, 0); Array.Copy(data, off, msg, head.Length, len);
            Queue(msg);
        }
        Log($"file out {name} {data.Length} bytes");
    }

    static void ReceiveChunk(byte[] m)
    {
        int nl = Array.IndexOf(m, (byte)'\n');
        if (nl < 0) return;
        var h = Utf8.GetString(m, 1, nl - 1).Split('\t');
        if (h.Length != 3 || !int.TryParse(h[1], out var idx) || !int.TryParse(h[2], out var count) || count < 1 || idx >= count) return;
        if (!partial.TryGetValue(h[0], out var parts) || parts.Length != count) partial[h[0]] = parts = new byte[count][];
        parts[idx] = m.AsSpan(nl + 1).ToArray();
        if (parts.Any(p => p == null)) return;
        partial.Remove(h[0]);
        var all = parts.SelectMany(p => p).ToArray();
        try { chan.WriteIncomingFile(h[0], all); }
        catch (Exception) { pendingIn[h[0]] = all; } // the game holds the file open: again next turn
        Log($"file in {h[0]} {all.Length} bytes");
    }

    static string Clean(string s) => (s ?? "").Replace('\n', ' ').Replace('\r', ' ').Replace('\t', ' ');

    static void WriteStatus(string state, string err)
    {
        var sb = new StringBuilder();
        bool inLobby = link != null && link.InLobby;
        sb.Append($"state={state} lobby={(inLobby ? link.LobbyId : 0)} owner={(inLobby && link.IsOwner ? 1 : 0)} me={Clean(link?.MyName).Replace(' ', '_')} " +
                  $"peer={(link != null && link.HasPeer ? 1 : 0)} ping={(pingMs < 0 ? -1 : (int)pingMs)} err={Clean(err).Replace(' ', '_')}\n");
        if (link != null)
        {
            foreach (var m in link.Members())
                sb.Append($"member\t{m.Id}\t{(m.Owner ? 1 : 0)}\t{(m.Me ? 1 : 0)}\t{m.Mode}\t{(m.Ready ? 1 : 0)}\t{Clean(m.Name)}\n");
            foreach (var f in link.Friends().Take(100))
                sb.Append($"friend\t{f.Id}\t{(f.Online ? 1 : 0)}\t{(f.InGame ? 1 : 0)}\t{f.Lobby}\t{Clean(f.Name)}\n");
            foreach (var i in link.Invites)
                sb.Append($"invite\t{i.Lobby}\t{i.From}\t{Clean(i.FromName)}\n");
        }
        var path = chan.Local("net-status.txt");
        try { File.WriteAllText(path + ".tmp", sb.ToString(), Utf8); File.Move(path + ".tmp", path, true); }
        catch (Exception) { } // the game reads it right now (access denied): the next one in half a second
    }
}
