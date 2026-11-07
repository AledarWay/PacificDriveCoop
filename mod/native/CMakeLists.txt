# Build tree for the C++ part of CoopSync: UE4SS from source (the commit the mod runs on, ue4ss-commit.txt) + our C++ mod.
# UE4SS sources: local/ue4ss-src (a clone of UE4SS-RE/RE-UE4SS with submodules; UEPseudo needs an Epic-linked
# GitHub account). Build: mod/native/build.bat (build dir local/native-build), or by hand from an x64 Native Tools prompt:
#   cmake -S mod/native -B local/native-build -G Ninja -DCMAKE_BUILD_TYPE=Game__Shipping__Win64
#   cmake --build local/native-build
cmake_minimum_required(VERSION 3.22)
project(CoopSyncNative)
set(UE4SS_SRC "${CMAKE_CURRENT_LIST_DIR}/../../local/ue4ss-src" CACHE PATH "RE-UE4SS source tree")
add_subdirectory(${UE4SS_SRC} ue4ss)
add_subdirectory(../CoopNative CoopNative)
