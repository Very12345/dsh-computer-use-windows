# Release only the modifier/mouse state potentially left by an interrupted
# plugin-owned input call. No click/down event, app launch or text input.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DesktopInputRelease {
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  public static void Release() {
    mouse_event(0x54,0,0,0,UIntPtr.Zero);
    foreach(byte key in new byte[] {16,17,18}) keybd_event(key,0,2,UIntPtr.Zero);
  }
}
'@
[DesktopInputRelease]::Release()
