# Travels one running instance through map locations and takes the hazard census in each (cmds/hazard-census.lua,
# class counts only): which zones have which anomalies. The instance must already be in a zone (start-save.ps1).
#   zone-census.ps1 -Tag host -Locs MLoc_Wilderness_Swamp_10,MLoc_Rural_Swamp_Town_Kraken_02 [-SettleSec 40]
param([string]$Tag = 'host', [string[]]$Locs, [int]$SettleSec = 40)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $dir = "$root\local\instances\$Tag\coopdev"
function Send([string]$code, [int]$timeout = 120) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec $timeout) -split "`r?`n" | Where-Object { $_ -notmatch '^=== ' }) -join "`n") -replace '^OK ', ''
}
$census = Get-Content "$t\cmds\hazard-census.lua" -Raw
foreach ($loc in $Locs) {
    "=== $loc"
    # home to the garage, the next leg's map set to this location, out again (the game's own way: route-override)
    $full = (Get-Content "$root\local\instances\maplocs.txt" | Where-Object { $_ -match "\.$loc\t" } | Select-Object -First 1) -replace "`t.*$", ''
    if (-not $full) { "  not in maplocs.txt"; continue }
    Send 'local o = {} FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, true, false, false, 1, o)' | Out-Null
    & "$t\wait-state.ps1" -State 4 -Dir $dir -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { "  $_" }
    "  " + (Send "ROUTE_TARGET_MAP = '$full' $(Get-Content "$t\cmds\route-override.lua" -Raw)")
    Send 'StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(FindFirstOf("PlayerController"))' | Out-Null
    $want = ($loc -replace '^MLoc_', '')
    $ok = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep 2
        try { $w = Send "local gi = FindFirstOf('DrivingGameInstance') local ok, n = pcall(function() return gi:GetWorld():GetFName():ToString() end) local pc = FindFirstOf('PlayerController') return (ok and n or '?') .. ' pawn=' .. tostring(pc and pc.Pawn and pc.Pawn:IsValid())" 20 } catch { $w = '' }
        if ($w -match [regex]::Escape($want) -and $w -match 'pawn=true') { $ok = $true; break }
    }
    "  arrived: $ok ($w)"
    if (-not $ok) { continue }
    Start-Sleep $SettleSec
    $c = Send $census 180
    ($c -split "`n") | Where-Object { $_ -match ' x\d+$' } | ForEach-Object { "  $_" }
}
