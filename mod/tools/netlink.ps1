# The network between a test's two games (dot-source it after $root, $Port and $NetExe are set):
#   default   the in-game network's local test link: each game gets COOPSYNC_NET=tcp:<port>:<name> (NetSpec) while
#             it starts; the host's "create" listens on 127.0.0.1:<port>, the guest's "join" connects
#   -NetExe   the old helper: two CoopNet.exe on the same local TCP link, the games get COOPSYNC_NET=exe
# The menu's commands still go into <chan>/net-control.txt (NetCtl): the in-game network reads it in the test mode.
function NetSpec([string]$name) { if ($NetExe) { 'exe' } else { "tcp:${Port}:$name" } }
function NetExeStart($chan, [string]$name) {
    if (-not $NetExe) { return $null }
    Start-Process "$root\mod\net\CoopNet\bin\Release\net8.0\win-x64\CoopNet.exe" -ArgumentList "--chan `"$chan`" --tcp $Port --name $name --parent $PID" -PassThru
}
function NetExeStop { foreach ($p in @($rh, $rc)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } }
