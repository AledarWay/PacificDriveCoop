// Wwise calls the game's exe exports (AK::SoundEngine): the radio track's position and a seek (audio.cpp).
#pragma once
#include <LuaMadeSimple/LuaMadeSimple.hpp>

namespace audio
{
    void register_all(const RC::LuaMadeSimple::Lua& lua);
}
