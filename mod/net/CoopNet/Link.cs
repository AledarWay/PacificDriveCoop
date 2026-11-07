using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Steamworks;

namespace CoopNet;

sealed class Member
{
    public ulong Id; public string Name = ""; public string Mode = "car"; public bool Ready; public bool Owner; public bool Me;
}
sealed class Friend { public ulong Id; public string Name = ""; public bool Online; public bool InGame; public ulong Lobby; }
sealed class Invite { public ulong Lobby; public ulong From; public string FromName = ""; }

// The lobby and the peer-to-peer link. SteamLink is the real one; TcpLink stands in for it in local tests
// (two games on one PC, no Steam accounts), with the same behaviour seen from the menu.
interface ILink
{
    string MyName { get; }
    bool InLobby { get; }
    bool IsOwner { get; }
    ulong LobbyId { get; }
    List<Member> Members();
    List<Friend> Friends();
    List<Invite> Invites { get; }
    string Error { get; }
    void Create();
    void Join(ulong lobby);
    void Leave();
    void InviteFriend(ulong friend);
    void SetMine(string key, string value);
    // the peer: the lobby owner for a guest, the (one, for now) guest for the owner
    bool HasPeer { get; }
    // false: not sent; SendBufferFull then says it is only for now (the send buffer is full: try again later)
    bool Send(byte[] msg);
    bool SendBufferFull { get; }
    List<byte[]> Receive();
    void Pump();
    void Shutdown();
}

sealed class SteamLink : ILink
{
    public const int MaxMembers = 2; // the mod syncs two players for now (3-4 is a later stage)
    const string Tag = "coopsync";
    readonly string version;
    CSteamID lobby = CSteamID.Nil;
    readonly CallResult<LobbyCreated_t> created;
    readonly CallResult<LobbyEnter_t> entered;
    readonly List<object> keep = new(); // the callbacks must stay referenced
    readonly HashSet<ulong> accepted = new();
    public List<Invite> Invites { get; } = new();
    public string Error { get; private set; } = "";
    public string MyName => SteamFriends.GetPersonaName();
    public bool InLobby => lobby.IsValid();
    public ulong LobbyId => lobby.m_SteamID;
    public bool IsOwner => InLobby && SteamMatchmaking.GetLobbyOwner(lobby) == SteamUser.GetSteamID();

    public SteamLink(string version)
    {
        this.version = version;
        if (!SteamAPI.Init()) throw new InvalidOperationException("SteamAPI.Init failed (is Steam running and logged in?)");
        SteamNetworkingUtils.InitRelayNetworkAccess();
        // the zone list (~0.8 MB) and the car layouts go out at once: the default 512 KB send buffer answered
        // k_EResultLimitExceeded (owner's real test); bigger buffer + the sender's queue (Program.Flush)
        var buf = GCHandle.Alloc(16 * 1024 * 1024, GCHandleType.Pinned);
        try
        {
            SteamNetworkingUtils.SetConfigValue(ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_SendBufferSize,
                ESteamNetworkingConfigScope.k_ESteamNetworkingConfig_Global, IntPtr.Zero, ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Int32, buf.AddrOfPinnedObject());
        }
        finally { buf.Free(); }
        created = CallResult<LobbyCreated_t>.Create(OnCreated);
        entered = CallResult<LobbyEnter_t>.Create(OnEntered);
        keep.Add(Callback<LobbyInvite_t>.Create(OnInvite));
        keep.Add(Callback<GameLobbyJoinRequested_t>.Create(r => Join(r.m_steamIDLobby.m_SteamID))); // accepted in Steam's UI
        keep.Add(Callback<SteamNetworkingMessagesSessionRequest_t>.Create(OnSessionRequest));
        keep.Add(Callback<SteamNetworkingMessagesSessionFailed_t>.Create(f =>
            Error = "p2p session failed: " + f.m_info.m_eEndReason + " " + f.m_info.m_szEndDebug));
    }

    public void Create()
    {
        if (InLobby) Leave();
        created.Set(SteamMatchmaking.CreateLobby(ELobbyType.k_ELobbyTypeFriendsOnly, MaxMembers));
    }
    void OnCreated(LobbyCreated_t r, bool ioFailure)
    {
        if (ioFailure || r.m_eResult != EResult.k_EResultOK) { Error = "create lobby: " + r.m_eResult; return; }
        lobby = new CSteamID(r.m_ulSteamIDLobby);
        SteamMatchmaking.SetLobbyData(lobby, Tag, version);
        SteamMatchmaking.SetLobbyData(lobby, "host", MyName);
        Error = "";
    }

    public void Join(ulong id)
    {
        if (InLobby && lobby.m_SteamID == id) return;
        if (InLobby) Leave();
        entered.Set(SteamMatchmaking.JoinLobby(new CSteamID(id)));
    }
    void OnEntered(LobbyEnter_t r, bool ioFailure)
    {
        if (ioFailure || r.m_EChatRoomEnterResponse != (uint)EChatRoomEnterResponse.k_EChatRoomEnterResponseSuccess)
        { Error = "join lobby: response " + r.m_EChatRoomEnterResponse; return; }
        var l = new CSteamID(r.m_ulSteamIDLobby);
        var v = SteamMatchmaking.GetLobbyData(l, Tag);
        if (v != version)
        {
            SteamMatchmaking.LeaveLobby(l);
            Error = v == "" ? "not a CoopSync lobby" : $"mod version differs: host {v}, mine {version}";
            return;
        }
        lobby = l;
        Invites.RemoveAll(i => i.Lobby == l.m_SteamID);
        Error = "";
    }

    public void Leave()
    {
        if (InLobby) SteamMatchmaking.LeaveLobby(lobby);
        lobby = CSteamID.Nil;
    }

    public void InviteFriend(ulong friend)
    {
        if (!InLobby) { Error = "invite: no lobby"; return; }
        if (!SteamMatchmaking.InviteUserToLobby(lobby, new CSteamID(friend))) Error = "invite failed";
    }

    void OnInvite(LobbyInvite_t r)
    {
        if (Invites.Any(i => i.Lobby == r.m_ulSteamIDLobby)) return;
        Invites.Add(new Invite { Lobby = r.m_ulSteamIDLobby, From = r.m_ulSteamIDUser, FromName = SteamFriends.GetFriendPersonaName(new CSteamID(r.m_ulSteamIDUser)) });
    }

    public void SetMine(string key, string value) { if (InLobby) SteamMatchmaking.SetLobbyMemberData(lobby, key, value); }

    public List<Member> Members()
    {
        var res = new List<Member>();
        if (!InLobby) return res;
        var owner = SteamMatchmaking.GetLobbyOwner(lobby); var me = SteamUser.GetSteamID();
        int n = SteamMatchmaking.GetNumLobbyMembers(lobby);
        for (int i = 0; i < n; i++)
        {
            var id = SteamMatchmaking.GetLobbyMemberByIndex(lobby, i);
            var mode = SteamMatchmaking.GetLobbyMemberData(lobby, id, "mode");
            res.Add(new Member
            {
                Id = id.m_SteamID, Name = SteamFriends.GetFriendPersonaName(id), Owner = id == owner, Me = id == me,
                Mode = mode == "" ? "car" : mode, Ready = SteamMatchmaking.GetLobbyMemberData(lobby, id, "ready") == "1",
            });
        }
        return res;
    }

    public List<Friend> Friends()
    {
        var res = new List<Friend>();
        int n = SteamFriends.GetFriendCount(EFriendFlags.k_EFriendFlagImmediate);
        for (int i = 0; i < n; i++)
        {
            var id = SteamFriends.GetFriendByIndex(i, EFriendFlags.k_EFriendFlagImmediate);
            var f = new Friend { Id = id.m_SteamID, Name = SteamFriends.GetFriendPersonaName(id),
                Online = SteamFriends.GetFriendPersonaState(id) != EPersonaState.k_EPersonaStateOffline };
            if (SteamFriends.GetFriendGamePlayed(id, out var g) && g.m_gameID.AppID() == SteamUtils.GetAppID())
            {
                f.InGame = true;
                if (g.m_steamIDLobby.IsValid()) f.Lobby = g.m_steamIDLobby.m_SteamID;
            }
            res.Add(f);
        }
        return res.OrderByDescending(f => f.InGame).ThenByDescending(f => f.Online).ThenBy(f => f.Name).ToList();
    }

    CSteamID Peer()
    {
        if (!InLobby) return CSteamID.Nil;
        var me = SteamUser.GetSteamID();
        if (!IsOwner) return SteamMatchmaking.GetLobbyOwner(lobby);
        int n = SteamMatchmaking.GetNumLobbyMembers(lobby);
        for (int i = 0; i < n; i++) { var id = SteamMatchmaking.GetLobbyMemberByIndex(lobby, i); if (id != me) return id; }
        return CSteamID.Nil;
    }
    public bool HasPeer => Peer().IsValid();
    public bool SendBufferFull { get; private set; }

    bool IsMember(CSteamID id)
    {
        if (!InLobby) return false;
        int n = SteamMatchmaking.GetNumLobbyMembers(lobby);
        for (int i = 0; i < n; i++) if (SteamMatchmaking.GetLobbyMemberByIndex(lobby, i) == id) return true;
        return false;
    }
    void OnSessionRequest(SteamNetworkingMessagesSessionRequest_t r)
    {
        var id = r.m_identityRemote.GetSteamID();
        if (IsMember(id)) { var ident = r.m_identityRemote; SteamNetworkingMessages.AcceptSessionWithUser(ref ident); accepted.Add(id.m_SteamID); }
    }

    public bool Send(byte[] msg)
    {
        var peer = Peer();
        if (!peer.IsValid()) return false;
        var ident = new SteamNetworkingIdentity(); ident.SetSteamID(peer);
        var h = GCHandle.Alloc(msg, GCHandleType.Pinned);
        try
        {
            var r = SteamNetworkingMessages.SendMessageToUser(ref ident, h.AddrOfPinnedObject(), (uint)msg.Length,
                Constants.k_nSteamNetworkingSend_ReliableNoNagle | Constants.k_nSteamNetworkingSend_AutoRestartBrokenSession, 0);
            SendBufferFull = r == EResult.k_EResultLimitExceeded;
            if (SendBufferFull) return false;
            if (r != EResult.k_EResultOK) { Error = "send: " + r; return false; }
            return true;
        }
        finally { h.Free(); }
    }

    readonly IntPtr[] rx = new IntPtr[64];
    public List<byte[]> Receive()
    {
        var res = new List<byte[]>();
        int n;
        while ((n = SteamNetworkingMessages.ReceiveMessagesOnChannel(0, rx, rx.Length)) > 0)
        {
            for (int i = 0; i < n; i++)
            {
                var m = Marshal.PtrToStructure<SteamNetworkingMessage_t>(rx[i]);
                if (IsMember(m.m_identityPeer.GetSteamID()))
                {
                    var b = new byte[m.m_cbSize];
                    Marshal.Copy(m.m_pData, b, 0, m.m_cbSize);
                    res.Add(b);
                }
                SteamNetworkingMessage_t.Release(rx[i]);
            }
        }
        return res;
    }

    public void Pump() => SteamAPI.RunCallbacks();
    public void Shutdown() { Leave(); SteamAPI.Shutdown(); }
}

// Local stand-in: "create" listens on 127.0.0.1:<port>, "join" connects to it. Frames: 4-byte length + bytes.
sealed class TcpLink : ILink
{
    readonly int port; readonly string name;
    TcpListener listener; TcpClient conn; NetworkStream stream;
    readonly List<byte> rxBuf = new();
    bool owner, inLobby;
    readonly Member peer = new();
    bool peerKnown;
    readonly Dictionary<string, string> mine = new();
    public List<Invite> Invites { get; } = new();
    public string Error { get; private set; } = "";
    public string MyName => name;
    public bool InLobby => inLobby;
    public bool IsOwner => inLobby && owner;
    public ulong LobbyId => inLobby ? (ulong)port : 0;

    public TcpLink(int port, string name) { this.port = port; this.name = name; }

    public void Create()
    {
        Leave();
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        owner = true; inLobby = true; Error = "";
    }
    public void Join(ulong lobby)
    {
        Leave();
        try
        {
            conn = new TcpClient(); conn.Connect(IPAddress.Loopback, port); conn.NoDelay = true; stream = conn.GetStream();
            owner = false; inLobby = true; Error = "";
            Hello();
        }
        catch (Exception e) { Error = "join: " + e.Message; conn = null; }
    }
    void Hello()
    {
        Send(Proto.Text('H', name));
        foreach (var kv in mine) Send(Proto.Text('D', kv.Key + "\t" + kv.Value));
    }
    public void Leave()
    {
        try { conn?.Close(); } catch { }
        try { listener?.Stop(); } catch { }
        conn = null; stream = null; listener = null; inLobby = false; peerKnown = false; rxBuf.Clear();
    }
    public void InviteFriend(ulong friend) { Error = "invite: not in the local test mode"; }
    public void SetMine(string key, string value) { mine[key] = value; if (stream != null) Send(Proto.Text('D', key + "\t" + value)); }

    public List<Member> Members()
    {
        var res = new List<Member>();
        if (!inLobby) return res;
        res.Add(new Member { Id = 1, Name = name, Me = true, Owner = owner, Mode = mine.GetValueOrDefault("mode", "car"), Ready = mine.GetValueOrDefault("ready") == "1" });
        if (peerKnown) res.Add(new Member { Id = 2, Name = peer.Name, Owner = !owner, Mode = peer.Mode, Ready = peer.Ready });
        return res;
    }
    public List<Friend> Friends() => new();
    public bool HasPeer => stream != null && peerKnown;
    public bool SendBufferFull => false;

    public bool Send(byte[] msg)
    {
        if (stream == null) return false;
        try { stream.Write(BitConverter.GetBytes(msg.Length)); stream.Write(msg); return true; }
        catch (Exception e) { Error = "send: " + e.Message; Drop(); return false; }
    }
    void Drop() { try { conn?.Close(); } catch { } conn = null; stream = null; peerKnown = false; rxBuf.Clear(); }

    public List<byte[]> Receive()
    {
        var res = new List<byte[]>();
        if (stream == null) return res;
        try
        {
            var buf = new byte[65536];
            while (stream.DataAvailable) { int n = stream.Read(buf, 0, buf.Length); if (n <= 0) break; rxBuf.AddRange(buf.AsSpan(0, n).ToArray()); }
        }
        catch (Exception e) { Error = "recv: " + e.Message; Drop(); return res; }
        while (rxBuf.Count >= 4)
        {
            int len = BitConverter.ToInt32(rxBuf.GetRange(0, 4).ToArray());
            if (rxBuf.Count < 4 + len) break;
            var m = rxBuf.GetRange(4, len).ToArray(); rxBuf.RemoveRange(0, 4 + len);
            // the link's own messages: the peer's name and member data
            if (m.Length > 0 && m[0] == 'H') { peer.Name = Proto.TextOf(m); peerKnown = true; continue; }
            if (m.Length > 0 && m[0] == 'D')
            {
                var kv = Proto.TextOf(m).Split('\t', 2);
                if (kv.Length == 2 && kv[0] == "mode") peer.Mode = kv[1];
                if (kv.Length == 2 && kv[0] == "ready") peer.Ready = kv[1] == "1";
                continue;
            }
            res.Add(m);
        }
        return res;
    }

    public void Pump()
    {
        if (listener != null && stream == null && listener.Pending())
        {
            conn = listener.AcceptTcpClient(); conn.NoDelay = true; stream = conn.GetStream();
            Hello();
        }
    }
    public void Shutdown() => Leave();
}

static class Proto
{
    static readonly UTF8Encoding Utf8 = new(false);
    public static byte[] Text(char type, string s)
    {
        var b = new byte[1 + Utf8.GetByteCount(s)];
        b[0] = (byte)type; Utf8.GetBytes(s, 0, s.Length, b, 1);
        return b;
    }
    public static string TextOf(byte[] m) => Utf8.GetString(m, 1, m.Length - 1);
}
