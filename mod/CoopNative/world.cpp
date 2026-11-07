// The native fast helpers (2026-10-25): the world walks of the Lua mod (spawnsync's collect / dressing / destroyTrees /
// zoneReady, lootsync's container and template part maps) and weak references, done in C++ (see world.hpp).
//
// Class tags: Lua decides what a class is (its name patterns: replicated, dressing, ...); C++ remembers the answer per
// class name (FName comparison index) and filters actors by it. CoopNative_NewClasses lists the classes of the world's
// actors it has no answer for yet, CoopNative_TagClass stores Lua's answer.
//
// Every pointer read from an object (root component, attach parent, outer) is checked against the engine's object
// array before it is followed: an object freed this frame is never touched (the Lua walk through AttachChildren and
// the native GetAttachParentActor crashed on such pointers).
#include "world.hpp"

#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObjectHashTables.hpp>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <array>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace RC;
using namespace RC::Unreal;

namespace world
{
namespace
{
    // the tag bits (the same numbers in spawnsync.lua's TAG table)
    enum : uint32_t
    {
        REPL = 1,          // a replicated class (spawnsync PATTERNS minus EXCLUDE)
        CONTAINER = 2,     // a replicated parent that does not make its children (road obstructions)
        PLAYERCAR = 4,     // the player's car
        DRESS = 8,         // a dressing class (DRESS_CLASSES, not replicated, not DRESS_SKIP)
        DRESS_ROOT = 16,   // prefab settings, ManageChildrenActor, leaf spawner
        TEMPLATE = 32,     // a replicated wreck template (BP_Template_*)
        STATICMESH = 64,   // StaticMeshActor itself
    };
    enum : uint32_t
    {
        OPT_LEVEL = 1,  // in a persistent level (outer named PersistentLevel)
        OPT_ROOT = 2,   // no replicated (non-container) ancestor and not on the player's car
        OPT_PREFAB = 4, // under a dressing root (spawnsync underPrefab)
        OPT_PATHS = 8,  // return path strings instead of objects
    };

    std::unordered_map<uint32_t, uint32_t> g_tags; // class name -> tags
    uint32_t name_key(const FName& n) { return n.GetComparisonIndex().ToUnstableInt(); }

    // a live, usable object: in the object array at its own index, not unreachable, not pending kill
    bool live(const UObject* o)
    {
        if (!o) return false;
        int32 idx = o->GetInternalIndex();
        if (idx < 0 || idx >= FUObjectArray::GetNumElements()) return false;
        FUObjectItem* item = FUObjectArray::IndexToObject(idx);
        if (!item || item->GetUObject() != o) return false;
        return !item->IsUnreachable() && !item->IsPendingKill();
    }
    bool usable_actor(UObject* o)
    {
        if (!live(o)) return false;
        if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject | RF_ArchetypeObject))) return false;
        // (a live object with a dead class pointer: IsA read 0xffffffffffffffff in CoopNative_Under, the guest's
        // anomaly test 2026-10-28, right after the player sync's start)
        if (!live(o->GetClassPrivate())) return false;
        return o->IsA<AActor>();
    }

    bool tags_of(UObject* actor, uint32_t& out)
    {
        UClass* c = actor->GetClassPrivate();
        if (!c) return false;
        auto it = g_tags.find(name_key(c->GetNamePrivate()));
        if (it == g_tags.end()) return false;
        out = it->second;
        return true;
    }
    uint32_t tags(UObject* actor)
    {
        uint32_t t = 0;
        tags_of(actor, t);
        return t;
    }

    int32 g_root_off = -1, g_parent_off = -1, g_relloc_off = -1, g_relloc_size = 0;
    uint32_t g_persistent_level = 0;
    bool offsets()
    {
        if (g_root_off >= 0) return true;
        auto actor_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Engine.Actor"));
        auto scene_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Engine.SceneComponent"));
        if (!actor_class || !scene_class) return false;
        auto rp = actor_class->FindProperty(FName(STR("RootComponent"), FNAME_Find));
        auto pp = scene_class->FindProperty(FName(STR("AttachParent"), FNAME_Find));
        auto lp = scene_class->FindProperty(FName(STR("RelativeLocation"), FNAME_Find));
        if (!rp || !pp || !lp) return false;
        g_parent_off = pp->GetOffset_Internal();
        g_relloc_off = lp->GetOffset_Internal();
        g_relloc_size = lp->GetElementSize();
        g_persistent_level = name_key(FName(STR("PersistentLevel"), FNAME_Add));
        g_root_off = rp->GetOffset_Internal();
        return true;
    }
    UObject* ptr_at(UObject* o, int32 off) { return *reinterpret_cast<UObject**>(reinterpret_cast<uint8_t*>(o) + off); }

    // the actor this actor hangs under: RootComponent -> AttachParent -> its outer (the owning actor); every link live
    UObject* parent_actor(UObject* actor)
    {
        UObject* root = ptr_at(actor, g_root_off);
        if (!live(root)) return nullptr;
        UObject* parent = ptr_at(root, g_parent_off);
        if (!live(parent)) return nullptr;
        UObject* owner = parent->GetOuterPrivate();
        return usable_actor(owner) ? owner : nullptr;
    }
    bool in_level(UObject* actor)
    {
        UObject* outer = actor->GetOuterPrivate();
        return outer && name_key(outer->GetNamePrivate()) == g_persistent_level;
    }
    // spawnsync isRoot: no replicated ancestor (road obstructions excepted), not on the player's car
    bool is_root(UObject* actor)
    {
        UObject* p = parent_actor(actor);
        for (int g = 0; p && g < 16; ++g)
        {
            uint32_t t = tags(p);
            if (t & PLAYERCAR) return false;
            if ((t & REPL) && !(t & CONTAINER)) return false;
            p = parent_actor(p);
        }
        return true;
    }
    // spawnsync underPrefab: a dressing root above it; a replicated ancestor ends the walk (a wreck template's own
    // static meshes count)
    bool under_prefab(UObject* actor, uint32_t self)
    {
        UObject* p = parent_actor(actor);
        for (int g = 0; p && g < 16; ++g)
        {
            uint32_t t = tags(p);
            if (t & DRESS_ROOT) return true;
            if (t & REPL) return (self & STATICMESH) && (t & TEMPLATE);
            p = parent_actor(p);
        }
        return false;
    }
    // where an actor stands: its root component's location, when that is not attached (then relative = world)
    bool location(UObject* actor, double& x, double& y, double& z)
    {
        UObject* root = ptr_at(actor, g_root_off);
        if (!live(root) || ptr_at(root, g_parent_off)) return false;
        auto p = reinterpret_cast<uint8_t*>(root) + g_relloc_off;
        if (g_relloc_size == 24) { auto v = reinterpret_cast<double*>(p); x = v[0], y = v[1], z = v[2]; }
        else { auto v = reinterpret_cast<float*>(p); x = v[0], y = v[1], z = v[2]; }
        return true;
    }

    std::string utf8(const std::wstring& w)
    {
        int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
        std::string s(static_cast<size_t>(n), ' ');
        WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
        return s;
    }
    std::wstring wide(std::string_view s)
    {
        int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
        std::wstring w(static_cast<size_t>(n), L' ');
        MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
        return w;
    }
    std::string path_of(UObject* o) { return utf8(o->GetPathName()); }
    std::string full_of(UObject* o) { return utf8(o->GetFullName()); }
    std::vector<std::string> lines(std::string_view s)
    {
        std::vector<std::string> out;
        size_t a = 0;
        while (a < s.size())
        {
            size_t b = s.find('\n', a);
            if (b == std::string_view::npos) b = s.size();
            if (b > a) out.emplace_back(s.substr(a, b - a));
            a = b + 1;
        }
        return out;
    }
    // "Class /Path.Obj" or "/Path.Obj" -> the object, when it is alive. Through the engine's object hash tables only:
    // UE4SS's StaticFindObject falls back to a walk over every object on a miss (45-49 ms per path that is gone: the
    // late join's stale lists made frames of 11-43 s). (No hash tables yet: the full search.)
    UObject* find_path(const std::string& p)
    {
        // (a class prefix only before the path's first '/': object names may hold spaces, "Timeline Camera Zoom")
        auto sp = p.find(" /");
        std::wstring w = wide(!p.empty() && p[0] != '/' && sp != std::string::npos ? p.substr(sp + 1) : p);
        UObject* o = FUObjectHashTables::IsAvailable() ? FUObjectHashTables::StaticFindObjectByPath(nullptr, w.c_str(), false)
                                                       : UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, w);
        return live(o) ? o : nullptr;
    }
    void all_of(const wchar_t* cls, std::vector<UObject*>& out)
    {
        out.clear();
        UObjectGlobals::FindAllOf(cls, out);
    }
    std::string arg_string(const LuaMadeSimple::Lua& lua) { return lua.is_string() ? std::string(lua.get_string()) : std::string{}; }

    // a Lua array of objects or path strings
    void push_list(const LuaMadeSimple::Lua& lua, const std::vector<UObject*>& objs, bool paths)
    {
        auto t = lua.prepare_new_table(static_cast<int32_t>(objs.size()));
        int64_t i = 0;
        for (UObject* o : objs)
        {
            lua.set_integer(++i);
            if (paths) lua.set_string(path_of(o));
            else LuaType::auto_construct_object(lua, o);
            t.fuse_pair();
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // CoopNative_NewClasses() -> { [className] = key }: classes of the world's actors without tags yet
    int lua_new_classes(const LuaMadeSimple::Lua& lua)
    {
        std::vector<UObject*> all;
        all_of(STR("Actor"), all);
        std::unordered_map<uint32_t, UClass*> fresh;
        for (UObject* o : all)
        {
            if (!usable_actor(o)) continue;
            UClass* c = o->GetClassPrivate();
            uint32_t k = name_key(c->GetNamePrivate());
            if (!g_tags.count(k)) fresh.emplace(k, c);
        }
        auto t = lua.prepare_new_table(0, static_cast<int32_t>(fresh.size()));
        for (auto& [k, c] : fresh)
        {
            lua.set_string(utf8(c->GetName()));
            lua.set_integer(k);
            t.fuse_pair();
        }
        return 1;
    }
    // CoopNative_TagClass(key, tags)
    int lua_tag_class(const LuaMadeSimple::Lua& lua)
    {
        auto k = static_cast<uint32_t>(lua.get_integer());
        g_tags[k] = static_cast<uint32_t>(lua.get_integer());
        return 0;
    }
    // CoopNative_ForgetClasses(): a new world may hold other classes of the same names (tests reload the scripts)
    int lua_forget_classes(const LuaMadeSimple::Lua&)
    {
        g_tags.clear();
        return 0;
    }

    // CoopNative_Find(want, opts) -> { actor or path, ... }: actors whose class has a tag in want, filtered by opts
    int lua_find(const LuaMadeSimple::Lua& lua)
    {
        auto want = static_cast<uint32_t>(lua.get_integer());
        auto opts = static_cast<uint32_t>(lua.is_number() ? lua.get_integer() : 0);
        std::vector<UObject*> all, out;
        if (offsets())
        {
            all_of(STR("Actor"), all);
            for (UObject* o : all)
            {
                uint32_t t = 0;
                if (!usable_actor(o) || !tags_of(o, t) || !(t & want)) continue;
                if ((opts & OPT_LEVEL) && !in_level(o)) continue;
                if ((opts & OPT_ROOT) && !is_root(o)) continue;
                if ((opts & OPT_PREFAB) && !under_prefab(o, t)) continue;
                out.push_back(o);
            }
        }
        push_list(lua, out, (opts & OPT_PATHS) != 0);
        return 1;
    }

    // CoopNative_TreePaths(roots) -> { path, ... }: roots ("\n"-separated paths or full names) and every actor whose
    // attach chain reaches one of them (spawnsync destroyTrees)
    int lua_tree_paths(const LuaMadeSimple::Lua& lua)
    {
        std::string roots_text = arg_string(lua);
        std::unordered_set<UObject*> roots;
        for (auto& p : lines(roots_text))
            if (UObject* o = find_path(p)) roots.insert(o);
        std::vector<UObject*> all, out;
        if (offsets() && !roots.empty())
        {
            all_of(STR("Actor"), all);
            for (UObject* o : all)
            {
                if (!usable_actor(o)) continue;
                UObject* x = o;
                for (int g = 0; x && g < 16; ++g)
                {
                    if (roots.count(x)) { out.push_back(o); break; }
                    x = parent_actor(x);
                }
            }
        }
        push_list(lua, out, true);
        return 1;
    }

    // CoopNative_Under(address) -> { actor, ... }: the actors whose attach chain reaches the actor at address (not
    // itself; carghost descendants)
    int lua_under(const LuaMadeSimple::Lua& lua)
    {
        auto root = reinterpret_cast<UObject*>(lua.get_integer());
        std::vector<UObject*> all, out;
        if (offsets() && live(root))
        {
            all_of(STR("Actor"), all);
            for (UObject* o : all)
            {
                if (o == root || !usable_actor(o)) continue;
                UObject* x = parent_actor(o);
                for (int g = 0; x && g < 8; ++g)
                {
                    if (x == root) { out.push_back(o); break; }
                    x = parent_actor(x);
                }
            }
        }
        push_list(lua, out, false);
        return 1;
    }

    // CoopNative_ZoneCounts(markerTag, originTag, skipTag) -> markers, atOrigin: actors in a persistent level with a
    // marker tag; actors with an origin tag (and not skipTag) standing at 0,0,0 (spawnsync zoneReady)
    int lua_zone_counts(const LuaMadeSimple::Lua& lua)
    {
        auto marker = static_cast<uint32_t>(lua.get_integer());
        auto origin = static_cast<uint32_t>(lua.get_integer());
        auto skip = static_cast<uint32_t>(lua.get_integer());
        int64_t markers = 0, at_origin = 0;
        std::vector<UObject*> all;
        if (offsets())
        {
            all_of(STR("Actor"), all);
            for (UObject* o : all)
            {
                uint32_t t = 0;
                if (!usable_actor(o) || !tags_of(o, t) || !(t & (marker | origin)) || !in_level(o)) continue;
                if (t & marker) { ++markers; continue; }
                if (t & skip) continue;
                double x, y, z;
                if (location(o, x, y, z) && x == 0 && y == 0 && z == 0) ++at_origin;
            }
        }
        lua.set_integer(markers);
        lua.set_integer(at_origin);
        return 2;
    }

    // CoopNative_OuterMap(className, outers) -> "outerFullName\tpath\n"...: the objects of a class by their outer
    // (lootsync: item containers by the item instance that owns them). outers: "\n"-separated full names to keep
    // (resolved first; "" = every object of the class, its outer's full name computed)
    int lua_outer_map(const LuaMadeSimple::Lua& lua)
    {
        std::wstring cls = wide(arg_string(lua));
        std::string keys = arg_string(lua);
        std::unordered_map<UObject*, std::string> wanted;
        bool filter = !keys.empty();
        for (auto& k : lines(keys))
            if (UObject* o = find_path(k)) wanted.emplace(o, k);
        std::string res;
        std::vector<UObject*> all;
        if (!filter || !wanted.empty())
        {
            all_of(cls.c_str(), all);
            for (UObject* o : all)
            {
                if (!live(o)) continue;
                UObject* outer = o->GetOuterPrivate();
                if (!live(outer)) continue;
                if (filter)
                {
                    auto it = wanted.find(outer);
                    if (it == wanted.end()) continue;
                    res += it->second;
                }
                else res += full_of(outer);
                res += '\t';
                res += path_of(o);
                res += '\n';
            }
        }
        lua.set_string(res);
        return 1;
    }

    // CoopNative_ParentMap(className) -> "parentFullName\tpath\n"...: actors of a class by the actor they hang under
    // (lootsync: a wreck template's parts)
    int lua_parent_map(const LuaMadeSimple::Lua& lua)
    {
        std::wstring cls = wide(arg_string(lua));
        std::string res;
        std::vector<UObject*> all;
        if (offsets())
        {
            all_of(cls.c_str(), all);
            for (UObject* o : all)
            {
                if (!usable_actor(o)) continue;
                UObject* p = parent_actor(o);
                if (!p) continue;
                res += full_of(p);
                res += '\t';
                res += path_of(o);
                res += '\n';
            }
        }
        lua.set_string(res);
        return 1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // the host's movement tracking (statesync's pass read every root's place from Lua each second: with the loot, 4.4 ms
    // per frame of the host's game, F lines 2026-10-26)
    struct Tracked
    {
        std::string path;
        FWeakObjectPtr weak;
        bool reported = false, seen = false;
        double rx = 0, ry = 0, rz = 0; // last reported
        double x = 0, y = 0, z = 0;    // last read
    };
    std::vector<Tracked> g_track;

    // CoopNative_TrackSet(paths): the actors to track ("\n"-separated paths); those tracked already keep their state
    int lua_track_set(const LuaMadeSimple::Lua& lua)
    {
        std::unordered_map<std::string, Tracked> old;
        for (auto& t : g_track) old.emplace(t.path, std::move(t));
        std::vector<Tracked> next;
        for (auto& p : lines(arg_string(lua)))
        {
            auto it = old.find(p);
            if (it != old.end()) { next.push_back(std::move(it->second)); continue; }
            Tracked t;
            t.path = p;
            if (UObject* o = find_path(p)) t.weak = FWeakObjectPtr(o);
            next.push_back(std::move(t));
        }
        g_track = std::move(next);
        lua.set_integer(static_cast<int64_t>(g_track.size()));
        return 1;
    }

    // CoopNative_TrackMoved(eps) -> "path\tX\tY\tZ\tPitch\tYaw\tRoll\n"...: tracked actors further than eps (cm) from
    // where they were last reported (or never reported); every tracked actor's place is read (for TrackNear)
    int lua_track_moved(const LuaMadeSimple::Lua& lua)
    {
        double eps = lua.is_number() ? lua.get_number() : 5.0;
        std::string res;
        char buf[160];
        for (auto& t : g_track)
        {
            UObject* o = t.weak.Get();
            t.seen = false;
            if (!usable_actor(o)) continue;
            auto a = static_cast<AActor*>(o);
            FVector l = a->K2_GetActorLocation();
            t.x = l.X(), t.y = l.Y(), t.z = l.Z(), t.seen = true;
            double dx = t.x - t.rx, dy = t.y - t.ry, dz = t.z - t.rz;
            if (t.reported && dx * dx + dy * dy + dz * dz <= eps * eps) continue;
            FRotator r = a->K2_GetActorRotation();
            std::snprintf(buf, sizeof buf, "\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\n", t.x, t.y, t.z, r.GetPitch(), r.GetYaw(), r.GetRoll());
            res += t.path;
            res += buf;
            t.rx = t.x, t.ry = t.y, t.rz = t.z, t.reported = true;
        }
        lua.set_string(res);
        return 1;
    }

    // CoopNative_TrackNear(points, radius) -> "path\n"...: tracked actors (as last read) within radius of a point
    // (points: "x y z" lines)
    int lua_track_near(const LuaMadeSimple::Lua& lua)
    {
        std::vector<std::array<double, 3>> pts;
        for (auto& l : lines(arg_string(lua)))
        {
            double x, y, z;
            if (std::sscanf(l.c_str(), "%lf %lf %lf", &x, &y, &z) == 3) pts.push_back({x, y, z});
        }
        double r = lua.is_number() ? lua.get_number() : 3000.0;
        std::string res;
        for (auto& t : g_track)
        {
            if (!t.seen) continue;
            for (auto& p : pts)
            {
                double dx = t.x - p[0], dy = t.y - p[1], dz = t.z - p[2];
                if (dx * dx + dy * dy + dz * dz <= r * r) { res += t.path; res += '\n'; break; }
            }
        }
        lua.set_string(res);
        return 1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // weak references: an object kept across frames without a Lua wrapper that crashes once the object is gone
    std::vector<FWeakObjectPtr> g_weak;
    std::unordered_map<UObject*, int64_t> g_weak_of;

    int64_t weak_new(UObject* o)
    {
        auto it = g_weak_of.find(o);
        if (it != g_weak_of.end() && g_weak[static_cast<size_t>(it->second - 1)].Get() == o) return it->second;
        g_weak.emplace_back(o);
        int64_t h = static_cast<int64_t>(g_weak.size());
        g_weak_of[o] = h;
        return h;
    }
    UObject* weak_get(int64_t h)
    {
        if (h < 1 || h > static_cast<int64_t>(g_weak.size())) return nullptr;
        UObject* o = g_weak[static_cast<size_t>(h - 1)].Get();
        return live(o) ? o : nullptr;
    }

    // CoopNative_RefPath(path) -> handle or nil: the live object at path (full name or path), as a weak handle
    int lua_ref_path(const LuaMadeSimple::Lua& lua)
    {
        UObject* o = find_path(arg_string(lua));
        if (!o) { lua.set_nil(); return 1; }
        lua.set_integer(weak_new(o));
        return 1;
    }
    // CoopNative_FindPath(path) -> object or nil: StaticFindObject without its walk over every object on a miss
    int lua_find_path(const LuaMadeSimple::Lua& lua)
    {
        UObject* o = find_path(arg_string(lua));
        if (!o) { lua.set_nil(); return 1; }
        LuaType::auto_construct_object(lua, o);
        return 1;
    }
    // CoopNative_HasPath(path) -> bool: is a live object there (the hash tables only: a miss at once). Lua then takes
    // the object with UE4SS's own StaticFindObject (fast on a hit); no Lua object is made here.
    int lua_has_path(const LuaMadeSimple::Lua& lua)
    {
        lua.set_bool(find_path(arg_string(lua)) != nullptr);
        return 1;
    }
    // CoopNative_Get(handle) -> object or nil (nil once it is destroyed, unreachable or pending kill)
    int lua_get(const LuaMadeSimple::Lua& lua)
    {
        UObject* o = weak_get(lua.get_integer());
        if (!o) { lua.set_nil(); return 1; }
        LuaType::auto_construct_object(lua, o);
        return 1;
    }
} // namespace

void register_all(const LuaMadeSimple::Lua& lua)
{
    lua.register_function("CoopNative_NewClasses", lua_new_classes);
    lua.register_function("CoopNative_TagClass", lua_tag_class);
    lua.register_function("CoopNative_ForgetClasses", lua_forget_classes);
    lua.register_function("CoopNative_Find", lua_find);
    lua.register_function("CoopNative_TreePaths", lua_tree_paths);
    lua.register_function("CoopNative_ZoneCounts", lua_zone_counts);
    lua.register_function("CoopNative_Under", lua_under);
    lua.register_function("CoopNative_OuterMap", lua_outer_map);
    lua.register_function("CoopNative_ParentMap", lua_parent_map);
    lua.register_function("CoopNative_RefPath", lua_ref_path);
    lua.register_function("CoopNative_Get", lua_get);
    lua.register_function("CoopNative_FindPath", lua_find_path);
    lua.register_function("CoopNative_HasPath", lua_has_path);
    lua.register_function("CoopNative_TrackSet", lua_track_set);
    lua.register_function("CoopNative_TrackMoved", lua_track_moved);
    lua.register_function("CoopNative_TrackNear", lua_track_near);
}
} // namespace world
