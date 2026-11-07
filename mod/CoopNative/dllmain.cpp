// CoopNative: the C++ half of CoopSync (probe, 2026-10-25). Loaded by UE4SS from Mods/CoopSync/dlls/main.dll; when a
// Lua mod starts, the functions are registered into its Lua states (main, game-thread hook, async), so the Lua code
// calls them like UE4SS's own globals.
//   CoopNative_Version()                 -> string
//   CoopNative_ScanActors(substr)        -> count, ms        actors whose class name contains substr ("" = all)
//   CoopNative_AttachedUnder(address)    -> count, ms        actors whose attach chain reaches the actor at address
//                                                            (what carghost.descendants walks in Lua)
//   CoopNative_WeakNew(address)          -> handle           a weak reference (FWeakObjectPtr) to an object
//   CoopNative_WeakValid(handle)         -> bool, address    still alive? (safe after the object is gone - the
//                                                            Lua object wrappers crash the game then)
// The in-game network (net.hpp), in place of CoopNet.exe and its channel files:
//   CoopNative_NetStart(chan, spec)      -> string           spec "" = Steam, "tcp:<port>:<name>" = local test link
//   CoopNative_NetCmd(line)                                  the menu's commands (create, join <id>, leave, ...)
//   CoopNative_NetStatus()               -> string           net-status text (head line, member/friend/invite rows)
//   CoopNative_NetSession()              -> string           session commands since the last call (role/mode/go/stop)
//   CoopNative_NetSend(ch, line)                             a line to the other player (0 state, 1 fast)
//   CoopNative_NetRecv(ch)               -> string           the other player's lines since the last call
//   CoopNative_NetDrain(ch)                                  forget the lines that came in on ch
// Wwise (audio.hpp): CoopNative_AkPlaying / AkPos / AkSeek - the radio track's position and a seek.
// Saves (save.hpp): CoopNative_SaveSplice / SaveInfo; files as documents: CoopNative_DocPutFile / DocGetFile.
#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/FWeakObjectPtr.hpp>

#include "net.hpp"
#include "world.hpp"
#include "audio.hpp"
#include "trace.hpp"
#include "save.hpp"

#include <chrono>
#include <string>
#include <unordered_map>
#include <vector>

#define NOMINMAX
#include <windows.h>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    std::vector<FWeakObjectPtr> g_weak;

    double now_ms()
    {
        using namespace std::chrono;
        return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
    }

    // an actor of the world: not a class default / archetype, not on its way out
    bool usable_actor(UObject* o)
    {
        if (!o) return false;
        if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject | RF_ArchetypeObject))) return false;
        if (o->IsUnreachable()) return false;
        return o->IsA<AActor>();
    }

    // property offsets found once (a lookup by name per actor cost as much as the whole Lua walk)
    int32 g_root_off = -1, g_parent_off = -1;
    bool offsets()
    {
        if (g_root_off >= 0 && g_parent_off >= 0) return true;
        auto actor_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Engine.Actor"));
        auto scene_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Engine.SceneComponent"));
        if (!actor_class || !scene_class) return false;
        auto rp = actor_class->FindProperty(FName(STR("RootComponent"), FNAME_Find));
        auto pp = scene_class->FindProperty(FName(STR("AttachParent"), FNAME_Find));
        if (!rp || !pp) return false;
        g_root_off = rp->GetOffset_Internal();
        g_parent_off = pp->GetOffset_Internal();
        return true;
    }
    UObject* ptr_at(UObject* o, int32 off) { return *reinterpret_cast<UObject**>(reinterpret_cast<uint8_t*>(o) + off); }

    // the actor this actor hangs under: RootComponent -> AttachParent -> its outer (the owning actor)
    UObject* attach_parent_actor(UObject* actor)
    {
        UObject* root = ptr_at(actor, g_root_off);
        if (!root) return nullptr;
        UObject* parent = ptr_at(root, g_parent_off);
        if (!parent) return nullptr;
        return parent->GetOuterPrivate();
    }

    // every actor of the world (UE4SS's class search, not a walk over all objects)
    void actors(std::vector<UObject*>& out)
    {
        out.clear();
        UObjectGlobals::FindAllOf(STR("Actor"), out);
    }

    std::wstring widen(std::string_view s) { return std::wstring(s.begin(), s.end()); }

    int lua_version(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string("CoopNative 0.2 (net)");
        return 1;
    }

    int lua_scan_actors(const LuaMadeSimple::Lua& lua)
    {
        std::wstring want = lua.is_string() ? widen(lua.get_string()) : std::wstring{};
        double t0 = now_ms();
        int64_t n = 0;
        std::unordered_map<UClass*, bool> verdict; // class -> name matches (one name per class, not per actor)
        std::vector<UObject*> all;
        actors(all);
        for (UObject* o : all)
        {
            if (!usable_actor(o)) continue;
            UClass* c = o->GetClassPrivate();
            auto it = verdict.find(c);
            if (it == verdict.end()) it = verdict.emplace(c, want.empty() || c->GetName().find(want) != std::wstring::npos).first;
            if (it->second) ++n;
        }
        lua.set_integer(n);
        lua.set_number(now_ms() - t0);
        return 2;
    }

    int lua_attached_under(const LuaMadeSimple::Lua& lua)
    {
        auto root = reinterpret_cast<UObject*>(lua.get_integer());
        double t0 = now_ms();
        int64_t n = 0;
        if (offsets())
        {
            std::vector<UObject*> all;
            actors(all);
            for (UObject* o : all)
            {
                if (!usable_actor(o)) continue;
                UObject* cur = attach_parent_actor(o);
                for (int g = 0; cur && g < 8; ++g)
                {
                    if (cur == root) { ++n; break; }
                    cur = attach_parent_actor(cur);
                }
            }
        }
        lua.set_integer(n);
        lua.set_number(now_ms() - t0);
        return 2;
    }

    int lua_weak_new(const LuaMadeSimple::Lua& lua)
    {
        auto obj = reinterpret_cast<UObject*>(lua.get_integer());
        g_weak.emplace_back(obj);
        lua.set_integer(static_cast<int64_t>(g_weak.size()));
        return 1;
    }

    int lua_weak_valid(const LuaMadeSimple::Lua& lua)
    {
        auto h = lua.get_integer();
        if (h < 1 || h > static_cast<int64_t>(g_weak.size()))
        {
            lua.set_bool(false);
            lua.set_integer(0);
            return 2;
        }
        UObject* o = g_weak[static_cast<size_t>(h - 1)].Get();
        bool ok = o && !o->IsUnreachable();
        lua.set_bool(ok);
        lua.set_integer(ok ? reinterpret_cast<int64_t>(o) : 0);
        return 2;
    }

    std::string arg_string(const LuaMadeSimple::Lua& lua) { return lua.is_string() ? std::string(lua.get_string()) : std::string{}; }

    int lua_net_start(const LuaMadeSimple::Lua& lua)
    {
        std::string chan = arg_string(lua), spec = arg_string(lua);
        lua.set_string(coopnet::start(chan, spec));
        return 1;
    }
    int lua_net_cmd(const LuaMadeSimple::Lua& lua)
    {
        coopnet::command(arg_string(lua));
        return 0;
    }
    int lua_net_status(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(coopnet::status());
        return 1;
    }
    int lua_net_session(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(coopnet::session_lines());
        return 1;
    }
    int lua_net_send(const LuaMadeSimple::Lua& lua)
    {
        int ch = static_cast<int>(lua.get_integer());
        coopnet::send_line(ch, arg_string(lua));
        return 0;
    }
    int lua_net_recv(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(coopnet::recv_lines(static_cast<int>(lua.get_integer())));
        return 1;
    }
    int lua_net_drain(const LuaMadeSimple::Lua& lua)
    {
        coopnet::drain(static_cast<int>(lua.get_integer()));
        return 0;
    }

    // CoopNative_DocPut(name, text)
    int lua_doc_put(const LuaMadeSimple::Lua& lua)
    {
        std::string name = arg_string(lua), data = arg_string(lua);
        coopnet::doc_put(name, data);
        return 0;
    }
    // CoopNative_DocGet(name) -> text, version | nil, 0
    int lua_doc_get(const LuaMadeSimple::Lua& lua)
    {
        std::string data;
        int64_t version = 0;
        if (coopnet::doc_get(arg_string(lua), data, version)) lua.set_string(data);
        else lua.set_nil();
        lua.set_integer(version);
        return 2;
    }

    // A file as a document (binary: the host's zone save for the guest) / a document into a file
    //   CoopNative_DocPutFile(name, path) -> bytes | -1      CoopNative_DocGetFile(name, path) -> version | nil
    int lua_doc_put_file(const LuaMadeSimple::Lua& lua)
    {
        std::string name = arg_string(lua), path = arg_string(lua);
        FILE* f = nullptr;
        if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) { lua.set_integer(-1); return 1; }
        std::string data;
        char buf[65536];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, n);
        fclose(f);
        coopnet::doc_put(name, data);
        lua.set_integer(static_cast<int64_t>(data.size()));
        return 1;
    }
    int lua_doc_get_file(const LuaMadeSimple::Lua& lua)
    {
        std::string name = arg_string(lua), path = arg_string(lua);
        std::string data;
        int64_t version = 0;
        if (!coopnet::doc_get(name, data, version)) { lua.set_nil(); return 1; }
        FILE* f = nullptr;
        if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) { lua.set_nil(); return 1; }
        fwrite(data.data(), 1, data.size(), f);
        fclose(f);
        lua.set_integer(version);
        return 1;
    }

    // A key held now, read on the calling (game) thread: GetAsyncKeyState while this game's window is in front.
    // UE4SS's RegisterKeyBind runs its Lua callback on UE4SS's own thread, in the Lua state the game thread's loops and
    // hooks use with no lock between them (LuaMod.cpp: process_delayed_actions / the hooks call Lua unlocked): a key
    // press during a loop broke the Lua heap - the friend's alpha 16 crash inside a fresh Lua table. hooks.lua polls.
    int lua_key_down(const LuaMadeSimple::Lua& lua)
    {
        int vk = lua.is_integer() ? static_cast<int>(lua.get_integer()) : 0;
        bool down = false;
        HWND fg = GetForegroundWindow();
        DWORD pid = 0;
        if (fg) GetWindowThreadProcessId(fg, &pid);
        if (vk > 0 && vk < 256 && pid == GetCurrentProcessId()) down = (GetAsyncKeyState(vk) & 0x8000) != 0;
        lua.set_bool(down);
        return 1;
    }

    void register_all(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("CoopNative_Version", lua_version);
        lua.register_function("CoopNative_ScanActors", lua_scan_actors);
        lua.register_function("CoopNative_AttachedUnder", lua_attached_under);
        lua.register_function("CoopNative_WeakNew", lua_weak_new);
        lua.register_function("CoopNative_WeakValid", lua_weak_valid);
        lua.register_function("CoopNative_NetStart", lua_net_start);
        lua.register_function("CoopNative_NetCmd", lua_net_cmd);
        lua.register_function("CoopNative_NetStatus", lua_net_status);
        lua.register_function("CoopNative_NetSession", lua_net_session);
        lua.register_function("CoopNative_NetSend", lua_net_send);
        lua.register_function("CoopNative_NetRecv", lua_net_recv);
        lua.register_function("CoopNative_NetDrain", lua_net_drain);
        lua.register_function("CoopNative_DocPut", lua_doc_put);
        lua.register_function("CoopNative_DocGet", lua_doc_get);
        lua.register_function("CoopNative_KeyDown", lua_key_down);
        lua.register_function("CoopNative_DocPutFile", lua_doc_put_file);
        lua.register_function("CoopNative_DocGetFile", lua_doc_get_file);
        world::register_all(lua);
        audio::register_all(lua);
        trace::register_all(lua);
        savefile::register_all(lua);
    }
} // namespace

// Two copies of the game on one PC ("Две копии игры.bat" sets COOPSYNC_TWO_GAMES=1): the game's Steam integration calls
// SteamAPI_RestartAppIfNecessary on frame 0 and quits to be relaunched through Steam, which runs one copy only. On the
// owner's PC (alpha 17) neither steam_appid.txt nor SteamAppId kept it from that ("Restarting within steam, exiting...").
// This mod loads ~1 s before that call (UE4SS.log vs the game's log): the function answers "no restart" then.
static void keep_steam_from_restarting()
{
    wchar_t v[8] = {};
    if (GetEnvironmentVariableW(L"COOPSYNC_TWO_GAMES", v, 8) == 0 || v[0] != L'1') return;
    HMODULE dll = GetModuleHandleW(L"steam_api64.dll");
    auto* fn = dll ? reinterpret_cast<unsigned char*>(GetProcAddress(dll, "SteamAPI_RestartAppIfNecessary")) : nullptr;
    if (!fn)
    {
        Output::send<LogLevel::Warning>(STR("[CoopNative] two games: SteamAPI_RestartAppIfNecessary not found\n"));
        return;
    }
    const unsigned char ret_false[] = {0x31, 0xC0, 0xC3}; // xor eax, eax; ret
    DWORD old = 0;
    if (!VirtualProtect(fn, sizeof(ret_false), PAGE_EXECUTE_READWRITE, &old)) return;
    memcpy(fn, ret_false, sizeof(ret_false));
    VirtualProtect(fn, sizeof(ret_false), old, &old);
    FlushInstructionCache(GetCurrentProcess(), fn, sizeof(ret_false));
    Output::send<LogLevel::Verbose>(STR("[CoopNative] two games: Steam restart check answered 'no'\n"));
}

class CoopNative : public CppUserModBase
{
  public:
    CoopNative() : CppUserModBase()
    {
        ModName = STR("CoopSync");
        ModVersion = STR("0.2");
        ModDescription = STR("CoopSync native half");
        ModAuthors = STR("CoopSync");
        Output::send<LogLevel::Verbose>(STR("[CoopNative] loaded\n"));
        keep_steam_from_restarting();
    }
    ~CoopNative() override { coopnet::stop(); }

    // every Lua mod that starts gets our functions (CoopSync; CoopDev for the tests)
    auto on_lua_start(StringViewType mod_name, LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua, LuaMadeSimple::Lua& async_lua,
                      LuaMadeSimple::Lua* hook_lua) -> void override
    {
        register_all(lua);
        register_all(main_lua);
        register_all(async_lua);
        if (hook_lua) register_all(*hook_lua);
        Output::send<LogLevel::Verbose>(STR("[CoopNative] functions registered into Lua mod {}\n"), mod_name);
    }
};

#define COOPNATIVE_API __declspec(dllexport)
extern "C"
{
    COOPNATIVE_API RC::CppUserModBase* start_mod() { return new CoopNative(); }
    COOPNATIVE_API void uninstall_mod(RC::CppUserModBase* mod) { delete mod; }
}
