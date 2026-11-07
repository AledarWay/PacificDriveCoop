// The in-game network (see net.hpp). A port of CoopNet (mod/net/CoopNet: Program.cs, Link.cs) to one worker thread.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "net.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <share.h>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;

namespace coopnet
{
namespace
{
    const char* const kVersion = "coopsync-net/2"; // the lobby tag: a CoopNet.exe lobby (coopsync-net/1) is refused
    const size_t kFileChunk = 256 * 1024;
    const size_t kLinesPerMsg = 200 * 1024; // bytes of lines packed into one message
    const size_t kQueueCap = 200000;        // lines waiting in or out (a peer gone for long): the oldest go

    std::string g_chan;
    std::FILE* g_log = nullptr;
    double now_s()
    {
        using namespace std::chrono;
        static const auto t0 = steady_clock::now();
        return duration<double>(steady_clock::now() - t0).count();
    }
    void log(const std::string& s)
    {
        if (!g_log) return;
        SYSTEMTIME t;
        GetLocalTime(&t);
        std::fprintf(g_log, "%02d:%02d:%02d.%03d %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, s.c_str());
        std::fflush(g_log);
    }
    std::set<std::string> g_logged;
    void log_once(const std::string& s)
    {
        if (g_logged.insert(s).second) log(s);
    }
    // UTF-8 <-> paths (the channel directory may hold a non-ASCII user name)
    fs::path upath(const std::string& s)
    {
        int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
        std::wstring w(n, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
        return fs::path(w);
    }
    std::string ustr(const fs::path& p)
    {
        const std::wstring& w = p.native();
        int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
        std::string s(n, '\0');
        WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
        return s;
    }
    fs::path P(const std::string& name) { return upath(g_chan) / upath(name); }

    Bytes text(char type, const std::string& s)
    {
        Bytes b(1 + s.size());
        b[0] = static_cast<uint8_t>(type);
        std::memcpy(b.data() + 1, s.data(), s.size());
        return b;
    }
    std::string text_of(const Bytes& m) { return std::string(reinterpret_cast<const char*>(m.data()) + 1, m.size() - 1); }
    std::string clean(std::string s)
    {
        for (auto& c : s)
            if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        return s;
    }
    std::string underscores(std::string s)
    {
        s = clean(s);
        std::replace(s.begin(), s.end(), ' ', '_');
        return s;
    }

    struct Member
    {
        uint64_t id = 0;
        std::string name, mode = "car";
        bool ready = false, owner = false, me = false;
    };
    struct Friend
    {
        uint64_t id = 0;
        std::string name;
        bool online = false, ingame = false;
        uint64_t lobby = 0;
    };
    struct Invite
    {
        uint64_t lobby = 0, from = 0;
        std::string from_name;
    };

    // the lobby and the peer-to-peer link (Link.cs's ILink)
    struct Link
    {
        virtual ~Link() = default;
        virtual std::string my_name() = 0;
        virtual bool in_lobby() = 0;
        virtual bool is_owner() = 0;
        virtual uint64_t lobby_id() = 0;
        virtual std::vector<Member> members() = 0;
        virtual std::vector<Friend> friends() { return {}; }
        virtual std::vector<Invite> invites() { return {}; }
        std::string error;
        virtual void create() = 0;
        virtual void join(uint64_t lobby) = 0;
        virtual void leave() = 0;
        virtual void invite(uint64_t) { error = "invite: not in the local test mode"; }
        virtual void set_mine(const std::string& key, const std::string& value) = 0;
        virtual bool has_peer() = 0;
        // false: not sent; send_buffer_full then says it is only for now
        virtual bool send(const Bytes& m) = 0;
        bool send_buffer_full = false;
        virtual void receive(std::vector<Bytes>& out) = 0;
        virtual void pump() = 0;
        virtual void shutdown() = 0;
    };

    // ------------------------------------------------------------------------------------------------------------
    // Steam: the game's steam_api64.dll (SDK 1.5x interfaces: Matchmaking v009, Friends v017, User v022, Utils v010,
    // NetworkingMessages v002, NetworkingUtils v004), its flat C exports. Structs as the SDK packs them on Windows (8).

    // the SDK's CCallbackBase, declared the same way so MSVC lays the vtable out as steam_api64.dll expects
    class CallbackBase
    {
      public:
        virtual void Run(void* param) = 0;
        virtual void Run(void* param, bool io_failure, uint64_t call) = 0;
        virtual int GetCallbackSizeBytes() = 0;
        uint8_t m_nCallbackFlags = 0;
        int m_iCallback = 0;
    };
    template <typename F> class Callback final : public CallbackBase
    {
      public:
        Callback(int id, int size, F f) : size_(size), f_(std::move(f)) { m_iCallback = id; }
        void Run(void* p) override { f_(static_cast<const uint8_t*>(p)); }
        void Run(void* p, bool, uint64_t) override { f_(static_cast<const uint8_t*>(p)); }
        int GetCallbackSizeBytes() override { return size_; }

      private:
        int size_;
        F f_;
    };

    template <typename T> T rd(const uint8_t* p, size_t off)
    {
        T v;
        std::memcpy(&v, p + off, sizeof(T));
        return v;
    }

    struct SteamApi
    {
        HMODULE dll = nullptr;
        void *mm = nullptr, *fr = nullptr, *us = nullptr, *ut = nullptr, *nm = nullptr, *nu = nullptr;
#define FN(name, ret, ...) ret (*name)(__VA_ARGS__) = nullptr
        FN(CreateLobby, uint64_t, void*, int, int);
        FN(JoinLobby, uint64_t, void*, uint64_t);
        FN(LeaveLobby, void, void*, uint64_t);
        FN(InviteUserToLobby, bool, void*, uint64_t, uint64_t);
        FN(GetNumLobbyMembers, int, void*, uint64_t);
        FN(GetLobbyMemberByIndex, uint64_t, void*, uint64_t, int);
        FN(GetLobbyData, const char*, void*, uint64_t, const char*);
        FN(SetLobbyData, bool, void*, uint64_t, const char*, const char*);
        FN(GetLobbyMemberData, const char*, void*, uint64_t, uint64_t, const char*);
        FN(SetLobbyMemberData, void, void*, uint64_t, const char*, const char*);
        FN(GetLobbyOwner, uint64_t, void*, uint64_t);
        FN(GetSteamID, uint64_t, void*);
        FN(GetPersonaName, const char*, void*);
        FN(GetFriendCount, int, void*, int);
        FN(GetFriendByIndex, uint64_t, void*, int, int);
        FN(GetFriendPersonaName, const char*, void*, uint64_t);
        FN(GetFriendPersonaState, int, void*, uint64_t);
        FN(GetFriendGamePlayed, bool, void*, uint64_t, void*);
        FN(GetAppID, uint32_t, void*);
        FN(IsAPICallCompleted, bool, void*, uint64_t, bool*);
        FN(GetAPICallResult, bool, void*, uint64_t, void*, int, int, bool*);
        FN(SendMessageToUser, int, void*, const void*, const void*, uint32_t, int, int);
        FN(ReceiveMessagesOnChannel, int, void*, int, void**, int);
        FN(AcceptSessionWithUser, bool, void*, const void*);
        FN(SetConfigValue, bool, void*, int, int, intptr_t, int, const void*);
        FN(InitRelayNetworkAccess, void, void*);
        FN(IdentitySetSteamID64, void, void*, uint64_t);
        FN(MessageRelease, void, void*);
        FN(RegisterCallback, void, void*, int);
        FN(UnregisterCallback, void, void*);
#undef FN

        template <typename T> bool get(T& f, const char* name)
        {
            f = reinterpret_cast<T>(GetProcAddress(dll, name));
            if (!f) log(std::string("steam: no export ") + name);
            return f != nullptr;
        }
        template <typename T> void* iface(const char* name)
        {
            T f = nullptr;
            if (!get(f, name)) return nullptr;
            return f();
        }
        bool load(std::string& err)
        {
            dll = GetModuleHandleW(L"steam_api64.dll");
            if (!dll) { err = "steam_api64.dll not loaded by the game"; return false; }
            using Acc = void* (*)();
            us = iface<Acc>("SteamAPI_SteamUser_v022");
            if (!us) { err = "Steam not initialized by the game (is Steam running and logged in?)"; return false; }
            mm = iface<Acc>("SteamAPI_SteamMatchmaking_v009");
            fr = iface<Acc>("SteamAPI_SteamFriends_v017");
            ut = iface<Acc>("SteamAPI_SteamUtils_v010");
            nm = iface<Acc>("SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
            nu = iface<Acc>("SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
            bool ok = mm && fr && ut && nm && nu;
            ok &= get(CreateLobby, "SteamAPI_ISteamMatchmaking_CreateLobby");
            ok &= get(JoinLobby, "SteamAPI_ISteamMatchmaking_JoinLobby");
            ok &= get(LeaveLobby, "SteamAPI_ISteamMatchmaking_LeaveLobby");
            ok &= get(InviteUserToLobby, "SteamAPI_ISteamMatchmaking_InviteUserToLobby");
            ok &= get(GetNumLobbyMembers, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
            ok &= get(GetLobbyMemberByIndex, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex");
            ok &= get(GetLobbyData, "SteamAPI_ISteamMatchmaking_GetLobbyData");
            ok &= get(SetLobbyData, "SteamAPI_ISteamMatchmaking_SetLobbyData");
            ok &= get(GetLobbyMemberData, "SteamAPI_ISteamMatchmaking_GetLobbyMemberData");
            ok &= get(SetLobbyMemberData, "SteamAPI_ISteamMatchmaking_SetLobbyMemberData");
            ok &= get(GetLobbyOwner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner");
            ok &= get(GetSteamID, "SteamAPI_ISteamUser_GetSteamID");
            ok &= get(GetPersonaName, "SteamAPI_ISteamFriends_GetPersonaName");
            ok &= get(GetFriendCount, "SteamAPI_ISteamFriends_GetFriendCount");
            ok &= get(GetFriendByIndex, "SteamAPI_ISteamFriends_GetFriendByIndex");
            ok &= get(GetFriendPersonaName, "SteamAPI_ISteamFriends_GetFriendPersonaName");
            ok &= get(GetFriendPersonaState, "SteamAPI_ISteamFriends_GetFriendPersonaState");
            ok &= get(GetFriendGamePlayed, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
            ok &= get(GetAppID, "SteamAPI_ISteamUtils_GetAppID");
            ok &= get(IsAPICallCompleted, "SteamAPI_ISteamUtils_IsAPICallCompleted");
            ok &= get(GetAPICallResult, "SteamAPI_ISteamUtils_GetAPICallResult");
            ok &= get(SendMessageToUser, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
            ok &= get(ReceiveMessagesOnChannel, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
            ok &= get(AcceptSessionWithUser, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
            ok &= get(SetConfigValue, "SteamAPI_ISteamNetworkingUtils_SetConfigValue");
            ok &= get(InitRelayNetworkAccess, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
            ok &= get(IdentitySetSteamID64, "SteamAPI_SteamNetworkingIdentity_SetSteamID64");
            ok &= get(MessageRelease, "SteamAPI_SteamNetworkingMessage_t_Release");
            ok &= get(RegisterCallback, "SteamAPI_RegisterCallback");
            ok &= get(UnregisterCallback, "SteamAPI_UnregisterCallback");
            if (!ok) err = "steam_api64.dll: an interface or export is missing (see net.log)";
            return ok;
        }
    };

    // SteamNetworkingIdentity: type (int), size (int), then a 128-byte union (the SteamID at offset 8); 136 bytes
    struct alignas(8) Identity
    {
        uint8_t raw[136] = {};
    };

    // the callbacks come on the thread that pumps Steam (the game's): they only queue for the worker
    std::mutex g_cb_mu;
    std::vector<Invite> g_cb_invites;
    std::vector<uint64_t> g_cb_join_requests;
    std::vector<Identity> g_cb_session_requests;

    class SteamLink final : public Link
    {
      public:
        static constexpr int kMaxMembers = 2; // two players for now (3-4 is a later stage)

        explicit SteamLink(std::string& err)
        {
            if (!api.load(err)) { ok = false; return; }
            api.InitRelayNetworkAccess(api.nu);
            // the zone list (~0.8 MB) and the car layouts go out at once: the default 512 KB send buffer answered
            // k_EResultLimitExceeded (owner's real test); a bigger buffer + the sender's queue (flush())
            int32_t buf = 16 * 1024 * 1024;
            api.SetConfigValue(api.nu, 9 /*SendBufferSize*/, 1 /*Global*/, 0, 1 /*Int32*/, &buf);
            me = api.GetSteamID(api.us);
            app = api.GetAppID(api.ut);
            auto invite = [](const uint8_t* p) {
                std::lock_guard<std::mutex> l(g_cb_mu);
                Invite i;
                i.from = rd<uint64_t>(p, 0);
                i.lobby = rd<uint64_t>(p, 8);
                g_cb_invites.push_back(i);
            };
            auto join_req = [](const uint8_t* p) {
                std::lock_guard<std::mutex> l(g_cb_mu);
                g_cb_join_requests.push_back(rd<uint64_t>(p, 0));
            };
            auto session_req = [](const uint8_t* p) {
                std::lock_guard<std::mutex> l(g_cb_mu);
                Identity id;
                std::memcpy(id.raw, p, sizeof id.raw);
                g_cb_session_requests.push_back(id);
            };
            cb_invite = std::make_unique<Callback<decltype(invite)>>(503 /*LobbyInvite_t*/, 24, invite);
            cb_join = std::make_unique<Callback<decltype(join_req)>>(333 /*GameLobbyJoinRequested_t*/, 16, join_req);
            cb_session = std::make_unique<Callback<decltype(session_req)>>(1251 /*SessionRequest_t*/, 136, session_req);
            api.RegisterCallback(cb_invite.get(), 503);
            api.RegisterCallback(cb_join.get(), 333);
            api.RegisterCallback(cb_session.get(), 1251);
            ok = true;
            log("steam: me " + std::to_string(me) + " app " + std::to_string(app) + " (" + my_name() + ")");
        }
        bool ok = false;

        std::string my_name() override
        {
            const char* n = api.GetPersonaName(api.fr);
            return n ? n : "";
        }
        bool in_lobby() override { return lobby != 0; }
        bool is_owner() override { return in_lobby() && api.GetLobbyOwner(api.mm, lobby) == me; }
        uint64_t lobby_id() override { return lobby; }

        void create() override
        {
            if (in_lobby()) leave();
            create_call = api.CreateLobby(api.mm, 1 /*FriendsOnly*/, kMaxMembers);
        }
        void join(uint64_t id) override
        {
            if (in_lobby() && lobby == id) return;
            if (in_lobby()) leave();
            join_call = api.JoinLobby(api.mm, id);
        }
        void leave() override
        {
            if (in_lobby()) api.LeaveLobby(api.mm, lobby);
            lobby = 0;
        }
        void invite(uint64_t friend_id) override
        {
            if (!in_lobby()) { error = "invite: no lobby"; return; }
            if (!api.InviteUserToLobby(api.mm, lobby, friend_id)) error = "invite failed";
        }
        void set_mine(const std::string& key, const std::string& value) override
        {
            if (in_lobby()) api.SetLobbyMemberData(api.mm, lobby, key.c_str(), value.c_str());
        }
        std::vector<Invite> invites() override { return invite_list; }

        std::vector<Member> members() override
        {
            std::vector<Member> res;
            if (!in_lobby()) return res;
            uint64_t owner = api.GetLobbyOwner(api.mm, lobby);
            int n = api.GetNumLobbyMembers(api.mm, lobby);
            for (int i = 0; i < n; ++i)
            {
                Member m;
                m.id = api.GetLobbyMemberByIndex(api.mm, lobby, i);
                m.name = str(api.GetFriendPersonaName(api.fr, m.id));
                m.owner = m.id == owner;
                m.me = m.id == me;
                std::string mode = str(api.GetLobbyMemberData(api.mm, lobby, m.id, "mode"));
                m.mode = mode.empty() ? "car" : mode;
                m.ready = str(api.GetLobbyMemberData(api.mm, lobby, m.id, "ready")) == "1";
                res.push_back(m);
            }
            return res;
        }

        std::vector<Friend> friends() override
        {
            std::vector<Friend> res;
            int n = api.GetFriendCount(api.fr, 4 /*Immediate*/);
            for (int i = 0; i < n; ++i)
            {
                Friend f;
                f.id = api.GetFriendByIndex(api.fr, i, 4);
                f.name = str(api.GetFriendPersonaName(api.fr, f.id));
                f.online = api.GetFriendPersonaState(api.fr, f.id) != 0 /*Offline*/;
                // FriendGameInfo_t: game id (app id in the low 24 bits), ip, ports, lobby at 16
                alignas(8) uint8_t g[24] = {};
                if (api.GetFriendGamePlayed(api.fr, f.id, g) && (rd<uint64_t>(g, 0) & 0xFFFFFF) == app)
                {
                    f.ingame = true;
                    f.lobby = rd<uint64_t>(g, 16);
                }
                res.push_back(f);
            }
            std::stable_sort(res.begin(), res.end(), [](const Friend& a, const Friend& b) {
                if (a.ingame != b.ingame) return a.ingame;
                if (a.online != b.online) return a.online;
                return a.name < b.name;
            });
            return res;
        }

        bool has_peer() override { return peer() != 0; }

        bool send(const Bytes& m) override
        {
            uint64_t p = peer();
            if (!p) return false;
            Identity id;
            api.IdentitySetSteamID64(id.raw, p);
            int r = api.SendMessageToUser(api.nm, id.raw, m.data(), static_cast<uint32_t>(m.size()),
                                          8 /*Reliable*/ | 1 /*NoNagle*/ | 32 /*AutoRestartBrokenSession*/, 0);
            send_buffer_full = r == 25 /*LimitExceeded*/;
            if (send_buffer_full) return false;
            if (r != 1 /*OK*/) { error = "send: EResult " + std::to_string(r); return false; }
            return true;
        }

        void receive(std::vector<Bytes>& out) override
        {
            void* rx[64];
            int n;
            while ((n = api.ReceiveMessagesOnChannel(api.nm, 0, rx, 64)) > 0)
            {
                for (int i = 0; i < n; ++i)
                {
                    // SteamNetworkingMessage_t: data, size, connection, the sender's identity (type at 16, id at 24)
                    auto msg = static_cast<const uint8_t*>(rx[i]);
                    auto data = rd<const uint8_t*>(msg, 0);
                    int size = rd<int>(msg, 8);
                    int type = rd<int>(msg, 16);
                    uint64_t from = rd<uint64_t>(msg, 24);
                    if (type != 16 /*SteamID*/) log_once("steam: a message with identity type " + std::to_string(type));
                    if (is_member(from) && data && size > 0) out.emplace_back(data, data + size);
                    api.MessageRelease(rx[i]);
                }
            }
        }

        void pump() override
        {
            bool failed = false;
            if (create_call && api.IsAPICallCompleted(api.ut, create_call, &failed))
            {
                // LobbyCreated_t (513): result at 0, lobby at 8
                alignas(8) uint8_t r[16] = {};
                bool got = api.GetAPICallResult(api.ut, create_call, r, sizeof r, 513, &failed);
                create_call = 0;
                int result = rd<int>(r, 0);
                if (!got || failed || result != 1) error = "create lobby: EResult " + std::to_string(got ? result : -1);
                else
                {
                    lobby = rd<uint64_t>(r, 8);
                    api.SetLobbyData(api.mm, lobby, "coopsync", kVersion);
                    api.SetLobbyData(api.mm, lobby, "host", my_name().c_str());
                    error.clear();
                    log("lobby created " + std::to_string(lobby));
                }
            }
            if (join_call && api.IsAPICallCompleted(api.ut, join_call, &failed))
            {
                // LobbyEnter_t (504): lobby at 0, permissions 8, locked 12, response at 16
                alignas(8) uint8_t r[24] = {};
                bool got = api.GetAPICallResult(api.ut, join_call, r, sizeof r, 504, &failed);
                join_call = 0;
                uint32_t resp = rd<uint32_t>(r, 16);
                uint64_t l = rd<uint64_t>(r, 0);
                if (!got || failed || resp != 1 /*Success*/) error = "join lobby: response " + std::to_string(got ? static_cast<int>(resp) : -1);
                else
                {
                    std::string v = str(api.GetLobbyData(api.mm, l, "coopsync"));
                    if (v != kVersion)
                    {
                        api.LeaveLobby(api.mm, l);
                        error = v.empty() ? "not a CoopSync lobby" : "mod version differs: host " + v + ", mine " + kVersion;
                    }
                    else
                    {
                        lobby = l;
                        invite_list.erase(std::remove_if(invite_list.begin(), invite_list.end(), [&](const Invite& i) { return i.lobby == l; }),
                                          invite_list.end());
                        error.clear();
                        log("lobby joined " + std::to_string(l));
                    }
                }
            }
            std::vector<Invite> inv;
            std::vector<uint64_t> joins;
            std::vector<Identity> sessions;
            {
                std::lock_guard<std::mutex> l(g_cb_mu);
                inv.swap(g_cb_invites);
                joins.swap(g_cb_join_requests);
                sessions.swap(g_cb_session_requests);
            }
            for (auto& i : inv)
            {
                if (std::any_of(invite_list.begin(), invite_list.end(), [&](const Invite& x) { return x.lobby == i.lobby; })) continue;
                i.from_name = str(api.GetFriendPersonaName(api.fr, i.from));
                invite_list.push_back(i);
            }
            for (uint64_t j : joins) join(j); // accepted in Steam's own UI
            for (auto& s : sessions)
                if (is_member(rd<uint64_t>(s.raw, 8))) api.AcceptSessionWithUser(api.nm, s.raw);
        }

        void shutdown() override
        {
            leave();
            if (cb_invite) api.UnregisterCallback(cb_invite.get());
            if (cb_join) api.UnregisterCallback(cb_join.get());
            if (cb_session) api.UnregisterCallback(cb_session.get());
        }

      private:
        SteamApi api;
        uint64_t me = 0, lobby = 0, create_call = 0, join_call = 0;
        uint32_t app = 0;
        std::vector<Invite> invite_list;
        std::unique_ptr<CallbackBase> cb_invite, cb_join, cb_session;

        static std::string str(const char* s) { return s ? s : ""; }
        // the peer: the lobby owner for a guest, the (one, for now) guest for the owner
        uint64_t peer()
        {
            if (!in_lobby()) return 0;
            if (!is_owner()) return api.GetLobbyOwner(api.mm, lobby);
            int n = api.GetNumLobbyMembers(api.mm, lobby);
            for (int i = 0; i < n; ++i)
            {
                uint64_t id = api.GetLobbyMemberByIndex(api.mm, lobby, i);
                if (id != me) return id;
            }
            return 0;
        }
        bool is_member(uint64_t id)
        {
            if (!in_lobby()) return false;
            int n = api.GetNumLobbyMembers(api.mm, lobby);
            for (int i = 0; i < n; ++i)
                if (api.GetLobbyMemberByIndex(api.mm, lobby, i) == id) return true;
            return false;
        }
    };

    // ------------------------------------------------------------------------------------------------------------
    // The local stand-in: "create" listens on 127.0.0.1:<port>, "join" connects to it. Frames: 4-byte length + bytes.
    class TcpLink final : public Link
    {
      public:
        TcpLink(int port, std::string name) : port_(port), name_(std::move(name))
        {
            WSADATA w;
            WSAStartup(MAKEWORD(2, 2), &w);
        }
        std::string my_name() override { return name_; }
        bool in_lobby() override { return in_lobby_; }
        bool is_owner() override { return in_lobby_ && owner_; }
        uint64_t lobby_id() override { return in_lobby_ ? static_cast<uint64_t>(port_) : 0; }

        void create() override
        {
            leave();
            listener_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in a = addr();
            if (bind(listener_, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0 || listen(listener_, 1) != 0)
            {
                error = "create: cannot listen on " + std::to_string(port_) + " (" + std::to_string(WSAGetLastError()) + ")";
                closesocket(listener_);
                listener_ = INVALID_SOCKET;
                return;
            }
            nonblocking(listener_);
            owner_ = true;
            in_lobby_ = true;
            error.clear();
        }
        void join(uint64_t) override
        {
            leave();
            conn_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in a = addr();
            if (connect(conn_, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0)
            {
                error = "join: " + std::to_string(WSAGetLastError());
                closesocket(conn_);
                conn_ = INVALID_SOCKET;
                return;
            }
            setup(conn_);
            owner_ = false;
            in_lobby_ = true;
            error.clear();
            hello();
        }
        void leave() override
        {
            drop();
            if (listener_ != INVALID_SOCKET) closesocket(listener_);
            listener_ = INVALID_SOCKET;
            in_lobby_ = false;
        }
        void set_mine(const std::string& key, const std::string& value) override
        {
            mine_[key] = value;
            if (conn_ != INVALID_SOCKET) send(text('D', key + "\t" + value));
        }
        std::vector<Member> members() override
        {
            std::vector<Member> res;
            if (!in_lobby_) return res;
            Member m;
            m.id = 1;
            m.name = name_;
            m.me = true;
            m.owner = owner_;
            m.mode = mine_.count("mode") ? mine_["mode"] : "car";
            m.ready = mine_.count("ready") && mine_["ready"] == "1";
            res.push_back(m);
            if (peer_known_)
            {
                Member p = peer_;
                p.id = 2;
                p.owner = !owner_;
                res.push_back(p);
            }
            return res;
        }
        bool has_peer() override { return conn_ != INVALID_SOCKET && peer_known_; }
        // the other game on this PC (two copies started by the two-games script): its lobby, if it made one, is
        // joined through the menu's lobby row like a friend's (a join with no lobby there fails with an error);
        // the menu shows the name "local-copy" in words of its own
        std::vector<Friend> friends() override
        {
            if (in_lobby_) return {};
            Friend f;
            f.id = static_cast<uint64_t>(port_);
            f.name = "local-copy";
            f.online = f.ingame = true;
            f.lobby = static_cast<uint64_t>(port_);
            return { f };
        }

        bool send(const Bytes& m) override
        {
            if (conn_ == INVALID_SOCKET) return false;
            uint32_t len = static_cast<uint32_t>(m.size());
            auto lp = reinterpret_cast<const uint8_t*>(&len);
            tx_.insert(tx_.end(), lp, lp + 4);
            tx_.insert(tx_.end(), m.begin(), m.end());
            flush_tx();
            return conn_ != INVALID_SOCKET;
        }

        void receive(std::vector<Bytes>& out) override
        {
            if (conn_ == INVALID_SOCKET) return;
            flush_tx();
            char buf[65536];
            while (conn_ != INVALID_SOCKET)
            {
                int n = recv(conn_, buf, sizeof buf, 0);
                if (n > 0) { rx_.insert(rx_.end(), buf, buf + n); continue; }
                if (n == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) break;
                error = n == 0 ? "recv: the other side closed" : "recv: " + std::to_string(WSAGetLastError());
                drop();
                return;
            }
            size_t off = 0;
            while (rx_.size() - off >= 4)
            {
                uint32_t len;
                std::memcpy(&len, rx_.data() + off, 4);
                if (rx_.size() - off < 4 + static_cast<size_t>(len)) break;
                Bytes m(rx_.begin() + off + 4, rx_.begin() + off + 4 + len);
                off += 4 + len;
                // the link's own messages: the peer's name and member data
                if (!m.empty() && m[0] == 'H') { peer_.name = text_of(m); peer_known_ = true; continue; }
                if (!m.empty() && m[0] == 'D')
                {
                    std::string kv = text_of(m);
                    auto t = kv.find('\t');
                    if (t != std::string::npos)
                    {
                        std::string k = kv.substr(0, t), v = kv.substr(t + 1);
                        if (k == "mode") peer_.mode = v;
                        if (k == "ready") peer_.ready = v == "1";
                    }
                    continue;
                }
                out.push_back(std::move(m));
            }
            rx_.erase(rx_.begin(), rx_.begin() + off);
        }

        void pump() override
        {
            if (listener_ != INVALID_SOCKET && conn_ == INVALID_SOCKET)
            {
                SOCKET s = accept(listener_, nullptr, nullptr);
                if (s != INVALID_SOCKET)
                {
                    conn_ = s;
                    setup(conn_);
                    hello();
                }
            }
            flush_tx();
        }
        void shutdown() override { leave(); }

      private:
        int port_;
        std::string name_;
        SOCKET listener_ = INVALID_SOCKET, conn_ = INVALID_SOCKET;
        Bytes rx_, tx_;
        bool owner_ = false, in_lobby_ = false, peer_known_ = false;
        Member peer_;
        std::map<std::string, std::string> mine_;

        sockaddr_in addr()
        {
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(static_cast<u_short>(port_));
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            return a;
        }
        static void nonblocking(SOCKET s)
        {
            u_long on = 1;
            ioctlsocket(s, FIONBIO, &on);
        }
        static void setup(SOCKET s)
        {
            nonblocking(s);
            BOOL nd = TRUE;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nd), sizeof nd);
        }
        void hello()
        {
            send(text('H', name_));
            for (auto& kv : mine_) send(text('D', kv.first + "\t" + kv.second));
        }
        void drop()
        {
            if (conn_ != INVALID_SOCKET) closesocket(conn_);
            conn_ = INVALID_SOCKET;
            peer_known_ = false;
            rx_.clear();
            tx_.clear();
        }
        void flush_tx()
        {
            while (conn_ != INVALID_SOCKET && !tx_.empty())
            {
                int n = ::send(conn_, reinterpret_cast<const char*>(tx_.data()), static_cast<int>(std::min<size_t>(tx_.size(), 1 << 20)), 0);
                if (n > 0) { tx_.erase(tx_.begin(), tx_.begin() + n); continue; }
                if (WSAGetLastError() == WSAEWOULDBLOCK) return;
                error = "send: " + std::to_string(WSAGetLastError());
                drop();
            }
        }
    };

    // ------------------------------------------------------------------------------------------------------------
    // shared with the Lua calls (game thread): g_mu
    std::mutex g_mu;
    std::condition_variable g_wake;
    std::deque<std::string> g_cmds, g_session;
    std::deque<std::string> g_out[2], g_in[2];
    std::string g_status;
    std::thread g_thread;
    std::atomic<bool> g_quit{false};
    bool g_started = false;
    bool g_test_ctl = false; // the local test mode: the tests' <chan>/net-control.txt lines too

    // the worker's own state (Program.cs)
    std::unique_ptr<Link> g_link;
    std::string g_link_err;
    double g_ping_ms = -1, g_last_ping = 0, g_last_status = 0, g_last_outbox = 0, g_last_ctl = 0;
    std::string g_role; // what the session was told
    std::string g_chan_role;
    std::string g_mode = "car";
    int g_run_id = 0;
    bool g_run_active = false, g_had_peer = false;
    std::set<uint64_t> g_run_members;
    std::deque<Bytes> g_q; // outgoing messages in order (the Steam send buffer may be full: they wait)
    std::map<std::string, std::vector<Bytes>> g_partial;
    std::map<std::string, std::vector<bool>> g_partial_have;
    // documents (2026-10-26: no inbox / outbox files any more): the host's zone list, run descriptor, gates, map and
    // session line. out = this side's latest (Lua puts), in = the peer's latest; versions count the changes.
    struct Doc
    {
        std::string data;
        int64_t version = 0;
    };
    std::map<std::string, Doc> g_docs_out, g_docs_in;
    std::set<std::string> g_docs_dirty;
    uint64_t g_ctl_off = 0;

    void session(const std::string& line)
    {
        log("session " + line);
        std::lock_guard<std::mutex> l(g_mu);
        g_session.push_back(line);
    }

    void handle(const std::string& line)
    {
        auto sp = line.find(' ');
        std::string cmd = line.substr(0, sp), arg = sp == std::string::npos ? "" : line.substr(sp + 1);
        while (!arg.empty() && (arg.back() == ' ' || arg.back() == '\r')) arg.pop_back();
        log("cmd " + line);
        Link& k = *g_link;
        if (cmd == "create") k.create();
        else if (cmd == "join") { try { k.join(std::stoull(arg)); } catch (...) {} }
        else if (cmd == "leave") k.leave();
        else if (cmd == "invite") { try { k.invite(std::stoull(arg)); } catch (...) {} }
        else if (cmd == "mode")
        {
            if (arg == "foot" || arg == "car") { g_mode = arg; k.set_mine("mode", arg); session("mode " + arg); }
        }
        else if (cmd == "ready") k.set_mine("ready", arg == "1" ? "1" : "0");
        else if (cmd == "start")
        {
            // the host left its garage for a run (session.lua, automatic): who is in the lobby now may join this run
            // later too (owner: only those present at the start; a newcomer waits for the next run)
            if (k.is_owner())
            {
                ++g_run_id;
                g_run_active = true;
                g_run_members.clear();
                for (auto& m : k.members())
                    if (!m.me) g_run_members.insert(m.id);
                if (k.has_peer()) g_q.push_back(text('S', std::to_string(g_run_id)));
                log("start run " + std::to_string(g_run_id) + ": " + std::to_string(g_run_members.size()) + " member(s)");
            }
        }
        else if (cmd == "runend") { g_run_active = false; log("run over"); }
    }

    // the tests write the menu's commands into <chan>/net-control.txt (as they did for CoopNet)
    void read_test_control(std::vector<std::string>& out)
    {
        // shared for writing: the test appends while this looks (an ifstream locked it out)
        HANDLE h = CreateFileW(P("net-control.txt").c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) return;
        LARGE_INTEGER sz{};
        GetFileSizeEx(h, &sz);
        uint64_t size = static_cast<uint64_t>(sz.QuadPart);
        if (size < g_ctl_off) g_ctl_off = 0;
        std::string data;
        if (size > g_ctl_off)
        {
            data.assign(static_cast<size_t>(size - g_ctl_off), ' ');
            LARGE_INTEGER off{};
            off.QuadPart = static_cast<LONGLONG>(g_ctl_off);
            SetFilePointerEx(h, off, nullptr, FILE_BEGIN);
            DWORD got = 0;
            ReadFile(h, data.data(), static_cast<DWORD>(data.size()), &got, nullptr);
            data.resize(got);
        }
        CloseHandle(h);
        auto last = data.rfind('\n');
        if (last == std::string::npos) return;
        g_ctl_off += last + 1;
        size_t s = 0;
        while (s <= last)
        {
            auto e = data.find('\n', s);
            std::string l = data.substr(s, e - s);
            while (!l.empty() && (l.back() == '\r' || l.back() == ' ')) l.pop_back();
            if (!l.empty()) out.push_back(l);
            s = e + 1;
        }
    }

    // A guest entering a lobby forgets the documents of an earlier lobby (alpha 9: a day-old host-session / host-run in
    // its inbox sent it to another map). In the worker, before anything of this lobby is received.
    void clear_docs_in()
    {
        std::lock_guard<std::mutex> l(g_mu);
        log("documents in cleared (" + std::to_string(g_docs_in.size()) + ")");
        g_docs_in.clear();
        g_partial.clear();
        g_partial_have.clear();
    }
    // A new peer gets every document of this side again (its latest version).
    void resend_docs()
    {
        std::lock_guard<std::mutex> l(g_mu);
        for (auto& d : g_docs_out) g_docs_dirty.insert(d.first);
        log("new peer: " + std::to_string(g_docs_out.size()) + " documents to send");
    }

    // the lobby decides the session role
    void update_session()
    {
        Link& k = *g_link;
        // a member of the running run (re)joined the lobby: it goes to the host's zone at once
        bool peer = k.has_peer();
        if (peer && !g_had_peer && k.is_owner() && g_run_active)
        {
            for (auto& m : k.members())
                if (!m.me && g_run_members.count(m.id))
                {
                    g_q.push_back(text('R', std::to_string(g_run_id)));
                    log("run " + std::to_string(g_run_id) + ": member back, sent R");
                }
        }
        if (peer && !g_had_peer) resend_docs();
        g_had_peer = peer;
        std::string want = !k.in_lobby() ? "" : k.is_owner() ? "host" : "client";
        if (want == g_role) return;
        if (want.empty()) session("stop");
        else if (want == "host") session("role host");
        else { clear_docs_in(); session("role client"); session("mode " + g_mode); }
        g_role = want;
        if (!want.empty() && want != g_chan_role)
        {
            // lines queued for the other role belong to an earlier session
            g_chan_role = want;
            std::lock_guard<std::mutex> l(g_mu);
            g_out[0].clear();
            g_out[1].clear();
        }
        k.set_mine("mode", g_mode);
    }

    // F <name>\t<index>\t<count>\n<bytes>
    void send_file(const std::string& name, const Bytes& data)
    {
        size_t count = std::max<size_t>(1, (data.size() + kFileChunk - 1) / kFileChunk);
        for (size_t i = 0; i < count; ++i)
        {
            size_t off = i * kFileChunk, len = std::min(kFileChunk, data.size() - std::min(off, data.size()));
            std::string head = "F" + name + "\t" + std::to_string(i) + "\t" + std::to_string(count) + "\n";
            Bytes m(head.begin(), head.end());
            m.insert(m.end(), data.begin() + off, data.begin() + off + len);
            g_q.push_back(std::move(m));
        }
        log("document out " + name + " " + std::to_string(data.size()) + " bytes");
    }

    void receive_chunk(const Bytes& m)
    {
        auto nl = std::find(m.begin(), m.end(), static_cast<uint8_t>('\n'));
        if (nl == m.end()) return;
        std::string h(m.begin() + 1, nl);
        auto t1 = h.find('\t'), t2 = h.rfind('\t');
        if (t1 == std::string::npos || t1 == t2) return;
        std::string name = h.substr(0, t1);
        size_t idx, count;
        try { idx = std::stoul(h.substr(t1 + 1, t2 - t1 - 1)); count = std::stoul(h.substr(t2 + 1)); }
        catch (...) { return; }
        if (name.empty() || count < 1 || idx >= count || count > 4096) return;
        auto& parts = g_partial[name];
        auto& have = g_partial_have[name];
        if (parts.size() != count) { parts.assign(count, {}); have.assign(count, false); }
        parts[idx].assign(nl + 1, m.end());
        have[idx] = true;
        if (std::find(have.begin(), have.end(), false) != have.end()) return;
        std::string all;
        for (auto& p : parts) all.append(reinterpret_cast<const char*>(p.data()), p.size());
        g_partial.erase(name);
        g_partial_have.erase(name);
        log("document in " + name + " " + std::to_string(all.size()) + " bytes");
        std::lock_guard<std::mutex> l(g_mu);
        auto& d = g_docs_in[name];
        d.data = std::move(all);
        ++d.version;
    }

    // the documents Lua put since the last turn (or all, for a new peer) -> the peer
    bool send_docs()
    {
        std::vector<std::pair<std::string, std::string>> out;
        {
            std::lock_guard<std::mutex> l(g_mu);
            for (auto& n : g_docs_dirty)
            {
                auto it = g_docs_out.find(n);
                if (it != g_docs_out.end()) out.emplace_back(n, it->second.data);
            }
            g_docs_dirty.clear();
        }
        for (auto& d : out) send_file(d.first, Bytes(d.second.begin(), d.second.end()));
        return !out.empty();
    }

    // lines Lua queued on channel ch -> one or more 'L' / 'M' messages (lines joined by \n)
    bool pack_lines(int ch)
    {
        std::deque<std::string> lines;
        {
            std::lock_guard<std::mutex> l(g_mu);
            lines.swap(g_out[ch]);
        }
        if (lines.empty()) return false;
        std::string buf;
        for (auto& s : lines)
        {
            if (!buf.empty() && buf.size() + s.size() + 1 > kLinesPerMsg)
            {
                g_q.push_back(text(ch == 0 ? 'L' : 'M', buf));
                buf.clear();
            }
            if (!buf.empty()) buf += '\n';
            buf += s;
        }
        if (!buf.empty()) g_q.push_back(text(ch == 0 ? 'L' : 'M', buf));
        return true;
    }

    void push_in(int ch, const std::string& body)
    {
        std::lock_guard<std::mutex> l(g_mu);
        auto& q = g_in[ch];
        size_t s = 0;
        while (s <= body.size())
        {
            auto e = body.find('\n', s);
            if (e == std::string::npos) e = body.size();
            q.push_back(body.substr(s, e - s));
            s = e + 1;
        }
        while (q.size() > kQueueCap) q.pop_front();
    }

    bool exchange(double now)
    {
        Link& k = *g_link;
        bool busy = false;
        if (k.has_peer() && !g_chan_role.empty())
        {
            busy |= pack_lines(0);
            busy |= pack_lines(1);
            busy |= send_docs();
            if (now - g_last_ping > 2 && g_q.size() < 4) { g_last_ping = now; g_q.push_back(text('P', std::to_string(now))); }
        }
        std::vector<Bytes> in;
        k.receive(in);
        for (auto& m : in)
        {
            if (m.empty()) continue;
            busy = true;
            switch (static_cast<char>(m[0]))
            {
            case 'L': push_in(0, text_of(m)); break;
            case 'M': push_in(1, text_of(m)); break;
            case 'F': receive_chunk(m); break;
            case 'P': g_q.push_back(text('Q', text_of(m))); break;
            case 'Q':
                try { g_ping_ms = (now - std::stod(text_of(m))) * 1000; } catch (...) {}
                break;
            case 'S':
            case 'R':
                if (!k.is_owner())
                {
                    log(m[0] == 'S' ? "start received" : "back into the running run");
                    session("mode " + g_mode);
                    session("go");
                }
                break;
            }
        }
        return busy;
    }

    bool flush()
    {
        Link& k = *g_link;
        if (!k.has_peer())
        {
            if (!k.in_lobby()) g_q.clear();
            return false;
        }
        bool sent = false;
        while (!g_q.empty())
        {
            if (k.send(g_q.front())) { g_q.pop_front(); sent = true; continue; }
            if (k.send_buffer_full) break; // later
            g_q.pop_front();               // another error (k.error says which): this one is lost
        }
        return sent;
    }

    void write_status(const std::string& state)
    {
        Link* k = g_link.get();
        bool in = k && k->in_lobby();
        std::string err = k ? (k->error.empty() ? g_link_err : k->error) : g_link_err;
        std::string s = "state=" + state + " lobby=" + std::to_string(in ? k->lobby_id() : 0) + " owner=" + (in && k->is_owner() ? "1" : "0") +
                        " me=" + underscores(k ? k->my_name() : "") + " peer=" + (k && k->has_peer() ? "1" : "0") +
                        " ping=" + std::to_string(g_ping_ms < 0 ? -1 : static_cast<int>(g_ping_ms)) + " err=" + underscores(err) + " net=native\n";
        if (k)
        {
            for (auto& m : k->members())
                s += "member\t" + std::to_string(m.id) + "\t" + (m.owner ? "1" : "0") + "\t" + (m.me ? "1" : "0") + "\t" + m.mode + "\t" +
                     (m.ready ? "1" : "0") + "\t" + clean(m.name) + "\n";
            int n = 0;
            for (auto& f : k->friends())
            {
                if (++n > 100) break;
                s += "friend\t" + std::to_string(f.id) + "\t" + (f.online ? "1" : "0") + "\t" + (f.ingame ? "1" : "0") + "\t" +
                     std::to_string(f.lobby) + "\t" + clean(f.name) + "\n";
            }
            for (auto& i : k->invites())
                s += "invite\t" + std::to_string(i.lobby) + "\t" + std::to_string(i.from) + "\t" + clean(i.from_name) + "\n";
        }
        {
            std::lock_guard<std::mutex> l(g_mu);
            g_status = s;
        }
        // the file for the tests and the report (the menu reads status())
        fs::path p = P("net-status.txt"), tmp = P("net-status.txt.tmp");
        {
            std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
            if (!f) return;
            f << s;
        }
        MoveFileExW(tmp.c_str(), p.c_str(), MOVEFILE_REPLACE_EXISTING); // the game reads it right now: the next one
    }

    void run()
    {
        while (!g_quit)
        {
            double now = now_s();
            bool busy = false;
            try
            {
                g_link->pump();
                std::vector<std::string> cmds;
                {
                    std::lock_guard<std::mutex> l(g_mu);
                    cmds.assign(g_cmds.begin(), g_cmds.end());
                    g_cmds.clear();
                }
                if (g_test_ctl && now - g_last_ctl > 0.1) { g_last_ctl = now; read_test_control(cmds); }
                for (auto& c : cmds) handle(c);
                update_session();
                busy = exchange(now);
                busy |= flush();
            }
            catch (const std::exception& e) { log_once(std::string("loop: ") + e.what()); }
            if (now - g_last_status > 0.5)
            {
                g_last_status = now;
                try { write_status(g_link->in_lobby() ? "lobby" : "idle"); }
                catch (const std::exception& e) { log_once(std::string("status: ") + e.what()); }
            }
            if (!busy)
            {
                std::unique_lock<std::mutex> l(g_mu);
                g_wake.wait_for(l, std::chrono::milliseconds(5));
            }
        }
        g_link->shutdown();
        log("stopped");
    }
} // namespace

std::string start(const std::string& chan, const std::string& spec)
{
    if (g_started) return g_chan == chan ? "running" : "running on " + g_chan;
    g_chan = chan;
    std::error_code ec;
    fs::create_directories(P(""), ec);
    g_log = _wfsopen(P("net.log").c_str(), L"ab", _SH_DENYNO); // readable while the game runs (report, tests)
    log(std::string("start ") + kVersion + " (in-game) chan=" + chan + " spec=" + spec);
    if (spec.rfind("tcp:", 0) == 0)
    {
        // tcp:<port>:<name>
        auto c2 = spec.find(':', 4);
        int port = 47811;
        try { port = std::stoi(spec.substr(4, c2 == std::string::npos ? std::string::npos : c2 - 4)); } catch (...) {}
        std::string name = c2 == std::string::npos ? "tcp-" + std::to_string(GetCurrentProcessId()) : spec.substr(c2 + 1);
        g_link = std::make_unique<TcpLink>(port, name);
        g_test_ctl = true;
        // older commands belong to an earlier game
        std::error_code e2;
        auto size = fs::file_size(P("net-control.txt"), e2);
        g_ctl_off = e2 ? 0 : size;
    }
    else
    {
        auto steam = std::make_unique<SteamLink>(g_link_err);
        if (!steam->ok)
        {
            log("link failed: " + g_link_err);
            write_status("offline");
            return "offline: " + g_link_err;
        }
        g_link = std::move(steam);
        g_link_err.clear(); // (a first try before the game had Steam up failed: not an error any more)
    }
    g_started = true;
    g_quit = false;
    g_thread = std::thread(run);
    return g_test_ctl ? "local test link (tcp)" : "steam";
}

void stop()
{
    if (!g_started) return;
    g_quit = true;
    g_wake.notify_all();
    if (g_thread.joinable()) g_thread.join();
    g_started = false;
    if (g_log) std::fclose(g_log);
    g_log = nullptr;
}

void command(const std::string& line)
{
    std::lock_guard<std::mutex> l(g_mu);
    g_cmds.push_back(line);
    g_wake.notify_all();
}

static std::string pop_all(std::deque<std::string>& q)
{
    std::string s;
    for (auto& l : q) { s += l; s += '\n'; }
    q.clear();
    return s;
}

std::string session_lines()
{
    std::lock_guard<std::mutex> l(g_mu);
    return pop_all(g_session);
}

std::string status()
{
    std::lock_guard<std::mutex> l(g_mu);
    return g_status;
}

void send_line(int ch, const std::string& line)
{
    if (ch < 0 || ch > 1 || !g_started) return;
    std::lock_guard<std::mutex> l(g_mu);
    auto& q = g_out[ch];
    q.push_back(line);
    while (q.size() > kQueueCap) q.pop_front();
    g_wake.notify_all();
}

std::string recv_lines(int ch)
{
    if (ch < 0 || ch > 1) return {};
    std::lock_guard<std::mutex> l(g_mu);
    return pop_all(g_in[ch]);
}

void doc_put(const std::string& name, const std::string& data)
{
    std::lock_guard<std::mutex> l(g_mu);
    // one zone list kept (each zone has its own, ~0.7 MB): a new one replaces the others
    if (name.rfind("host-spawnlist-", 0) == 0)
        for (auto it = g_docs_out.begin(); it != g_docs_out.end();)
            if (it->first != name && it->first.rfind("host-spawnlist-", 0) == 0) { g_docs_dirty.erase(it->first); it = g_docs_out.erase(it); }
            else ++it;
    auto& d = g_docs_out[name];
    d.data = data;
    ++d.version;
    g_docs_dirty.insert(name);
    g_wake.notify_all();
}

bool doc_get(const std::string& name, std::string& data, int64_t& version)
{
    std::lock_guard<std::mutex> l(g_mu);
    auto it = g_docs_in.find(name);
    if (it == g_docs_in.end()) return false;
    data = it->second.data;
    version = it->second.version;
    return true;
}

void drain(int ch)
{
    if (ch < 0 || ch > 1) return;
    std::lock_guard<std::mutex> l(g_mu);
    g_in[ch].clear();
}
} // namespace coopnet
