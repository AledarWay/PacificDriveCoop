# Screenshot of a game window (by process id) into a PNG: for checking the mod's UI in graphics test runs.
#   shot.ps1 -GamePid <pid> -Out <png> [-ClickX x -ClickY y]   (click: window-relative, before the shot)
param([int]$GamePid, [string]$Out, [int]$ClickX = -1, [int]$ClickY = -1)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class ShotWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  // the game's own window (class UnrealWindow), not UE4SS's debug window of the same process
  public static IntPtr GameWindow(uint pid) {
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowEx(IntPtr.Zero, h, "UnrealWindow", null)) != IntPtr.Zero) { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) return h; }
    return IntPtr.Zero;
  }
}
"@
$h = [ShotWin]::GameWindow([uint32]$GamePid)
if ($h -eq [IntPtr]::Zero) { throw "no game window for pid $GamePid" }
[ShotWin]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
$r = New-Object ShotWin+RECT
[ShotWin]::GetWindowRect($h, [ref]$r) | Out-Null
if ($ClickX -ge 0) {
    [ShotWin]::SetCursorPos($r.L + $ClickX, $r.T + $ClickY) | Out-Null
    Start-Sleep -Milliseconds 300
    [ShotWin]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [ShotWin]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
}
$w = $r.R - $r.L; $hh = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"shot $Out ${w}x$hh"
