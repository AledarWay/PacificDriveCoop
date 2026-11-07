# Copies the mod's Lua (mod/CoopSync, mod/CoopDev) into the test copy's UE4SS Mods folder (bytes as they are:
# the sources are UTF-8 without BOM, which UE4SS needs). Run before tests; lua-lint first.
$root = "C:\PacificDriveCoop"; $mods = "$root\testgame\PenDriverPro\Binaries\Win64\ue4ss\Mods"
& "$root\mod\tools\lua-lint.ps1" | Out-Null
if ($LASTEXITCODE) { "deploy: lua-lint failed, nothing copied"; exit 1 }
$n = 0
foreach ($m in 'CoopSync', 'CoopDev') {
    $dst = "$mods\$m\Scripts"; New-Item -ItemType Directory -Force $dst | Out-Null
    foreach ($f in Get-ChildItem "$root\mod\$m\Scripts" -Filter *.lua) { Copy-Item $f.FullName "$dst\$($f.Name)" -Force; $n++ }
}
# the texts, one file per language (CoopSync's loc.lua)
New-Item -ItemType Directory -Force "$mods\CoopSync\Scripts\lang" | Out-Null
foreach ($f in Get-ChildItem "$root\mod\CoopSync\Scripts\lang" -Filter *.lua) { Copy-Item $f.FullName "$mods\CoopSync\Scripts\lang\$($f.Name)" -Force; $n++ }
"deploy: $n Lua files copied to $mods"
# the native half (mod/CoopNative -> Mods/CoopSync/dlls/main.dll, built by mod\native\build.bat) and the UE4SS
# build it is compiled against (its C++ API must match): copied when they changed
$win64 = "$root\testgame\PenDriverPro\Binaries\Win64"; $bin = "$root\local\native-build"
$native = [ordered]@{
    "$bin\CoopNative\main.dll"                   = "$mods\CoopSync\dlls\main.dll"
    "$bin\Game__Shipping__Win64\bin\UE4SS.dll"   = "$win64\ue4ss\UE4SS.dll"
    "$bin\Game__Shipping__Win64\bin\dwmapi.dll"  = "$win64\dwmapi.dll"
}
foreach ($src in $native.Keys) {
    $dst = $native[$src]
    if (-not (Test-Path $src)) { "deploy: $src missing (run mod\native\build.bat first)"; continue }
    if ((Test-Path $dst) -and (Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash) { continue }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force; "deploy: $(Split-Path $dst -Leaf) updated"
}
