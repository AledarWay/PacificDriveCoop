using System.Text;

namespace CoopNet;

// The mod's side of the link: local files in the channel directory (UE4SS Lua has no sockets). Same layout as
// relay.ps1:
//   line channel 0 (state): host.events (host -> client), client.requests (client -> host)
//   line channel 1 (fast):  host.fast (host -> client),   client.fast (client -> host)
//   files: <chan>/outbox/<name> is sent whole and appears as <peer chan>/inbox/<name> (sent ones -> outbox/sent)
sealed class Channel
{
    static readonly UTF8Encoding Utf8 = new(false);
    readonly string dir, outbox, inbox, sent;
    string[] outFiles = new string[2], inFiles = new string[2];
    readonly long[] outOffsets = new long[2];
    public string Role { get; private set; } = "";

    public Channel(string dir)
    {
        this.dir = dir;
        outbox = Path.Combine(dir, "outbox"); inbox = Path.Combine(dir, "inbox"); sent = Path.Combine(outbox, "sent");
        foreach (var d in new[] { dir, outbox, inbox, sent }) Directory.CreateDirectory(d);
    }

    // host or client: which files go out. Lines already in the outgoing files belong to an earlier session.
    public void SetRole(string role)
    {
        if (role == Role) return;
        Role = role;
        bool host = role == "host";
        outFiles = host ? new[] { P("host.events"), P("host.fast") } : new[] { P("client.requests"), P("client.fast") };
        inFiles = host ? new[] { P("client.requests"), P("client.fast") } : new[] { P("host.events"), P("host.fast") };
        for (int i = 0; i < 2; i++) outOffsets[i] = File.Exists(outFiles[i]) ? new FileInfo(outFiles[i]).Length : 0;
    }
    string P(string name) => Path.Combine(dir, name);

    // new complete lines the game appended to an outgoing file (a shorter file = the game truncated it)
    public List<string> ReadLines(int ch)
    {
        var res = new List<string>();
        if (Role == "" || !File.Exists(outFiles[ch])) return res;
        using var fs = new FileStream(outFiles[ch], FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (fs.Length < outOffsets[ch]) outOffsets[ch] = 0;
        if (fs.Length == outOffsets[ch]) return res;
        fs.Seek(outOffsets[ch], SeekOrigin.Begin);
        var buf = new byte[fs.Length - outOffsets[ch]];
        int n = fs.Read(buf, 0, buf.Length);
        int last = Array.LastIndexOf(buf, (byte)'\n', n - 1);
        if (last < 0) return res;
        outOffsets[ch] += last + 1;
        foreach (var l in Utf8.GetString(buf, 0, last).Split('\n'))
        {
            var t = l.TrimEnd('\r');
            if (t.Length > 0) res.Add(t);
        }
        return res;
    }

    public void AppendLine(int ch, string line)
    {
        if (Role == "") return;
        using var fs = new FileStream(inFiles[ch], FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        var b = Utf8.GetBytes(line + "\n");
        fs.Write(b, 0, b.Length);
    }

    // finished outgoing files (*.tmp = the game is still writing it, then renames)
    public IEnumerable<string> OutgoingFiles() =>
        Directory.EnumerateFiles(outbox).Where(f => !f.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)).ToList();

    public void MarkSent(string path)
    {
        var to = Path.Combine(sent, Path.GetFileName(path));
        try { File.Move(path, to, true); } catch (Exception) { } // (access denied while the game looks: sent again, harmless)
    }

    public void WriteIncomingFile(string name, byte[] data)
    {
        name = Path.GetFileName(name); // never a path from the peer
        if (name.Length == 0) return;
        var part = Path.Combine(inbox, name + ".part");
        File.WriteAllBytes(part, data);
        File.Move(part, Path.Combine(inbox, name), true);
    }

    // a file in the channel directory itself (status, control)
    public string Local(string name) => Path.Combine(dir, name);
}
