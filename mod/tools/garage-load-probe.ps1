# Probe (owner's alpha 19 item 5: "the guest should never see a random zone"): the guest loads the host's zone save
# straight from its garage - its garage save with the host's "Map" spliced in, UserLoadGame - instead of travelling
# to its own generated zone first. Prints where the guest ends up: its world, game state, cars, its place by the
# host's car. Games are left running with -Keep.
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
& "$t\start-zone.ps1" -Tag host -Seed 12345 | Select-Object -Last 1
& "$t\start-zone.ps1" -Tag client -Seed 777 -StopInGarage | Select-Object -Last 1
$zs = "ZS = ZS or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/zonesave.lua')"
$census = "local o = {} for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if c:IsValid() and c.RootComponent and c.RootComponent:IsValid() then local l = c:K2_GetActorLocation() o[#o + 1] = string.format('%s@%.0f,%.0f,%.0f', c:GetFName():ToString(), l.X, l.Y, l.Z) end end local p = FindFirstOf('PlayerController').Pawn local pl = p:K2_GetActorLocation() local w = FindFirstOf('World') return 'world=' .. w:GetFName():ToString() .. ' cars=' .. #o .. ' ' .. table.concat(o, ' ') .. string.format(' pawn=%.0f,%.0f,%.0f', pl.X, pl.Y, pl.Z)"
"host: " + (Send $hd $census)
"guest (garage): " + (Send $cd $census)
$zfile = "$($hd.Replace('\','/'))/host-zonesave.sav"
"host zone save: " + (Send $hd "$zs return ZS.hostSave('$zfile')")
$t0 = Get-Date
do { Start-Sleep 1; $zst = Send $hd "$zs ZS.tick() return ZS.s.state" } while ($zst -match 'saving' -and ((Get-Date) - $t0).TotalSeconds -lt 60)
"host zone save: $zst - " + (Send $hd "$zs return ZS.info()")
Copy-Item "$hd\host-zonesave.sav" "$cd\host-zonesave.sav" -Force
$w0 = Send $cd "return tostring(FindFirstOf('World'):GetAddress())"
"guest loads from its garage: " + (Send $cd "$zs local r, e = ZS.guestLoad('$($cd.Replace('\','/'))/host-zonesave.sav', 500) return tostring(r) .. ' ' .. tostring(e or '')")
$t0 = Get-Date
do { Start-Sleep 2; $w1 = Send $cd "local w = FindFirstOf('World') return w and w:IsValid() and tostring(w:GetAddress()) or 'none'" } while (($w1 -eq $w0 -or $w1 -eq 'none' -or $w1 -eq '') -and ((Get-Date) - $t0).TotalSeconds -lt 180)
"guest's level changed after $([int]((Get-Date) - $t0).TotalSeconds) s"
& "$t\wait-state.ps1" -State 5 -Dir $cd -TimeoutSec 180 | Select-Object -Last 1 | ForEach-Object { "guest state: $_" }
"guest load took $([int]((Get-Date) - $t0).TotalSeconds) s"
Start-Sleep 10
"guest: " + (Send $cd $census)
"host: " + (Send $hd $census)
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
