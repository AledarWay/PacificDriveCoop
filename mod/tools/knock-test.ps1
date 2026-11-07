# Automated "knocked / kicked objects for both" test (owner, alpha 18 items 31 / 38: "a tree / barrel / physical object
# knocked by the host's car stays standing on the guest", "destruction / pushing objects by a kick not synced").
# Setup as collide-test's (both cars in the zone, state and player sync on both; the shrubs and trees by the cars are
# swapped in on both sides).
#   1. the host's car drives through a shrub: broken on the host, broken / gone on the guest too (KB)
#   2. the host kicks one: the guest's copy gets the same kick (KK; a kick of one the other side has not swapped in -
#      its player far - is let go)
#   3. the guest's own car drives through another one: the host's copy goes too
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
function Kn($dir, [string]$op, [string]$extra = '') { Send $dir "KN_OP = '$op' $extra $(Get-Content "$t\cmds\knock-probe.lua" -Raw)" }
function Obj($s) { if ($s -match '^(\S+) (-?\d+),(-?\d+)$') { "KN_CLS = '$($Matches[1])' KN_X = $($Matches[2]) KN_Y = $($Matches[3])" } }

& "$t\collide-test.ps1" -SetupOnly | Select-String 'started|arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }

"=== 1. the host's car drives through a shrub"
$a = Kn $hd 'aim'; "  host aimed at: $a"; $oa = Obj $a
Start-Sleep 5
$h = Kn $hd 'state' $oa; $c = Kn $cd 'state' $oa
$hr = Send $hd "return CoopSyncState.report()"; $cr = Send $cd "return CoopSyncState.report()"
Check "the host broke it, the guest's copy broke too (KB)" ($oa -and $h -ne 'standing' -and $c -ne 'standing' -and $cr -match 'ap_KB=') "host: $h | guest: $c | host: $hr | guest: $cr"

"=== 2. the host kicks one (the guest still on foot near: its copy swapped in)"
$k = Kn $hd 'aim' "KN_MIN = 300 KN_SPEED = 0 KN_BACK = 2500 KN_LIKE = 'Oak'"; $ok = Obj $k
"  host kicks: " + (Kn $hd 'kick' $ok) + " ($k)"
Start-Sleep 3
$cr = Send $cd "return CoopSyncState.report()"
Check "the guest's copy got the kick (KK)" ($cr -match 'ap_KK=1') "guest: $cr"

"=== 3. the guest's own car drives through another one"
"  guest: " + (Send $cd "return CoopPlayers.botEnterCar()")
Start-Sleep 4
$b = Kn $cd 'aim' 'KN_MIN = 300'; "  guest aimed at: $b"; $ob = Obj $b
"  guest: " + (Send $cd "return CoopPlayers.botInput(3, 1.0, 0)")
Start-Sleep 5
$h = Kn $hd 'state' $ob; $c = Kn $cd 'state' $ob
$hr = Send $hd "return CoopSyncState.report()"
Check "the guest broke it, the host's copy broke too" ($ob -and $c -ne 'standing' -and $h -ne 'standing' -and $hr -match 'req_KB=') "host: $h | guest: $c | host: $hr"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id ([int]$sess.relayHost), ([int]$sess.relayClient) -Force -ErrorAction SilentlyContinue
}
