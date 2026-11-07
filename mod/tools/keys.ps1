# Hold a key in a game window (real keyboard input through the OS): keys.ps1 -GamePid <pid> -Key W -Seconds 3
# For checking the game's own input path (driving a twin car with the keyboard) in graphics test runs.
param([int]$GamePid, [string]$Key = 'W', [double]$Seconds = 2, [int]$MouseDX = 0, [int]$MouseDY = 0, [switch]$CornerClick)
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class KeyWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static IntPtr GameWindow(uint pid) {
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowEx(IntPtr.Zero, h, "UnrealWindow", null)) != IntPtr.Zero) { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) return h; }
    return IntPtr.Zero;
  }
}
"@
$h = [KeyWin]::GameWindow([uint32]$GamePid)
if ($h -eq [IntPtr]::Zero) { throw "no game window for pid $GamePid" }
[KeyWin]::SetForegroundWindow($h) | Out-Null
# a click in the window gives it the keyboard (SetForegroundWindow alone is refused for a background process)
$r = New-Object KeyWin+RECT; [KeyWin]::GetWindowRect($h, [ref]$r) | Out-Null
# -CornerClick: the focusing click goes near the window's top right corner (an open menu's buttons are elsewhere)
if ($CornerClick) { [KeyWin]::SetCursorPos($r.R - 40, $r.T + 70) | Out-Null }
else { [KeyWin]::SetCursorPos([int](($r.L + $r.R) / 2), [int](($r.T + $r.B) / 2)) | Out-Null }
[KeyWin]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60; [KeyWin]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 400
# -MouseDX / -MouseDY: move the mouse instead (relative, spread over -Seconds) - looking around
if ($MouseDX -ne 0 -or $MouseDY -ne 0) {
    $steps = [math]::Max(1, [int]($Seconds * 30))
    for ($i = 0; $i -lt $steps; $i++) {
        [KeyWin]::mouse_event(1, [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]($MouseDX / $steps)), 0), [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]($MouseDY / $steps)), 0), 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 33
    }
    "moved the mouse $MouseDX,$MouseDY"; exit 0
}
$vk = switch ($Key) { 'Space' { 0x20 } 'E' { 0x45 } 'Escape' { 0x1B } 'F7' { 0x76 } 'Enter' { 0x0D } 'Up' { 0x26 } 'Down' { 0x28 } default { [byte][char]$Key.ToUpper() } }
$scan = [byte][KeyWin]::MapVirtualKey($vk, 0)
[KeyWin]::keybd_event($vk, $scan, 0x8, [IntPtr]::Zero)   # KEYEVENTF_SCANCODE down
Start-Sleep -Milliseconds ([int]($Seconds * 1000))
[KeyWin]::keybd_event($vk, $scan, 0xA, [IntPtr]::Zero)   # up
"held $Key $Seconds s"
