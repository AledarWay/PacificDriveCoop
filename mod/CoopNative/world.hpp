// The native fast helpers: world walks and weak references for the Lua mod (world.cpp).
#pragma once
#include <LuaMadeSimple/LuaMadeSimple.hpp>

namespace world
{
    void register_all(const RC::LuaMadeSimple::Lua& lua);
}
