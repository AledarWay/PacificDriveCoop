# Fast offline check of the mod's Lua (< 1 s, no game): syntax (luac -p), UTF-8 BOM (UE4SS fails to load
# a script that starts with one) and unknown globals (luac -l lists every global access as GETTABUP/SETTABUP
# _ENV "name"; anything outside the allow-list below is usually a typo or a missing `local`).
# Full in-game load check: lua-check.ps1.
param([string[]]$Paths = @("C:\PacificDriveCoop\mod\CoopSync\Scripts", "C:\PacificDriveCoop\mod\CoopDev\Scripts", "C:\PacificDriveCoop\mod\tools\cmds"))
$luac = "C:\PacificDriveCoop\tools\lua\luac54.exe"
$std = 'coroutine assert collectgarbage debug dofile error getmetatable io ipairs load loadfile math next os package pairs pcall print rawequal rawget rawlen rawset require select setmetatable string table tonumber tostring type utf8 xpcall _G _VERSION'
$ue4ss = 'FindAllOf FindFirstOf FindObject FindObjects StaticFindObject StaticConstructObject LoadAsset FName FText FString UEHelpers EInternalObjectFlags EObjectFlags LoopAsync LoopInGameThreadWithDelay LoopInGameThreadAfterFrames CancelDelayedAction IsDelayedActionActive IsValidDelayedActionHandle ExecuteInGameThread ExecuteAsync ExecuteWithDelay RegisterHook UnregisterHook RegisterKeyBind Key ModifierKey RegisterConsoleCommandHandler NotifyOnNewObject IterateGameDirectories ModRef'
# our cross-module / cross-mod globals (CoopSync*, Dev of CoopDev, UPPER_CASE parameters a test sets before a cmds/*.lua run, like BOT_SKIP)
$ours = '^(CoopSync\w*|CoopDev\w*|Dev|[A-Z][A-Z0-9]*_[A-Z0-9_]+)$'
$allowed = @{}; foreach ($n in ($std + ' ' + $ue4ss) -split ' ') { $allowed[$n] = 1 }
$bad = 0; $files = 0
foreach ($f in Get-ChildItem $Paths -Filter *.lua) {
    $files++
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { "BOM   $($f.Name)"; $bad++ }
    $listing = & $luac -p -l $f.FullName 2>&1
    if ($LASTEXITCODE) { "SYNTAX $($f.Name): $listing"; $bad++; continue }
    $seen = @{}
    foreach ($m in ($listing | Select-String '\[(\d+)\]\s+(GETTABUP|SETTABUP)\s.*_ENV "(\w+)"')) {
        $line = $m.Matches[0].Groups[1].Value; $op = $m.Matches[0].Groups[2].Value; $n = $m.Matches[0].Groups[3].Value
        if ($allowed[$n] -or $n -match $ours) { continue }
        # cmds/*.lua are one-shot chunks: plain global writes there are tolerated, unknown reads are not
        if ($f.DirectoryName -like '*\cmds' -and $op -eq 'SETTABUP') { $allowed[$n] = 1; continue }
        $k = "$op $n"; if ($seen[$k]) { continue }; $seen[$k] = 1
        "GLOBAL $($f.Name):${line} $($op.Substring(0,3)) $n"; $bad++
    }
}
# the mod's texts: every L("...") translated, no Russian text outside it (loc-check.ps1)
& "$PSScriptRoot\loc-check.ps1" | Where-Object { $_ -notmatch '^loc-check: OK' }
if ($LASTEXITCODE) { $bad++ }
if ($bad) { "lua-lint: $bad problem(s) in $files files"; exit 1 } else { "lua-lint: OK ($files files)" }
