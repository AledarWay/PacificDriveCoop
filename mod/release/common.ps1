# Shared by install, uninstall and the report: where the game is (through Steam) and where its saves are.
$AppId = 1458140

function Find-Game {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $p = Get-ItemProperty $k -ErrorAction Stop; $steam = if ($p.SteamPath) { $p.SteamPath } else { $p.InstallPath }; if ($steam) { break } } catch {}
    }
    if (-not $steam) { return $null }
    $libs = @($steam.Replace('/', '\'))
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (Test-Path $acf) {
            $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) { $d = Join-Path $lib "steamapps\common\$($m.Groups[1].Value)"; if (Test-Path $d) { return $d } }
        }
    }
    return $null
}

function Game-Bin([string]$gameDir) { "$gameDir\PenDriverPro\Binaries\Win64" }
function Game-Saved { Join-Path $env:LOCALAPPDATA 'PenDriverPro\Saved' }
# the two copies of TwoGamesTest.bat: each with its own -userdir (saves, logs, the mod's channel)
function TwoGames-Root { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PacificDriveCoop\two-games' }
