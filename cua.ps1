param(
  [string]$ScreenshotDir = "$env:TEMP\dsh-computer-use"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class CuaWin32
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION u; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int size);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

    public static void Mouse(uint flags, int dx, int dy, uint data)
    {
        INPUT input = new INPUT();
        input.type = 0;
        input.u.mi.dx = dx;
        input.u.mi.dy = dy;
        input.u.mi.mouseData = data;
        input.u.mi.dwFlags = flags;
        INPUT[] batch = new INPUT[] { input };
        SendInput(1, batch, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Key(ushort vk, bool up)
    {
        INPUT input = new INPUT();
        input.type = 1;
        input.u.ki.wVk = vk;
        input.u.ki.dwFlags = up ? 2u : 0u;
        INPUT[] batch = new INPUT[] { input };
        SendInput(1, batch, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Char(ushort codeUnit)
    {
        INPUT down = new INPUT();
        down.type = 1;
        down.u.ki.wVk = 0;
        down.u.ki.wScan = codeUnit;
        down.u.ki.dwFlags = 4u;
        INPUT up = down;
        up.u.ki.dwFlags = 4u | 2u;
        INPUT[] batch = new INPUT[] { down, up };
        SendInput(2, batch, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

[CuaWin32]::SetProcessDPIAware() | Out-Null

$script:state = @{}
$script:shotSeq = 0
$script:shotDir = $ScreenshotDir
if (-not (Test-Path -LiteralPath $script:shotDir)) {
  New-Item -ItemType Directory -Path $script:shotDir -Force | Out-Null
}

function Get-ProcessPath([int]$processId) {
  try { return (Get-Process -Id $processId -ErrorAction Stop).Path } catch { return $null }
}

function Get-FrameRect([IntPtr]$hwnd) {
  $rect = New-Object CuaWin32+RECT
  $hr = [CuaWin32]::DwmGetWindowAttribute($hwnd, 9, [ref]$rect, 16)
  if ($hr -eq 0 -and ($rect.Right - $rect.Left) -gt 0) { return $rect }
  [CuaWin32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
  return $rect
}

function Format-Window([IntPtr]$hwnd) {
  $title = New-Object System.Text.StringBuilder 512
  [CuaWin32]::GetWindowText($hwnd, $title, 512) | Out-Null
  $cls = New-Object System.Text.StringBuilder 256
  [CuaWin32]::GetClassName($hwnd, $cls, 256) | Out-Null
  $processId = 0
  [CuaWin32]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
  $rect = Get-FrameRect $hwnd
  return @{
    id = [int64]$hwnd.ToInt64()
    title = $title.ToString()
    className = $cls.ToString()
    app = (Get-ProcessPath $processId)
    pid = $processId
    bounds = @{ x = $rect.Left; y = $rect.Top; width = ($rect.Right - $rect.Left); height = ($rect.Bottom - $rect.Top) }
  }
}

$script:enumWindows = $null
function Get-VisibleWindows {
  $script:enumWindows = New-Object System.Collections.Generic.List[object]
  $callback = [CuaWin32+EnumWindowsProc]{
    param([IntPtr]$h, [IntPtr]$l)
    if (-not [CuaWin32]::IsWindowVisible($h)) { return $true }
    $info = Format-Window $h
    if (-not [string]::IsNullOrWhiteSpace($info.title)) { $script:enumWindows.Add($info) }
    return $true
  }
  [CuaWin32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
  $items = $script:enumWindows
  $script:enumWindows = $null
  return $items
}

function Get-ElementActions($element) {
  $actions = New-Object System.Collections.Generic.List[string]
  $pattern = $null
  foreach ($entry in @(
      @{ Name = 'Invoke'; Type = [System.Windows.Automation.InvokePattern] },
      @{ Name = 'Value'; Type = [System.Windows.Automation.ValuePattern] },
      @{ Name = 'Toggle'; Type = [System.Windows.Automation.TogglePattern] },
      @{ Name = 'Select'; Type = [System.Windows.Automation.SelectionItemPattern] },
      @{ Name = 'ExpandCollapse'; Type = [System.Windows.Automation.ExpandCollapsePattern] },
      @{ Name = 'Scroll'; Type = [System.Windows.Automation.ScrollPattern] },
      @{ Name = 'Text'; Type = [System.Windows.Automation.TextPattern] }
    )) {
    try {
      $pattern = $null
      if ($element.TryGetCurrentPattern($entry.Type.Pattern, [ref]$pattern)) { $actions.Add($entry.Name) }
    } catch { }
  }
  return $actions.ToArray()
}

function Format-ElementLine([int]$index, $element, [int]$depth) {
  $name = ''
  try { $name = [string]$element.Current.Name } catch { }
  if ($name.Length -gt 80) { $name = $name.Substring(0, 80) + '...' }
  $name = $name -replace '[\r\n\t]+', ' '
  $type = ''
  try { $type = $element.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { }
  $automationId = ''
  try { $automationId = [string]$element.Current.AutomationId } catch { }
  $actions = Get-ElementActions $element
  $line = ('{0}{1} {2} "{3}"' -f ('  ' * [Math]::Min($depth, 12)), $index, $type, $name)
  if ($automationId -ne '') { $line += (' id=' + $automationId) }
  if ($actions.Count -gt 0) { $line += (' [' + ($actions -join ',') + ']') }
  return $line
}

function Get-WindowState([IntPtr]$hwnd, [bool]$includeScreenshot, [bool]$includeText) {
  if (-not [CuaWin32]::IsWindow($hwnd)) { throw "window $($hwnd.ToInt64()) no longer exists" }
  $window = Format-Window $hwnd
  $elements = New-Object System.Collections.Generic.List[object]
  $lines = New-Object System.Collections.Generic.List[string]
  if ($includeText) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
      $finder = New-Object System.Windows.Automation.TreeWalker([System.Windows.Automation.TreeWalker]::RawViewWalker.Condition)
      $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $limit = [Math]::Min($all.Count, 400)
      for ($i = 0; $i -lt $limit; $i++) {
        $element = $all.Item($i)
        $elements.Add($element)
        $lines.Add((Format-ElementLine $elements.Count $element 0))
      }
      if ($all.Count -gt $limit) { $lines.Add(("... {0} more elements omitted" -f ($all.Count - $limit))) }
    } catch {
      $lines.Add(('accessibility unavailable: ' + $_.Exception.Message))
    }
  }
  $screenshots = @()
  if ($includeScreenshot) {
    $shot = Save-WindowScreenshot $hwnd
    $screenshots = @($shot)
  }
  $documentText = $null
  $selectedText = $null
  if ($includeText) {
    foreach ($element in $elements) {
      $pattern = $null
      try {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) { continue }
      } catch { continue }
      try {
        $documentText = [string]$pattern.DocumentRange.GetText(8000)
        try { $selection = $pattern.GetSelection(); if ($selection.Count -gt 0) { $selectedText = $selection[0].GetText(2000) } } catch { }
      } catch { }
      break
    }
  }
  $focused = $null
  try {
    $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -ne $focusedElement) {
      $focusedType = $focusedElement.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      $focused = ('{0} "{1}"' -f $focusedType, ([string]$focusedElement.Current.Name))
    }
  } catch { }
  $previous = $script:state[[int64]$hwnd]
  if ($null -ne $previous -and (-not $includeScreenshot) -and $previous.screenshot.Count -gt 0) {
    $screenshots = $previous.screenshot
  }
  $script:state[[int64]$hwnd] = @{ elements = $elements; screenshot = $screenshots }
  return @{
    window = $window
    accessibility = @{
      tree = ($lines -join "`n")
      document_text = $documentText
      focused_element = $focused
      selected_text = $selectedText
    }
    screenshots = $screenshots
  }
}

function Save-WindowScreenshot([IntPtr]$hwnd) {
  $rect = Get-FrameRect $hwnd
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { throw 'window has no visible bounds' }
  $script:shotSeq++
  $file = Join-Path $script:shotDir ('cua-{0}-{1}.png' -f $hwnd.ToInt64(), $script:shotSeq)
  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $hdc = $graphics.GetHdc()
  $ok = $false
  try { $ok = [CuaWin32]::PrintWindow($hwnd, $hdc, 2) } catch { $ok = $false }
  $graphics.ReleaseHdc($hdc)
  if (-not $ok) {
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $width, $height))
  }
  $graphics.Dispose()
  $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  return @{
    id = ('shot-' + $script:shotSeq)
    path = $file
    width = $width
    height = $height
    originX = $rect.Left
    originY = $rect.Top
    zIndex = 0
    window = (Format-Window $hwnd)
    coordinateGuidance = ('image is {0}x{1} px; convert image coordinates by x*{2:0.###}+{3}, y*{4:0.###}+{5}' -f $width, $height, 1, $rect.Left, 1, $rect.Top)
  }
}

function Resolve-Screenshot([string]$screenshotId, [IntPtr]$hwnd) {
  if ([string]::IsNullOrEmpty($screenshotId)) { throw 'screenshotId is required for coordinate actions' }
  foreach ($entry in $script:state.Values) {
    foreach ($shot in $entry.screenshot) {
      if ($shot.id -eq $screenshotId) {
        if ([int64]$shot.window.id -ne $hwnd.ToInt64()) { throw "screenshot $screenshotId belongs to another window" }
        return $shot
      }
    }
  }
  throw "unknown or expired screenshot $screenshotId; capture state again"
}

function Get-ScreenPointFromImage([int64]$hwnd, [string]$screenshotId, [int]$x, [int]$y) {
  $shot = Resolve-Screenshot $screenshotId ([IntPtr]$hwnd)
  $scaleX = [double]$shot.width / [double]($shot.window.bounds.width)
  $scaleY = [double]$shot.height / [double]($shot.window.bounds.height)
  $screenX = [int][Math]::Round($shot.window.bounds.x + ($x / $scaleX))
  $screenY = [int][Math]::Round($shot.window.bounds.y + ($y / $scaleY))
  return @{ x = $screenX; y = $screenY }
}

function Send-MouseClick([int]$screenX, [int]$screenY, [int]$count, [string]$button) {
  $flags = 0x8000 -bor 0x0001
  [CuaWin32]::Mouse([uint32]$flags, $screenX, $screenY, 0)
  Start-Sleep -Milliseconds 30
  $down = 0x0002
  $up = 0x0004
  switch ($button) {
    'right' { $down = 0x0008; $up = 0x0010 }
    'middle' { $down = 0x0020; $up = 0x0040 }
    default { }
  }
  for ($i = 0; $i -lt [Math]::Max(1, $count); $i++) {
    [CuaWin32]::Mouse([uint32]$flags -bor [uint32]$down, $screenX, $screenY, 0)
    Start-Sleep -Milliseconds 15
    [CuaWin32]::Mouse([uint32]$flags -bor [uint32]$up, $screenX, $screenY, 0)
    Start-Sleep -Milliseconds 15
  }
}

function Activate-Window([IntPtr]$hwnd) {
  if ([CuaWin32]::GetForegroundWindow() -eq $hwnd) { return $true }
  [CuaWin32]::ShowWindow($hwnd, 9) | Out-Null
  $currentThread = [CuaWin32]::GetCurrentThreadId()
  $targetPid = 0
  $targetThread = [CuaWin32]::GetWindowThreadProcessId($hwnd, [ref]$targetPid)
  $attached = $false
  try {
    if ($currentThread -ne $targetThread) { $attached = [CuaWin32]::AttachThreadInput($currentThread, $targetThread, $true) }
    # A synthetic Alt press releases the foreground lock for this process.
    [CuaWin32]::Key(0x12, $false)
    [CuaWin32]::Key(0x12, $true)
    [CuaWin32]::BringWindowToTop($hwnd) | Out-Null
    [CuaWin32]::SetForegroundWindow($hwnd) | Out-Null
    [CuaWin32]::SetActiveWindow($hwnd) | Out-Null
    [CuaWin32]::SetFocus($hwnd) | Out-Null
  } finally {
    if ($attached) { [CuaWin32]::AttachThreadInput($currentThread, $targetThread, $false) | Out-Null }
  }
  Start-Sleep -Milliseconds 150
  return ([CuaWin32]::GetForegroundWindow() -eq $hwnd)
}

function Assert-Foreground([IntPtr]$hwnd) {
  if (Activate-Window $hwnd) { return }
  throw 'the target window could not be brought to the foreground; Windows requires the target window to be foreground before typing, clicking by coordinate, scrolling, or dragging'
}

$script:keyNames = @{
  'Return' = 0x0D; 'Enter' = 0x0D; 'Tab' = 0x09; 'Escape' = 0x1B; 'Esc' = 0x1B; 'Space' = 0x20
  'BackSpace' = 0x08; 'Delete' = 0x2E; 'Insert' = 0x2D; 'Home' = 0x24; 'End' = 0x23
  'Page_Up' = 0x21; 'Page_Down' = 0x22; 'Prior' = 0x21; 'Next' = 0x22
  'Up' = 0x26; 'Down' = 0x28; 'Left' = 0x25; 'Right' = 0x27
  'Control_L' = 0x11; 'Control_R' = 0xA3; 'Control' = 0x11; 'Ctrl' = 0x11
  'Shift_L' = 0x10; 'Shift_R' = 0xA1; 'Shift' = 0x10
  'Alt_L' = 0x12; 'Alt_R' = 0xA5; 'Alt' = 0x12
  'period' = 0xBE; 'comma' = 0xBC; 'slash' = 0xBF; 'backslash' = 0xDC
  'semicolon' = 0xBA; 'apostrophe' = 0xDE; 'minus' = 0xBD; 'equal' = 0xBB
  'bracketleft' = 0xDB; 'bracketright' = 0xDD; 'grave' = 0xC0
}

function Get-KeyCode([string]$name) {
  $key = $name.Trim()
  if ($script:keyNames.ContainsKey($key)) { return [int]$script:keyNames[$key] }
  if ($key -match '^(?i)KP_([0-9])$') { return 0x60 + [int]$Matches[1] }
  if ($key -match '^(?i)Numpad_([0-9])$') { return 0x60 + [int]$Matches[1] }
  if ($key -match '^(?i)F([0-9]{1,2})$') { return 0x6F + [int]$Matches[1] }
  if ($key.Length -eq 1) {
    $upper = $key.ToUpperInvariant()
    $code = [int][char]$upper[0]
    if (($code -ge 0x41 -and $code -le 0x5A) -or ($code -ge 0x30 -and $code -le 0x39)) { return $code }
  }
  throw "unsupported key name: $name"
}

function Send-KeyChord([string]$chord) {
  $keys = $chord.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  if ($keys.Count -eq 0) { throw 'empty key chord' }
  $codes = @($keys | ForEach-Object { Get-KeyCode $_ })
  foreach ($code in $codes) { [CuaWin32]::Key([uint16]$code, $false); Start-Sleep -Milliseconds 15 }
  for ($i = $codes.Count - 1; $i -ge 0; $i--) { [CuaWin32]::Key([uint16]$codes[$i], $true); Start-Sleep -Milliseconds 15 }
}

function Send-Text([string]$text) {
  foreach ($ch in $text.ToCharArray()) {
    [CuaWin32]::Char([uint16][char]$ch)
    Start-Sleep -Milliseconds 8
  }
}

function Invoke-ElementAction([IntPtr]$hwnd, [int]$index) {
  $entry = $script:state[[int64]$hwnd]
  if ($null -eq $entry -or $index -lt 1 -or $index -gt $entry.elements.Count) {
    throw "element index $index is not in the latest state of this window; capture state again"
  }
  $element = $entry.elements[$index - 1]
  $pattern = $null
  foreach ($type in @(
      [System.Windows.Automation.InvokePattern],
      [System.Windows.Automation.TogglePattern],
      [System.Windows.Automation.SelectionItemPattern],
      [System.Windows.Automation.ExpandCollapsePattern]
    )) {
    try {
      $pattern = $null
      if (-not $element.TryGetCurrentPattern($type.Pattern, [ref]$pattern)) { continue }
      switch ($type.Name) {
        'InvokePattern' { $pattern.Invoke(); return 'invoked' }
        'TogglePattern' { $pattern.Toggle(); return 'toggled' }
        'SelectionItemPattern' { $pattern.Select(); return 'selected' }
        'ExpandCollapsePattern' { $pattern.Expand(); return 'expanded' }
      }
    } catch { }
  }
  $point = $element.GetClickablePoint()
  Assert-Foreground $hwnd | Out-Null
  Send-MouseClick ([int]$point.X) ([int]$point.Y) 1 'left'
  return 'clicked'
}

function Invoke-Request($method, $params) {
  switch ($method) {
    'list_windows' {
      return @(Get-VisibleWindows)
    }
    'list_apps' {
      $windows = @(Get-VisibleWindows)
      $apps = @{}
      foreach ($window in $windows) {
        $key = if ([string]::IsNullOrEmpty($window.app)) { 'pid:' + $window.pid } else { $window.app }
        if (-not $apps.ContainsKey($key)) {
          $apps[$key] = @{
            id = $key
            displayName = (Split-Path -Leaf $key)
            isRunning = $true
            windows = New-Object System.Collections.Generic.List[object]
          }
        }
        $apps[$key].windows.Add(@{ id = $window.id; app = $key; title = $window.title })
      }
      return @($apps.Values)
    }
    'get_window' {
      $hwnd = [IntPtr][int64]$params.window_id
      if (-not [CuaWin32]::IsWindow($hwnd)) { throw "window $($params.window_id) no longer exists" }
      return (Format-Window $hwnd)
    }
    'get_window_state' {
      $hwnd = [IntPtr][int64]$params.window_id
      $includeScreenshot = $true
      if ($null -ne $params.include_screenshot) { $includeScreenshot = [bool]$params.include_screenshot }
      $includeText = $false
      if ($null -ne $params.include_text) { $includeText = [bool]$params.include_text }
      return (Get-WindowState $hwnd $includeScreenshot $includeText)
    }
    'activate_window' {
      $hwnd = [IntPtr][int64]$params.window_id
      $activated = Activate-Window $hwnd
      return @{ activated = $activated; window = (Format-Window $hwnd) }
    }
    'click' {
      $hwnd = [IntPtr][int64]$params.window_id
      if ($null -ne $params.element_index) {
        Activate-Window $hwnd | Out-Null
        $kind = Invoke-ElementAction $hwnd ([int]$params.element_index)
        return @{ action = $kind }
      }
      if ($null -eq $params.x -or $null -eq $params.y) { throw 'click needs element_index or x/y' }
      $point = Get-ScreenPointFromImage ([int64]$hwnd) ([string]$params.screenshot_id) ([int]$params.x) ([int]$params.y)
      Assert-Foreground $hwnd | Out-Null
      $button = 'left'
      if ($null -ne $params.mouse_button) { $button = [string]$params.mouse_button }
      $count = 1
      if ($null -ne $params.click_count) { $count = [int]$params.click_count }
      Send-MouseClick $point.x $point.y $count $button
      return @{ action = 'clicked'; screen = $point }
    }
    'type_text' {
      $hwnd = [IntPtr][int64]$params.window_id
      Assert-Foreground $hwnd | Out-Null
      Send-Text ([string]$params.text)
      return @{ action = 'typed'; length = ([string]$params.text).Length }
    }
    'press_key' {
      $hwnd = [IntPtr][int64]$params.window_id
      Assert-Foreground $hwnd | Out-Null
      Send-KeyChord ([string]$params.key)
      return @{ action = 'pressed'; key = [string]$params.key }
    }
    'scroll' {
      $hwnd = [IntPtr][int64]$params.window_id
      $point = Get-ScreenPointFromImage ([int64]$hwnd) ([string]$params.screenshot_id) ([int]$params.x) ([int]$params.y)
      Assert-Foreground $hwnd | Out-Null
      $scrollY = 0; if ($null -ne $params.scrollY) { $scrollY = [int]$params.scrollY }
      $scrollX = 0; if ($null -ne $params.scrollX) { $scrollX = [int]$params.scrollX }
      [CuaWin32]::Mouse(0x8000 -bor 0x0001, $point.x, $point.y, 0)
      if ($scrollY -ne 0) {
        $steps = [Math]::Min(10, [Math]::Max(1, [Math]::Abs($scrollY) / 120))
        $delta = if ($scrollY -gt 0) { -120 } else { 120 }
        for ($i = 0; $i -lt $steps; $i++) { [CuaWin32]::Mouse(0x0800, 0, 0, [uint32]([int32]$delta)); Start-Sleep -Milliseconds 20 }
      }
      if ($scrollX -ne 0) {
        $deltaX = if ($scrollX -gt 0) { -120 } else { 120 }
        [CuaWin32]::Mouse(0x01000, 0, 0, [uint32]([int32]$deltaX))
      }
      return @{ action = 'scrolled' }
    }
    'drag' {
      $hwnd = [IntPtr][int64]$params.window_id
      $from = Get-ScreenPointFromImage ([int64]$hwnd) ([string]$params.screenshot_id) ([int]$params.from_x) ([int]$params.from_y)
      $to = Get-ScreenPointFromImage ([int64]$hwnd) ([string]$params.screenshot_id) ([int]$params.to_x) ([int]$params.to_y)
      Assert-Foreground $hwnd | Out-Null
      [CuaWin32]::Mouse(0x8000 -bor 0x0001, $from.x, $from.y, 0)
      [CuaWin32]::Mouse(0x0002, $from.x, $from.y, 0)
      for ($step = 1; $step -le 8; $step++) {
        $x = [int]($from.x + (($to.x - $from.x) * $step / 8))
        $y = [int]($from.y + (($to.y - $from.y) * $step / 8))
        [CuaWin32]::Mouse(0x8000 -bor 0x0001, $x, $y, 0)
        Start-Sleep -Milliseconds 25
      }
      [CuaWin32]::Mouse(0x0004, $to.x, $to.y, 0)
      return @{ action = 'dragged' }
    }
    'set_value' {
      $hwnd = [IntPtr][int64]$params.window_id
      $entry = $script:state[[int64]$hwnd]
      $index = [int]$params.element_index
      if ($null -eq $entry -or $index -lt 1 -or $index -gt $entry.elements.Count) { throw "element index $index is not in the latest state" }
      $element = $entry.elements[$index - 1]
      $pattern = $null
      if (-not $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { throw 'element has no ValuePattern' }
      $null = Activate-Window $hwnd
      $pattern.SetValue([string]$params.value)
      return @{ action = 'value-set' }
    }
    'perform_secondary_action' {
      $hwnd = [IntPtr][int64]$params.window_id
      $entry = $script:state[[int64]$hwnd]
      $index = [int]$params.element_index
      if ($null -eq $entry -or $index -lt 1 -or $index -gt $entry.elements.Count) { throw "element index $index is not in the latest state" }
      $element = $entry.elements[$index - 1]
      $label = ([string]$params.action).ToLowerInvariant()
      $pattern = $null
      if ($label -match 'expand|collapse|raise') {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
          if ($label -match 'collapse') { $pattern.Collapse() } else { $pattern.Expand() }
          return @{ action = $label }
        }
      }
      if ($label -match 'scroll') {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$pattern)) {
          $amount = [System.Windows.Automation.ScrollAmount]::LargeIncrement
          if ($label -match 'up') { $pattern.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, -$amount) }
          elseif ($label -match 'down') { $pattern.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, $amount) }
          elseif ($label -match 'left') { $pattern.Scroll(-$amount, [System.Windows.Automation.ScrollAmount]::NoAmount) }
          else { $pattern.Scroll($amount, [System.Windows.Automation.ScrollAmount]::NoAmount) }
          return @{ action = $label }
        }
      }
      $pattern = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return @{ action = 'invoked' }
      }
      throw "element does not support secondary action '$($params.action)'"
    }
    'launch_app' {
      $app = [string]$params.app
      if ([string]::IsNullOrWhiteSpace($app)) { throw 'launch_app needs an executable path or name' }
      $before = @{}
      foreach ($existing in (Get-VisibleWindows)) { $before[[int64]$existing.id] = $true }
      $process = Start-Process -FilePath $app -PassThru
      $exeName = Split-Path -Leaf $app
      $deadline = (Get-Date).AddSeconds(20)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $windows = @(Get-VisibleWindows | Where-Object {
            (-not $before.ContainsKey([int64]$_.id)) -and ($_.pid -eq $process.Id -or ($_.app -ne $null -and (Split-Path -Leaf $_.app) -ieq $exeName))
          })
        if ($windows.Count -gt 0) { return @{ pid = $process.Id; windows = $windows } }
      }
      return @{ pid = $process.Id; windows = @() }
    }
    'close' {
      return @{ closed = $true }
    }
    default { throw "unknown method: $method" }
  }
}

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $response = $null
  $requestId = $null
  try {
    $request = $line | ConvertFrom-Json
    $requestId = $request.id
    $result = Invoke-Request ([string]$request.method) $request.params
    $response = @{ id = $requestId; ok = $true; result = $result }
  } catch {
    $response = @{ id = $requestId; ok = $false; error = $_.Exception.Message }
  }
  $json = $response | ConvertTo-Json -Depth 10 -Compress
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}
