# Car parts broken by a tool (2026-11-09, owner: "the friend could saw off the whole white bar of a part, the red one
# never started, so the part could not be broken"; "the parts' breakage is not synced").
# -SetupOnly: the pair with both twins up (own-car mode, both players on foot), then stop (probes by hand).
param([switch]$Keep, [switch]$SetupOnly)
$root = "C:\PacificDriveCoop"; $t = "$root\mod\tools"; $inst = "$root\local\instances"
$hd = "$inst\host\coopdev"; $cd = "$inst\client\coopdev"
$lib = "CoopSync = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua') CoopSyncState = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/statesync.lua') CoopPlayers = dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/playersync.lua')"
function Send($dir, [string]$code) {
    $f = "$dir\_send.lua"; Set-Content $f $code -Encoding ascii
    ((((& "$t\send.ps1" -File $f -Dir $dir -TimeoutSec 120) -split "`r?`n" | Where-Object { $_ -notmatch '^(=== )' }) -join "`n") -replace '^OK ', '').Trim()
}
function P($p) { $p.Replace('\', '/') }
function Probe($dir, [string]$pre, [string]$file) { Send $dir ($pre + " " + (Get-Content "$t\cmds\$file" -Raw)) }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "  [{0}] {1} -- {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
& "$t\deploy.ps1"
"=== 0. the guest joins with its own car"
& "$t\sync-test.ps1" -KeepHost -KeepClient -Net -GuestJoin | Select-String 'arrived'
$sess = @{}; Get-Content "$inst\net-session.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; $sess[$k] = $v }
"  guest car aside: " + (Send $cd "local c for _, x in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do if x:IsValid() and x:GetFullName():find(':PersistentLevel.', 1, true) then c = x break end end local h = $(Send $hd "local c = FindFirstOf('BP_PlayerCarNew_C') local l = c:K2_GetActorLocation() return string.format('{X=%.1f,Y=%.1f,Z=%.1f}', l.X, l.Y + 800, l.Z + 60)") c:K2_SetActorLocation(h, false, {}, true) c.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = -50 }, false, FName('None')) return 'moved'")
Start-Sleep 3
"host: " + (Send $hd "$lib CoopSyncState.start(CoopSync, 'host', '$(P $sess.hchan)') return CoopPlayers.start(CoopSync, 'host', '$(P $sess.hchan)')")
"client: " + (Send $cd "$lib CoopSyncState.start(CoopSync, 'client', '$(P $sess.cchan)', '$(P "$($sess.cchan)\inbox\host-spawnlist.tsv")') return CoopPlayers.start(CoopSync, 'client', '$(P $sess.cchan)', { ownCar = true })")
Start-Sleep 15
"  host: " + (Send $hd "return CoopPlayers.botExitCar()") + " | guest: " + (Send $cd "return CoopPlayers.botExitCar()")
Start-Sleep 4
if ($SetupOnly) { "setup done"; return }

# the wreck nearest the host's player: its parts on a side as @{ socket = @{ h; bh } }
function Wp($dir, [string]$pre) { $r = Probe $dir "WP_AT = $script:at WP_PART = nil WP_N = 0 WP_DMG = 5 WP_MSG = nil $pre" "wreck-part-probe.lua"; $r }
function Parts($dir) {
    $m = @{}
    foreach ($s in ((Wp $dir "") -split ' \|\| ')) { if ($s -match '^(\S+) \S+ h=([-\d.]+) bh=([-\d.]+)$') { $m[$matches[1]] = @{ h = [double]$matches[2]; bh = [double]$matches[3] } } }
    $m
}
function Hit($dir, [string]$sock, [int]$n) { Wp $dir "WP_PART = '$sock' WP_N = $n" | Out-Null; Start-Sleep -Milliseconds 400 }
function Fmt($p) { ($p.Keys | Sort-Object | ForEach-Object { "$_=$($p[$_].h)/$($p[$_].bh)" }) -join ' ' }
$script:at = Send $hd "local l = FindFirstOf('PlayerController').Pawn:K2_GetActorLocation() return string.format('{ X = %.0f, Y = %.0f, Z = %.0f }', l.X, l.Y, l.Z)"
"  wreck: " + ((Wp $hd "") -split ' \|\| ')[0]
$canBreak = "local HC = StaticFindObject('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C') local n, all = 0, 0 for _, p in ipairs(FindAllOf('LootableTemplatePart') or {}) do if p:IsValid() then local hc = p:GetComponentByClass(HC) if hc and hc:IsValid() then all = all + 1 if hc.CanBeBreaking then n = n + 1 end end end end return n .. '/' .. all"

# (the host's first full list 3 s in, by design - WRK.allAt in statesync.lua; 4 s left only ~1 s of margin, tight
# enough that one part's line still in flight at the check moment made this FAIL once in three live runs even
# though the sync itself was fine a moment later, 2026-11-13)
"=== 1. the guest's wreck parts can break, their health is the host's (the host's full list 3 s in)"
Start-Sleep 8
$cb = Send $cd $canBreak
$cbn, $cba = $cb -split '/'
Check "guest: every wreck part can break (CanBeBreaking, as on the host)" ($cba -gt 0 -and $cbn -eq $cba) "guest $cb, host $(Send $hd $canBreak)"
$hp = Parts $hd; $gp = Parts $cd
$same = $hp.Count -gt 0 -and @($hp.Keys | Where-Object { -not $gp.ContainsKey($_) -or [math]::Abs($gp[$_].h - $hp[$_].h) -gt 0.2 }).Count -eq 0
Check "guest: the wreck's parts have the host's health" $same "host $(Fmt $hp) | guest $(Fmt $gp)"
if (-not $same) {
    $diag = "local W = CoopSyncWreck local out = {} out[#out+1] = string.format('sent=%s applied=%s lateApplied=%s breakable=%s', tostring(W.sent), tostring(W.applied), tostring(W.lateApplied), tostring(W.breakable)) local n = 0 for k, e in pairs(W.missed or {}) do n = n + 1 if n <= 10 then out[#out+1] = 'missed:' .. k .. '@' .. tostring(os.clock() - e.at) end end out[#out+1] = 'missed_total=' .. n local idxN = 0 for k in pairs(W.index or {}) do idxN = idxN + 1 end out[#out+1] = 'index_size=' .. idxN return table.concat(out, ' | ')"
    "  DIAG host: " + (Send $hd $diag)
    "  DIAG guest: " + (Send $cd $diag)
}

# the two parts with the least health, doors / panels / the trunk only (a few hits of WP_DMG=5 breaks them off at a
# predictable pace); a wheel's own random roll can start as low as ~13, and 1-2 hits straight through it before the
# loop below ever checks - the "red bar filling" moment this step means to catch never happens (2026-11-13)
$order = @($hp.Keys | Where-Object { $hp[$_].h -gt 0 -and $_ -match '^(Door|Panel|Trunk)' } | Sort-Object { $hp[$_].h })
if ($order.Count -lt 2) { $order = @($hp.Keys | Where-Object { $hp[$_].h -gt 0 } | Sort-Object { $hp[$_].h }) } # this wreck has too few (wheels back in, as before)
$p1, $p2 = $order[0], $order[1]
"  parts: $p1 (guest saws it off), $p2 (host saws it)"

"=== 2. the guest saws $p1 past its health: the red bar fills, on the host too"
$gb = 0
for ($i = 0; $i -lt 20 -and $gb -lt 3; $i++) { Hit $cd $p1 1; $g = Parts $cd; if (-not $g.ContainsKey($p1)) { break }; $gb = $g[$p1].bh }
Start-Sleep 2
$g = Parts $cd; $h = Parts $hd
Check "guest: past the white bar the red one fills (break health)" ($g.ContainsKey($p1) -and $g[$p1].h -eq 0 -and $g[$p1].bh -gt 0) "guest $p1=$($g[$p1].h)/$($g[$p1].bh)"
Check "host: its copy shows the guest's sawing (health and break health)" ($h.ContainsKey($p1) -and $g.ContainsKey($p1) -and [math]::Abs($h[$p1].h - $g[$p1].h) -le 0.2 -and [math]::Abs($h[$p1].bh - $g[$p1].bh) -le 0.2) "host $p1=$($h[$p1].h)/$($h[$p1].bh)"

"=== 3. the guest saws it off: gone on both"
for ($i = 0; $i -lt 30; $i++) { $g = Parts $cd; if (-not $g.ContainsKey($p1)) { break }; Hit $cd $p1 1 }
Start-Sleep 8
$g = Parts $cd; $h = Parts $hd
Check "guest: the part broke off" (-not $g.ContainsKey($p1)) "guest $(Fmt $g)"
Check "host: the part is gone there too" (-not $h.ContainsKey($p1)) "host $(Fmt $h)"

"=== 4. the host saws $p2 halfway: the guest's copy shows it"
$h0 = $h[$p2].h
for ($i = 0; $i -lt 10; $i++) { $h = Parts $hd; if ($h[$p2].h -le $h0 / 2) { break }; Hit $hd $p2 1 }
Start-Sleep 2
$h = Parts $hd; $g = Parts $cd
Check "guest: the host's sawing shows on its copy" ($h[$p2].h -lt $h0 -and $g.ContainsKey($p2) -and [math]::Abs($g[$p2].h - $h[$p2].h) -le 0.2) "host $p2=$($h[$p2].h)/$($h[$p2].bh) (was $h0) | guest $($g[$p2].h)/$($g[$p2].bh)"

"=== 5. no errors"
$stat = "local W = CoopSyncWreck return string.format('sent=%d applied=%d late=%d breakable=%d', W.sent or 0, W.applied or 0, W.lateApplied or 0, W.breakable or 0)"
"  host: " + (Send $hd $stat) + " | guest: " + (Send $cd $stat)
$errQ = "local r = CoopSyncState.report() return r:match('ERRORS: (.*)') or 'none'"
$e1 = Send $hd $errQ; $e2 = Send $cd $errQ
Check "no state sync errors on either side" ($e1 -eq 'none' -and $e2 -eq 'none') "host: $e1 | guest: $e2"

""
"=== RESULT: $script:pass passed, $script:fail failed -> $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' })"
if (-not $Keep) { Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process CoopNet -ErrorAction SilentlyContinue | Stop-Process -Force }
