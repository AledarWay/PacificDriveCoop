# The sun / sky / fog on both instances of a running pair sampled in-game every 250 ms for -Sec on the PC's wall clock
# (both games on one PC: the same clock), lined up by time - a true side-by-side, not two probes seconds apart.
# -HostCode runs on the host right after the sampling starts (e.g. a weather event).
param([int]$Sec = 60, [string]$HostCode = "", [switch]$Quiet)
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
function Snd($dir, [string]$code) { $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii; (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', '' }
$start = "LS_OUT = {} local function last(cls) local r for _, c in ipairs(FindAllOf(cls) or {}) do if c:IsValid() and not c:GetFullName():find('Default__', 1, true) then r = c end end return r end " +
    "local w = FindFirstOf('PlayerController').Pawn:GetFullName():match('PersistentLevel') and FindFirstOf('PlayerController').Pawn:GetFullName():match('^%S+%s+/[^.]*%.([^:]+):') " +
    "local function here(cls) for _, c in ipairs(FindAllOf(cls) or {}) do if c:IsValid() and c:GetFullName():find('.' .. w .. ':', 1, true) then return c end end return last(cls) end " +
    "local sun, sky, fog = here('DirectionalLightComponent'), here('SkyLightComponent'), here('ExponentialHeightFogComponent') " +
    "local s0 = os.time() local guard = os.clock() + 1.5 while os.time() == s0 and os.clock() < guard do end local base = os.time() * 1000 - os.clock() * 1000 local t0 = os.clock() local h h = LoopInGameThreadWithDelay(250, function() local c = os.clock() if c - t0 > $Sec then CancelDelayedAction(h) return end " +
    "LS_OUT[#LS_OUT + 1] = string.format('%d %.3f %.3f %.4f', math.floor(base + c * 1000), sun.Intensity, sky.Intensity, fog.FogDensity) end) return 'sampling in ' .. tostring(w)"
"host: " + (Snd "$inst\host\coopdev" $start); "guest: " + (Snd "$inst\client\coopdev" $start)
if ($HostCode) { "host: " + (Snd "$inst\host\coopdev" $HostCode) }
Start-Sleep ($Sec + 3)
$get = "return table.concat(LS_OUT, ';')"
$hs = (Snd "$inst\host\coopdev" $get) -split ';'; $cs = (Snd "$inst\client\coopdev" $get) -split ';'
$HS = foreach ($x in $hs) { $p = $x -split ' '; if ($p.Count -eq 4) { [pscustomobject]@{ t = [double]$p[0]; sun = [double]$p[1]; sky = [double]$p[2]; fog = [double]$p[3] } } }
$CS = foreach ($x in $cs) { $p = $x -split ' '; if ($p.Count -eq 4) { [pscustomobject]@{ t = [double]$p[0]; sun = [double]$p[1]; sky = [double]$p[2]; fog = [double]$p[3] } } }
"samples host $($HS.Count) guest $($CS.Count)"
$i = 0; $maxS = 0; $maxF = 0; $n = 0; $allS = @(); $allF = @()
foreach ($c in $CS) {
    while ($i -lt $HS.Count - 1 -and [Math]::Abs($HS[$i + 1].t - $c.t) -le [Math]::Abs($HS[$i].t - $c.t)) { $i++ }
    $h = $HS[$i]; if ([Math]::Abs($h.t - $c.t) -gt 200) { continue }
    $ds = if ($h.sun -gt 0.05) { [Math]::Abs($c.sun - $h.sun) / $h.sun } else { 0 }
    $df = if ($h.fog -gt 0.001) { [Math]::Abs($c.fog - $h.fog) / $h.fog } else { 0 }
    if ($ds -gt $maxS) { $maxS = $ds }; if ($df -gt $maxF) { $maxF = $df }; $allS += $ds; $allF += $df
    if (-not $Quiet -and $n % 8 -eq 0) { "{0,6:F1}s  host sun {1:F3} fog {2:F4}  |  guest sun {3:F3} fog {4:F4}" -f (($c.t - $CS[0].t) / 1000), $h.sun, $h.fog, $c.sun, $c.fog }
    $n++
}
# (the 90th percentile too: the max of 60 pairs caught a single swing - nextzone 2026-11-10, fog 5.2 % once)
function P90($v) { if (-not $v.Count) { return '0.000' }; $o = @($v | Sort-Object); [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F3}', $o[[Math]::Min($o.Count - 1, [int][Math]::Floor($o.Count * 0.9))]) }
"paired $n  max sun diff {0:P1}  max fog diff {1:P1}" -f $maxS, $maxF
"LIGHTPAIR n=$n sun=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F3}', $maxS)) fog=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F3}', $maxF)) sun90=$(P90 $allS) fog90=$(P90 $allF)"
