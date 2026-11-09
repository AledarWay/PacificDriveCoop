# The sun / sky / fog on both instances of a running pair every -StepSec for -Sec (probes by hand); -HostCode runs on
# the host first (e.g. a new weather target)
param([int]$Sec = 60, [int]$StepSec = 5, [string]$HostCode = "")
$t = "C:\PacificDriveCoop\mod\tools"; $inst = "C:\PacificDriveCoop\local\instances"
function Snd($dir, [string]$code) { $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii; (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 60) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', '' }
$q = "local s, k, f = '-', '-', '-' for _, c in ipairs(FindAllOf('DirectionalLightComponent') or {}) do if c:IsValid() and not c:GetFullName():find('Default__', 1, true) then s = string.format('%.3f', c.Intensity) end end " +
    "for _, c in ipairs(FindAllOf('SkyLightComponent') or {}) do if c:IsValid() and not c:GetFullName():find('Default__', 1, true) then k = string.format('%.2f', c.Intensity) end end " +
    "for _, c in ipairs(FindAllOf('ExponentialHeightFogComponent') or {}) do if c:IsValid() and not c:GetFullName():find('Default__', 1, true) then f = string.format('%.4f', c.FogDensity) end end " +
    "local m = FindFirstOf('BP_ToDManager_C') local t = {} m['Get Current Time Of Day'](m, t) local p = {} m['Get Target to D Preset'](m, p) local pr = p['Target TOD Preset'] " +
    "return string.format('tod=%.4f sun=%s sky=%s fog=%s target=%s', t['Returned Time Of Day'], s, k, f, (pr and pr:IsValid()) and pr:GetFName():ToString() or '-')"
if ($HostCode) { "host: " + (Snd "$inst\host\coopdev" $HostCode) }
$end = (Get-Date).AddSeconds($Sec)
do {
    $h = Snd "$inst\host\coopdev" $q; $c = Snd "$inst\client\coopdev" $q
    "{0:HH:mm:ss}  host {1}  |  guest {2}" -f (Get-Date), $h, $c
    Start-Sleep $StepSec
} while ((Get-Date) -lt $end)
