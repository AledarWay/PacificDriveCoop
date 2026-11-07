// Blueprint call trace (2026-10-30, the native car rework): which of the game's script functions run, called from
// which, on which objects - to find the game's own "one car" lookups (the character's pedals went to the own car while
// the player sat in the other's; the gear lever, the exit door: NOTES "Native cars"). A pre-callback on the script VM
// (ProcessLocalScriptFunction: a blueprint function called from another; ProcessInternal: one called by the engine,
// input events, timers) records caller -> callee edges while tracing is on; off, the callbacks return at once.
//   CoopNative_TraceStart(substr[, caller])  start (cleared); substr (required): only callees whose name contains it;
//                                    caller: only calls with that in one of the three callers
//   CoopNative_TraceGet()            -> text, one line per call chain: count  callers (nearest first) -> callee  [object addresses]
//   CoopNative_TraceStop()
#include "trace.hpp"

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UFunction.hpp>

#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>

#define NOMINMAX
#include <windows.h>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    bool g_hooked = false, g_on = false;
    DWORD g_thread = 0; // the game thread (TraceStart is called from Lua there): animation blueprints run on worker threads
    std::wstring g_filter, g_caller; // callee substring; caller substring (one of the callers, "" = any)
    struct Edge
    {
        std::wstring caller, callee;
        int64_t count = 0;
        std::vector<uintptr_t> objects; // the first few distinct objects the callee ran on
    };
    std::vector<Edge> g_edges;
    std::unordered_map<uint64_t, size_t> g_index; // (caller, callee) pointers -> edge
    std::unordered_map<UFunction*, std::wstring> g_names;
    std::unordered_map<UFunction*, bool> g_pass; // callee -> matches the filter
    constexpr size_t MAX_EDGES = 20000;

    const std::wstring& name_of(UFunction* f)
    {
        auto it = g_names.find(f);
        if (it != g_names.end()) return it->second;
        std::wstring n = f ? f->GetFullName() : std::wstring(L"(none)");
        auto sp = n.find(L' '); // "Function /Game/...:Name" -> the path
        if (sp != std::wstring::npos) n = n.substr(sp + 1);
        return g_names.emplace(f, std::move(n)).first->second;
    }

    // The caller frames: read under SEH (a frame given to ProcessInternal comes from the engine; the walk up from one
    // crashed the game). n = how many were read.
    int callers_of(FFrame* frame, UFunction** out, int max)
    {
        int n = 0;
        __try
        {
            FFrame* prev = frame->PreviousFrame();
            while (prev && n < max)
            {
                UFunction* f = prev->Node();
                if (!f) break;
                out[n++] = f;
                prev = prev->PreviousFrame();
            }
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
        }
        return n;
    }

    void record(UObject* context, FFrame& stack, bool script)
    {
        if (!g_on || GetCurrentThreadId() != g_thread) return;
        UFunction* callee = stack.Node();
        if (!callee) return;
        auto p = g_pass.find(callee);
        if (p == g_pass.end()) p = g_pass.emplace(callee, g_filter.empty() || name_of(callee).find(g_filter) != std::wstring::npos).first;
        if (!p->second) return;
        // (the callers up to three frames back, script calls only: "caller < its caller < ...")
        uint64_t key = reinterpret_cast<uint64_t>(callee);
        UFunction* chain[3] = {};
        int n = script ? callers_of(&stack, chain, 3) : 0;
        if (!g_caller.empty())
        {
            bool hit = false;
            for (int i = 0; i < n && !hit; ++i) hit = name_of(chain[i]).find(g_caller) != std::wstring::npos;
            if (!hit) return;
        }
        for (int i = 0; i < n; ++i) key = key * 1000003ull ^ reinterpret_cast<uint64_t>(chain[i]);
        auto it = g_index.find(key);
        if (it == g_index.end())
        {
            if (g_edges.size() >= MAX_EDGES) return;
            std::wstring callers;
            for (int i = 0; i < n; ++i) callers += (i ? L" < " : L"") + name_of(chain[i]);
            g_edges.push_back(Edge{callers.empty() ? std::wstring(L"(engine)") : callers, name_of(callee)});
            it = g_index.emplace(key, g_edges.size() - 1).first;
        }
        Edge& e = g_edges[it->second];
        ++e.count;
        auto a = reinterpret_cast<uintptr_t>(context);
        if (e.objects.size() < 4 && std::find(e.objects.begin(), e.objects.end(), a) == e.objects.end()) e.objects.push_back(a);
    }

    void hook()
    {
        if (g_hooked) return;
        g_hooked = true;
        Hook::FCallbackOptions o;
        o.OwnerModName = STR("CoopSync");
        o.HookName = STR("trace");
        o.bReadonly = true;
        Hook::RegisterProcessLocalScriptFunctionPreCallback(
                [](auto&, UObject* context, FFrame& stack, void*) { record(context, stack, true); }, o);
        Hook::RegisterProcessInternalPreCallback([](auto&, UObject* context, FFrame& stack, void*) { record(context, stack, false); }, o);
        Output::send<LogLevel::Verbose>(STR("[CoopNative] trace hooks registered\n"));
    }

    int lua_trace_start(const LuaMadeSimple::Lua& lua)
    {
        std::string f = lua.is_string() ? std::string(lua.get_string()) : std::string{};
        // (a filter is required: tracing every script function stalled the game - 2026-10-30)
        if (f.empty()) return 0;
        g_filter.assign(f.begin(), f.end());
        std::string c = lua.is_string() ? std::string(lua.get_string()) : std::string{};
        g_caller.assign(c.begin(), c.end());
        g_edges.clear();
        g_index.clear();
        g_pass.clear();
        g_thread = GetCurrentThreadId();
        hook();
        g_on = true;
        return 0;
    }
    int lua_trace_stop(const LuaMadeSimple::Lua&)
    {
        g_on = false;
        return 0;
    }
    int lua_trace_get(const LuaMadeSimple::Lua& lua)
    {
        std::wstring out;
        for (const Edge& e : g_edges)
        {
            out += std::to_wstring(e.count) + L"\t" + e.caller + L" -> " + e.callee + L"\t";
            for (auto a : e.objects) out += std::to_wstring(a) + L" ";
            out += L"\n";
        }
        std::string s;
        s.reserve(out.size());
        for (wchar_t c : out) s += c < 128 ? static_cast<char>(c) : '?';
        lua.set_string(s);
        return 1;
    }
} // namespace

namespace trace
{
    void register_all(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("CoopNative_TraceStart", lua_trace_start);
        lua.register_function("CoopNative_TraceStop", lua_trace_stop);
        lua.register_function("CoopNative_TraceGet", lua_trace_get);
    }
} // namespace trace
