@echo off
rem Builds the native half (CoopNative -> main.dll) and our UE4SS (UE4SS.dll, dwmapi.dll) into local\native-build.
rem Finds MSVC through vswhere (Build Tools locally, any VS 2022+ edition on the CI runner).
setlocal
set ROOT=%~dp0..\..
set PATH=%PATH%;C:\Program Files (x86)\Microsoft Visual Studio\Installer;%USERPROFILE%\.cargo\bin
for /f "usebackq tokens=*" %%i in (`vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VS=%%i
if not defined VS (echo MSVC not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%ROOT%"
if not exist local\native-build\build.ninja cmake -S mod\native -B local\native-build -G Ninja -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 || exit /b 1
cmake --build local\native-build
