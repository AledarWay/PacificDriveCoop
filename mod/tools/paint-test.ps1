# Automated "abandoned cars' paint" test (owner's alpha 19 item 16: "all abandoned cars on the guest have the same
# orange-blue paint"). Setup as collide-test's. The host sends each abandoned car's paint / decal palette by place (VP,
# 3 s after the start, then every 20 s); the guest's copy takes them and builds its materials.
#   1. every abandoned car (BP_Template_BaseVehicle_C) of the host has a copy at its place on the guest with the same
#      palettes and dynamic materials
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', '').Trim()
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# each abandoned car away from 0, 0: "x,y=paint/decal/materials" (its place in metres)
$list = "local out = {} for _, c in ipairs(FindAllOf('BP_Template_BaseVehicle_C') or {}) do if c:IsValid() and c:GetFullName():find(':PersistentLevel.', 1, true) then local l = c:K2_GetActorLocation() if math.abs(l.X) + math.abs(l.Y) > 1000 then local function n(x) local ok, v = pcall(function() return x:GetFName():ToString():gsub('BP_Palette_', '') end) return ok and v or 'nil' end out[#out + 1] = string.format('%d,%d=%s/%s/%d', math.floor(l.X / 100 + 0.5), math.floor(l.Y / 100 + 0.5), n(c.SelectedPaintPalette), n(c.SelectedDecalPalette), #c.DynamicMaterialInstances) end end end table.sort(out) return table.concat(out, ' ')"

& "$t\collide-test.ps1" -SetupOnly | Select-String 'started|arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
Start-Sleep 8

"=== 1. the abandoned cars' palettes on both sides"
$h = Send $hd $list; $c = Send $cd $list
$hm = @{}; foreach ($x in ($h -split ' ')) { $k, $v = $x -split '=', 2; if ($v) { $hm[$k] = $v } }
$cm = @{}; foreach ($x in ($c -split ' ')) { $k, $v = $x -split '=', 2; if ($v) { $cm[$k] = $v } }
$same = 0; $diff = @()
foreach ($k in $hm.Keys) {
    $hv = ($hm[$k] -split '/')[0..1] -join '/'; $cv = if ($cm[$k]) { ($cm[$k] -split '/')[0..1] -join '/' } else { 'missing' }
    $mats = if ($cm[$k]) { [int](($cm[$k] -split '/')[2]) } else { 0 }
    if ($hv -eq $cv -and $mats -gt 0) { $same++ } else { $diff += "$k host=$($hm[$k]) guest=$($cm[$k])" }
}
$cr = Send $cd "return CoopSyncState.report()"
Check "every abandoned car of the host has its palettes and materials on the guest" ($hm.Count -ge 3 -and $diff.Count -eq 0) "same $same of $($hm.Count); differ: $($diff -join ' | ') | guest: $(($cr -split ' ') -match '^ap_VP' -join ' ')"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
