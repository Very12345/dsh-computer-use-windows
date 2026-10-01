param([long]$WindowHandle)
$ErrorActionPreference = 'Stop'
# Read-only test diagnostics. This helper never activates, moves or inputs.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SmokeDesktopMetrics {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT value);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
}
'@
[void][SmokeDesktopMetrics]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
$point = New-Object SmokeDesktopMetrics+POINT
if (-not [SmokeDesktopMetrics]::GetCursorPos([ref]$point)) { throw 'Cursor unavailable' }
@{ x=$point.x; y=$point.y; primary=@{w=[SmokeDesktopMetrics]::GetSystemMetrics(0);h=[SmokeDesktopMetrics]::GetSystemMetrics(1)}; dpi=[SmokeDesktopMetrics]::GetDpiForWindow([IntPtr]$WindowHandle) } | ConvertTo-Json -Compress
