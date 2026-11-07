# CoopNative: the C++ half of the CoopSync mod (built into Mods/CoopSync/dlls/main.dll, next to its Lua scripts:
# UE4SS then calls on_lua_start for the Lua mod of the same name, where the native functions are registered).
set(TARGET CoopNative)
add_library(${TARGET} SHARED dllmain.cpp net.cpp world.cpp audio.cpp trace.cpp save.cpp)
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS ws2_32)
set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME "main")
