# Syntax/load check of the CoopSync Lua modules: starts a headless game to the main menu only and
# dofile()s every module. ~30 s.
# Runs the fast offline lua-lint.ps1 first and stops if it fails.
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $w = "$root\testgame\PenDriverPro\Binaries\Win64"
& "$t\lua-lint.ps1"; if ($LASTEXITCODE) { exit 1 }
$u = "$root\local\instances\lint\userdir"; $dir = "$root\local\instances\lint\coopdev"
New-Item -ItemType Directory -Force $u, $dir | Out-Null
$env:COOPDEV_DIR = $dir.Replace('\', '/')
$p = Start-Process "$w\PenDriverPro-Win64-Shipping.exe" -ArgumentList ((& "$PSScriptRoot\game-args.ps1" -UserDir $u) + "-userdir=`"$u`"") -WorkingDirectory $w -PassThru
try {
    & "$t\wait-state.ps1" -State 1 -Dir $dir -TimeoutSec 120 | Select-Object -Last 1
    $code = "local r = {} for _, m in ipairs({'lootsync', 'spawnsync', 'statesync', 'playersync', 'runsync'}) do local ok, e = pcall(dofile, 'C:/PacificDriveCoop/mod/CoopSync/Scripts/' .. m .. '.lua') r[#r + 1] = m .. '=' .. (ok and 'ok' or tostring(e)) end return table.concat(r, ' | ')"
    Set-Content "$dir\..\lint.lua" $code -Encoding ascii
    & "$t\send.ps1" -File "$dir\..\lint.lua" -Dir $dir -TimeoutSec 60 | Select-String 'OK|ERR'
} finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
