// The game's save file (odsave<N>.sav), for the zone through the game's own save (2026-10-31; NOTES "Prototype: the
// host's zone through the game's save", tools/save-splice.ps1 + SaveTree.cs - the same, in C++: 4 MB in Lua is slow).
// Format: "SAVC" header (16 bytes), 16 chunk slots of 24 bytes (tag, offset, stored size, stored size, flags,
// unpacked size; unused slots point at the file's end), chunks from byte 400; GAME (flags 6) is an LZ4 block. GAME =
// u32 6, u32 3, then a typed tree from byte 8 (SaveTree.cs has the types).
//   CoopNative_SaveSplice(guest, host, out, dx, dy) -> "ok ..." | "ERR ..."
//       the guest's save with the host save's root "Map" (the zone), its scene's PlayerTransform /
//       PlayerCameraTransform / CarTransform moved by the host car's right side * (dx: along, dy: sideways) cm
//   CoopNative_SaveInfo(path) -> "chunks=... game=<bytes> keys=<root keys>" | "ERR ..."
#include "save.hpp"

#include <cmath>
#include <filesystem>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace
{
    using Bytes = std::vector<uint8_t>;

    bool read_file(const std::string& p, Bytes& out)
    {
        std::ifstream f(p, std::ios::binary);
        if (!f) return false;
        out.assign(std::istreambuf_iterator<char>(f), {});
        return true;
    }
    bool write_file(const std::string& p, const Bytes& b)
    {
        std::ofstream f(p, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size()));
        return static_cast<bool>(f);
    }
    uint32_t u32(const Bytes& b, size_t p) { uint32_t v; std::memcpy(&v, &b[p], 4); return v; }
    void put32(Bytes& b, size_t p, uint32_t v) { std::memcpy(&b[p], &v, 4); }

    bool lz4_block(const Bytes& s, size_t pos, size_t len, Bytes& d)
    {
        size_t end = pos + len;
        if (end > s.size()) return false;
        d.clear();
        d.reserve(len * 4);
        while (pos < end)
        {
            uint8_t t = s[pos++];
            size_t lit = t >> 4;
            if (lit == 15) { uint8_t x; do { if (pos >= end) return false; x = s[pos++]; lit += x; } while (x == 255); }
            if (pos + lit > end) return false;
            d.insert(d.end(), s.begin() + pos, s.begin() + pos + lit);
            pos += lit;
            if (pos >= end) break;
            if (pos + 2 > end) return false;
            size_t off = s[pos] | (s[pos + 1] << 8);
            pos += 2;
            if (off == 0 || off > d.size()) return false;
            size_t ml = t & 15;
            if (ml == 15) { uint8_t x; do { if (pos >= end) return false; x = s[pos++]; ml += x; } while (x == 255); }
            ml += 4;
            size_t st = d.size() - off;
            for (size_t i = 0; i < ml; ++i) d.push_back(d[st + i]);
        }
        return true;
    }
    // an LZ4 block of literals only (valid LZ4, not compressed)
    Bytes lz4_literals(const Bytes& d)
    {
        Bytes o;
        o.reserve(d.size() + d.size() / 255 + 16);
        size_t n = d.size();
        if (n < 15) o.push_back(static_cast<uint8_t>(n << 4));
        else
        {
            o.push_back(0xF0);
            size_t rest = n - 15;
            while (rest >= 255) { o.push_back(255); rest -= 255; }
            o.push_back(static_cast<uint8_t>(rest));
        }
        o.insert(o.end(), d.begin(), d.end());
        return o;
    }

    struct Slot { std::string tag; uint32_t off, len, flags, raw; };
    struct Save { Bytes file; std::vector<Slot> slots; Bytes game; int game_slot = -1; };

    std::string load_save(const std::string& path, Save& sv)
    {
        if (!read_file(path, sv.file)) return "cannot read " + path;
        if (sv.file.size() < 400 || std::memcmp(sv.file.data(), "SAVC", 4) != 0) return "not a SAVC file: " + path;
        for (int i = 0; i < 16; ++i)
        {
            size_t o = 16 + i * 24;
            Slot s{std::string(reinterpret_cast<const char*>(&sv.file[o]), 4), u32(sv.file, o + 4), u32(sv.file, o + 8), u32(sv.file, o + 16), u32(sv.file, o + 20)};
            sv.slots.push_back(s);
            if (s.tag == "GAME") sv.game_slot = i;
        }
        if (sv.game_slot < 0) return "no GAME chunk";
        const Slot& g = sv.slots[sv.game_slot];
        if (g.flags == 6) { if (!lz4_block(sv.file, g.off, g.len, sv.game)) return "bad LZ4 in GAME"; }
        else sv.game.assign(sv.file.begin() + g.off, sv.file.begin() + g.off + g.len);
        return "";
    }

    // the save tree (SaveTree.cs): skip a value of type t (its type byte read), p after it
    struct Bad {};
    struct Walker
    {
        const Bytes& b;
        size_t p;
        uint32_t U32() { if (p + 4 > b.size()) throw Bad{}; uint32_t v = u32(b, p); p += 4; return v; }
        std::string Str()
        {
            int32_t n = static_cast<int32_t>(U32());
            if (n < -(1 << 20) || n > (1 << 20)) throw Bad{};
            if (n < 0) { size_t c = static_cast<size_t>(-n) * 2; if (p + c > b.size()) throw Bad{}; p += c; return "?"; }
            if (p + n > b.size()) throw Bad{};
            std::string s(reinterpret_cast<const char*>(&b[p]), n);
            p += n;
            while (!s.empty() && s.back() == '\0') s.pop_back();
            return s;
        }
        void Skip(size_t n) { if (p + n > b.size()) throw Bad{}; p += n; }
        // an FFormatArgumentValue: a type byte, then int64 / uint64 / float / double / FText / gender byte
        void Arg()
        {
            switch (b.at(p++))
            {
            case 0: case 1: case 3: Skip(8); return;
            case 2: Skip(4); return;
            case 4: Text(); return;
            case 5: Skip(1); return;
            default: throw Bad{};
            }
        }
        // an FText: u32 flags, a history byte, then that history (runs' stats in a save from later in the game: the
        // zone saves of new players had none, a swamp zone's "ERR host tree", 2026-11-02)
        void Text()
        {
            Skip(4);
            int h = b.at(p++);
            switch (h)
            {
            case 0xff: if (U32()) Str(); return;                                  // none
            case 0x00: Str(); Str(); Str(); return;                               // base: namespace, key, source
            case 0x01: case 0x02: case 0x03:                                       // named / ordered / argument format
            {
                Text();
                uint32_t n = U32();
                for (uint32_t i = 0; i < n; ++i) { if (h != 2) Str(); Arg(); }
                return;
            }
            case 0x04: case 0x05: case 0x06:                                       // as number / percent / currency
                if (h == 6) Str();
                Arg();
                if (U32()) Skip(4 + 4 + 1 + 4 * 4);                               // FNumberFormattingOptions
                Str();                                                             // target culture
                return;
            case 0x0b: Str(); Str(); return;                                       // string table: table, key
            default: throw Bad{};
            }
        }
        void Value(int t)
        {
            switch (t)
            {
            case 0x06: Text(); return;
            case 0x17: Skip(U32()); return;                                        // bytes (a photo's JPEG)
            case 0x18: Skip(8); return;                                            // int64
            case 0x15: case 0x16: { uint32_t n = U32(); for (uint32_t i = 0; i < n; ++i) { Str(); Value(b.at(p++)); } return; }
            case 0x14: { int kt = b.at(p++), vt = b.at(p++); U32(); uint32_t n = U32(); for (uint32_t i = 0; i < n; ++i) Value(kt); for (uint32_t i = 0; i < n; ++i) Value(vt); return; }
            case 0x13: { int et = b.at(p++); uint32_t n = U32(); for (uint32_t i = 0; i < n; ++i) Value(et); return; }
            case 0x10: { uint32_t n = U32(); for (uint32_t i = 0; i < n; ++i) { Str(); Value(b.at(p++)); } return; }
            case 0x01: case 0x02: case 0x03: Skip(4); return;
            case 0x0f: Skip(8); return;
            case 0x07: case 0x08: Skip(12); return;
            case 0x0c: case 0x0d: Skip(16); return;
            case 0x0a: Skip(40); return;
            case 0x04: case 0x05: case 0x0e: case 0x11: case 0x19: case 0x1a: Str(); return;
            case 0x12: { int kind = b.at(p++); int n = kind == 0 ? 0 : kind == 1 ? 1 : 2; for (int i = 0; i < n; ++i) Str(); if (kind == 1) Skip(16); return; }
            default: throw Bad{};
            }
        }
    };
    // the root map's keys -> [start, end) of each value (type byte included); "(root)" -> the whole root
    bool root_ranges(const Bytes& g, std::map<std::string, std::pair<size_t, size_t>>& r)
    {
        try
        {
            Walker w{g, 8};
            int t = g.at(w.p++);
            if (t != 0x15 && t != 0x16) return false;
            uint32_t n = w.U32();
            for (uint32_t i = 0; i < n; ++i)
            {
                std::string k = w.Str();
                size_t s = w.p;
                w.Value(g.at(w.p++));
                r[k] = {s, w.p};
            }
            r["(root)"] = {8, w.p};
            return true;
        }
        catch (...) { return false; }
    }

    // the save with GAME replaced, written to out (chunks other than GAME as they were)
    bool write_save(const Save& sv, const Bytes& game, const std::string& out)
    {
        Bytes packed = lz4_literals(game);
        Bytes body;
        struct NS { bool on; uint32_t off, len, raw; };
        std::vector<NS> ns;
        for (size_t i = 0; i < sv.slots.size(); ++i)
        {
            const Slot& s = sv.slots[i];
            bool tagOk = true;
            for (char c : s.tag) if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) tagOk = false;
            if (s.off >= sv.file.size() || !tagOk) { ns.push_back({false, 0, 0, 0}); continue; }
            uint32_t off = static_cast<uint32_t>(400 + body.size());
            if (static_cast<int>(i) == sv.game_slot) { body.insert(body.end(), packed.begin(), packed.end()); ns.push_back({true, off, static_cast<uint32_t>(packed.size()), static_cast<uint32_t>(game.size())}); }
            else { if (s.len) body.insert(body.end(), sv.file.begin() + s.off, sv.file.begin() + s.off + s.len); ns.push_back({true, off, s.len, s.raw}); }
        }
        uint32_t end = static_cast<uint32_t>(400 + body.size());
        Bytes f(end, 0);
        std::memcpy(f.data(), sv.file.data(), 16);
        for (int i = 0; i < 16; ++i)
        {
            size_t o = 16 + i * 24;
            std::memcpy(&f[o], &sv.file[o], 24);
            if (ns[i].on) { put32(f, o + 4, ns[i].off); put32(f, o + 8, ns[i].len); put32(f, o + 12, ns[i].len); put32(f, o + 20, ns[i].raw); }
            else put32(f, o + 4, end);
        }
        std::memcpy(&f[400], body.data(), body.size());
        return write_file(out, f);
    }

    // the scene transforms in a Map value: key "<name>\0" then type 0x0a and 10 floats (quat x y z w, translation, scale)
    size_t find_xform(const Bytes& g, size_t from, size_t to, const char* name)
    {
        std::string k = std::string(name) + '\0';
        for (size_t i = from; i + k.size() + 41 <= to; ++i)
        {
            if (std::memcmp(&g[i], k.data(), k.size()) == 0 && i >= 4 && u32(g, i - 4) == k.size() && g[i + k.size()] == 0x0a) return i + k.size() + 1;
        }
        return 0;
    }
    float f32(const Bytes& b, size_t p) { float v; std::memcpy(&v, &b[p], 4); return v; }
    void putf(Bytes& b, size_t p, float v) { std::memcpy(&b[p], &v, 4); }
} // namespace

namespace savefile
{
    std::string splice(const std::string& guest, const std::string& host, const std::string& out, double along, double side)
    {
        Save g, h;
        std::string e = load_save(guest, g);
        if (!e.empty()) return "ERR guest: " + e;
        e = load_save(host, h);
        if (!e.empty()) return "ERR host: " + e;
        std::map<std::string, std::pair<size_t, size_t>> gr, hr;
        if (!root_ranges(g.game, gr)) return "ERR guest tree";
        if (!root_ranges(h.game, hr)) return "ERR host tree";
        auto hm = hr.find("Map");
        if (hm == hr.end()) return "ERR the host's save has no Map";
        // the host's Map, its scene transforms moved beside the host's car
        Bytes map(h.game.begin() + hm->second.first, h.game.begin() + hm->second.second);
        size_t car = find_xform(map, 0, map.size(), "CarTransform");
        std::string moved = "no CarTransform";
        if (car)
        {
            float qx = f32(map, car), qy = f32(map, car + 4), qz = f32(map, car + 8), qw = f32(map, car + 12);
            double yaw = std::atan2(2.0 * (qw * qz + qx * qy), 1.0 - 2.0 * (qy * qy + qz * qz));
            double fx = std::cos(yaw), fy = std::sin(yaw), rx = -std::sin(yaw), ry = std::cos(yaw);
            double dx = fx * along + rx * side, dy = fy * along + ry * side;
            int n = 0;
            for (const char* name : {"PlayerTransform", "PlayerCameraTransform", "CarTransform"})
            {
                size_t at = find_xform(map, 0, map.size(), name);
                if (!at) continue;
                putf(map, at + 16, static_cast<float>(f32(map, at + 16) + dx));
                putf(map, at + 20, static_cast<float>(f32(map, at + 20) + dy));
                ++n;
            }
            moved = "moved " + std::to_string(n) + " by " + std::to_string(static_cast<int>(dx)) + "," + std::to_string(static_cast<int>(dy));
        }
        // the guest's GAME with that Map (replaced, or appended at the root's end with the root count raised)
        Bytes game;
        auto gm = gr.find("Map");
        auto root = gr["(root)"];
        if (gm != gr.end())
        {
            game.insert(game.end(), g.game.begin(), g.game.begin() + gm->second.first);
            game.insert(game.end(), map.begin(), map.end());
            game.insert(game.end(), g.game.begin() + gm->second.second, g.game.end());
        }
        else
        {
            game.insert(game.end(), g.game.begin(), g.game.begin() + root.second);
            const char key[] = "Map";
            uint32_t kl = 4;
            game.insert(game.end(), reinterpret_cast<uint8_t*>(&kl), reinterpret_cast<uint8_t*>(&kl) + 4);
            game.insert(game.end(), key, key + 4);
            game.insert(game.end(), map.begin(), map.end());
            game.insert(game.end(), g.game.begin() + root.second, g.game.end());
            put32(game, 9, u32(game, 9) + 1);
        }
        std::map<std::string, std::pair<size_t, size_t>> check;
        if (!root_ranges(game, check)) return "ERR the spliced tree does not parse";
        if (!write_save(g, game, out)) return "ERR cannot write " + out;
        return "ok map=" + std::to_string(map.size()) + " game=" + std::to_string(game.size()) + " " + moved;
    }

    std::string info(const std::string& path)
    {
        Save s;
        std::string e = load_save(path, s);
        if (!e.empty()) return "ERR " + e;
        std::map<std::string, std::pair<size_t, size_t>> r;
        if (!root_ranges(s.game, r)) return "ERR tree";
        std::string keys;
        for (auto& kv : r) if (kv.first != "(root)") keys += kv.first + ":" + std::to_string(kv.second.second - kv.second.first) + " ";
        return "game=" + std::to_string(s.game.size()) + " keys=" + keys;
    }
} // namespace savefile

namespace
{
    std::string arg(const RC::LuaMadeSimple::Lua& lua) { return lua.is_string() ? std::string(lua.get_string()) : std::string{}; }
    int lua_splice(const RC::LuaMadeSimple::Lua& lua)
    {
        std::string g = arg(lua), h = arg(lua), o = arg(lua);
        double along = lua.is_number() ? lua.get_number() : 0, side = lua.is_number() ? lua.get_number() : 0;
        lua.set_string(savefile::splice(g, h, o, along, side));
        return 1;
    }
    int lua_info(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.set_string(savefile::info(arg(lua)));
        return 1;
    }
    // CoopNative_DeleteFiles(dir, prefix) -> count: the files in dir whose names start with prefix (the scratch slot's
    // backups the game writes along: odsave<N>-backup-<time>.sav)
    int lua_delete_files(const RC::LuaMadeSimple::Lua& lua)
    {
        std::string dir = arg(lua), prefix = arg(lua);
        int64_t n = 0;
        std::error_code ec;
        if (!prefix.empty())
            for (auto& e : std::filesystem::directory_iterator(dir, ec))
            {
                std::string name = e.path().filename().string();
                if (e.is_regular_file(ec) && name.rfind(prefix, 0) == 0 && std::filesystem::remove(e.path(), ec)) ++n;
            }
        lua.set_integer(n);
        return 1;
    }
} // namespace

namespace savefile
{
    void register_all(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.register_function("CoopNative_SaveSplice", lua_splice);
        lua.register_function("CoopNative_SaveInfo", lua_info);
        lua.register_function("CoopNative_DeleteFiles", lua_delete_files);
    }
} // namespace savefile
