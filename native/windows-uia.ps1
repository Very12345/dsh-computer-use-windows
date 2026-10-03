param(
  [Parameter(Mandatory = $false)]
  [string]$Action,
  [switch]$Persistent
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================================
# DSH Windows desktop backend (MIT derivative; see native/LICENSE and NOTICE)
#
# Modes:
#   -One-shot:  windows-uia.ps1 -Action <name>        (args: JSON on stdin)
#   -Persistent: windows-uia.ps1 -Persistent          (args: JSON lines on stdin,
#                one JSON line response per line on stdout; keeps the process
#                alive so repeated actions skip PowerShell startup, assembly
#                loading and C# compilation)
# ============================================================================

function Write-JsonLine {
  param([object]$Value)
  $Value | ConvertTo-Json -Depth 50 -Compress
}

function Get-InputObject {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{}
  }
  return $raw | ConvertFrom-Json
}

function Get-Prop {
  param([object]$Object, [string]$Name, [object]$Default = $null)
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  if ($null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Get-ViewMode {
  param([object]$InputObject, [string]$Default = "control")
  $mode = ("" + (Get-Prop $InputObject "viewMode" $Default)).Trim().ToLowerInvariant()
  switch ($mode) {
      "raw" { return "raw" }
      "control" { return "control" }
      "content" { return "content" }
      default { throw "viewMode must be one of: raw, control, content." }
  }
}

function Get-DetailLevel {
  param([object]$InputObject, [string]$Default = "compact")
  $level = ("" + (Get-Prop $InputObject "detailLevel" $Default)).Trim().ToLowerInvariant()
  switch ($level) {
      "compact" { return "compact" }
      "full" { return "full" }
      default { throw "detailLevel must be one of: compact, full." }
  }
}

function Get-ViewCondition {
  param([string]$ViewMode = "control", [bool]$IncludeOffscreen = $false)
  $condition = switch ($ViewMode) {
      "raw" { [System.Windows.Automation.Automation]::RawViewCondition }
      "content" { [System.Windows.Automation.Automation]::ContentViewCondition }
      default { [System.Windows.Automation.Automation]::ControlViewCondition }
  }
  if ($null -eq $condition) {
    $condition = [System.Windows.Automation.Condition]::TrueCondition
  }
  if (-not $IncludeOffscreen) {
    $visible = New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::IsOffscreenProperty), $false
    $condition = New-Object System.Windows.Automation.AndCondition -ArgumentList $condition, $visible
  }
  return $condition
}

# ----------------------------------------------------------------------------
# Native P/Invoke surface. Compiled once to a cached DLL (keyed by a hash of
# this source) so restarted processes skip the ~hundreds-of-ms C# compile.
# ----------------------------------------------------------------------------
$script:WcuCs = @'
using System;
using System.Runtime.InteropServices;

public static class WindowsComputerUseNative {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern uint GetClipboardSequenceNumber();

  public const int MOUSEEVENTF_MOVE = 0x0001;
  public const int MOUSEEVENTF_LEFTDOWN = 0x0002;
  public const int MOUSEEVENTF_LEFTUP = 0x0004;
  public const int MOUSEEVENTF_RIGHTDOWN = 0x0008;
  public const int MOUSEEVENTF_RIGHTUP = 0x0010;
  public const int MOUSEEVENTF_MIDDLEDOWN = 0x0020;
  public const int MOUSEEVENTF_MIDDLEUP = 0x0040;
  public const int MOUSEEVENTF_WHEEL = 0x0800;
  public const int MOUSEEVENTF_HWHEEL = 0x01000;

  // SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN
  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int nIndex);

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT {
    public uint type;
    public INPUTUNION U;
  }
  [DllImport("user32.dll")]
  public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

  // Send a button or wheel event at the CURRENT pointer position. Movement is
  // done with SetCursorPos (raw screen coords, matching the UIA/screenshot
  // space), not with MOUSEEVENTF_ABSOLUTE: on multi-monitor / high-DPI setups
  // the ABSOLUTE 0..65535 normalization against SM_CXVIRTUALSCREEN silently
  // mis-maps (observed: X exactly halved), so we never position via SendInput.
  public static uint SendMouseEvent(int x, int y, uint flags, int data) {
    MOUSEINPUT mi = new MOUSEINPUT();
    mi.dx = 0; mi.dy = 0; mi.mouseData = (uint)data;
    mi.dwFlags = flags; // button/wheel only; caller positioned via SetCursorPos
    mi.time = 0; mi.dwExtraInfo = new IntPtr(0);
    INPUT[] inputs = new INPUT[1];
    inputs[0].type = 0; // INPUT_MOUSE
    inputs[0].U.mi = mi;
    return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
  }

  public const uint KEYEVENTF_UNICODE = 0x0004;

  // Synthesize the text as Unicode key events (KEYEVENTF_UNICODE). No clipboard
  // is touched, so this also works on password fields and other controls that
  // reject paste. The target control must be foreground + focused. Returns
  // false if any input event was dropped (queue full).
  public static bool SendUnicodeText(string text) {
    if (string.IsNullOrEmpty(text)) return true;
    var chars = text.ToCharArray();
    var inputs = new INPUT[chars.Length * 2];
    int n = 0;
    foreach (char ch in chars) {
      // press
      inputs[n].type = 1; // INPUT_KEYBOARD
      inputs[n].U.ki.wVk = 0;
      inputs[n].U.ki.wScan = ch;
      inputs[n].U.ki.dwFlags = KEYEVENTF_UNICODE;
      inputs[n].U.ki.time = 0;
      inputs[n].U.ki.dwExtraInfo = new IntPtr(0);
      n++;
      // release
      inputs[n].type = 1;
      inputs[n].U.ki.wVk = 0;
      inputs[n].U.ki.wScan = 0;
      inputs[n].U.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      inputs[n].U.ki.time = 0;
      inputs[n].U.ki.dwExtraInfo = new IntPtr(0);
      n++;
    }
    int sent = 0;
    int size = Marshal.SizeOf(typeof(INPUT));
    while (sent < n) {
      int chunk = Math.Min(64, n - sent);
      var slice = new INPUT[chunk];
      Array.Copy(inputs, sent, slice, 0, chunk);
      uint ok = SendInput((uint)chunk, slice, size);
      if (ok != (uint)chunk) return false;
      sent += chunk;
    }
    return true;
  }

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public uint flags; public IntPtr hwndActive,hwndFocus,hwndCapture,hwndMenuOwner,hwndMoveSize,hwndCaret; public RECT rcCaret;
  }
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
  [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);

  static bool KeyEvent(ushort vk, bool up, bool extended=false) {
    var inputs=new INPUT[1];inputs[0].type=1;inputs[0].U.ki.wVk=vk;inputs[0].U.ki.dwFlags=(up?2u:0u)|(extended?1u:0u);
    return SendInput(1,inputs,Marshal.SizeOf(typeof(INPUT)))==1;
  }
  public static bool SendKeyChord(string[] keys) {
    var mods=new System.Collections.Generic.List<ushort>();string main=null;
    foreach(var raw in keys){var k=raw.ToLowerInvariant();ushort mod=k=="ctrl"?(ushort)17:k=="shift"?(ushort)16:k=="alt"?(ushort)18:(ushort)0;if(mod!=0){if(!mods.Contains(mod))mods.Add(mod);}else{if(main!=null)throw new ArgumentException("Exactly one non-modifier key is required.");main=raw;}}
    if(main==null)throw new ArgumentException("A non-modifier key is required.");
    ushort vk=0;var name=main.ToLowerInvariant();int n;
    var special=new System.Collections.Generic.Dictionary<string,ushort>{{"backspace",8},{"tab",9},{"enter",13},{"numpadenter",13},{"escape",27},{"space",32},{"pageup",33},{"pagedown",34},{"end",35},{"home",36},{"left",37},{"up",38},{"right",39},{"down",40},{"insert",45},{"delete",46},{"numpadadd",107},{"numpadsubtract",109},{"numpadmultiply",106},{"numpaddivide",111},{"numpaddecimal",110}};
    if(special.ContainsKey(name))vk=special[name];
    else if(name.StartsWith("numpad")&&int.TryParse(name.Substring(6),out n)&&n>=0&&n<=9)vk=(ushort)(96+n);
    else if(name.StartsWith("f")&&int.TryParse(name.Substring(1),out n)&&n>=1&&n<=24)vk=(ushort)(111+n);
    else if(main.Length==1){short code=VkKeyScanW(main[0]);if(code==-1)throw new ArgumentException("Unsupported key for the current keyboard layout.");vk=(ushort)(code&255);if((code&256)!=0&&!mods.Contains(16))mods.Add(16);if((code&512)!=0&&!mods.Contains(17))mods.Add(17);if((code&1024)!=0&&!mods.Contains(18))mods.Add(18);}
    else throw new ArgumentException("Unsupported key name: "+main);
    bool extended=(vk>=33&&vk<=40)||vk==45||vk==46||vk==111||name=="numpadenter",ok=true;
    try {foreach(var mod in mods){if(!KeyEvent(mod,false))return false;}if(!KeyEvent(vk,false,extended))return false;ok=KeyEvent(vk,true,extended);}
    finally {KeyEvent(vk,true,extended);for(int i=mods.Count-1;i>=0;i--)ok=KeyEvent(mods[i],true)&&ok;}
    return ok;
  }

  [DllImport("user32.dll")]
  public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

  [DllImport("user32.dll")]
  public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);


  public delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr data);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder text, int count);
  public static IntPtr[] TopLevelWindows() {
    var result = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr hwnd, IntPtr data) { result.Add(hwnd); return true; }, IntPtr.Zero);
    return result.ToArray();
  }

  public const byte VK_MENU = 0x12;
  public const uint KEYEVENTF_KEYUP = 0x0002;

  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();

  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int left; public int top; public int right; public int bottom; }

  // DWMWA_EXTENDED_FRAME_BOUNDS = 9: the real window rect without the invisible
  // drop-shadow margin DWM adds to GetWindowRect.
  [DllImport("dwmapi.dll")]
  public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);

  // PW_RENDERFULLCONTENT = 2: asks DirectComposition-backed windows to render.
  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint nFlags);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int x; public int y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT p);

  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_NOZORDER = 0x0004;
  public const uint SWP_NOACTIVATE = 0x0010;

  // ---- background (message-queue) input path ----
  // PostMessage delivers to the target window's message queue WITHOUT touching
  // the system input queue: the user's foreground stays untouched. Classic
  // Win32/Edit controls honor these; Chromium/Electron/UWP content often drops
  // them (that is the documented 'background_unavailable' case).
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern short VkKeyScanW(char ch);

  // WM_* message ids
  public const uint WM_MOUSEMOVE = 0x0200;
  public const uint WM_LBUTTONDOWN = 0x0201;
  public const uint WM_LBUTTONUP = 0x0202;
  public const uint WM_LBUTTONDBLCLK = 0x0203;
  public const uint WM_RBUTTONDOWN = 0x0204;
  public const uint WM_RBUTTONUP = 0x0205;
  public const uint WM_MBUTTONDOWN = 0x0207;
  public const uint WM_MBUTTONUP = 0x0208;
  public const uint WM_CHAR = 0x0102;
  public const uint WM_KEYDOWN = 0x0100;
  public const uint WM_KEYUP = 0x0101;
  public const uint WM_CLOSE = 0x0010;
  // MK_* mouse key state words (wParam for mouse messages)
  public const int MK_LBUTTON = 0x0001;
  public const int MK_RBUTTON = 0x0002;
  public const int MK_MBUTTON = 0x0010;

  // Pack client-area x/y into the LPARAM for mouse messages.
  public static IntPtr MakeLParam(int x, int y) {
    return new IntPtr((y & 0xFFFF) << 16 | (x & 0xFFFF));
  }
}
'@

function Get-CsHash {
  param([string]$Source)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Source))
  return ([BitConverter]::ToString($bytes).Replace("-", "").Substring(0, 16)).ToLowerInvariant()
}

function Load-Assemblies {
  # DPI awareness MUST be set before any GDI+/WinForms assembly is loaded:
  # loading System.Windows.Forms/System.Drawing initializes GDI, which locks
  # the process DPI context (and GetSystemMetrics then returns virtualized
  # 150%-scaled values like 3414x960 instead of physical 5120x1440).
  if (-not ("WindowsComputerUseNative" -as [type])) {
    $dll = Join-Path $env:TEMP ("wcu-native-" + (Get-CsHash -Source $script:WcuCs) + ".dll")
    if (-not (Test-Path $dll)) {
      Add-Type -TypeDefinition $script:WcuCs -OutputAssembly $dll
    }
    [void][System.Reflection.Assembly]::LoadFrom($dll)
  }
  Set-DpiAware

  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  # Standard Win32 controls need the client-side providers. Without these,
  # controls can silently appear as unnamed Pane nodes with no Value pattern.
  Add-Type -AssemblyName UIAutomationClientsideProviders
  # Register the exported table directly: .NET 10 assembly-name casing breaks proxy type lookup.
  $providers = [UIAutomationClientsideProviders.UIAutomationClientSideProviders]::ClientSideProviderDescriptionTable
  try {
    [System.Windows.Automation.ClientSettings]::RegisterClientSideProviders($providers)
  } catch {
    # .NET Framework's first registration can initialize its proxy table and
    # throw NullReferenceException. A single second registration completes it.
    if ($_.Exception.InnerException -isnot [NullReferenceException]) { throw }
    [System.Windows.Automation.ClientSettings]::RegisterClientSideProviders($providers)
  }
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
}

function Set-DpiAware {
  # Per-Monitor V2 (context value -4); fall back to system-aware. Must run
  # before any screen/UIA work so coordinates and pixels are physical.
  $ok = Invoke-Safe { [WindowsComputerUseNative]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } $false
  if (-not $ok) {
    [void][WindowsComputerUseNative]::SetProcessDPIAware()
  }
}

function Invoke-Safe {
  param([scriptblock]$Block, [object]$Default = $null)
  try {
    return & $Block
  } catch {
    return $Default
  }
}

function Get-ControlTypeName {
  param([object]$ControlType)
  if ($null -eq $ControlType) { return $null }
  $name = Invoke-Safe { $ControlType.ProgrammaticName } $null
  if ($null -eq $name) { return $null }
  return ($name -replace "^ControlType\.", "")
}

function Convert-Rect {
  param([object]$Rect)
  if ($null -eq $Rect) { return $null }
  $empty = Invoke-Safe { $Rect.IsEmpty } $true
  if ($empty) { return $null }
  $x = [int][Math]::Round($Rect.X)
  $y = [int][Math]::Round($Rect.Y)
  $width = [int][Math]::Round($Rect.Width)
  $height = [int][Math]::Round($Rect.Height)
  return [ordered]@{
    x = $x
    y = $y
    width = $width
    height = $height
    centerX = [int]($x + ($width / 2))
    centerY = [int]($y + ($height / 2))
  }
}

function Get-Patterns {
  param([System.Windows.Automation.AutomationElement]$Element)
  $items = New-Object System.Collections.Generic.List[string]
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern) } $false) { $items.Add("Invoke") }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) } $false) { $items.Add("Value") }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern) } $false) { $items.Add("Toggle") }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern) } $false) { $items.Add("SelectionItem") }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern) } $false) { $items.Add("ExpandCollapse") }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$pattern) } $false) { $items.Add("ScrollItem") }
  foreach ($entry in @(@('Scroll',[System.Windows.Automation.ScrollPattern]::Pattern),@('Text',[System.Windows.Automation.TextPattern]::Pattern),@('Selection',[System.Windows.Automation.SelectionPattern]::Pattern))) {
    $pattern=$null
    if (Invoke-Safe { $Element.TryGetCurrentPattern($entry[1],[ref]$pattern) } $false) { $items.Add([string]$entry[0]) }
  }
  return ,([string[]]$items.ToArray())
}

function Get-ValueText {
  param([System.Windows.Automation.AutomationElement]$Element)
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) } $false) {
    return Invoke-Safe { $pattern.Current.Value } $null
  }
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern) } $false) {
    return Invoke-Safe { $pattern.DocumentRange.GetText(65536) } $null
  }
  return $null
}

function Convert-ElementInfo {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [string]$Id = $null,
    [int]$Depth = 0,
    [string]$DetailLevel = "full"
  )

  $rect = Convert-Rect (Invoke-Safe { $Element.Current.BoundingRectangle } $null)
  $processId = Invoke-Safe { $Element.Current.ProcessId } $null
  $nativeHwnd = Invoke-Safe { $Element.Current.NativeWindowHandle } $null
  # RuntimeId is stable for the life of the owning process (survives UI
  # re-layouts that shift tree paths), so prefer a runtimeId-based id.
  $rtArr = Invoke-Safe { @($Element.GetRuntimeId()) } $null
  $rtStr = $null
  if ($null -ne $rtArr -and $rtArr.Count -ge 2) { $rtStr = ($rtArr | ForEach-Object { [int]$_ }) -join "-" }
  $info = [ordered]@{
    id = if ($null -ne $rtStr) { "uia:rt:$rtStr" } else { $Id }
    depth = $Depth
    name = Invoke-Safe { $Element.Current.Name } ""
    automationId = Invoke-Safe { $Element.Current.AutomationId } ""
    className = Invoke-Safe { $Element.Current.ClassName } ""
    controlType = Get-ControlTypeName (Invoke-Safe { $Element.Current.ControlType } $null)
    boundingBox = $rect
    isEnabled = Invoke-Safe { $Element.Current.IsEnabled } $null
    isOffscreen = Invoke-Safe { $Element.Current.IsOffscreen } $null
    hasKeyboardFocus = Invoke-Safe { $Element.Current.HasKeyboardFocus } $null
    isPassword = Invoke-Safe { $Element.Current.IsPassword } $false
  }
  if ($DetailLevel -eq "full") {
    $value = if ($info.isPassword) { $null } else { Get-ValueText $Element }
    $patterns = [string[]](Get-Patterns $Element)
    $info["localizedControlType"] = Invoke-Safe { $Element.Current.LocalizedControlType } ""
    $info["processId"] = $processId
    $info["nativeWindowHandle"] = $nativeHwnd
    $info["runtimeId"] = if ($null -ne $rtStr) { $rtStr } else { $null }
    $info["value"] = $value
    $info["patterns"] = $patterns
    $valuePattern=$null
    if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$valuePattern) } $false) { $info['isReadOnly']=$valuePattern.Current.IsReadOnly }
    $selectionItem=$null
    if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selectionItem) } $false) { $info['isSelected']=$selectionItem.Current.IsSelected }
  } else {
    if ($Depth -le 1 -and $null -ne $processId) { $info["processId"] = $processId }
    if ($null -ne $nativeHwnd -and [int64]$nativeHwnd -ne 0) { $info["nativeWindowHandle"] = $nativeHwnd }
  }
  return $info
}

# ============================================================================
# Window targeting
# ============================================================================

function Has-WindowTarget {
  param([object]$InputObject)
  if ($null -eq $InputObject) { return $false }
  $title = [string](Get-Prop $InputObject "windowTitle" "")
  $processId = Get-Prop $InputObject "processId" $null
  $hwnd = Get-Prop $InputObject "nativeWindowHandle" $null
  return (-not [string]::IsNullOrWhiteSpace($title)) -or ($null -ne $processId) -or ($null -ne $hwnd)
}

function Test-TargetMatch {
  param([object]$Info, [object]$InputObject)
  $title = [string](Get-Prop $InputObject "windowTitle" "")
  $processId = Get-Prop $InputObject "processId" $null
  $hwnd = Get-Prop $InputObject "nativeWindowHandle" $null

  if (-not [string]::IsNullOrWhiteSpace($title)) {
    $name = "" + $Info.name
    if ($name.IndexOf($title, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
  }
  if ($null -ne $processId -and [int]$Info.processId -ne [int]$processId) { return $false }
  if ($null -ne $hwnd -and [int64]$Info.nativeWindowHandle -ne [int64]$hwnd) { return $false }
  return $true
}

function Set-WindowForeground {
  param([System.Windows.Automation.AutomationElement]$Element)
  $hwnd = Invoke-Safe { $Element.Current.NativeWindowHandle } 0
  if (-not ($hwnd -and $hwnd -ne 0)) { return $false }
  $ptr = [IntPtr]([int64]$hwnd)
  if ([WindowsComputerUseNative]::GetForegroundWindow() -eq $ptr) { return $true }

  # Beat the Windows foreground lock: a background process is normally
  # silently refused by SetForegroundWindow. Attaching our input thread to
  # the current foreground window's thread and tapping the Alt key releases
  # the lock long enough to switch (classic AutoHotkey trick).
  $fgPtr = [WindowsComputerUseNative]::GetForegroundWindow()
  $fgOwner = [uint32]0
  $tgtOwner = [uint32]0
  $fgThread = [WindowsComputerUseNative]::GetWindowThreadProcessId($fgPtr, [ref]$fgOwner)
  $tgtThread = [WindowsComputerUseNative]::GetWindowThreadProcessId($ptr, [ref]$tgtOwner)
  $callerThread = [WindowsComputerUseNative]::GetCurrentThreadId()
  $attached = $false
  $targetAttached = $false
  if ($fgThread -ne $callerThread -and $fgThread -ne 0) {
    $attached = [WindowsComputerUseNative]::AttachThreadInput($callerThread, $fgThread, $true)
  }
  if ($tgtThread -ne $callerThread -and $tgtThread -ne $fgThread) {
    $targetAttached = [WindowsComputerUseNative]::AttachThreadInput($callerThread, $tgtThread, $true)
  }
  try {
    [void][WindowsComputerUseNative]::keybd_event([WindowsComputerUseNative]::VK_MENU, 0, 0, [UIntPtr]::Zero)
    [void][WindowsComputerUseNative]::keybd_event([WindowsComputerUseNative]::VK_MENU, 0, [WindowsComputerUseNative]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    # SW_RESTORE is not a no-op on maximized/snapped windows — it un-maximizes
    # them. Only restore windows that are actually minimized; otherwise leave
    # the window state untouched.
    if ([WindowsComputerUseNative]::IsIconic($ptr)) {
      [WindowsComputerUseNative]::ShowWindow($ptr, 9) | Out-Null
      Start-Sleep -Milliseconds 80
    }
    [WindowsComputerUseNative]::SetForegroundWindow($ptr) | Out-Null
    Start-Sleep -Milliseconds 120
  } finally {
    if ($targetAttached) { [void][WindowsComputerUseNative]::AttachThreadInput($callerThread, $tgtThread, $false) }
    if ($attached) { [void][WindowsComputerUseNative]::AttachThreadInput($callerThread, $fgThread, $false) }
  }

  # Verify the switch actually happened; report it so callers can react.
  $nowFg = [WindowsComputerUseNative]::GetForegroundWindow()
  return ($nowFg -eq $ptr)
}

function Activate-TargetIfRequested {
  param([object]$InputObject)
  if ((Has-WindowTarget $InputObject) -and [bool](Get-Prop $InputObject "activate" $false)) {
    $target = Resolve-TargetWindow $InputObject
    $ok = Set-WindowForeground $target
    if (-not $ok) {
      $title = [string](Get-Prop $InputObject "windowTitle" "")
      $targetHandle=$target.Current.NativeWindowHandle
      $foregroundHandle=[WindowsComputerUseNative]::GetForegroundWindow().ToInt64()
      throw "ACTIVATION_REJECTED: Failed to bring the target window ('$title', HWND=$targetHandle, foreground=$foregroundHandle) to the foreground. Input was NOT sent. Reobserve before another action."
    }
  }
}

function Assert-TargetIsForeground {
  # Fail-closed guard for input actions: if a specific window was requested,
  # make sure it is ACTUALLY the foreground window before we let keystrokes
  # or clicks out. Otherwise a silent background activation would have typed
  # into the wrong (possibly the user's) window.
  param([object]$InputObject)
  if (-not (Has-WindowTarget $InputObject)) { return }
  $target = Resolve-TargetWindow $InputObject
  $hwnd = Invoke-Safe { $target.Current.NativeWindowHandle } 0
  $fg = [WindowsComputerUseNative]::GetForegroundWindow()
  if (-not ($hwnd -and $hwnd -ne 0) -or ($fg -ne [IntPtr]([int64]$hwnd))) {
    $title = [string](Get-Prop $InputObject "windowTitle" "")
    throw "Target window ('$title') is not the foreground window, so no input was sent. Re-run with activate: true, or call activate_window first."
  }
}

function Get-BestTextControl {
  # Pick the most likely text-input control inside a window: the largest
  # (by bounding-box area) enabled Edit or Document control.
  param([System.Windows.Automation.AutomationElement]$Window)
  $cands = New-Object System.Collections.Generic.List[object]
  try {
    $cond1 = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Edit)
    $cond2 = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Document)
    $orCond = New-Object System.Windows.Automation.OrCondition ($cond1, $cond2)
    $enabledCond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::IsEnabledProperty), $true
    $cond = New-Object System.Windows.Automation.AndCondition ($orCond, $enabledCond)
    $coll = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    for ($i = 0; $i -lt $coll.Count; $i++) {
      $el = $coll.Item($i)
      $rect = Convert-Rect (Invoke-Safe { $el.Current.BoundingRectangle } $null)
      $area = 0
      if ($null -ne $rect) { $area = [int64]$rect.width * [int64]$rect.height }
      $cands.Add([pscustomobject]@{ el = $el; area = $area })
    }
  } catch {
    return $null
  }
  if ($cands.Count -eq 0) { return $null }
  return ($cands | Sort-Object area -Descending | Select-Object -First 1).el
}

function Focus-TextControl {
  # Set keyboard focus on the window's main text control. Returns the
  # control type name when focus was set, else $null.
  param([System.Windows.Automation.AutomationElement]$Window)
  $el = Get-BestTextControl $Window
  if ($null -eq $el) { return $null }
  $ok = Invoke-Safe { $el.SetFocus(); $true } $false
  if (-not $ok) { return $null }
  Start-Sleep -Milliseconds 80
  $focused = Invoke-Safe { [bool]$el.Current.HasKeyboardFocus } $false
  if (-not $focused) { return $null }
  return (Get-ControlTypeName (Invoke-Safe { $el.Current.ControlType } $null))
}

# ============================================================================
# Homing: remember window rects when observed, compensate coordinates when
# the window moved between observation and action (desktop-touch-mcp Tier 1).
# ============================================================================

$script:WindowCache = @{}   # hwnd -> @{ x=..; y=..; ts=.. }
$script:OcrAwait = $null    # WinRT AsTask helper (filled lazily by Get-OcrEngine)

function Get-FreshWindowRect {
  param([System.Windows.Automation.AutomationElement]$Element)
  return Convert-Rect (Invoke-Safe { $Element.Current.BoundingRectangle } $null)
}

function Update-WindowCache {
  param([System.Windows.Automation.AutomationElement]$Element)
  $hwnd = Invoke-Safe { [int64]$Element.Current.NativeWindowHandle } 0
  if (-not ($hwnd -and $hwnd -ne 0)) { return }
  $rect = Get-FreshWindowRect $Element
  if ($null -eq $rect) { return }
  $script:WindowCache[[string]$hwnd] = @{ x = $rect.x; y = $rect.y; ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
}

function Home-Point {
  # If the target window was observed before and has since moved, shift the
  # given screen point by (dx, dy). Returns @{ x=..; y=..; homed=$null or @{dx=..;dy=..} }.
  param([int]$X, [int]$Y, [System.Windows.Automation.AutomationElement]$Target)
  $result = [ordered]@{ x = $X; y = $Y; homed = $null }
  $hwnd = Invoke-Safe { [int64]$Target.Current.NativeWindowHandle } 0
  if (-not ($hwnd -and $hwnd -ne 0)) { return $result }
  $key = [string]$hwnd
  $cached = $script:WindowCache[$key]
  if ($null -eq $cached) { return $result }
  $now = Get-FreshWindowRect $Target
  if ($null -eq $now) { return $result }
  $dx = 0 # coordinates already mapped against current bound window
  $dy = 0
  if ($dx -ne 0 -or $dy -ne 0) {
    $result.x = $X + $dx
    $result.y = $Y + $dy
    $result.homed = [ordered]@{ dx = $dx; dy = $dy }
  }
  return $result
}

# ----------------------------------------------------------------------------
# Window identity guard: when the caller targets a window BY TITLE, remember
# which HWND/PID that title referred to at observation time. If the title now
# resolves to a different HWND/PID (app restarted, window recreated), acting
# on the new window with stale coordinates/focus would be a silent miss or —
# worse — a hit on the wrong app. Fail closed with an identity_changed error.
# ----------------------------------------------------------------------------
$script:WindowIdentity = @{}   # lowercased title -> @{ hwnd=; pid=; ts= }

function Update-WindowIdentity {
  param([object]$InputObject, [System.Windows.Automation.AutomationElement]$Target)
  $title = [string](Get-Prop $InputObject "windowTitle" "")
  if ([string]::IsNullOrWhiteSpace($title) -or $null -eq $Target) { return }
  $hwnd = Invoke-Safe { [int64]$Target.Current.NativeWindowHandle } 0
  $procId = Invoke-Safe { [int]$Target.Current.ProcessId } 0
  $script:WindowIdentity[$title.Trim().ToLowerInvariant()] = @{ hwnd = $hwnd; pid = $procId; ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
}

function Assert-WindowIdentity {
  param([object]$InputObject, [System.Windows.Automation.AutomationElement]$Target)
  $title = [string](Get-Prop $InputObject "windowTitle" "")
  if ([string]::IsNullOrWhiteSpace($title) -or $null -eq $Target) { return }
  $key = $title.Trim().ToLowerInvariant()
  $hwnd = Invoke-Safe { [int64]$Target.Current.NativeWindowHandle } 0
  $procId = Invoke-Safe { [int]$Target.Current.ProcessId } 0
  $cached = $script:WindowIdentity[$key]
  if ($null -eq $cached) {
    # First sighting of this title: baseline it, no check.
    $script:WindowIdentity[$key] = @{ hwnd = $hwnd; pid = $procId; ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
    return
  }
  $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  if (($now - [int64]$cached.ts) -gt 300000) {
    # Stale baseline (older than 5 min): silently re-baseline rather than
    # failing on a long-ago observation.
    $script:WindowIdentity[$key] = @{ hwnd = $hwnd; pid = $procId; ts = $now }
    return
  }
  if ($hwnd -ne [int64]$cached.hwnd -or $procId -ne [int]$cached.pid) {
    throw "identity_changed: the window titled '$title' is a different window than when last observed (HWND $([int64]$cached.hwnd) -> $hwnd, PID $([int]$cached.pid) -> $procId). The app may have restarted or the window was recreated. Re-observe with snapshot before acting."
  }
  $script:WindowIdentity[$key] = @{ hwnd = $hwnd; pid = $procId; ts = $now }
}

# ============================================================================
# Emergency-stop failsafe: parking the physical cursor in the top-left corner
# of the virtual screen for ~500ms refuses further input actions (the user's
# panic brake). Config: WCU_FAILSAFE=0 disables; WCU_FAILSAFE_CORNER="x,y"
# moves the corner; WCU_FAILSAFE_RADIUS (default 12) and WCU_FAILSAFE_HOLD_MS
# (default 500) tune it.
# ============================================================================

$script:FailsafeFirstSeen = 0

function Test-Failsafe {
  # Returns $true when an input action is ALLOWED. Throws when the failsafe
  # is engaged (cursor parked in the corner beyond the hold time).
  if ([string]$env:WCU_FAILSAFE -eq '0') { return $true }
  $radius = 12
  if ("$env:WCU_FAILSAFE_RADIUS" -match '^\d+$') { $radius = [int]$env:WCU_FAILSAFE_RADIUS }
  $holdMs = 500
  if ("$env:WCU_FAILSAFE_HOLD_MS" -match '^\d+$') { $holdMs = [int]$env:WCU_FAILSAFE_HOLD_MS }

  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $cx = $vs.Left
  $cy = $vs.Top
  if ("$env:WCU_FAILSAFE_CORNER" -match '^(-?\d+)\s*,\s*(-?\d+)$') { $cx = [int]$Matches[1]; $cy = [int]$Matches[2] }

  $p = New-Object WindowsComputerUseNative+POINT
  [void][WindowsComputerUseNative]::GetCursorPos([ref]$p)
  $inCorner = [Math]::Abs($p.x - $cx) -le $radius -and [Math]::Abs($p.y - $cy) -le $radius
  if (-not $inCorner) { $script:FailsafeFirstSeen = 0; return $true }
  $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  if ($script:FailsafeFirstSeen -eq 0) { $script:FailsafeFirstSeen = $now; return $true }
  if (($now - $script:FailsafeFirstSeen) -ge $holdMs) {
    throw "EMERGENCY STOP: the mouse is parked in the failsafe corner ($cx,$cy) and input is refused. Move the mouse away to resume."
  }
  return $true
}

# ============================================================================
# Background (PostMessage) input: no system input queue, no foreground steal.
# ============================================================================

function Resolve-TargetHwnd {
  param([object]$InputObject)
  $hwnd = Get-Prop $InputObject "nativeWindowHandle" $null
  if ($null -ne $hwnd) { return [int64]$hwnd }
  $target = Resolve-TargetWindow $InputObject
  return Invoke-Safe { [int64]$target.Current.NativeWindowHandle } 0
}

function Post-BackgroundClick {
  # Post a button press/release at screen coords into the target window's
  # message queue (converted to client coords). Returns $true when the
  # messages were queued. The app may still ignore them (Chromium/Electron/
  # UWP) — callers must label the result as unverified.
  param([long]$Hwnd, [int]$X, [int]$Y, [string]$Button, [int]$Count)
  $ptr = [IntPtr]$Hwnd
  $pt = New-Object WindowsComputerUseNative+POINT
  $pt.x = $X
  $pt.y = $Y
  if (-not [WindowsComputerUseNative]::ScreenToClient($ptr, [ref]$pt)) { return $false }
  $dbl = [uint32]0
  switch ($Button) {
      "right" { $down = [WindowsComputerUseNative]::WM_RBUTTONDOWN; $up = [WindowsComputerUseNative]::WM_RBUTTONUP; $mk = [WindowsComputerUseNative]::MK_RBUTTON }
      "middle" { $down = [WindowsComputerUseNative]::WM_MBUTTONDOWN; $up = [WindowsComputerUseNative]::WM_MBUTTONUP; $mk = [WindowsComputerUseNative]::MK_MBUTTON }
      default {
        $down = [WindowsComputerUseNative]::WM_LBUTTONDOWN
        $up = [WindowsComputerUseNative]::WM_LBUTTONUP
        $mk = [WindowsComputerUseNative]::MK_LBUTTON
        $dbl = [WindowsComputerUseNative]::WM_LBUTTONDBLCLK
      }
  }
  $lp = [WindowsComputerUseNative]::MakeLParam($pt.x, $pt.y)
  $ok = [WindowsComputerUseNative]::PostMessageW($ptr, $down, [IntPtr]$mk, $lp)
  Start-Sleep -Milliseconds 30
  $ok = [WindowsComputerUseNative]::PostMessageW($ptr, $up, [IntPtr]0, $lp) -and $ok
  if ($Count -ge 2 -and $dbl -ne 0) {
    # A real double-click: the double-click message carries the click, so a
    # second up completes it.
    Start-Sleep -Milliseconds 30
    $ok = [WindowsComputerUseNative]::PostMessageW($ptr, $dbl, [IntPtr]$mk, $lp) -and $ok
    Start-Sleep -Milliseconds 30
    $ok = [WindowsComputerUseNative]::PostMessageW($ptr, $up, [IntPtr]0, $lp) -and $ok
  }
  Start-Sleep -Milliseconds 40
  return $ok
}

function Post-BackgroundText {
  # Post WM_CHAR per UTF-16 code unit into the target window. No clipboard,
  # no foreground, no system input queue. Works on controls that accept char
  # input (Edit, RichEdit, most Win32 dialogs).
  param([long]$Hwnd, [string]$Text)
  $ptr = [IntPtr]$Hwnd
  $allOk = $true
  foreach ($ch in $Text.ToCharArray()) {
    $ok = [WindowsComputerUseNative]::PostMessageW($ptr, [WindowsComputerUseNative]::WM_CHAR, [IntPtr][int][char]$ch, [IntPtr]1)
    if (-not $ok) { $allOk = $false }
    Start-Sleep -Milliseconds 5
  }
  return $allOk
}

# ============================================================================
# OCR (Windows.Media.Ocr via a compiled C# WinRT helper): the fallback for
# UIA-blind apps (games, self-drawn Tk/Qt, RDP, canvases). Word boxes come
# back in the image's pixel coords; the caller maps them to screen coords.
#
# PowerShell 5.1 cannot resolve WinRT type literals reliably on recent
# builds, so the WinRT calls live in a small C# helper compiled against
# Windows.winmd and cached in TEMP (same pattern as the main native DLL).
# ============================================================================

$script:WcuOcrCs = @'
using System;
using System.Text;
using System.Threading.Tasks;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Graphics.Imaging;
using Windows.Foundation;

public static class WindowsComputerUseOcr {
  private static T WaitOp<T>(IAsyncOperation<T> op) {
    var tcs = new TaskCompletionSource<T>();
    op.Completed = (o, s) => {
      try {
        if (s == AsyncStatus.Completed) tcs.SetResult(o.GetResults());
        else if (s == AsyncStatus.Canceled) tcs.SetCanceled();
        else tcs.SetException(new Exception("OCR async operation failed (status: " + s + ")."));
      } catch (Exception ex) { tcs.TrySetException(ex); }
    };
    return tcs.Task.GetAwaiter().GetResult();
  }

  // Returns tab-separated lines:
  //   LANG\t<language tag>
  //   TEXT\t<full text, newlines as \n>
  //   LINE\t<line text>\t<word>@x,y,w,h;<word>@x,y,w,h;...
  public static string Recognize(string pngPath) {
    try {
      StorageFile file = WaitOp(StorageFile.GetFileFromPathAsync(pngPath));
      var stream = WaitOp(file.OpenAsync(FileAccessMode.Read));
      var decoder = WaitOp(BitmapDecoder.CreateAsync(stream));
      var bitmap = WaitOp(decoder.GetSoftwareBitmapAsync());
      OcrEngine engine = OcrEngine.TryCreateFromUserProfileLanguages();
      if (engine == null) throw new Exception("No OCR engine available (no OCR language installed for this system).");
      OcrResult result = WaitOp(engine.RecognizeAsync(bitmap));
      var sb = new StringBuilder();
      sb.Append("TEXT\t").AppendLine(result.Text.Replace("\r", "").Replace("\n", "\\n"));
      foreach (OcrLine line in result.Lines) {
        var ws = new StringBuilder();
        foreach (OcrWord word in line.Words) {
          var r = word.BoundingRect;
          ws.Append(word.Text.Replace("\t", " ")).Append('@')
            .Append((int)Math.Round(r.Left)).Append(',')
            .Append((int)Math.Round(r.Top)).Append(',')
            .Append((int)Math.Round(r.Width)).Append(',')
            .Append((int)Math.Round(r.Height)).Append(';');
        }
        sb.Append("LINE\t").Append(line.Text.Replace("\r", "").Replace("\n", "\\n")).Append('\t').AppendLine(ws.ToString());
      }
      return sb.ToString();
    } catch (Exception ex) {
      throw new Exception("OCR failed: " + ex.Message, ex);
    }
  }
}
'@

function Get-OcrHelper {
  # Compile (once, cached) and load the C# WinRT OCR helper.
  if ("WindowsComputerUseOcr" -as [type]) { return }
  $dll = Join-Path $env:TEMP ("wcu-ocr-" + (Get-CsHash -Source $script:WcuOcrCs) + ".dll")
  if (-not (Test-Path $dll)) {
    $wd = "C:\Windows\System32\WinMetadata"
    # Only the winmds the C# code touches (plus the framework facades csc
    # needs for WinRT binding). Keeping the set small also keeps the command
    # line short.
    $need = @("Windows.Media.winmd", "Windows.Storage.winmd", "Windows.Graphics.winmd", "Windows.Foundation.winmd")
    $winmdRefs = @()
    foreach ($n in $need) {
      $p = Join-Path $wd $n
      if (-not (Test-Path $p)) {
        throw "OCR unavailable: $n not found in $wd (requires Windows 10+)."
      }
      $winmdRefs += $p
    }
    # Add-Type pre-validates references with Assembly.Load, which cannot load
    # winmd files — so invoke csc.exe directly.
    $fw = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319"
    if (-not (Test-Path $fw)) { $fw = "C:\Windows\Microsoft.NET\Framework\v4.0.30319" }
    $csc = Join-Path $fw "csc.exe"
    if (-not (Test-Path $csc)) { throw "OCR unavailable: csc.exe not found at $fw." }
    $src = "$dll.cs"
    [System.IO.File]::WriteAllText($src, $script:WcuOcrCs)
    # Each /r must be its own argument (PowerShell would otherwise hand the
    # whole joined string to csc as one file name).
    $refArgs = ($winmdRefs + @((Join-Path $fw "System.Runtime.dll"), (Join-Path $fw "System.dll"), (Join-Path $fw "System.Runtime.WindowsRuntime.dll"))) | ForEach-Object { "/r:$_" }
    $cscArgList = @("/nologo", "/target:library", "/out:$dll") + $refArgs + @($src)
    $out = & $csc @cscArgList 2>&1
    if ($LASTEXITCODE -ne 0) {
      $msg = (($out | Out-String).Trim())
      throw "OCR helper compile failed: " + $msg.Substring(0, [Math]::Min(300, $msg.Length))
    }
  }
  [void][System.Reflection.Assembly]::LoadFrom($dll)
}

function Invoke-Ocr {
  # OCR a PNG file; word boxes come back in the image's pixel coordinates.
  param([string]$PngPath)
  Get-OcrHelper
  $raw = [WindowsComputerUseOcr]::Recognize($PngPath)
  $linesOut = @()
  $fullText = ""
  $lang = ""
  foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^LANG\t(.*)$') { $lang = $Matches[1]; continue }
    if ($line -match '^TEXT\t(.*)$') { $fullText = $Matches[1]; continue }
    if ($line -match '^LINE\t(.*)\t(.*)$') {
      $lineText = $Matches[1]
      $words = @()
      foreach ($w in ($Matches[2] -split ';')) {
        if ($w -eq '') { continue }
        $at = $w.LastIndexOf('@')
        if ($at -lt 0) { continue }
        $wtext = $w.Substring(0, $at)
        $coords = $w.Substring($at + 1) -split ','
        if ($coords.Count -lt 4) { continue }
        $words += [ordered]@{ text = $wtext; x = [int]$coords[0]; y = [int]$coords[1]; width = [int]$coords[2]; height = [int]$coords[3] }
      }
      $linesOut += [ordered]@{ text = $lineText; words = $words }
    }
  }
  return [ordered]@{ text = $fullText.Replace("\\n", "`n"); lines = $linesOut; language = $lang }
}

# ============================================================================
# WGC window capture (Windows.Graphics.Capture): the fallback for surfaces
# that PrintWindow renders pitch black (UWP / WinUI / DirectComposition).
# Compiled to a cached DLL like the OCR helper; runs a short-lived STA pump
# thread to receive the WinRT FrameArrived event, grabs one frame, saves a PNG.
# ============================================================================
$script:WgcCs = @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
using Windows.Foundation;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;

public static class WgcCapture {
  const uint QS_ALLINPUT = 0x04FF;
  const uint WM_DESTROY = 0x0002;

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WNDCLASSEX {
    public uint cbSize; public uint style; public IntPtr lpfnWndProc;
    public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
    public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
    public String lpszMenuName; public String lpszClassName; public IntPtr hIconSm;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

  [DllImport("user32.dll")] static extern bool RegisterClassEx(ref WNDCLASSEX wc);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr hInst, IntPtr param);
  [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] static extern int MsgWaitForMultipleObjects(int count, WaitHandle[] handles, bool wake, uint ms, uint flags);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
  [DllImport("user32.dll")] static extern void PostQuitMessage(int code);

  delegate IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  static IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return IntPtr.Zero; }
    return DefWindowProc(hwnd, msg, wParam, lParam);
  }

  // Capture one frame of the window to a PNG. Returns the PNG path on success,
  // null on timeout / no frame, throws on setup failure.
  public static string CaptureWindow(uint hwnd, int width, int height, string outPng, int timeoutMs) {
    ManualResetEvent done = new ManualResetEvent(false);
    Exception[] error = new Exception[1];
    bool[] got = new bool[1];

    Thread pump = new Thread(delegate () {
      try {
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = new WindowProc(WndProc);
        wc.lpszClassName = "WgcCapturePump" + Guid.NewGuid().ToString("N");
        RegisterClassEx(ref wc);
        CreateWindowEx(0, wc.lpszClassName, "wgc", 0, -32000, -32000, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        GraphicsCaptureItem item = GraphicsCaptureItem.CreateFromWindowId(hwnd);
        SizeInt32 size;
        item.TryGetClosestSize((uint)width, out size);

        IDirect3DDevice device = null;
        Direct3D11FeatureLevel fl;
        Direct3D11CreateDevice(IntPtr.Zero, Direct3D11DriverType.Hardware, null, out device, out fl);

        GraphicsCaptureSession session = GraphicsCaptureSession.CreateAsync(item).GetAwaiter().GetResult();
        Direct3D11CaptureFramePool pool = Direct3D11CaptureFramePool.Create(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
        session.IsBorderRequired = false;
        try { session.IsCursorCaptureEnabled = true; } catch { }
        session.StartCapture(pool);

        pool.FrameArrived += delegate (Direct3D11CaptureFramePool sender, object args) {
          Direct3D11CaptureFrame frame = null;
          pool.TryGetNextFrame(out frame);
          try {
            if (frame != null) {
              IDirect3DSurface surface = frame.Surface;
              SoftwareBitmap bitmap = surface.AsSoftwareBitmap();
              int w = (int)bitmap.PixelWidth;
              int h = (int)bitmap.PixelHeight;
              int len = w * h * 4;
              PixelDataProvider provider = new PixelDataProvider();
              IntPtr head;
              bitmap.GetPixelData((uint)len, provider, out head);
              byte[] data = new byte[len];
              Marshal.Copy(head, data, 0, len);
              Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
              BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
              Marshal.Copy(data, 0, bd.Scan0, len);
              bmp.UnlockBits(bd);
              bmp.Save(outPng, ImageFormat.Png);
              got[0] = true;
            }
          } catch (Exception ex) {
            error[0] = ex;
          } finally {
            done.Set();
            PostQuitMessage(got[0] ? 0 : 1);
          }
        };

        // Pump until the frame event or the timeout.
        bool finished = false;
        while (!finished) {
          int wait = MsgWaitForMultipleObjects(1, new WaitHandle[] { done }, false, 400, QS_ALLINPUT);
          if (wait == 0) { finished = true; break; }          // frame event
          if (wait == 0x102) { finished = true; break; }        // timeout slice
          MSG msg;
          while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        }
        try { session.Dispose(); pool.Dispose(); device.Dispose(); } catch { }
      } catch (Exception ex) {
        error[0] = ex;
        done.Set();
      }
    });
    pump.IsBackground = true;
    pump.SetApartmentState(ApartmentState.STA);
    pump.Start();

    if (!done.WaitOne(timeoutMs)) {
      return null; // timeout: no frame arrived
    }
    if (error[0] != null) throw new Exception("WGC capture failed: " + error[0].Message, error[0]);
    return got[0] ? outPng : null;
  }
}
'@

function Get-WgcHelper {
  if ("WgcCapture" -as [type]) { return }
  if ($script:WgcCompileFailed) { throw "WGC helper previously failed to compile (missing .NET Core reference pack); WGC capture is disabled on this machine." }
  $dll = Join-Path $env:TEMP ("wcu-wgc-" + (Get-CsHash -Source $script:WgcCs) + ".dll")
  if (-not (Test-Path $dll)) {
    $wd = "C:\Windows\System32\WinMetadata"
    # Reference whichever graphics winmds exist: older Windows ships separate
    # Windows.Graphics.{DirectX,Direct3D11,Imaging,Capture}.winmd; Windows 11
    # 24H2+ consolidates them into Windows.Graphics.winmd.
    $cands = @("Windows.Graphics.Capture.winmd","Windows.Graphics.DirectX.Direct3D11.winmd","Windows.Graphics.DirectX.winmd","Windows.Graphics.Imaging.winmd","Windows.Graphics.winmd","Windows.Foundation.winmd")
    $need = @()
    foreach ($c in $cands) { if (Test-Path (Join-Path $wd $c)) { $need += (Join-Path $wd $c) } }
    if ($need.Count -lt 2) { throw "WGC unavailable: not enough WinRT graphics winmd found in $wd (requires Windows 10 1903+)." }
    $fw = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319"
    $csc = Join-Path $fw "csc.exe"
    if (-not (Test-Path $csc)) { throw "WGC unavailable: csc.exe not found." }
    $src = "$dll.cs"
    [System.IO.File]::WriteAllText($src, $script:WgcCs)
    $refArgs = $need | ForEach-Object { "/r:" + $_ }
    $refArgs += @("/r:System.dll", "/r:System.Drawing.dll", "/r:System.Runtime.WindowsRuntime.dll")
    # The consolidated WinRT winmds reference the .NET Core System.Runtime
    # facade (4.0.0.0, token b03f5f7f11d50a3f); the .NET Framework csc needs a
    # matching reference from the .NET Core REFERENCE pack (the shared runtime's
    # implementation assemblies pull in the non-referenceable
    # System.Private.CoreLib, so only the Microsoft.NETCore.App.Ref pack works).
    # If the ref pack is absent the compile fails and the capture chain degrades
    # to the screen-region fallback (handled by the caller's Invoke-Safe).
    $refPack = "C:\Program Files\dotnet\packs\Microsoft.NETCore.App.Ref"
    if (Test-Path $refPack) {
      $coreRef = Get-ChildItem $refPack -Recurse -Filter "System.Runtime.dll" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
      if ($coreRef) { $refArgs += ("/r:" + $coreRef) }
    }
    $cscArgs = @("/nologo", "/target:library", "/out:$dll") + $refArgs + @($src)
    $out = & $csc $cscArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      $msg = (($out | Out-String).Trim())
      $script:WgcCompileFailed = $true
      throw "WGC helper compile failed: " + $msg.Substring(0, [Math]::Min(300, $msg.Length))
    }
  }
  [void][System.Reflection.Assembly]::LoadFrom($dll)
}

function Invoke-WgcCapture {
  # Capture one frame of the window via Windows.Graphics.Capture. Returns the
  # PNG path on success, $null on timeout / no frame, throws on setup failure.
  param([long]$Hwnd, [int]$Width, [int]$Height, [string]$OutPng, [int]$TimeoutMs = 4000)
  Get-WgcHelper
  return [WgcCapture]::CaptureWindow([uint32]$Hwnd, [int]$Width, [int]$Height, $OutPng, [int]$TimeoutMs)
}


function Get-NativeWindowList {
  param([bool]$IncludeInvisible = $false, [int]$MaxWindows = 50, [switch]$RecordObservation)
  $items = New-Object System.Collections.Generic.List[object]
  $foreground = [WindowsComputerUseNative]::GetForegroundWindow()
  $owners = @{}
  foreach ($handle in [WindowsComputerUseNative]::TopLevelWindows()) {
    $visible = [WindowsComputerUseNative]::IsWindowVisible($handle)
    if (-not $IncludeInvisible -and (-not $visible -or [WindowsComputerUseNative]::IsIconic($handle))) { continue }
    $title = New-Object System.Text.StringBuilder 2048
    [void][WindowsComputerUseNative]::GetWindowText($handle, $title, $title.Capacity)
    $class = New-Object System.Text.StringBuilder 256
    [void][WindowsComputerUseNative]::GetClassName($handle, $class, $class.Capacity)
    $rect = New-Object WindowsComputerUseNative+RECT
    if (-not [WindowsComputerUseNative]::GetWindowRect($handle, [ref]$rect)) { continue }
    $ownerId = [uint32]0
    [void][WindowsComputerUseNative]::GetWindowThreadProcessId($handle, [ref]$ownerId)
    if (-not $ownerId) { continue }
    if (-not $owners.ContainsKey([string]$ownerId)) {
      try {
        $proc = Get-Process -Id $ownerId -ErrorAction Stop
        $owners[[string]$ownerId] = @{ executable = $proc.ProcessName + '.exe'; processStartedAt = $proc.StartTime.ToUniversalTime().Ticks.ToString() }
      } catch { $owners[[string]$ownerId] = @{ executable = ''; processStartedAt = '' } }
    }
    $owner = $owners[[string]$ownerId]
    $hwnd = $handle.ToInt64()
    $box = [ordered]@{ x=$rect.left; y=$rect.top; width=$rect.right-$rect.left; height=$rect.bottom-$rect.top; centerX=($rect.left+$rect.right)/2; centerY=($rect.top+$rect.bottom)/2 }
    $items.Add([ordered]@{id="uia:hwnd:${hwnd}:pid:${ownerId}"; depth=1; name=$title.ToString(); className=$class.ToString(); controlType='Window'; processId=$ownerId; executable=$owner.executable; processStartedAt=$owner.processStartedAt; nativeWindowHandle=$hwnd; boundingBox=$box; isEnabled=[WindowsComputerUseNative]::IsWindowEnabled($handle); isOffscreen=(-not $visible -or [WindowsComputerUseNative]::IsIconic($handle)); hasKeyboardFocus=($foreground -eq $handle); source='win32'})
    # Target lookup must not replace the coordinates used by Home-Point.
    # Only explicit observations establish a new coordinate baseline.
    if ($RecordObservation) {
      $script:WindowCache[[string]$hwnd] = @{ x=$rect.left; y=$rect.top; ts=[DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
    }
    if ($items.Count -ge $MaxWindows) { break }
  }
  return ,$items
}

function Resolve-TargetWindow {
  param([object]$InputObject)
  if (-not (Has-WindowTarget $InputObject)) { return $null }

  $hwnd = Get-Prop $InputObject "nativeWindowHandle" $null
  if ($null -ne $hwnd) {
    $element = Invoke-Safe { [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$hwnd)) } $null
    if ($null -eq $element) { throw "No UI Automation window found for nativeWindowHandle '$hwnd'." }
    return $element
  }

  $fallback = $null
  foreach ($info in (Get-NativeWindowList -IncludeInvisible $true -MaxWindows 4096)) {
    if (-not (Test-TargetMatch -Info $info -InputObject $InputObject)) { continue }
    if (-not $info.isOffscreen) {
      return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$info.nativeWindowHandle))
    }
    if ($null -eq $fallback) { $fallback = $info }
  }
  if ($null -ne $fallback) { return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$fallback.nativeWindowHandle)) }
  throw "No top-level window matched the requested target."
}

function Get-ScopeRoot {
  param([string]$Scope, [object]$InputObject = $null)
  if ($Scope -eq "desktop") {
    return [System.Windows.Automation.AutomationElement]::RootElement
  }

  $target = Resolve-TargetWindow $InputObject
  if ($null -ne $target) {
    if ([bool](Get-Prop $InputObject "activate" $false)) {
      [void](Set-WindowForeground $target)
    }
    return $target
  }

  $hwnd = [WindowsComputerUseNative]::GetForegroundWindow()
  if ($hwnd -ne [IntPtr]::Zero) {
    $element = Invoke-Safe { [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } $null
    if ($null -ne $element) { return $element }
  }
  return [System.Windows.Automation.AutomationElement]::RootElement
}

# ============================================================================
# Tree + element resolution
# ============================================================================

function Get-Children {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [string]$ViewMode = "control",
    [bool]$IncludeOffscreen = $false
  )
  $items = New-Object "System.Collections.Generic.List[System.Windows.Automation.AutomationElement]"
  try {
    # Enumerate raw children, then bridge non-control containers explicitly.
    # Bound the traversal when bridging non-control containers.
    $pending=New-Object System.Collections.Generic.Queue[object]
    foreach($child in $Element.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)) { $pending.Enqueue(@{node=$child;depth=0}) }
    $visited=0
    while($pending.Count -gt 0 -and $visited -lt 600) {
      $entry=$pending.Dequeue();$child=$entry.node;$visited++
      $matches=$ViewMode -eq 'raw' -or ($ViewMode -eq 'control' -and $child.Current.IsControlElement) -or ($ViewMode -eq 'content' -and $child.Current.IsContentElement)
      if($matches) { if($IncludeOffscreen -or -not $child.Current.IsOffscreen){$items.Add($child)} }
      elseif($entry.depth -lt 20) { foreach($nested in $child.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)){$pending.Enqueue(@{node=$nested;depth=$entry.depth+1})} }
    }
  } catch {
    if ($null -ne $script:AccessibilityErrors) { $script:AccessibilityErrors.Add($_.Exception.GetType().Name) }
    return ,$items
  }
  return ,$items
}

function Get-BoundInputFocus {
  param([long]$Hwnd)
  $pidValue=[uint32]0
  $thread=[WindowsComputerUseNative]::GetWindowThreadProcessId([IntPtr]$Hwnd,[ref]$pidValue)
  $gui=New-Object WindowsComputerUseNative+GUITHREADINFO
  $gui.cbSize=[Runtime.InteropServices.Marshal]::SizeOf($gui)
  if (-not [WindowsComputerUseNative]::GetGUIThreadInfo($thread,[ref]$gui)) { return $null }
  $belongs=$gui.hwndFocus -eq [IntPtr]$Hwnd -or [WindowsComputerUseNative]::IsChild([IntPtr]$Hwnd,$gui.hwndFocus)
  $point=New-Object WindowsComputerUseNative+POINT
  $hasCursor=[WindowsComputerUseNative]::GetCursorPos([ref]$point)
  return @{nativeWindowHandle=$gui.hwndFocus.ToInt64();belongsToTarget=($belongs -and $hasCursor -and [WindowsComputerUseNative]::GetForegroundWindow() -eq [IntPtr]$Hwnd);cursor=@{x=$point.x;y=$point.y}}
}

function Assert-VisualFocus {
  param([object]$InputObject)
  Assert-TargetIsForeground $InputObject
  $focus=Get-BoundInputFocus ([long](Get-Prop $InputObject 'nativeWindowHandle' 0))
  if (!$focus.belongsToTarget -or $focus.nativeWindowHandle -ne [long](Get-Prop $InputObject 'expectedFocusHandle' 0)) { throw 'FOCUS_CHANGED: visual input focus changed. No text sent.' }
  $cursor=Get-Prop $InputObject 'expectedCursor' $null
  if ($null -eq $cursor -or $cursor.x -ne $focus.cursor.x -or $cursor.y -ne $focus.cursor.y) { throw 'FOCUS_CHANGED: cursor moved after the observed click. No text sent.' }
  $uia=Invoke-Safe { [System.Windows.Automation.AutomationElement]::FocusedElement } $null
  if ($uia -and $uia.Current.IsPassword) { throw 'Password entry is excluded.' }
}

function Convert-Tree {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [string]$Path,
    [int]$Depth,
    [int]$MaxDepth,
    [ref]$Count,
    [int]$MaxNodes,
    [string]$ViewMode = "control",
    [bool]$IncludeOffscreen = $false,
    [string]$DetailLevel = "compact"
  )

  if ($Count.Value -ge $MaxNodes) { return $null }
  $id = "uia:$Path"
  $info = Convert-ElementInfo -Element $Element -Id $id -Depth $Depth -DetailLevel $DetailLevel
  $Count.Value = $Count.Value + 1
  $childrenOut = New-Object System.Collections.Generic.List[object]

  if ($Depth -lt $MaxDepth) {
    $children = Get-Children -Element $Element -ViewMode $ViewMode -IncludeOffscreen $IncludeOffscreen
    if ($null -ne $children) {
      for ($i = 0; $i -lt $children.Count; $i++) {
        if ($Count.Value -ge $MaxNodes) { break }
        $childPath = "$Path.$i"
        $child = Convert-Tree -Element $children.Item($i) -Path $childPath -Depth ($Depth + 1) -MaxDepth $MaxDepth -Count $Count -MaxNodes $MaxNodes -ViewMode $ViewMode -IncludeOffscreen $IncludeOffscreen -DetailLevel $DetailLevel
        if ($null -ne $child) { $childrenOut.Add($child) }
      }
    }
  }
  $info["children"] = @($childrenOut.ToArray())
  return $info
}

function Resolve-Element {
  param([string]$ElementId, [object]$InputObject = $null)
  if ([string]::IsNullOrWhiteSpace($ElementId)) {
    throw "elementId is required."
  }


  if ($ElementId -match '^uia:hwnd:(\d+):pid:(\d+)$') {
    $handle = [IntPtr]([int64]$Matches[1])
    $expectedOwner = [uint32]$Matches[2]
    $null = Get-ViewMode $InputObject "control"
    $ownerId = [uint32]0
    [void][WindowsComputerUseNative]::GetWindowThreadProcessId($handle, [ref]$ownerId)
    if (-not [WindowsComputerUseNative]::IsWindow($handle) -or $ownerId -ne $expectedOwner) { throw 'Window identity changed; refresh the window list.' }
    return [System.Windows.Automation.AutomationElement]::FromHandle($handle)
  }

  # Preferred form: uia:rt:<n>-<n>-... resolved by RuntimeId (stable for the
  # life of the owning process, immune to UI re-layouts).
  if ($ElementId -match '^uia:rt:(.+)$') {
    $rtParts = $Matches[1] -split '-'
    if ($rtParts.Count -lt 2) { throw "Malformed runtime element id '$ElementId'." }
    # RuntimeId lookup bypasses view traversal, but the declared view filters
    # must still be validated here — an illegal viewMode has to fail exactly
    # like it does on the legacy path instead of being silently ignored.
    $null = Get-ViewMode $InputObject "control"
    $rtArr = New-Object 'int[]' $rtParts.Count
    for ($i = 0; $i -lt $rtParts.Count; $i++) { $rtArr[$i] = [int]$rtParts[$i] }
    # Bound element ids are scoped strictly to the selected top-level window.
    $target = Resolve-TargetWindow $InputObject
    $roots = @($target)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::RuntimeIdProperty, $rtArr)
    foreach ($root in $roots) {
      $found = Invoke-Safe { $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond) } $null
      if ($null -ne $found) { return $found }
    }
    throw "Element '$ElementId' no longer exists (stale — the control was removed or its app restarted). Re-run snapshot/tree to get fresh ids."
  }

  # Legacy form: uia:<active|root>.<index>.<index>... resolved by tree path.
  if ($ElementId -match '^uia:(active|root)(\.\d+)*$') {
    $path = $ElementId.Substring(4)
    $parts = $path.Split(".")
    $scopeName = $parts[0]
    $viewMode = Get-ViewMode $InputObject "control"
    $includeOffscreen = [bool](Get-Prop $InputObject "includeOffscreen" $false)
    $element = if ($scopeName -eq "root") {
      [System.Windows.Automation.AutomationElement]::RootElement
    } else {
      Get-ScopeRoot "active_window" $InputObject
    }
    for ($i = 1; $i -lt $parts.Length; $i++) {
      $index = [int]$parts[$i]
      $children = Get-Children -Element $element -ViewMode $viewMode -IncludeOffscreen $includeOffscreen
      if ($null -eq $children -or $index -lt 0 -or $index -ge $children.Count) {
        throw "Element path '$ElementId' is stale or out of range at segment $i."
      }
      $element = $children.Item($index)
    }
    return $element
  }

  throw "Unsupported element id '$ElementId'. Use an id from windows_computer_use_snapshot or windows_computer_use_accessibility_tree."
}

function Assert-PointInTarget {
  param([object]$InputObject, [int]$X, [int]$Y)
  $target = Resolve-TargetWindow $InputObject
  # UIA FromPoint can see our disabled, click-through indicator windows.
  # Win32 hit testing skips disabled windows and reflects the input target.
  $point=New-Object WindowsComputerUseNative+POINT;$point.x=$X;$point.y=$Y
  $hit=[WindowsComputerUseNative]::WindowFromPoint($point)
  $owner=[uint32]0
  [void][WindowsComputerUseNative]::GetWindowThreadProcessId($hit,[ref]$owner)
  if ($owner -ne $target.Current.ProcessId) { throw 'POINT_OCCLUDED: another app is over the target point. No input sent.' }
  $bound=[IntPtr]([int64](Get-Prop $InputObject 'nativeWindowHandle' 0))
  if($hit -eq $bound -or [WindowsComputerUseNative]::IsChild($bound,$hit)){return}
  throw 'POINT_OUTSIDE_TARGET: point belongs to another window. No input sent.'
}

function Get-PointFromArgs {
  param([object]$InputObject)
  $elementId = Get-Prop $InputObject "elementId" $null
  if ($null -ne $elementId) {
    $el = Resolve-Element $elementId $InputObject
    $rect = Convert-Rect (Invoke-Safe { $el.Current.BoundingRectangle } $null)
    if ($null -eq $rect) { throw "Element '$elementId' has no clickable bounding box." }
    return [ordered]@{ x = $rect.centerX; y = $rect.centerY; element = $el; elementId = $elementId }
  }

  $x = Get-Prop $InputObject "x" $null
  $y = Get-Prop $InputObject "y" $null
  if ($null -eq $x -or $null -eq $y) {
    throw "Provide either elementId or x and y."
  }
  return [ordered]@{ x = [int]$x; y = [int]$y; element = $null; elementId = $null }
}

# ============================================================================
# Search
# ============================================================================

function Element-Matches {
  param([object]$Info, [string]$Query, [string]$ControlType)
  if (-not [string]::IsNullOrWhiteSpace($ControlType)) {
    if (($Info.controlType + "") -notlike "*$ControlType*") { return $false }
  }
  if ([string]::IsNullOrWhiteSpace($Query)) { return $true }
  $haystack = @(
    $Info.name,
    $Info.automationId,
    $Info.className,
    $Info.controlType,
    $Info.localizedControlType,
    $Info.value
  ) -join "`n"
  return $haystack.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Search-Tree {
  param([object]$Node, [string]$Query, [string]$ControlType, [int]$MaxResults, [System.Collections.Generic.List[object]]$Results)
  if ($null -eq $Node -or $Results.Count -ge $MaxResults) { return }
  if (Element-Matches -Info $Node -Query $Query -ControlType $ControlType) {
    $copy = [ordered]@{}
    foreach ($prop in $Node.Keys) {
      if ($prop -ne "children") { $copy[$prop] = $Node[$prop] }
    }
    $Results.Add($copy)
  }
  foreach ($child in @($Node.children)) {
    if ($Results.Count -ge $MaxResults) { break }
    Search-Tree -Node $child -Query $Query -ControlType $ControlType -MaxResults $MaxResults -Results $Results
  }
}

# ============================================================================
# Input (modern SendInput path)
# ============================================================================

function Get-ButtonFlags {
  param([string]$Button)
  switch ($Button) {
      "right" { return @([uint32]0x0008, [uint32]0x0010) }
      "middle" { return @([uint32]0x0020, [uint32]0x0040) }
      default { return @([uint32]0x0002, [uint32]0x0004) }
  }
}

function Emit-DesktopActivity {
  param([int]$X,[int]$Y,[string]$Kind='move')
  if (-not $Persistent) { return }
  [Console]::Out.WriteLine((@{type='activity';action=$Kind;point=@{x=$X;y=$Y}} | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
}

function Click-At {
  param([int]$X, [int]$Y, [string]$Button = "left", [int]$Count = 1)
  $flags = Get-ButtonFlags $Button
  Move-ToPoint -X $X -Y $Y
  Emit-DesktopActivity $X $Y 'click'
  Start-Sleep -Milliseconds 40
  for ($i = 0; $i -lt $Count; $i++) {
    if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, [uint32]$flags[0], 0) -ne 1) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: Windows rejected mouse input.' }
    try { Start-Sleep -Milliseconds 30 }
    finally {
      if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, [uint32]$flags[1], 0) -ne 1) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: Windows rejected mouse release.' }
    }
    Start-Sleep -Milliseconds 60
  }
}

function Move-ToPoint {
  param([int]$X, [int]$Y)
  Emit-DesktopActivity $X $Y
  if (-not [WindowsComputerUseNative]::SetCursorPos($X, $Y)) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: Windows rejected cursor positioning. Restore the interactive desktop before retrying.' }
}

function Type-Text {
  param([string]$Text, [bool]$RestoreClipboard = $true, [object]$VisualTarget = $null,
    [object]$Editable = $null, [object]$InputTarget = $null, [bool]$Replace = $false)
  $position = New-Object WindowsComputerUseNative+POINT
  if (-not [WindowsComputerUseNative]::GetCursorPos([ref]$position)) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: Windows input desktop is unavailable.' }
  Move-ToPoint -X $position.x -Y $position.y
  $oldData = $null; $oldKnown = $false
  # An IDataObject obtained from OLE may lazily refer to the live clipboard.
  # Materialize its formats before writing, rather than keeping that proxy.
  if ($RestoreClipboard -and $null -ne $Editable) { try {
    $previous = [System.Windows.Forms.Clipboard]::GetDataObject()
    if ($null -ne $previous) {
      $oldData = New-Object System.Windows.Forms.DataObject
      foreach ($format in $previous.GetFormats($false)) {
        $data = $previous.GetData($format, $false)
        if ($null -ne $data) { $oldData.SetData($format, $false, $data) }
      }
    }
    $oldKnown = $true
  } catch { $oldData = $null } }
  $before = if ($null -ne $Editable) { Get-ValueText $Editable } else { $null }
  $written = $false; $pasteAttempted = $false; $sequence = 0
  $info = [ordered]@{ write_verified=$false; format='UnicodeText'; target_text_observed=$false; restored=$false; retained=$false; restore_reason='not_requested' }
  try {
    $payload = New-Object System.Windows.Forms.DataObject
    $payload.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $false, $Text)
    # copy=true flushes the OLE data so it survives a cancelled worker. The
    # bounded retries are clipboard-lock retries only; input is never replayed.
    try { [System.Windows.Forms.Clipboard]::SetDataObject($payload, $true, 3, 80) }
    catch { throw 'CLIPBOARD_WRITE_FAILED: Windows refused the clipboard write. No text sent.' }
    $written = $true
    $sequence = [WindowsComputerUseNative]::GetClipboardSequenceNumber()
    $until = [DateTime]::UtcNow.AddMilliseconds(1000)
    do {
      if ([WindowsComputerUseNative]::GetClipboardSequenceNumber() -ne $sequence) {
        throw 'CLIPBOARD_CHANGED: Clipboard ownership changed before paste. No text sent.'
      }
      try { $readback = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText) } catch { $readback = $null }
      if ([string]::Equals($readback, $Text, [StringComparison]::Ordinal)) { $info.write_verified = $true; break }
      Start-Sleep -Milliseconds 40
    } while ([DateTime]::UtcNow -lt $until)
    if (-not $info.write_verified) { throw 'CLIPBOARD_VERIFY_FAILED: Clipboard text did not match the requested text. No text sent.' }
    [void](Test-Failsafe)
    if ($null -ne $VisualTarget) { Assert-VisualFocus $VisualTarget }
    if ($null -ne $InputTarget) { Assert-TargetIsForeground $InputTarget }
    if ($null -ne $Editable -and (-not $Editable.Current.HasKeyboardFocus -or $Editable.Current.IsPassword)) {
      throw 'FOCUS_CHANGED: Editable focus changed before paste. No text sent.'
    }
    if ($null -ne $Editable -and $null -ne $InputTarget) {
      $prior = Get-Prop $InputTarget 'expectedPriorValue' $null
      if ($null -ne $prior -and (Get-ValueText $Editable) -cne [string]$prior) {
        throw 'CONTENT_CHANGED: Editable content changed during clipboard preparation. No text sent.'
      }
    }
    if ([WindowsComputerUseNative]::GetClipboardSequenceNumber() -ne $sequence) {
      throw 'CLIPBOARD_CHANGED: Clipboard ownership changed before paste. No text sent.'
    }
    if ($Replace) {
      if (-not [WindowsComputerUseNative]::SendKeyChord(@('Ctrl','a'))) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: select-all failed; effects may already exist.' }
      if ([WindowsComputerUseNative]::GetClipboardSequenceNumber() -ne $sequence -or -not $Editable.Current.HasKeyboardFocus) {
        throw 'INPUT_STATE_UNKNOWN: Clipboard or focus changed after selection. Paste was not dispatched; selection effects may already exist.'
      }
    }
    $pasteAttempted = $true
    if (-not [WindowsComputerUseNative]::SendKeyChord(@('Ctrl','v'))) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: paste input was rejected; effects may already exist.' }
    if ($null -ne $Editable) {
      $until = [DateTime]::UtcNow.AddMilliseconds(2000)
      do {
        [void](Test-Failsafe)
        try { $actual = Get-ValueText $Editable } catch { $actual = $null }
        $newText = $null -ne $before -and ($Replace -or $before.IndexOf($Text, [StringComparison]::Ordinal) -lt 0)
        $textMatches = $null -ne $actual -and $(if ($Replace) { [string]::Equals($actual, $Text, [StringComparison]::Ordinal) } else { $actual.IndexOf($Text, [StringComparison]::Ordinal) -ge 0 })
        if ($newText -and $textMatches -and $actual -cne $before) {
          $info.target_text_observed = $true; break
        }
        Start-Sleep -Milliseconds 40
      } while ([DateTime]::UtcNow -lt $until)
    } else {
      # A custom editor can read CF_UNICODETEXT asynchronously after Ctrl+V.
      # A short sleep is not proof that it consumed the data. Keep the intended
      # payload available instead of pasting an empty/private prior clipboard.
      Start-Sleep -Milliseconds 250
    }
  } finally {
    $ownsClipboard = $written -and [WindowsComputerUseNative]::GetClipboardSequenceNumber() -eq $sequence
    if ($ownsClipboard -and $oldKnown -and (-not $pasteAttempted -or $info.target_text_observed)) { try {
      if ($null -ne $oldData) { [System.Windows.Forms.Clipboard]::SetDataObject($oldData, $true, 3, 80) }
      else { [System.Windows.Forms.Clipboard]::Clear() }
      $info.restored = $true
    } catch { } }
    $info.retained = $ownsClipboard -and -not $info.restored
    $info.restore_reason = if ($info.restored) { if ($pasteAttempted) { 'target_text_observed' } else { 'no_paste_dispatched' } } elseif ($written -and -not $ownsClipboard) { 'clipboard_changed_externally' } elseif ($pasteAttempted -and -not $info.target_text_observed) { 'target_read_unconfirmed' } elseif (-not $RestoreClipboard) { 'not_requested' } else { 'previous_clipboard_unavailable' }
  }
  return $info
}

function Convert-KeyChord {
  param([object[]]$Keys)
  $mod = ""
  $main = $null
  foreach ($keyRaw in $Keys) {
    $key = ("" + $keyRaw).Trim()
    switch -Regex ($key.ToLowerInvariant()) {
        "^(ctrl|control)$" { $mod += "^"; continue }
        "^(alt|option)$" { $mod += "%"; continue }
        "^shift$" { $mod += "+"; continue }
        "^(cmd|meta|win|windows)$" { throw "The Windows key is blocked by design (it would open system dialogs such as Win+R / Win+L). Use a different key combination." }
        default { $main = $key }
    }
  }
  if ([string]::IsNullOrWhiteSpace($main)) { throw "A non-modifier key is required." }
  $special = @{
    "enter" = "{ENTER}"; "return" = "{ENTER}"; "tab" = "{TAB}"; "esc" = "{ESC}"; "escape" = "{ESC}"
    "backspace" = "{BACKSPACE}"; "delete" = "{DELETE}"; "del" = "{DELETE}"; "home" = "{HOME}"
    "end" = "{END}"; "pageup" = "{PGUP}"; "pagedown" = "{PGDN}"; "up" = "{UP}"; "down" = "{DOWN}"
    "left" = "{LEFT}"; "right" = "{RIGHT}"; "space" = " "; "insert" = "{INSERT}"
    "f1" = "{F1}"; "f2" = "{F2}"; "f3" = "{F3}"; "f4" = "{F4}"; "f5" = "{F5}"; "f6" = "{F6}"
    "f7" = "{F7}"; "f8" = "{F8}"; "f9" = "{F9}"; "f10" = "{F10}"; "f11" = "{F11}"; "f12" = "{F12}"
  }
  $lower = $main.ToLowerInvariant()
  $encoded = if ($special.ContainsKey($lower)) {
    $special[$lower]
  } elseif ($main.Length -eq 1) {
    $main.ToLowerInvariant()
  } else {
    "{" + $main.ToUpperInvariant() + "}"
  }
  return $mod + $encoded
}

function Invoke-ElementPattern {
  param([System.Windows.Automation.AutomationElement]$Element)
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern) } $false) {
    $pattern.Invoke()
    return "Invoke"
  }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern) } $false) {
    $pattern.Toggle()
    return "Toggle"
  }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern) } $false) {
    $pattern.Select()
    return "SelectionItem"
  }
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern) } $false) {
    $state = Invoke-Safe { $pattern.Current.ExpandCollapseState } $null
    if ($state -eq [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
      $pattern.Expand()
    } else {
      $pattern.Collapse()
    }
    return "ExpandCollapse"
  }
  return $null
}

function Set-ElementValue {
  param([System.Windows.Automation.AutomationElement]$Element, [string]$Value)
  $pattern = $null
  if (Invoke-Safe { $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) } $false) {
    $pattern.SetValue($Value)
    return "ValuePattern"
  }
  return $null
}

# ============================================================================
# Screenshot: window-crop (PrintWindow -> screen-region fallback) + downscale
# ============================================================================

function Get-NativeWindowBounds {
  param([long]$Hwnd)
  if (-not $Hwnd) { return $null }
  $r = New-Object WindowsComputerUseNative+RECT
  if (-not [WindowsComputerUseNative]::GetWindowRect([IntPtr]$Hwnd, [ref]$r)) { return $null }
  return [ordered]@{ x = $r.left; y = $r.top; width = $r.right - $r.left; height = $r.bottom - $r.top }
}

function Send-WheelDelta {
  param([int]$Delta,[uint32]$Flags)
  if ($Delta -eq 0) { return 0 }
  $magnitude = [Math]::Abs($Delta)
  $direction = if ($Delta -gt 0) { 1 } else { -1 }
  $wholeNotches = [int][Math]::Floor($magnitude / 120)
  $remainder = $magnitude % 120
  $sent = 0
  for ($i = 0; $i -lt $wholeNotches; $i++) {
    [void](Test-Failsafe)
    if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, $Flags, ($direction * 120)) -ne 1) {
      throw "COMPUTER_USE_INPUT_UNAVAILABLE: Windows accepted $sent wheel notches but rejected the next one. Reobserve; do not blindly resend."
    }
    $sent = $sent + 1
    if ($i -lt ($wholeNotches - 1) -or $remainder -gt 0) { Start-Sleep -Milliseconds 12 }
  }
  if ($remainder -gt 0) {
    [void](Test-Failsafe)
    if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, $Flags, ($direction * $remainder)) -ne 1) {
      throw "COMPUTER_USE_INPUT_UNAVAILABLE: Windows accepted $sent wheel notches but rejected the remaining partial wheel delta. Reobserve; do not blindly resend."
    }
  }
  return $wholeNotches
}

function Get-ExtendedFrameBounds {
  param([long]$Hwnd)
  if (-not ($Hwnd -and $Hwnd -ne 0)) { return $null }
  $r = New-Object WindowsComputerUseNative+RECT
  $hr = Invoke-Safe { [WindowsComputerUseNative]::DwmGetWindowAttribute([IntPtr]$Hwnd, 9, [ref]$r, 16) } 0
  if ($hr -ne 0) { return $null }
  $w = $r.right - $r.left
  $h = $r.bottom - $r.top
  if ($w -le 0 -or $h -le 0) { return $null }
  return [ordered]@{ x = $r.left; y = $r.top; width = $w; height = $h }
}

function Try-PrintWindowCapture {
  # PrintWindow renders the window's own surface even when it is not the
  # foreground window. DirectComposition-backed surfaces (UWP/WinUI) can come
  # back pitch black — detect that and report failure so the caller falls
  # back to a screen-region capture.
  param([long]$Hwnd, [int]$Width, [int]$Height)
  if ($Width -le 0 -or $Height -le 0) { return $null }
  $bmp = New-Object System.Drawing.Bitmap $Width, $Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $hdc = $g.GetHdc()
    try {
      $ok = [WindowsComputerUseNative]::PrintWindow([IntPtr]$Hwnd, $hdc, 2)
    } finally {
      $g.ReleaseHdc($hdc)
    }
    if (-not $ok) { return $null }
    $allDark = $true
    for ($i = 0; $i -lt $Width; $i += 24) {
      for ($j = 0; $j -lt $Height; $j += 24) {
        $px = $bmp.GetPixel($i, $j)
        if ($px.R -gt 10 -or $px.G -gt 10 -or $px.B -gt 10) { $allDark = $false; break }
      }
      if (-not $allDark) { break }
    }
    if ($allDark) { return $null }
    return $bmp
  } finally {
    $g.Dispose()
  }
}

function Capture-Screenshot {
  param([object]$WindowElement = $null, [int]$MaxWidth = 1600)
  # GC: drop our own screenshot PNGs older than 30 minutes.
  $cutoff = [DateTimeOffset]::Now.AddMinutes(-30).UtcDateTime
  Get-ChildItem -Path $env:TEMP -Filter "windows-computer-use-*.png" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = $null
  $method = "screen"
  $occludedPossible = $false
  $windowCaptureFailed = $false
  $bx = $vs.Left; $by = $vs.Top; $bw = $vs.Width; $bh = $vs.Height

  if ($null -ne $WindowElement) {
    $hwnd = Invoke-Safe { [int64]$WindowElement.Current.NativeWindowHandle } 0
    $rect = $null
    # PrintWindow renders the entire Win32 window, including resize borders.
    # Its bitmap origin must match GetWindowRect, not DWM's visible frame.
    if ($hwnd -and $hwnd -ne 0) { $rect = Get-NativeWindowBounds -Hwnd $hwnd }
    if ($null -eq $rect) { $rect = Convert-Rect (Invoke-Safe { $WindowElement.Current.BoundingRectangle } $null) }

    if ($null -ne $rect -and $hwnd -and $hwnd -ne 0) {
      $bmp = Invoke-Safe { Try-PrintWindowCapture -Hwnd $hwnd -Width $rect.width -Height $rect.height } $null
      if ($null -ne $bmp) {
        $method = "printwindow"
        $bx = $rect.x; $by = $rect.y; $bw = $rect.width; $bh = $rect.height
      } else {
        # PrintWindow came back black/failed (UWP/WinUI/DirectComposition).
        # Try Windows.Graphics.Capture: it reads the window's composited
        # frame from DWM, so it works even when the window is occluded.
        $wgcPng = Join-Path $env:TEMP ("wcu-wgc-" + [Guid]::NewGuid().ToString("N") + ".png")
        $frameRect = Get-ExtendedFrameBounds -Hwnd $hwnd
        if ($null -eq $frameRect) { $frameRect = $rect }
        $wgc = Invoke-Safe { Invoke-WgcCapture -Hwnd $hwnd -Width $frameRect.width -Height $frameRect.height -OutPng $wgcPng -TimeoutMs 4000 } $null
        if ($null -ne $wgc -and (Test-Path $wgcPng)) {
          try {
            $src = New-Object System.Drawing.Bitmap($wgcPng)
            $dst = New-Object System.Drawing.Bitmap($src.Width, $src.Height)
            $g = [System.Drawing.Graphics]::FromImage($dst)
            try { $g.DrawImage($src, 0, 0) } finally { $g.Dispose() }
            $src.Dispose()
            $bmp = $dst
            $method = "wgc"
            $bx = $frameRect.x; $by = $frameRect.y; $bw = $frameRect.width; $bh = $frameRect.height
          } catch {
            $bmp = $null
          }
          Remove-Item $wgcPng -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $bmp) {
          # Last resort: the on-screen part of the window rect. This may show
          # whatever is covering the window — flagged, not hidden.
          $cx = [Math]::Max($rect.x, $vs.Left); $cy = [Math]::Max($rect.y, $vs.Top)
          $cx2 = [Math]::Min($rect.x + $rect.width, $vs.Left + $vs.Width)
          $cy2 = [Math]::Min($rect.y + $rect.height, $vs.Top + $vs.Height)
          if ($cx2 -gt $cx -and $cy2 -gt $cy) {
            $tmp = New-Object System.Drawing.Bitmap ($cx2 - $cx), ($cy2 - $cy)
            $g = [System.Drawing.Graphics]::FromImage($tmp)
            try { $g.CopyFromScreen($cx, $cy, 0, 0, $tmp.Size) } finally { $g.Dispose() }
            $bmp = $tmp
            $method = "screen-region"
            $occludedPossible = $true
            $bx = $cx; $by = $cy; $bw = $cx2 - $cx; $bh = $cy2 - $cy
          } else {
            $windowCaptureFailed = $true
          }
        }
      }
    } else {
      $windowCaptureFailed = $true
    }
  }

  if ($null -eq $bmp) {
    if ($windowCaptureFailed) {
      # Target window has no capturable surface (minimized/hidden): capture
      # the whole screen but say so explicitly instead of pretending.
      $windowCaptureFailed = $true
    }
    $bmp = New-Object System.Drawing.Bitmap $bw, $bh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($bx, $by, 0, 0, $bmp.Size) } finally { $g.Dispose() }
  }

  $scale = 1.0
  if ($MaxWidth -gt 0 -and $bmp.Width -gt $MaxWidth) {
    $scale = [double]$MaxWidth / [double]$bmp.Width
    $nw = [int]$MaxWidth
    $nh = [int]($bmp.Height * $scale)
    if ($nh -lt 1) { $nh = 1 }
    $small = New-Object System.Drawing.Bitmap $nw, $nh
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    try {
      $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g2.DrawImage($bmp, 0, 0, $nw, $nh)
    } finally { $g2.Dispose() }
    $bmp.Dispose()
    $bmp = $small
  }

  $file = Join-Path $env:TEMP ("windows-computer-use-" + [Guid]::NewGuid().ToString("N") + ".png")
  $imageWidth = $bmp.Width; $imageHeight = $bmp.Height
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $bytes = [System.IO.File]::ReadAllBytes($file)

  $meta = [ordered]@{
    path = $file
    mimeType = "image/png"
    bytes = $bytes.Length
    method = $method
    bounds = [ordered]@{ x = $bx; y = $by; width = $bw; height = $bh }
    width = $imageWidth
    height = $imageHeight
    imageScale = [double]$imageWidth / [double]$bw
    origin = [ordered]@{ x = $bx; y = $by }
  }
  if ($occludedPossible) { $meta["occludedPossible"] = $true }
  if ($windowCaptureFailed) { $meta["windowCaptureFailed"] = $true }
  $meta["base64"] = [Convert]::ToBase64String($bytes)
  return $meta
}

function Get-TreeResult {
  param([string]$Scope, [int]$MaxDepth, [int]$MaxNodes, [object]$InputObject = $null)
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $viewMode = Get-ViewMode $InputObject "control"
  $includeOffscreen = [bool](Get-Prop $InputObject "includeOffscreen" $false)
  $detailLevel = Get-DetailLevel $InputObject "compact"
  $root = Get-ScopeRoot $Scope $InputObject
  $trace=[bool](Get-Prop $InputObject 'diagnostics' $false)
  if($trace){[Console]::Error.WriteLine('snapshot:root')}
  $script:AccessibilityErrors=New-Object System.Collections.Generic.List[string]
  Update-WindowCache $root
  Update-WindowIdentity $InputObject $root
  $prefix = if ($Scope -eq "desktop") { "root" } else { "active" }
  $count = 0
  $tree = Convert-Tree -Element $root -Path $prefix -Depth 0 -MaxDepth $MaxDepth -Count ([ref]$count) -MaxNodes $MaxNodes -ViewMode $viewMode -IncludeOffscreen $includeOffscreen -DetailLevel $detailLevel
  if($trace){[Console]::Error.WriteLine('snapshot:tree')}
  $focused=$null; $selectedText=$null
  $direct=Invoke-Safe { [System.Windows.Automation.AutomationElement]::FocusedElement } $null
  if($trace){[Console]::Error.WriteLine('snapshot:focus')}
  if ($direct -and $direct.Current.ProcessId -eq $root.Current.ProcessId) {
    $cursor=$direct; $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
    for ($i=0;$cursor -and $i -lt 64;$i++) {
      if ($cursor.Current.NativeWindowHandle -eq $root.Current.NativeWindowHandle) { $focused=Convert-ElementInfo -Element $direct -DetailLevel 'full';break }
      $cursor=Invoke-Safe { $walker.GetParent($cursor) } $null
    }
    if($trace){[Console]::Error.WriteLine('snapshot:bound-focus')}
    # Selection ranges in modern WinUI providers can terminate the .NET
    # Framework UIA client. Read this optional field only for classic Edit.
    if ($focused -and !$focused.isPassword -and $direct.Current.ClassName -eq 'Edit') {
      $pattern=$null
      if (Invoke-Safe { $direct.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pattern) } $false) { $selectedText=Invoke-Safe { ($pattern.GetSelection() | ForEach-Object {$_.GetText(65536)}) -join '' } $null }
    }
  }
  if($trace){[Console]::Error.WriteLine('snapshot:selection')}
  $stopwatch.Stop()
  return [ordered]@{
    ok = $true
    scope = $Scope
    viewMode = $viewMode
    includeOffscreen = $includeOffscreen
    detailLevel = $detailLevel
    nodeCount = $count
    truncated = ($count -ge $MaxNodes)
    durationMs = [int]$stopwatch.ElapsedMilliseconds
    tree = $tree
    windowBounds = Get-NativeWindowBounds -Hwnd (Invoke-Safe { [int64]$root.Current.NativeWindowHandle } 0)
    focusedElement = $focused
    selectedText = $selectedText
    inputFocus = Get-BoundInputFocus (Invoke-Safe { [int64]$root.Current.NativeWindowHandle } 0)
    accessibilityErrors = @($script:AccessibilityErrors.ToArray())
  }
}

# ============================================================================
# Action dispatch (shared by one-shot and persistent modes)
# ============================================================================

function Invoke-Action {
  param([string]$Action, [object]$inputObject = $null)

  if ($Action -notin @('list_windows','list_apps','launch_app','snapshot','click','double_click','keypress','type_text','scroll','drag','set_value','invoke','activate_window','close_window')) { throw 'Unsupported desktop action.' }
  if (Has-WindowTarget $inputObject) {
    $targetHwnd = [IntPtr]([int64](Get-Prop $inputObject 'nativeWindowHandle' 0))
    $actualOwner = [uint32]0
    [void][WindowsComputerUseNative]::GetWindowThreadProcessId($targetHwnd, [ref]$actualOwner)
    if (-not [WindowsComputerUseNative]::IsWindow($targetHwnd) -or $actualOwner -ne [uint32](Get-Prop $inputObject 'processId' 0)) { throw 'WINDOW_CHANGED: HWND/PID identity no longer matches.' }
    $proc = Get-Process -Id $actualOwner -ErrorAction Stop
    if ($proc.StartTime.ToUniversalTime().Ticks.ToString() -ne [string](Get-Prop $inputObject 'processStartedAt' '')) { throw 'WINDOW_CHANGED: process identity changed.' }
    if ($Action -ne 'snapshot') {
      [void](Test-Failsafe)
      if (-not ($Action -eq 'type_text' -and [bool](Get-Prop $inputObject 'visual' $false))) { Activate-TargetIfRequested $inputObject }
      Assert-TargetIsForeground $inputObject
    }
  } elseif ($Action -notin @('list_windows','list_apps','launch_app')) { throw 'A bound HWND/PID/start-time target is required.' }
  switch ($Action) {
    "list_apps" {
      $apps = New-Object System.Collections.Generic.List[object]
      # Only launchable registered .exe paths and a small OS application catalog.
      foreach ($exe in @('notepad.exe','calc.exe','mspaint.exe','explorer.exe')) {
        $apps.Add([ordered]@{ executable=$exe; name=$exe })
      }
      foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths','HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths')) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
          $file = [string]$entry.GetValue('')
          if ($file -and $file.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($file)) { $apps.Add([ordered]@{ executable=$file; name=$entry.PSChildName }) }
        }
      }
      return ([ordered]@{ok=$true; apps=@($apps.ToArray())})
    }
    "launch_app" {
      $exe = [string](Get-Prop $inputObject 'executable' '')
      if (-not $exe.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase) -or $exe -match '[\r\n";|]') { throw 'Invalid app executable.' }
      $launched = Start-Process -FilePath $exe -PassThru -ErrorAction Stop
      return ([ordered]@{ok=$true; processId=$launched.Id})
    }
    "health" {
      $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $active = Get-ScopeRoot "active_window"
      Update-WindowCache $active
      return ([ordered]@{
        ok = $true
        platform = "Windows"
        powershell = $PSVersionTable.PSVersion.ToString()
        mode = if ($Persistent) { "persistent" } else { "oneshot" }
        uiAutomation = $true
        screenshot = $true
        sendInput = $true
        postmessage = $true
        ocr = "lazy"
        homing = $true
        failsafe = ([string]$env:WCU_FAILSAFE -ne '0')
        activeWindow = Convert-ElementInfo -Element $active -Id "uia:active" -Depth 0
        virtualScreen = [ordered]@{ x = $screen.Left; y = $screen.Top; width = $screen.Width; height = $screen.Height }
      })
    }
    "snapshot" {
      $scope = Get-Prop $inputObject "scope" "active_window"
      $includeScreenshot = [bool](Get-Prop $inputObject "includeScreenshot" $true)
      $captureWindow = [bool](Get-Prop $inputObject "captureWindow" $false)
      $maxWidth = [int](Get-Prop $inputObject "maxWidth" 1600)
      $maxDepth = [int](Get-Prop $inputObject "maxDepth" 5)
      $maxNodes = [int](Get-Prop $inputObject "maxNodes" 250)
      $treeResult = Get-TreeResult -Scope $scope -MaxDepth $maxDepth -MaxNodes $maxNodes -InputObject $inputObject
      if ($includeScreenshot) {
        $winEl = $null
        if ($captureWindow) {
          $winEl = Invoke-Safe { Resolve-TargetWindow $inputObject } $null
          if ($null -eq $winEl -and $scope -ne "desktop") { $winEl = Invoke-Safe { Get-ScopeRoot $scope $inputObject } $null }
        }
        $treeResult.screenshot = Capture-Screenshot -WindowElement $winEl -MaxWidth $maxWidth
      }
      return $treeResult
    }
    "tree" {
      $scope = Get-Prop $inputObject "scope" "active_window"
      $maxDepth = [int](Get-Prop $inputObject "maxDepth" 6)
      $maxNodes = [int](Get-Prop $inputObject "maxNodes" 500)
      return (Get-TreeResult -Scope $scope -MaxDepth $maxDepth -MaxNodes $maxNodes -InputObject $inputObject)
    }
    "list_windows" {
      $includeInvisible = [bool](Get-Prop $inputObject "includeInvisible" $false)
      $maxWindows = [int](Get-Prop $inputObject "maxWindows" 50)
      $windows = Get-NativeWindowList -IncludeInvisible $includeInvisible -MaxWindows $maxWindows -RecordObservation
      return ([ordered]@{ ok = $true; windows = @($windows.ToArray()) })
    }
    "find" {
      $query = Get-Prop $inputObject "query" ""
      $scope = Get-Prop $inputObject "scope" "active_window"
      $controlType = Get-Prop $inputObject "controlType" ""
      $maxDepth = [int](Get-Prop $inputObject "maxDepth" 8)
      $maxNodes = [int](Get-Prop $inputObject "maxNodes" 1200)
      $maxResults = [int](Get-Prop $inputObject "maxResults" 25)
      $findInput = [pscustomobject]@{
        viewMode = Get-ViewMode $inputObject "control"
        includeOffscreen = [bool](Get-Prop $inputObject "includeOffscreen" $false)
        detailLevel = "full"
        windowTitle = Get-Prop $inputObject "windowTitle" $null
        processId = Get-Prop $inputObject "processId" $null
        nativeWindowHandle = Get-Prop $inputObject "nativeWindowHandle" $null
        activate = [bool](Get-Prop $inputObject "activate" $false)
      }
      $treeResult = Get-TreeResult -Scope $scope -MaxDepth $maxDepth -MaxNodes $maxNodes -InputObject $findInput
      $results = New-Object System.Collections.Generic.List[object]
      Search-Tree -Node $treeResult.tree -Query $query -ControlType $controlType -MaxResults $maxResults -Results $results
      $out = [ordered]@{ ok = $true; query = $query; results = @($results.ToArray()); scannedNodes = $treeResult.nodeCount; truncated = $treeResult.truncated }
      if ($results.Count -eq 0 -and $treeResult.nodeCount -lt 10) {
        $out["hint"] = "UIA tree is sparse (fewer than 10 nodes): this app may not expose an accessibility tree (game / self-drawn Tk / Qt / canvas / RDP). Use the ocr tool to locate text by pixels."
      }
      return $out
    }
    "element_info" {
      $elementId = Get-Prop $inputObject "elementId" $null
      if ($null -ne $elementId) {
        $el = Resolve-Element $elementId $inputObject
        return ([ordered]@{ ok = $true; element = (Convert-ElementInfo -Element $el -Id $elementId -Depth 0) })
      } else {
        $x = [int](Get-Prop $inputObject "x" 0)
        $y = [int](Get-Prop $inputObject "y" 0)
        Activate-TargetIfRequested $inputObject
        $point = New-Object System.Windows.Point($x, $y)
        $el = [System.Windows.Automation.AutomationElement]::FromPoint($point)
        return ([ordered]@{ ok = $true; point = [ordered]@{ x = $x; y = $y }; element = (Convert-ElementInfo -Element $el -Id $null -Depth 0) })
      }
    }
    "click" {
      [void](Test-Failsafe)
      $point = Get-PointFromArgs $inputObject
      $button = Get-Prop $inputObject "button" "left"
      $dispatch = [string](Get-Prop $inputObject "dispatch" "auto")
      $result = [ordered]@{ ok = $true; action = "click"; x = $point.x; y = $point.y; button = $button; elementId = $point.elementId }

      # Coordinate input goes to whatever is physically under the point, so
      # activate:true must bring the target forward BEFORE homing/clicking —
      # otherwise the click silently lands on the overlapping window.
      Activate-TargetIfRequested $inputObject

      # Homing: if this window was observed before and moved, compensate.
      if ((Has-WindowTarget $inputObject) -and ($null -eq $point.elementId)) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $homed = Home-Point -X $point.x -Y $point.y -Target $target
        $point.x = $homed.x
        $point.y = $homed.y
        if ($null -ne $homed.homed) { $result["homed"] = $homed.homed }
      }

      # Dispatch layering (cua-style): element clicks try the UIA pattern
      # first (background, verified semantic action); raw coordinates need
      # the system input queue (foreground SendInput) unless the caller
      # explicitly asks for background PostMessage.
      $useBackground = ($dispatch -eq "background") -or (($dispatch -eq "auto") -and ($null -ne $point.elementId))
      if ($useBackground) {
        if ($null -ne $point.elementId) {
          $patternMethod = Invoke-ElementPattern $point.element
          if ($null -ne $patternMethod) {
            $result["method"] = "background:$patternMethod"
            return $result
          }
        }
        $hwnd = 0
        if ($null -ne $point.element) { $hwnd = Invoke-Safe { [int64]$point.element.Current.NativeWindowHandle } 0 }
        if (-not ($hwnd -and $hwnd -ne 0)) { $hwnd = Resolve-TargetHwnd $inputObject }
        if (-not ($hwnd -and $hwnd -ne 0)) {
          throw "background_unavailable: no window handle to post to. Retry with dispatch:'foreground'."
        }
        if (-not (Post-BackgroundClick -Hwnd $hwnd -X $point.x -Y $point.y -Button $button -Count 1)) {
          throw "background_unavailable: PostMessage was refused. Retry with dispatch:'foreground'."
        }
        $result["method"] = "postmessage"
        $result["verified"] = $false
        $result["note"] = "Background click queued, delivery unverified. Chromium/Electron/UWP content may ignore PostMessage; if nothing happened, retry with dispatch:'foreground'."
        return $result
      }

      Assert-PointInTarget $inputObject $point.x $point.y
      Click-At -X $point.x -Y $point.y -Button $button -Count 1
      $result["method"] = "sendinput"
      return $result
    }
    "double_click" {
      [void](Test-Failsafe)
      $point = Get-PointFromArgs $inputObject
      $button = Get-Prop $inputObject "button" "left"
      $dispatch = [string](Get-Prop $inputObject "dispatch" "auto")
      $result = [ordered]@{ ok = $true; action = "double_click"; x = $point.x; y = $point.y; button = $button; elementId = $point.elementId }
      Activate-TargetIfRequested $inputObject
      if ((Has-WindowTarget $inputObject) -and ($null -eq $point.elementId)) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $homed = Home-Point -X $point.x -Y $point.y -Target $target
        $point.x = $homed.x
        $point.y = $homed.y
        if ($null -ne $homed.homed) { $result["homed"] = $homed.homed }
      }
      if ($dispatch -eq "background") {
        $hwnd = 0
        if ($null -ne $point.element) { $hwnd = Invoke-Safe { [int64]$point.element.Current.NativeWindowHandle } 0 }
        if (-not ($hwnd -and $hwnd -ne 0)) { $hwnd = Resolve-TargetHwnd $inputObject }
        if (-not ($hwnd -and $hwnd -ne 0)) {
          throw "background_unavailable: no window handle to post to. Retry with dispatch:'foreground'."
        }
        if (-not (Post-BackgroundClick -Hwnd $hwnd -X $point.x -Y $point.y -Button $button -Count 2)) {
          throw "background_unavailable: PostMessage was refused. Retry with dispatch:'foreground'."
        }
        $result["method"] = "postmessage"
        $result["verified"] = $false
        $result["note"] = "Background double-click queued, delivery unverified (WM_LBUTTONDBLCLK). Retry with dispatch:'foreground' if nothing happened."
        return $result
      }
      Assert-PointInTarget $inputObject $point.x $point.y
      Click-At -X $point.x -Y $point.y -Button $button -Count 2
      $result["method"] = "sendinput"
      return $result
    }
    "move" {
      [void](Test-Failsafe)
      $point = Get-PointFromArgs $inputObject
      $result = [ordered]@{ ok = $true; action = "move"; x = $point.x; y = $point.y; elementId = $point.elementId }
      Activate-TargetIfRequested $inputObject
      if ((Has-WindowTarget $inputObject) -and ($null -eq $point.elementId)) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $homed = Home-Point -X $point.x -Y $point.y -Target $target
        $point.x = $homed.x
        $point.y = $homed.y
        if ($null -ne $homed.homed) { $result["homed"] = $homed.homed }
      }
      Move-ToPoint -X $point.x -Y $point.y
      return $result
    }
    "drag" {
      [void](Test-Failsafe)
      Activate-TargetIfRequested $inputObject
      $path = @(Get-Prop $inputObject "path" @())
      if ($path.Count -lt 2) { throw "path must contain at least two points." }
      $button = Get-Prop $inputObject "button" "left"
      $flags = Get-ButtonFlags $button
      # Homing: shift the whole path if the target window moved since the
      # coordinates were observed.
      if (Has-WindowTarget $inputObject) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $homed = Home-Point -X ([int]$path[0].x) -Y ([int]$path[0].y) -Target $target
        if ($null -ne $homed.homed) {
          $dx = $homed.homed.dx
          $dy = $homed.homed.dy
          $shifted = @()
          foreach ($pt in $path) { $shifted += [pscustomobject]@{ x = [int]$pt.x + $dx; y = [int]$pt.y + $dy } }
          $path = $shifted
        }
      }
      $first = $path[0]
      $last = $path[$path.Count - 1]
      if ($path.Count -eq 2) {
        $route=New-Object System.Collections.Generic.List[object]
        for ($i=0;$i -le 20;$i++) { $route.Add(@{x=[int][Math]::Round($first.x+($last.x-$first.x)*$i/20);y=[int][Math]::Round($first.y+($last.y-$first.y)*$i/20)}) }
        $path=@($route.ToArray())
      }
      $delay=[Math]::Max(5,[Math]::Min(100,[int]((Get-Prop $inputObject 'durationMs' 350)/[Math]::Max(1,$path.Count-1))))
      foreach ($pt in $path) { Assert-PointInTarget $inputObject ([int]$pt.x) ([int]$pt.y) }
      Emit-DesktopActivity ([int]$first.x) ([int]$first.y)
      Move-ToPoint ([int]$first.x) ([int]$first.y)
      Start-Sleep -Milliseconds 50
      if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, [uint32]$flags[0], 0) -ne 1) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: drag press failed.' }
      try {
        foreach ($pt in $path) {
          Emit-DesktopActivity ([int]$pt.x) ([int]$pt.y)
          Assert-TargetIsForeground $inputObject
          Move-ToPoint ([int]$pt.x) ([int]$pt.y)
          Start-Sleep -Milliseconds $delay
        }
      } finally { if ([WindowsComputerUseNative]::SendMouseEvent(0, 0, [uint32]$flags[1], 0) -ne 1) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: drag release failed; check mouse state.' } }
      return ([ordered]@{ ok = $true; action = "drag"; points = $path.Count; button = $button })
    }
    "scroll" {
      [void](Test-Failsafe)
      $point = Get-PointFromArgs $inputObject
      $requestedDeltaY = [double](Get-Prop $inputObject "deltaY" 480)
      $requestedDeltaX = [double](Get-Prop $inputObject "deltaX" 0)
      if ([double]::IsNaN($requestedDeltaX) -or [double]::IsInfinity($requestedDeltaX) -or [double]::IsNaN($requestedDeltaY) -or [double]::IsInfinity($requestedDeltaY)) { throw 'Scroll deltas must be finite numbers.' }
      $maxDelta = 3600 # At most 30 discrete 120-unit wheel notches per axis per call.
      $deltaY = [int][Math]::Truncate([Math]::Max(-$maxDelta, [Math]::Min($maxDelta, $requestedDeltaY)))
      $deltaX = [int][Math]::Truncate([Math]::Max(-$maxDelta, [Math]::Min($maxDelta, $requestedDeltaX)))
      $limited = $deltaY -ne $requestedDeltaY -or $deltaX -ne $requestedDeltaX
      Activate-TargetIfRequested $inputObject
      if ((Has-WindowTarget $inputObject) -and ($null -eq $point.elementId)) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $homed = Home-Point -X $point.x -Y $point.y -Target $target
        $point.x = $homed.x
        $point.y = $homed.y
      }
      if ($deltaY -ne 0 -or $deltaX -ne 0) {
        Assert-PointInTarget $inputObject $point.x $point.y
        Emit-DesktopActivity $point.x $point.y
        [void][WindowsComputerUseNative]::SetCursorPos($point.x, $point.y)
        Start-Sleep -Milliseconds 30
        $notchesY = Send-WheelDelta -Delta (-1 * $deltaY) -Flags ([uint32][WindowsComputerUseNative]::MOUSEEVENTF_WHEEL)
        $notchesX = Send-WheelDelta -Delta $deltaX -Flags ([uint32][WindowsComputerUseNative]::MOUSEEVENTF_HWHEEL)
      }
      else { $notchesY = 0; $notchesX = 0 }
      return ([ordered]@{ ok = $true; action = "scroll"; x = $point.x; y = $point.y; requestedDeltaX = $requestedDeltaX; requestedDeltaY = $requestedDeltaY; deltaX = $deltaX; deltaY = $deltaY; notchesX = $notchesX; notchesY = $notchesY; limited = $limited; elementId = $point.elementId })
    }
    "type_text" {
      [void](Test-Failsafe)
      $method = [string](Get-Prop $inputObject "method" "clipboard")
      $text = [string](Get-Prop $inputObject "text" "")
      if ($text.Length -eq 0) { throw "text is required." }
      if ([bool](Get-Prop $inputObject 'visual' $false)) {
        Assert-VisualFocus $inputObject
        $clipboard = Type-Text -Text $text -RestoreClipboard $false -VisualTarget $inputObject
        return @{ok=$true;method='visual-clipboard-paste';verified=$false;clipboard=$clipboard}
      }

      # Background path: post WM_CHAR straight into the target window's
      # message queue — no clipboard, no foreground, no system input queue.
      if ($method -eq "background") {
        if (-not (Has-WindowTarget $inputObject)) {
          throw "method:'background' requires a window target (windowTitle / processId / nativeWindowHandle)."
        }
        $hwnd = Resolve-TargetHwnd $inputObject
        if (-not ($hwnd -and $hwnd -ne 0)) { throw "No window handle found for the target." }
        $ok = Post-BackgroundText -Hwnd $hwnd -Text $text
        if (-not $ok) { throw "background_unavailable: some WM_CHAR messages were refused. Retry with method:'clipboard'." }
        return ([ordered]@{ ok = $true; action = "type_text"; length = $text.Length; method = "postmessage-wmchar"; verified = $false; note = "Background text queued, delivery unverified; controls that reject WM_CHAR (some custom UIs) need method:'clipboard'." })
      }

      # Foreground path (clipboard or sendinput): the target must be
      # foreground + focused. sendinput synthesizes Unicode key events
      # (KEYEVENTF_UNICODE) — no clipboard touched, so it also types into
      # password fields and other controls that reject paste.
      Activate-TargetIfRequested $inputObject
      Assert-TargetIsForeground $inputObject
      $focusedControl = $null
      $target = $null
      if (Has-WindowTarget $inputObject) {
        $target = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $target
        $focusId = [string](Get-Prop $inputObject 'elementId' '')
      $editable = Resolve-Element $focusId $inputObject
      if (-not $editable.Current.HasKeyboardFocus -or $editable.Current.IsPassword) { throw 'FOCUS_CHANGED: editable focus changed or is a password field. No text sent.' }
      $prior = Get-Prop $inputObject 'expectedPriorValue' $null
      if ($null -ne $prior -and (Get-ValueText $editable) -cne [string]$prior) { throw 'CONTENT_CHANGED: editable content changed after observation. No text sent.' }
      $focusedControl = Get-ControlTypeName $editable.Current.ControlType
      }
      $result = [ordered]@{ ok = $true; action = "type_text"; length = $text.Length; focusedControl = $focusedControl }
      if ($method -eq "sendinput") {
        $ok = [bool][WindowsComputerUseNative]::SendUnicodeText($text)
        if (-not $ok) { throw "method:'sendinput' dropped some key events (input queue full). Retry, or use method:'clipboard'." }
        $result["method"] = "sendinput-unicode"
        $result["note"] = "Synthesized Unicode key events; target was foreground + focused. Works on password fields (no paste)."
      } else {
        $restore = [bool](Get-Prop $inputObject "restoreClipboard" $true)
        $result['clipboard'] = Type-Text -Text $text -RestoreClipboard $restore -Editable $editable -InputTarget $inputObject
        $result["restoreClipboard"] = $restore
        $result["method"] = "clipboard-paste"
      }
      # Closed-loop verification: read back the value of the control we typed
      # into, so the model gets evidence instead of a blind "ok". (Skipped for
      # sendinput on password fields, which deliberately hide their value.)
      if ($method -ne "sendinput" -and $null -ne $focusedControl -and $null -ne $target) {
        $verify = Get-BestTextControl $target
        if ($null -ne $verify) {
          $val = Get-ValueText $verify
          if ($null -ne $val) { $result["verifyValue"] = if ($val.Length -gt 200) { $val.Substring(0, 200) + "..." } else { $val } }
        }
      }
      return $result
    }
    "keypress" {
      [void](Test-Failsafe)
      $dispatch = [string](Get-Prop $inputObject "dispatch" "foreground")
      $keys = @(Get-Prop $inputObject "keys" @())
      if (Has-WindowTarget $inputObject) {
        $ktarget = Resolve-TargetWindow $inputObject
        Assert-WindowIdentity $inputObject $ktarget
      }
      if ($dispatch -eq "background") {
        # Only a single printable character can be posted as WM_CHAR. Chords
        # and functional keys need the system input queue — say so honestly
        # instead of pretending (cua's background_unavailable pattern).
        if ($keys.Count -ne 1) {
          throw "background_unavailable: key chords and functional keys need the system input queue. Use dispatch:'foreground'."
        }
        $ch = [string]$keys[0]
        if ($ch.Length -ne 1) {
          throw "background_unavailable: only a single character can be posted in background. Use dispatch:'foreground' for functional keys."
        }
        if (-not (Has-WindowTarget $inputObject)) {
          throw "background dispatch requires a window target (windowTitle / processId / nativeWindowHandle)."
        }
        $hwnd = Resolve-TargetHwnd $inputObject
        if (-not ($hwnd -and $hwnd -ne 0)) { throw "No window handle found for the target." }
        $ok = [WindowsComputerUseNative]::PostMessageW([IntPtr]$hwnd, [WindowsComputerUseNative]::WM_CHAR, [IntPtr][int][char]$ch, [IntPtr]1)
        if (-not $ok) { throw "background_unavailable: WM_CHAR was refused. Use dispatch:'foreground'." }
        return ([ordered]@{ ok = $true; action = "keypress"; keys = $keys; method = "postmessage-wmchar"; verified = $false; note = "Background key queued, delivery unverified." })
      }
      Activate-TargetIfRequested $inputObject
      Assert-TargetIsForeground $inputObject
      if (-not [WindowsComputerUseNative]::SendKeyChord([string[]]$keys)) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: key input was rejected; effects may already exist.' }
      return ([ordered]@{ ok = $true; action = "keypress"; keys = $keys; method = "sendinput-keys" })
    }
    "focus" {
      $elementId = [string](Get-Prop $inputObject "elementId" "")
      $el = Resolve-Element $elementId $inputObject
      $el.SetFocus()
      return ([ordered]@{ ok = $true; action = "focus"; elementId = $elementId })
    }
    "invoke" {
      $elementId = [string](Get-Prop $inputObject "elementId" "")
      $fallback = [bool](Get-Prop $inputObject "fallbackClick" $true)
      $el = Resolve-Element $elementId $inputObject
      $requested = [string](Get-Prop $inputObject 'pattern' 'invoke')
      $pattern = $null
      switch ($requested) {
        'invoke' { if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) { $pattern.Invoke() } else { throw 'Invoke pattern unavailable.' } }
        'toggle' { if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$pattern)) { $pattern.Toggle() } else { throw 'Toggle pattern unavailable.' } }
        'select' { if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)) { $pattern.Select() } else { throw 'Selection pattern unavailable.' } }
        'expand' { if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern,[ref]$pattern)) { $pattern.Expand() } else { throw 'Expand pattern unavailable.' } }
        'collapse' { if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern,[ref]$pattern)) { $pattern.Collapse() } else { throw 'Collapse pattern unavailable.' } }
        {$_ -in @('scroll_up','scroll_down','scroll_left','scroll_right')} {
          if (-not $el.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern)) { throw 'Scroll pattern unavailable.' }
          $none=[System.Windows.Automation.ScrollAmount]::NoAmount
          $inc=[System.Windows.Automation.ScrollAmount]::SmallIncrement
          $dec=[System.Windows.Automation.ScrollAmount]::SmallDecrement
          switch($requested) { 'scroll_up'{$pattern.Scroll($none,$dec)} 'scroll_down'{$pattern.Scroll($none,$inc)} 'scroll_left'{$pattern.Scroll($dec,$none)} 'scroll_right'{$pattern.Scroll($inc,$none)} }
        }
        default { throw 'Unsupported semantic action.' }
      }
      $method = $requested
      if ($null -eq $method -and $fallback) {
        $rect = Convert-Rect (Invoke-Safe { $el.Current.BoundingRectangle } $null)
        if ($null -eq $rect) { throw "Element has no invokable pattern and no bounding box for fallback click." }
        Click-At -X $rect.centerX -Y $rect.centerY -Button "left" -Count 1
        $method = "ClickFallback"
      }
      if ($null -eq $method) { throw "Element has no supported invokable pattern." }
      return ([ordered]@{ ok = $true; action = "invoke"; elementId = $elementId; method = $method })
    }
    "set_value" {
      $elementId = [string](Get-Prop $inputObject "elementId" "")
      $value = [string](Get-Prop $inputObject "value" "")
      $fallback = [bool](Get-Prop $inputObject "fallbackType" $true)
      $restore = [bool](Get-Prop $inputObject "restoreClipboard" $true)
      $el = Resolve-Element $elementId $inputObject
      if ($el.Current.IsPassword) { throw 'Password entry is excluded.' }
      $prior = Get-Prop $inputObject 'expectedPriorValue' $null
      if ($null -ne $prior -and (Get-ValueText $el) -cne [string]$prior) { throw 'CONTENT_CHANGED: editable content changed after observation. No replacement sent.' }
      $method = Set-ElementValue $el -Value $value
      $clipboard = $null
      if ($null -eq $method -and $fallback) {
        $el.SetFocus()
        if ($value.Length -eq 0) {
          if (-not [WindowsComputerUseNative]::SendKeyChord(@('Ctrl','a'))) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: select-all failed; effects may already exist.' }
          if (-not [WindowsComputerUseNative]::SendKeyChord(@('Backspace'))) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: empty replacement failed; effects may already exist.' }
        } else { $clipboard = Type-Text -Text $value -RestoreClipboard $restore -Editable $el -InputTarget $inputObject -Replace $true }
        $method = "FocusSelectAllTypeFallback"
      }
      if ($null -eq $method) { throw "Element has no ValuePattern and fallbackType is false." }
      return ([ordered]@{ ok = $true; action = "set_value"; elementId = $elementId; method = $method; length = $value.Length; clipboard = $clipboard })
    }
    "activate_window" {
      if (-not (Has-WindowTarget $inputObject)) { throw "Provide windowTitle, processId, or nativeWindowHandle." }
      $el = Resolve-TargetWindow $inputObject
      $activated = Set-WindowForeground $el
      Update-WindowCache $el
      Update-WindowIdentity $inputObject $el
      return ([ordered]@{ ok = $true; action = "activate_window"; activated = [bool]$activated; window = (Convert-ElementInfo -Element $el -Id "uia:active" -Depth 0) })
    }
    "cursor_pos" {
      $p = New-Object WindowsComputerUseNative+POINT
      [void][WindowsComputerUseNative]::GetCursorPos([ref]$p)
      return ([ordered]@{ ok = $true; x = $p.x; y = $p.y })
    }
    "screen_info" {
      # Diagnostics: raw virtual-screen metrics vs GDI+ virtual screen, so
      # coordinate-space mismatches (DPI awareness state) are visible.
      $p = New-Object WindowsComputerUseNative+POINT
      [void][WindowsComputerUseNative]::GetCursorPos([ref]$p)
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      return ([ordered]@{
        ok = $true
        metrics = [ordered]@{
          xVirtualScreen = [WindowsComputerUseNative]::GetSystemMetrics(76)
          yVirtualScreen = [WindowsComputerUseNative]::GetSystemMetrics(77)
          cxVirtualScreen = [WindowsComputerUseNative]::GetSystemMetrics(78)
          cyVirtualScreen = [WindowsComputerUseNative]::GetSystemMetrics(79)
          primary = [ordered]@{ w = [WindowsComputerUseNative]::GetSystemMetrics(0); h = [WindowsComputerUseNative]::GetSystemMetrics(1) }
        }
        gdiVirtualScreen = [ordered]@{ x = $vs.Left; y = $vs.Top; width = $vs.Width; height = $vs.Height }
        cursor = [ordered]@{ x = $p.x; y = $p.y }
      })
    }
    "wait_for" {
      # Server-side polling: wait until a window appears/disappears (or
      # timeout). Saves the model from burning round-trips on sleeps.
      $title = [string](Get-Prop $inputObject "windowTitle" "")
      if ([string]::IsNullOrWhiteSpace($title)) { throw "windowTitle is required for wait_for." }
      $appear = [bool](Get-Prop $inputObject "appear" $true)
      $timeoutMs = [int](Get-Prop $inputObject "timeoutMs" 5000)
      $intervalMs = [int](Get-Prop $inputObject "intervalMs" 250)
      if ($intervalMs -lt 50) { $intervalMs = 50 }
      if ($timeoutMs -lt 100) { $timeoutMs = 100 }
      $start = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      while ($true) {
        $found = $false
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $children = Get-Children -Element $root -ViewMode "control" -IncludeOffscreen $true
        for ($i = 0; $i -lt $children.Count; $i++) {
          $name = Invoke-Safe { $children.Item($i).Current.Name } ""
          if (($name + "").IndexOf($title, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $found = $true; break }
        }
        $hit = if ($appear) { $found } else { -not $found }
        $elapsed = [int]([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $start)
        if ($hit) {
          return ([ordered]@{ ok = $true; action = "wait_for"; found = $found; waitedMs = $elapsed })
        }
        if ($elapsed -ge $timeoutMs) {
          return ([ordered]@{ ok = $true; action = "wait_for"; found = $found; timedOut = $true; waitedMs = $elapsed })
        }
        Start-Sleep -Milliseconds $intervalMs
      }
    }
    "close_window" {
      # Graceful close: post WM_CLOSE (the app can veto it with a save dialog),
      # unlike killing the process.
      if (-not (Has-WindowTarget $inputObject)) { throw "Provide windowTitle, processId, or nativeWindowHandle." }
      $hwnd = Resolve-TargetHwnd $inputObject
      if (-not ($hwnd -and $hwnd -ne 0)) { throw "No window handle found for the target." }
      $posted = [WindowsComputerUseNative]::PostMessageW([IntPtr]$hwnd, [WindowsComputerUseNative]::WM_CLOSE, [IntPtr]0, [IntPtr]0)
      return ([ordered]@{ ok = $true; action = "close_window"; posted = [bool]$posted })
    }
    "move_window" {
      # Move (not resize) the target window. Default is SWP_NOACTIVATE (no
      # focus steal); activate:true hands the foreground to the moved window.
      # Note: maximized windows are not moved by Windows.
      if (-not (Has-WindowTarget $inputObject)) { throw "Provide windowTitle, processId, or nativeWindowHandle." }
      $x = Get-Prop $inputObject "x" $null
      $y = Get-Prop $inputObject "y" $null
      if ($null -eq $x -or $null -eq $y) { throw "x and y are required for move_window." }
      $el = Resolve-TargetWindow $inputObject
      $hwnd = Invoke-Safe { [int64]$el.Current.NativeWindowHandle } 0
      if (-not ($hwnd -and $hwnd -ne 0)) { throw "No window handle found for the target." }
      $flags = [uint32]([WindowsComputerUseNative]::SWP_NOSIZE -bor [WindowsComputerUseNative]::SWP_NOZORDER)
      if (-not [bool](Get-Prop $inputObject "activate" $false)) {
        $flags = [uint32]($flags -bor [WindowsComputerUseNative]::SWP_NOACTIVATE)
      }
      $ok = [WindowsComputerUseNative]::SetWindowPos([IntPtr]$hwnd, [IntPtr]::Zero, [int]$x, [int]$y, 0, 0, $flags)
      $result = [ordered]@{ ok = $true; action = "move_window"; moved = [bool]$ok; x = [int]$x; y = [int]$y; note = if ($ok) { $null } else { "SetWindowPos refused (window may be maximized)." } }
      if ([bool](Get-Prop $inputObject "activate" $false)) {
        # SetWindowPos's implicit activation is silently refused by the
        # Windows foreground lock for background callers, so enforce the
        # switch with the AttachThreadInput helper and report the outcome.
        $activated = Set-WindowForeground $el
        $result["activated"] = [bool]$activated
        if (-not $activated) {
          $result["warning"] = "activate:true was requested but the window could not be brought to the foreground (Windows foreground lock); the window was moved but is not foreground."
        }
      }
      return $result
    }
    "ocr" {
      # OCR the target window (or the whole desktop) — the fallback for
      # UIA-blind apps (games, self-drawn Tk/Qt, RDP, canvases). Word boxes
      # come back in SCREEN coordinates. With `query`, matched words are also
      # upgraded to the underlying UIA control (FromPoint), so the model can
      # then invoke/click the real control instead of the glyph.
      $scope = Get-Prop $inputObject "scope" "active_window"
      $maxWidth = [int](Get-Prop $inputObject "maxWidth" 1920)
      $query = [string](Get-Prop $inputObject "query" "")
      $winEl = $null
      $activationRefused = $false
      if (Has-WindowTarget $inputObject) {
        $winEl = Resolve-TargetWindow $inputObject
        # Capture happens on screen pixels: an occluded window would OCR the
        # overlapping content, so honour activate:true before capturing. A
        # refused activation degrades the capture but is not fatal — warn.
        if ([bool](Get-Prop $inputObject "activate" $false) -and -not (Set-WindowForeground $winEl)) {
          $activationRefused = $true
        }
      } elseif ($scope -ne "desktop") {
        $winEl = Get-ScopeRoot $scope $inputObject
      }
      $shot = Capture-Screenshot -WindowElement $winEl -MaxWidth $maxWidth
      if ($shot.windowCaptureFailed) { throw "OCR target has no capturable surface (minimized/hidden?). Restore the window and retry." }
      $origX = [int]$shot.bounds.x
      $origY = [int]$shot.bounds.y
      $scale = 1.0
      if ($null -ne $shot.imageScale) { $scale = [double]$shot.imageScale }
      $ocr = Invoke-Ocr -PngPath $shot.path
      $lines = @()
      foreach ($line in $ocr.lines) {
        $words = @()
        foreach ($w in $line.words) {
          $words += [ordered]@{
            text = $w.text
            x = [int]($origX + ($w.x / $scale))
            y = [int]($origY + ($w.y / $scale))
            width = [int]($w.width / $scale)
            height = [int]($w.height / $scale)
          }
        }
        $lines += [ordered]@{ text = $line.text; words = $words }
      }
      # OCR -> control upgrade: for lines containing the query, hit-test the
      # matched word's center with UIA FromPoint and report the control there.
      $matched = @()
      if ($query.Length -gt 0 -and $lines.Count -gt 0) {
        foreach ($line in $lines) {
          if ($matched.Count -ge 3) { break }
          $lineText = [string]$line.text
          $idx = $lineText.IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase)
          if ($idx -lt 0) { continue }
          $words = @($line.words)
          if ($words.Count -eq 0) { continue }
          # Map the match's char offset to a word (words join with one space).
          $pos = 0
          $word = $words[0]
          foreach ($w in $words) {
            $wlen = ([string]$w.text).Length
            if ($pos -le $idx -and $idx -lt ($pos + $wlen)) { $word = $w; break }
            $pos += $wlen + 1
          }
          $wx = [int]([int]$word.x + [int]($word.width / 2))
          $wy = [int]([int]$word.y + [int]($word.height / 2))
          $ctl = $null
          $el = Invoke-Safe { [System.Windows.Automation.AutomationElement]::FromPoint((New-Object System.Windows.Point($wx, $wy))) } $null
          if ($null -ne $el) {
            $ctl = [ordered]@{
              controlType = Get-ControlTypeName (Invoke-Safe { $el.Current.ControlType } $null)
              name = Invoke-Safe { $el.Current.Name } ""
              automationId = Invoke-Safe { $el.Current.AutomationId } ""
              className = Invoke-Safe { $el.Current.ClassName } ""
              boundingBox = Convert-Rect (Invoke-Safe { $el.Current.BoundingRectangle } $null)
            }
          }
          $matched += [ordered]@{ line = $lineText; word = [ordered]@{ text = $word.text; x = $wx; y = $wy }; control = $ctl }
        }
      }
      $result = [ordered]@{
        ok = $true
        action = "ocr"
        text = $ocr.text
        lines = $lines
        image = $shot.path
        imageBounds = $shot.bounds
        source = if ($winEl -ne $null) { "window" } else { "desktop" }
      }
      if ($query.Length -gt 0) {
        $result["query"] = $query
        $result["matched"] = $matched
        if ($matched.Count -eq 0) { $result["note"] = "No OCR line contained the query; the text may be split across words differently. Try a shorter query or read 'lines' directly." }
      }
      if ($activationRefused) {
        $result["warning"] = "activate:true was requested but the window could not be brought to the foreground (Windows foreground lock); the capture may show overlapping content."
      }
      return $result
    }
    "wait" {
      $milliseconds = [int](Get-Prop $inputObject "milliseconds" 500)
      Start-Sleep -Milliseconds $milliseconds
      return ([ordered]@{ ok = $true; action = "wait"; milliseconds = $milliseconds })
    }
    default {
      return $null
    }
  }
}

# ============================================================================
# Entry points
# ============================================================================

Load-Assemblies
Set-DpiAware

if ($Persistent) {
  # Persistent mode: one JSON request per stdin line, one JSON response per
  # stdout line. Stays alive between actions so repeated calls skip process
  # startup, assembly loading and native-DLL resolution entirely.
  while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $req = $null
    try { $req = $line | ConvertFrom-Json } catch { continue }
    $id = Get-Prop $req "id" 0
    $name = [string](Get-Prop $req "action" "")
    $result = $null
    try {
      $result = Invoke-Action -Action $name -InputObject (Get-Prop $req "args" $null)
      if ($null -eq $result) { throw "Unknown action '$name'." }
    } catch {
      $result = [ordered]@{
        ok = $false
        action = $name
        error = $_.Exception.Message
        category = $_.CategoryInfo.Category.ToString()
        scriptStackTrace = $_.ScriptStackTrace
        code = if ($_.Exception.Message -match '^([A-Z_]+):') { $Matches[1] } else { 'BACKEND_REJECTED' }
        dispatched = -not ($_.Exception.Message -match '(?i)No (input|text|replacement) (was )?sent|input was NOT sent|^(FOCUS_CHANGED|CONTENT_CHANGED|WINDOW_CHANGED|POINT_OCCLUDED|POINT_OUTSIDE_TARGET):')
      }
    }
    $result["id"] = $id
    Write-Host ($result | ConvertTo-Json -Depth 50 -Compress)
    [Console]::Out.Flush()
  }
  exit 0
} else {
  if ([string]::IsNullOrWhiteSpace($Action)) {
    Write-Host ([ordered]@{ ok = $false; error = "No action given. Pass -Action <name>, or run with -Persistent for the line protocol." } | ConvertTo-Json -Depth 50 -Compress)
    exit 1
  }
  $inputObject = Get-InputObject
  $result = $null
  try {
    $result = Invoke-Action -Action $Action -InputObject $inputObject
    if ($null -eq $result) { throw "Unknown action '$Action'." }
  } catch {
    $result = [ordered]@{
      ok = $false
      action = $Action
      error = $_.Exception.Message
      category = $_.CategoryInfo.Category.ToString()
      scriptStackTrace = $_.ScriptStackTrace
    }
  }
  Write-Host ($result | ConvertTo-Json -Depth 50 -Compress)
  if (-not $result.ok) { exit 1 }
  exit 0
}
