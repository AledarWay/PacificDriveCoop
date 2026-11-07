// Wwise from the mod: the game's exe exports the sound engine's API (AK::SoundEngine, found by their decorated names),
// none of it reachable from Lua (the UE integration has no seek / position UFunction). The radio's music is a Wwise
// event on the music track player's AkComponent; the game object of a UAkComponent is its address.
//   CoopNative_AkPlaying(gameObject)          -> "pid eventId\n..."   what plays on that game object
//   CoopNative_AkPos(pid)                     -> ms | nil, result     the position of that playing source
//   CoopNative_AkSeek(eventId, gameObject, ms, pid) -> result         seek (pid 0 = every instance of the event there)
// result: the AKRESULT (1 = AK_Success); -1 = the export was not found.
// The player's own files play in a UMediaPlayer, whose time is an FTimespan (UE4SS Lua gets an empty table for it):
//   CoopNative_MediaTime(mediaPlayer)        -> ms, duration ms | nil     (UMediaPlayer GetTime / GetDuration)
//   CoopNative_MediaSeek(mediaPlayer, ms)    -> bool                      (UMediaPlayer Seek)
#include "audio.hpp"

#include <Unreal/UObject.hpp>
#include <Unreal/UFunction.hpp>

#include <Windows.h>
#include <cstdint>
#include <cstring>
#include <string>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    using GetPlayingIDsFn = int (*)(uint64_t gameObject, uint32_t& count, uint32_t* out);
    using GetEventIDFn = uint32_t (*)(uint32_t pid);
    using GetPosFn = int (*)(uint32_t pid, int32_t* outMs, bool extrapolate);
    using SeekFn = int (*)(uint32_t eventId, uint64_t gameObject, int32_t ms, bool nearestMarker, uint32_t pid);

    GetPlayingIDsFn g_playing = nullptr;
    GetEventIDFn g_event_of = nullptr;
    GetPosFn g_pos = nullptr;
    SeekFn g_seek = nullptr;
    bool g_resolved = false;

    void resolve()
    {
        if (g_resolved) return;
        g_resolved = true;
        HMODULE exe = GetModuleHandleW(nullptr);
        g_playing = reinterpret_cast<GetPlayingIDsFn>(GetProcAddress(exe, "?GetPlayingIDsFromGameObject@Query@SoundEngine@AK@@YA?AW4AKRESULT@@_KAEAIPEAI@Z"));
        g_event_of = reinterpret_cast<GetEventIDFn>(GetProcAddress(exe, "?GetEventIDFromPlayingID@Query@SoundEngine@AK@@YAII@Z"));
        g_pos = reinterpret_cast<GetPosFn>(GetProcAddress(exe, "?GetSourcePlayPosition@SoundEngine@AK@@YA?AW4AKRESULT@@IPEAH_N@Z"));
        g_seek = reinterpret_cast<SeekFn>(GetProcAddress(exe, "?SeekOnEvent@SoundEngine@AK@@YA?AW4AKRESULT@@I_KH_NI@Z"));
    }

    int lua_ak_playing(const LuaMadeSimple::Lua& lua)
    {
        resolve();
        auto go = static_cast<uint64_t>(lua.get_integer());
        std::string out;
        if (g_playing && g_event_of && go)
        {
            uint32_t ids[64]{};
            uint32_t n = 64;
            if (g_playing(go, n, ids) == 1)
            {
                for (uint32_t i = 0; i < n && i < 64; ++i)
                    out += std::to_string(ids[i]) + " " + std::to_string(g_event_of(ids[i])) + "\n";
            }
        }
        lua.set_string(out);
        return 1;
    }

    int lua_ak_pos(const LuaMadeSimple::Lua& lua)
    {
        resolve();
        auto pid = static_cast<uint32_t>(lua.get_integer());
        if (!g_pos) { lua.set_nil(); lua.set_integer(-1); return 2; }
        int32_t ms = 0;
        int r = g_pos(pid, &ms, true);
        if (r == 1) lua.set_integer(ms); else lua.set_nil();
        lua.set_integer(r);
        return 2;
    }

    int lua_ak_seek(const LuaMadeSimple::Lua& lua)
    {
        resolve();
        auto ev = static_cast<uint32_t>(lua.get_integer());
        auto go = static_cast<uint64_t>(lua.get_integer());
        auto ms = static_cast<int32_t>(lua.get_integer());
        auto pid = static_cast<uint32_t>(lua.is_number() ? lua.get_integer() : 0);
        lua.set_integer(g_seek ? g_seek(ev, go, ms, false, pid) : -1);
        return 1;
    }
    // an FTimespan is one int64 of 100 ns ticks; a call's parameters in a zeroed buffer of the function's size
    bool call_timespan(UObject* o, const TCHAR* name, int64_t& ticks)
    {
        UFunction* fn = o ? o->GetFunctionByNameInChain(name) : nullptr;
        if (!fn) return false;
        alignas(16) uint8_t parms[64]{};
        o->ProcessEvent(fn, parms);
        std::memcpy(&ticks, parms, sizeof(ticks));
        return true;
    }

    int lua_media_time(const LuaMadeSimple::Lua& lua)
    {
        auto mp = reinterpret_cast<UObject*>(lua.get_integer());
        int64_t t = 0, d = 0;
        if (!mp || !call_timespan(mp, STR("GetTime"), t)) { lua.set_nil(); return 1; }
        call_timespan(mp, STR("GetDuration"), d);
        lua.set_integer(t / 10000);
        lua.set_integer(d / 10000);
        return 2;
    }

    int lua_media_seek(const LuaMadeSimple::Lua& lua)
    {
        auto mp = reinterpret_cast<UObject*>(lua.get_integer());
        int64_t ms = lua.get_integer();
        UFunction* fn = mp ? mp->GetFunctionByNameInChain(STR("Seek")) : nullptr;
        if (!fn) { lua.set_bool(false); return 1; }
        alignas(16) uint8_t parms[64]{};
        int64_t ticks = ms * 10000;
        std::memcpy(parms, &ticks, sizeof(ticks)); // (const FTimespan& Time, then the bool result at 8)
        mp->ProcessEvent(fn, parms);
        lua.set_bool(parms[8] != 0);
        return 1;
    }
} // namespace

namespace audio
{
    void register_all(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("CoopNative_AkPlaying", lua_ak_playing);
        lua.register_function("CoopNative_AkPos", lua_ak_pos);
        lua.register_function("CoopNative_AkSeek", lua_ak_seek);
        lua.register_function("CoopNative_MediaTime", lua_media_time);
        lua.register_function("CoopNative_MediaSeek", lua_media_seek);
    }
} // namespace audio
