# Action audit: real input in both Lua states, the log's context and the persistent config switch.
param([switch]$Keep)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$ha = "$inst\host\userdir\Saved\CoopSync\audit.log"; $ca = "$inst\client\userdir\Saved\CoopSync\audit.log"
function Send($dir, [string]$code, [switch]$Session) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    (((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120 -Session:$Session) -split "`r?`n" | Where-Object { $_ -match '^(OK|RUNTIME|COMPILE)' }) -join ' ') -replace '^OK ', ''
}
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
$env:COOPSYNC_AUDIT = '1'
& "$t\cars-test.ps1" -SetupOnly | Select-Object -Last 2
Start-Sleep 3
$hl = Get-Content $ha -Raw -ErrorAction SilentlyContinue; $cl = Get-Content $ca -Raw -ErrorAction SilentlyContinue
Check "both states start an audit with session context" ($hl -match 'audit\tstarted' -and $cl -match 'audit\tstarted' -and $hl -match 'session\t' -and $cl -match 'session\t') "host=$ha client=$ca"

Send $hd "CE_CAR = 'own' CE_HL = 'ExitDoor' $(Get-Content "$t\cmds\car-e.lua" -Raw)" | Out-Null
Start-Sleep 2
$hl = Get-Content $ha -Raw -ErrorAction SilentlyContinue
Check "host input and its door effect are logged" ($hl -match 'input\tinteract=true' -and $hl -match 'door\texit') (($hl -split "`n" | Select-Object -Last 8) -join ' | ')

Send $cd "CE_CAR = 'twin' CE_HL = 'door1' $(Get-Content "$t\cmds\car-e.lua" -Raw)" | Out-Null
Start-Sleep 2
$cl = Get-Content $ca -Raw -ErrorAction SilentlyContinue
Check "guest input and its door effect are logged" ($cl -match 'input\tinteract=true' -and $cl -match 'door\t') (($cl -split "`n" | Select-Object -Last 8) -join ' | ')

$off = Send $hd "CoopSyncConfig.set('audit', 0) return tostring(CoopSyncConfig.get('audit'))" -Session
$on = Send $hd "CoopSyncConfig.set('audit', 1) return tostring(CoopSyncConfig.get('audit'))" -Session
$reportHasAudit = (Select-String -Path "$root\mod\CoopSync\tools\collect-report.ps1" -Pattern "'audit.log'" -Quiet)
Check "the config switch persists and reports include the audit" ($off -eq '0' -and $on -eq '1' -and $reportHasAudit) "off=$off on=$on"

"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
$env:COOPSYNC_AUDIT = $null
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force }
