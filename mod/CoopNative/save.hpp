#pragma once
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <string>

namespace savefile
{
    std::string splice(const std::string& guest, const std::string& host, const std::string& out, double along, double side);
    std::string info(const std::string& path);
    void register_all(const RC::LuaMadeSimple::Lua& lua);
}
