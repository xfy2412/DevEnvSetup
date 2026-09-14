<#
.SYNOPSIS
    One-shot dev desktop layout for this machine: opens / arranges Edge +
    Windows Terminal into the saved layout.

.DESCRIPTION
    Windows measured on \\.\DISPLAY1 (3840x2160, taskbar 108 px tall):
      1. weather   msedge  (-14,  -14) 3868x2080  (maximised, full screen)
                   https://www.weather.com.cn/weather40dn/101250502.shtml
      2. rightedge msedge  (2488,  0) 1367x2052  (right third, full height)
                   http://127.0.0.1:3080/ + deepseek chat session
      3. terminal  WindowsTerminal (-15, 0) 2557x1191
                   tab 1: dsh web, at D:\git-repo
                   tab 2: pwsh,    at D:\git-repo\ServerPluginCore
    Z-order (top -> bottom): terminal > rightedge > weather.

.PARAMETER Save
    Capture the current geometry of the matching windows into the JSON
    profile and exit.  Arrange the windows by hand first, then run -Save.

.PARAMETER ProfilePath
    Layout profile to read/write.  Defaults to WindowsLayout.json next to
    this script.

.PARAMETER NoLaunch
    Only move windows that already exist; never start new ones.

.PARAMETER NoElevate
    Do not re-launch elevated.  Windows owned by an elevated process can only
    be moved by an elevated script, so without this the script asks for
    elevation when it detects that mismatch.

.PARAMETER WhatIf
    Diagnose only: report what would be launched, adopted and moved, then stop
    without touching any window.  Combine with -Verbose to see the host chain,
    the excluded windows and the candidates.

.PARAMETER WeatherView
    After arranging the windows, replay on the weather window the gestures Edge
    has no command line for: page zoom (default 150%) and scrolling down.
    The keystrokes are only sent once the weather window is confirmed to be in
    the foreground; if that fails, nothing is injected.

.PARAMETER ZoomPercent
    Page zoom for -WeatherView.  Must be one of Edge's presets (100, 110, 125,
    150, 175, 200, ...).  Default 150.

.PARAMETER ScrollTicks
    Arrow-key presses (VK_DOWN) to scroll in -WeatherView, matching the manual
    gesture exactly.  Default 4, use 0 for no scrolling.

.PARAMETER Refresh
    Press F5 on the weather page during -WeatherView.  With -WeatherView the
    actions are always ordered refresh -> zoom -> scroll: a reload resets both
    the scroll position and the page zoom, so it has to come first.

.EXAMPLE
    .\WindowsLayout.ps1
    Move / open everything and restore the saved layout.

.EXAMPLE
    .\WindowsLayout.ps1 -Save
    Re-measure the current hand-made layout and store it as the new profile.

.NOTES
    Windows identified by process + window class + title token:
      weather    msedge / Chrome_WidgetWin_1 / title contains the weather word
      rightedge  msedge / Chrome_WidgetWin_1 / any other Edge window
      terminal   WindowsTerminal / CASCADIA_HOSTING_WINDOW_CLASS
    The terminal window hosting this script (and its ancestors) is never a
    candidate, so running the script from a terminal does not make it think a
    terminal is already available.
    All three must be open for -Save to accept the layout, otherwise the
    profile is left untouched.  Restoring never edits tabs or page contents.
    DSH's own dev server (dsh web) is never restarted by this script.
#>
[CmdletBinding()]
param(
    [switch]$Save,
    [string]$ProfilePath = (Join-Path $PSScriptRoot 'WindowsLayout.json'),
    [switch]$NoLaunch,
    [switch]$NoElevate,
    [switch]$WhatIf,
    [switch]$WeatherView,
    [int]$ZoomPercent = 150,
    [int]$ScrollTicks = 4,
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Win32 interop
# --------------------------------------------------------------------------
if (-not ('DshWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DshWin32
{
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    // Physical screen size.  Do NOT use System.Windows.Forms for this: its
    // Screen.Bounds caches the DPI-virtualised size from the moment the
    // assembly loads, so a process that declares DPI awareness afterwards still
    // reads a scaled-down size such as 1707x960 instead of 3840x2160.
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", EntryPoint="GetConsoleWindow")] static extern IntPtr NativeGetConsoleWindow();
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr token, int cls, out uint info, uint len, out uint ret);

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);


    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT
    {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    public class W
    {
        public IntPtr H;
        public string Title = "";
        public string Class = "";
        public uint Pid;
        public string Proc = "?";
        public int X, Y, Wd, Ht;
        public int ShowCmd;
        public int NX, NY, NW, NH;
        public bool Cloaked;
        public int Z;
    }

    // ---------------------------------------------------------------------
    // Enumeration is done with a *static* delegate and static staging lists.
    // Delegates created inline at the P/Invoke call site can be collected by
    // the GC mid-enumeration, which silently truncates the window list.
    // ---------------------------------------------------------------------
    static readonly EnumProc s_enumCallback = new EnumProc(Collect);
    static readonly List<IntPtr> s_h = new List<IntPtr>();
    static readonly List<string> s_title = new List<string>();
    static readonly List<string> s_class = new List<string>();
    static readonly List<uint> s_pid = new List<uint>();

    static bool Collect(IntPtr h, IntPtr lParam)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, 1024);
        string title = sb.ToString();
        if (!IsWindowVisible(h)) return true;
        if (title.Trim().Length == 0) return true;
        StringBuilder cls = new StringBuilder(256);
        GetClassNameW(h, cls, 256);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        s_h.Add(h);
        s_title.Add(title);
        s_class.Add(cls.ToString());
        s_pid.Add(pid);
        return true;
    }

    public static List<W> All()
    {
        s_h.Clear(); s_title.Clear(); s_class.Clear(); s_pid.Clear();
        EnumWindows(s_enumCallback, IntPtr.Zero);

        // Resolve process names once per pid, off the enumeration callback.
        Dictionary<uint, string> procs = new Dictionary<uint, string>();
        List<W> list = new List<W>();
        for (int i = 0; i < s_h.Count; i++)
        {
            IntPtr h = s_h[i];
            W w = new W();
            w.H = h;
            w.Title = s_title[i];
            w.Class = s_class[i];
            w.Pid = s_pid[i];
            string proc;
            if (!procs.TryGetValue(w.Pid, out proc))
            {
                try { proc = System.Diagnostics.Process.GetProcessById((int)w.Pid).ProcessName; }
                catch { proc = "?"; }
                procs[w.Pid] = proc;
            }
            w.Proc = proc;

            RECT r;
            GetWindowRect(h, out r);
            w.X = r.Left; w.Y = r.Top; w.Wd = r.Right - r.Left; w.Ht = r.Bottom - r.Top;

            WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
            wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (GetWindowPlacement(h, ref wp))
            {
                w.ShowCmd = wp.showCmd;
                w.NX = wp.rcNormalPosition.Left; w.NY = wp.rcNormalPosition.Top;
                w.NW = wp.rcNormalPosition.Right - wp.rcNormalPosition.Left;
                w.NH = wp.rcNormalPosition.Bottom - wp.rcNormalPosition.Top;
            }

            int cloaked = 0;
            try { DwmGetWindowAttribute(h, 14, out cloaked, 4); } catch { }
            w.Cloaked = cloaked != 0;
            w.Z = list.Count;
            list.Add(w);
        }
        return list;
    }

    public static List<W> Visible()
    {
        List<W> res = new List<W>();
        foreach (W w in All())
        {
            if (!IsWindowVisible(w.H)) continue;
            if (w.Cloaked) continue;
            if (w.Wd <= 0 || w.Ht <= 0) continue;
            if (w.Title.Trim().Length == 0) continue;
            res.Add(w);
        }
        return res;
    }

    // Move a window to an exact outer rectangle without disturbing z-order.
    public static void Place(IntPtr h, int x, int y, int w, int hh)
    {
        uint SWP = 0x0004 | 0x0010 | 0x0040; // NOZORDER | NOACTIVATE | SHOWWINDOW
        SetWindowPos(h, IntPtr.Zero, x, y, w, hh, SWP);
    }

    // Read one window's current outer rectangle.  A move from a process at a
    // lower integrity level than the window's owner fails silently, so the
    // caller must verify instead of trusting the return value.
    public static bool Rect(IntPtr h, out int x, out int y, out int w, out int hh)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { x = y = w = hh = 0; return false; }
        x = r.Left; y = r.Top; w = r.Right - r.Left; hh = r.Bottom - r.Top;
        return true;
    }

    // Real top-level z-order, front-most first.  Enumeration order (EnumWindows)
    // is NOT z-order and must not be used to report or verify stacking.
    public static List<IntPtr> TopLevelZOrder()
    {
        List<IntPtr> res = new List<IntPtr>();
        IntPtr h = GetTopWindow(IntPtr.Zero);
        int guard = 0;
        while (h != IntPtr.Zero && guard++ < 500)
        {
            if (IsWindowVisible(h)) res.Add(h);
            h = GetWindow(h, 2);   // GW_HWNDNEXT
        }
        return res;
    }

    // The console window of this process, i.e. the terminal window hosting the
    // script (zero when there is none).
    public static IntPtr GetConsoleWindow() { return NativeGetConsoleWindow(); }

    [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    // Current window title, used as a page-load indicator for Edge windows.
    public static string WindowTitle(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, 1024);
        return sb.ToString();
    }

    // ---------------------------------------------------------------------
    // Keyboard / mouse-wheel injection.
    //
    // Browser page zoom and scroll position cannot be expressed as an Edge
    // command line, and the scroll position is not persisted by Chromium at
    // all.  Replaying the user's own gestures (Ctrl+0/Ctrl+Plus and wheel
    // notches) is the only approach that needs no debug port, no extension and
    // no page-specific JavaScript.
    // ---------------------------------------------------------------------
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint MOUSEEVENTF_WHEEL = 0x0800;

    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }

    static void KeyEvent(ushort vk, bool up)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_KEYBOARD;
        a[0].U.ki.wVk = vk;
        a[0].U.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    static void Chord(ushort modifier, ushort key)
    {
        KeyEvent(modifier, false);
        System.Threading.Thread.Sleep(15);
        KeyEvent(key, false);
        System.Threading.Thread.Sleep(15);
        KeyEvent(key, true);
        System.Threading.Thread.Sleep(15);
        KeyEvent(modifier, true);
        System.Threading.Thread.Sleep(70);
    }

    // Reset zoom to 100% then step to the requested level, so the result does
    // not depend on the current zoom.  Chromium's "+" and "-" steps.
    public static void ApplyZoom(int stepsFrom100)
    {
        Chord(0x11, 0x30);                    // CTRL + 0  -> 100%
        System.Threading.Thread.Sleep(120);
        ushort key = stepsFrom100 >= 0 ? (ushort)0xBB : (ushort)0xBD;   // '+' : '-'
        for (int i = 0; i < Math.Abs(stepsFrom100); i++) Chord(0x11, key);
    }

    public static void WheelNotches(int notches, int screenX, int screenY)
    {
        POINT old; GetCursorPos(out old);
        SetCursorPos(screenX, screenY);
        System.Threading.Thread.Sleep(120);
        int count = Math.Abs(notches);
        for (int i = 0; i < count; i++)
        {
            INPUT[] a = new INPUT[1];
            a[0].type = INPUT_MOUSE;
            a[0].U.mi.dwFlags = MOUSEEVENTF_WHEEL;
            a[0].U.mi.mouseData = (uint)(notches < 0 ? -120 : 120);
            SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(50);
        }
        System.Threading.Thread.Sleep(150);
        SetCursorPos(old.X, old.Y);
    }

    // VK_DOWN / VK_UP, i.e. exactly the gesture used to scroll by hand.
    public static void ArrowKeys(bool down, int times)
    {
        ushort vk = down ? (ushort)0x28 : (ushort)0x26;
        for (int i = 0; i < times; i++)
        {
            KeyEvent(vk, false);
            System.Threading.Thread.Sleep(25);
            KeyEvent(vk, true);
            System.Threading.Thread.Sleep(60);
        }
    }

    public static void PressKey(ushort vk)
    {
        KeyEvent(vk, false);
        System.Threading.Thread.Sleep(25);
        KeyEvent(vk, true);
    }

    public static void RefreshPage() { PressKey(0x74); }   // VK_F5

    // Bring a window to the foreground and report whether it really got there.
    // Input injection must be skipped when this fails, otherwise the keystrokes
    // land in whatever window happens to be active.
    public static bool Activate(IntPtr h)
    {
        if (IsForeground(h)) return true;
        ShowWindow(h, 9);                     // SW_RESTORE (also un-minimises)
        SetForegroundWindow(h);
        for (int i = 0; i < 10; i++)
        {
            System.Threading.Thread.Sleep(120);
            if (IsForeground(h)) return true;
            SetForegroundWindow(h);
        }
        return IsForeground(h);
    }

    // Raise a window to the front when a plain SetWindowPos(HWND_TOP) has no
    // effect.  On this machine SetWindowPos reordering does nothing at all - it
    // returns success and the z-order never changes (verified by raising the
    // same window eight times in a row), while BringWindowToTop +
    // SetForegroundWindow DOES reorder.  This is what the final stacking pass
    // uses.
    public static bool ActivateTopmost(IntPtr h)
    {
        ShowWindow(h, 9);
        BringWindowToTop(h);
        bool fg = SetForegroundWindow(h);
        System.Threading.Thread.Sleep(200);
        return fg || IsForeground(h);
    }

    // True only when the console window really is a terminal window.
    //
    // Inside Windows Terminal GetConsoleWindow() returns a HIDDEN
    // PseudoConsoleWindow with a 0x0 rect, owned by the shell - not the visible
    // terminal window.  Classifying it as a terminal made the script hide the
    // home window and start a duplicate terminal, so a usable size is required
    // in addition to the class.
    public static bool IsConsoleTerminal(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        StringBuilder cls = new StringBuilder(256);
        GetClassNameW(h, cls, 256);
        string c = cls.ToString();
        if (c == "CASCADIA_HOSTING_WINDOW_CLASS") return true;
        if (c == "ConsoleWindowClass" || c == "PseudoConsoleWindow")
        {
            RECT r;
            if (!GetWindowRect(h, out r)) return false;
            return (r.Right - r.Left) > 0 && (r.Bottom - r.Top) > 0;
        }
        return false;
    }

    public static uint WindowPid(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    // WINDOWPLACEMENT.showCmd == 3 means maximised.  A maximised window
    // swallows a SetWindowPos move, so it has to be restored first.
    public static bool IsMaximized(IntPtr h)
    {
        WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
        wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(h, ref wp)) return false;
        return wp.showCmd == 3;
    }

    public static void Restore(IntPtr h)
    {
        ShowWindow(h, 9);   // SW_RESTORE
    }

    // TokenElevation (class 20) -> BOOLEAN.  pid 0 means "this process".
    public static bool IsElevated(uint pid)
    {
        IntPtr h = pid == 0 ? GetCurrentProcess() : OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) return false;
        IntPtr tok;
        if (!OpenProcessToken(h, 0x0008, out tok)) { if (pid != 0) CloseHandle(h); return false; }
        uint info, ret;
        bool elevated = GetTokenInformation(tok, 20, out info, 4, out ret) && info != 0;
        CloseHandle(tok);
        if (pid != 0) CloseHandle(h);
        return elevated;
    }
}
'@
}

# Physical pixels, no DPI virtualisation (PER_MONITOR_AWARE_V2).
try { [void][DshWin32]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
# Title classifiers keep non-ASCII text out of this script file (a UTF-8
# script without BOM is read as ANSI by Windows PowerShell 5.1, which would
# corrupt literal CJK patterns).  \uXXXX is handled by the .NET regex engine.
function Get-TitlePattern {
    param([string]$Token)
    switch ($Token) {
        # Edge titles the weather page with the "Guiyang weather" wording in
        # corner brackets; this token is the "weather" word (U+5929 U+6C14)
        # and also appears in that page's own tab title.  The script file is
        # kept pure ASCII, so the token is built from code points rather than
        # a literal string.
        'weather' { return (-join ([char]0x5929, [char]0x6C14)) }
        default   { return $Token }
    }
}

# Walk up from this process to (and including) the terminal host.  Used as a
# fallback host test when the console window does not belong to a terminal.
function Get-ScriptHostPath {
    $ids = New-Object System.Collections.Generic.List[uint32]
    $cur = [uint32]$PID
    for ($i = 0; $i -lt 16 -and $cur -ne 0; $i++) {
        [void]$ids.Add($cur)
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -eq 'WindowsTerminal.exe') { break }
        $cur = [uint32]$p.ParentProcessId
    }
    return , $ids.ToArray()
}

# The terminal window that hosts this script must not be mistaken for "a
# terminal is already available" - otherwise no terminal is started.
#
# Only the *host window* is excluded, never the whole owning process: one
# WindowsTerminal.exe process owns every terminal window of that instance,
# including any window this script launches, so excluding by pid would throw
# away the very window we just created.
# Which windows must never be treated as layout targets?
#
# This is deliberately based on the parent chain, not on GetConsoleWindow()
# alone: inside Windows Terminal the console window is a HIDDEN pseudoconsole
# whose owner reports as the shell (pwsh), not as WindowsTerminal, so a
# "is the console a terminal?" test says no even though the script is clearly
# running inside a terminal window.
#
# Two different situations have to be told apart:
#   * this shell IS hosted by a terminal (pwsh inside Windows Terminal, or a
#     shell inside conhost that itself sits under Windows Terminal) -> only the
#     terminal window(s) in the chain are excluded, so the home window stays
#     the target;
#   * this shell is some unrelated host (explorer -> cmd -> pwsh, VS Code,
#     node, ...) -> its ancestor windows are excluded so the script cannot grab
#     the window of the app that launched it.
function Get-ExcludedWindows {
    param([long[]]$HostIds, $all)

    $console = [DshWin32]::GetConsoleWindow()
    $excluded = New-Object System.Collections.Generic.List[long]
    $hostTerminalWindows = New-Object System.Collections.Generic.List[long]

    if ($console -ne [IntPtr]::Zero) {
        [void]$excluded.Add([long]$console)
    }

    # Terminal windows belonging to the host chain ARE the home window(s): this
    # shell's tabs live in one of them.  They must be offered to the layout, not
    # hidden from it - that is what makes "run from the home terminal and
    # position it" work.  Only the hidden console handle is excluded.
    foreach ($w in $all) {
        if ($w.Class -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { continue }
        if ($HostIds -contains $w.Pid) { [void]$hostTerminalWindows.Add([long]$w.H) }
    }

    return [pscustomobject]@{
        Excluded            = $excluded.ToArray()
        HostIsTerminal      = ($hostTerminalWindows.Count -gt 0)
        HostTerminalWindows = $hostTerminalWindows.ToArray()
        ConsoleIsTerminal   = [DshWin32]::IsConsoleTerminal($console)
    }
}

function Get-Ctx {
    $hostIds = Get-ScriptHostPath
    $all = [DshWin32]::Visible()
    $ex = Get-ExcludedWindows $hostIds $all
    [pscustomobject]@{
        All               = $all
        List              = @($all | Where-Object { $ex.Excluded -notcontains [long]$_.H })
        Claimed           = New-Object System.Collections.Generic.HashSet[long]
        HostIds             = $hostIds
        Excluded            = $ex.Excluded
        ConsoleIsTerminal   = $ex.ConsoleIsTerminal
        HostIsTerminal      = $ex.HostIsTerminal
        HostTerminalWindows = $ex.HostTerminalWindows
        Elevated            = @{}
        SelfElev            = [DshWin32]::IsElevated(0)
    }
}

function Get-ProcessElevation {
    param($ctx, [uint32]$pid)
    if ($ctx.Elevated.ContainsKey($pid)) { return $ctx.Elevated[$pid] }
    $e = [DshWin32]::IsElevated($pid)
    $ctx.Elevated[$pid] = $e
    return $e
}

function Get-WinLabel($w) {
    $t = $w.Title
    if ($t.Length -gt 64) { $t = $t.Substring(0, 61) + '...' }
    '{0} "{1}" pid={2} ({3},{4}) {5}x{6}' -f $w.Proc, $t, $w.Pid, $w.X, $w.Y, $w.Wd, $w.Ht
}

# Encode a PowerShell snippet for "pwsh -EncodedCommand".  Windows Terminal's
# command-line parser treats ';' as a tab separator even inside quotes, so a
# command containing ';' must never be passed as -Command.  Used when this
# script has to open the terminal itself (profile entry "terminal" with tabs).
function ConvertTo-EncodedCommand {
    param([Parameter(Mandatory)][string]$Script)
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

# Title test for one window against a profile match rule.  Windows that were
# launched a moment ago may still carry a stale title, which is exactly how a
# freshly opened Edge window could be claimed for the wrong entry (the weather
# entry grabbing a right-edge window, or vice versa).
function Test-WindowTitle {
    param($Win, $Rule)
    if ($Rule.titleClass) {
        $needle = Get-TitlePattern $Rule.titleClass
        if ($Win.Title.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    if ($Rule.notTitleClass) {
        $needle = Get-TitlePattern $Rule.notTitleClass
        if ($Win.Title.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    return $true
}

function Select-Window {
    param($Ctx, $Rule)

    $cand = @($Ctx.List | Where-Object {
        $_.Proc -eq $Rule.process -and -not $Ctx.Claimed.Contains([long]$_.H)
    })
    if ($Rule.class) { $cand = @($cand | Where-Object { $_.Class -eq $Rule.class }) }
    if ($Rule.titleClass) {
        $rx = Get-TitlePattern $Rule.titleClass
        $cand = @($cand | Where-Object { $_.Title -match $rx })
    }
    if ($Rule.notTitleClass) {
        $rx = Get-TitlePattern $Rule.notTitleClass
        $cand = @($cand | Where-Object { $_.Title -notmatch $rx })
    }
    if ($cand.Count -eq 0) { return $null }

    $pick = if ($Rule.pick) { $Rule.pick } else { 'first' }
    $sel = switch ($pick) {
        'largest' { $cand | Sort-Object { $_.Wd * $_.Ht } -Descending | Select-Object -First 1 }
        'widest'  { $cand | Sort-Object Wd -Descending | Select-Object -First 1 }
        'newest'  { $cand | Sort-Object Pid -Descending | Select-Object -First 1 }
        'oldest'  { $cand | Sort-Object Pid | Select-Object -First 1 }
        default   { $cand | Sort-Object Pid | Select-Object -First 1 }
    }
    [void]$Ctx.Claimed.Add([long]$sel.H)
    return $sel
}

function Test-Rect {
    param($w, $rect)
    return ($w.X -eq $rect.x -and $w.Y -eq $rect.y -and $w.Wd -eq $rect.w -and $w.Ht -eq $rect.h)
}

# Replay the user's own gestures on the weather window: reset zoom, step it up,
# then scroll with wheel notches.  Edge has no command line for page zoom and
# Chromium does not persist scroll position, so this is the only approach that
# needs no debug port, no extension and no page-specific JavaScript.
#
# SAFETY: the keystrokes are only sent after the target window is confirmed to
# be the foreground window.  If activation fails, nothing is injected - the
# input would otherwise land in whatever window happens to be active.
function Set-WeatherView {
    param($Ctx, [int]$ZoomPercent = 150, [int]$ScrollTicks = 4, [switch]$Refresh)

    $entry = $profile.windows | Where-Object { $_.id -eq 'weather' } | Select-Object -First 1
    if (-not $entry) { Write-Warning 'profile has no weather entry'; return }

    $ctx = Get-Ctx
    $w = Select-Window -Ctx $ctx -Rule $entry.match
    if (-not $w) {
        Write-Warning 'weather window not found; nothing to zoom or scroll'
        return
    }

    # One activation for the whole sequence.  Nothing else touches this window
    # until it is done, so it stays in the foreground throughout.
    if (-not [DshWin32]::Activate($w.H)) {
        Write-Warning ('could not bring the weather window to the foreground (hwnd={0}); keystrokes were NOT sent' -f $w.H)
        Write-Warning 'Click the weather window and re-run, or run this mode interactively.'
        return
    }

    # ORDER: refresh -> short settle -> zoom -> scroll.
    #
    # F5 must come first because a reload resets both the scroll position and
    # the page zoom.
    if ($Refresh) {
        [DshWin32]::RefreshPage()
        Write-Host '  weather    pressed F5 to refresh' -ForegroundColor Green
        Start-Sleep -Milliseconds 1500
    }

    # Chromium's zoom steps are level-relative and ROUNDED, not a clean x1.2
    # chain: 100 -> 110 -> 125 -> 150 -> 175 -> 200 -> 250 ...
    # (verified on this machine: 150% needs THREE Ctrl+'+' presses from 100%).
    # Only the zoom level matters; the factor differs per browser version.
    $zoomTable = @{
        25 = -12; 33 = -9; 50 = -5; 67 = -3; 75 = -2; 80 = -2; 90 = -1; 100 = 0
        110 = 1; 125 = 2; 150 = 3; 175 = 4; 200 = 5; 250 = 7; 300 = 8; 400 = 10; 500 = 11
    }
    if (-not $zoomTable.ContainsKey([int]$ZoomPercent)) {
        Write-Warning ('zoom {0}% is not one of Edge''s presets: {1}' -f $ZoomPercent, (($zoomTable.Keys | Sort-Object) -join ', '))
        return
    }
    $steps = $zoomTable[[int]$ZoomPercent]
    [DshWin32]::ApplyZoom([int]$steps)
    Write-Host ('  weather    zoom set to {0}% ({1} step(s) from 100%)' -f $ZoomPercent, $steps) -ForegroundColor Green

    # Last: the scroll offset must survive, so nothing may reload after it.
    if ($ScrollTicks -ne 0) {
        [DshWin32]::ArrowKeys($true, [Math]::Abs($ScrollTicks))
        Write-Host ('  weather    pressed Down {0} time(s)' -f [Math]::Abs($ScrollTicks)) -ForegroundColor Green
    }
}

# Move a window and confirm it actually landed.  SetWindowPos reports success
# even when UIPI blocks the move, and a maximised window ignores a plain move,
# so the maximised state is cleared first and the result read back.
function Move-WindowTo {
    param([IntPtr]$Handle, $rect, [switch]$Restore)
    if ($Restore) {
        if ([DshWin32]::IsMaximized($Handle)) {
            [DshWin32]::Restore($Handle)
            Start-Sleep -Milliseconds 180
        }
    }
    [DshWin32]::Place($Handle, $rect.x, $rect.y, $rect.w, $rect.h)
    Start-Sleep -Milliseconds 150
    $x = 0; $y = 0; $w = 0; $h = 0
    if (-not [DshWin32]::Rect($Handle, [ref]$x, [ref]$y, [ref]$w, [ref]$h)) {
        return [pscustomobject]@{ Ok = $false; X = 0; Y = 0; W = 0; H = 0 }
    }
    $ok = ($x -eq $rect.x -and $y -eq $rect.y -and $w -eq $rect.w -and $h -eq $rect.h)
    return [pscustomobject]@{ Ok = $ok; X = $x; Y = $y; W = $w; H = $h }
}

# --------------------------------------------------------------------------
# Load profile
# --------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Layout profile not found: $ProfilePath`nRun '.\WindowsLayout.ps1 -Save' after arranging the windows by hand."
}
$profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json

# The monitor the profile was measured on (falls back to the current one).
function Get-ProfileMonitor {
    $mon = $profile.monitor
    if ($mon -and $mon.bounds) { return $mon.bounds }
    return (Get-CurrentMonitor)
}

# Physical screen size, straight from Win32 so the value is never the
# DPI-virtualised one (see the note on GetSystemMetrics above).
function Get-CurrentMonitor {
    return [pscustomobject]@{
        x = 0
        y = 0
        w = [DshWin32]::GetSystemMetrics(0)   # SM_CXSCREEN
        h = [DshWin32]::GetSystemMetrics(1)   # SM_CYSCREEN
    }
}

# The recorded rectangles carry the few pixels of invisible resize border that
# a maximised / aero-snapped window hangs past the screen edge (e.g. -14, 3868).
#
# They are also tied to the monitor the profile was recorded on.  If the display
# layout differs now (resolution change, another monitor), the rectangles are
# scaled proportionally so a full-screen window stays full screen and an
# edge-anchored window stays on the same edge; otherwise a window measured at
# 3840 wide would be clamped into nonsense on a smaller screen.
function Resolve-Rect {
    param($rect, $bounds, [int]$slack = 32)

    $x = [int]$rect.x; $y = [int]$rect.y; $w = [int]$rect.w; $h = [int]$rect.h

    $pm = Get-ProfileMonitor
    $cm = Get-CurrentMonitor
    if ($pm -and $cm -and $pm.w -gt 0 -and $pm.h -gt 0 -and
        ($pm.w -ne $cm.w -or $pm.h -ne $cm.h)) {

        $sx = $cm.w / $pm.w
        $sy = $cm.h / $pm.h

        # anchor: keep the window on the same screen edge / corner it had
        $storedX = $x - [int]$pm.x
        $toX = if ($storedX -le 4) { [int]$cm.x }
               elseif (($storedX + $w) -ge ([int]$pm.x + [int]$pm.w - 4)) { [int]$cm.x + [int]$cm.w - $w }
               else { [int]$cm.x + [int][Math]::Round($storedX * $sx) }

        $storedY = $y - [int]$pm.y
        $toY = if ($storedY -le 4) { [int]$cm.y }
               elseif (($storedY + $h) -ge ([int]$pm.y + [int]$pm.h - 4)) { [int]$cm.y + [int]$cm.h - $h }
               else { [int]$cm.y + [int][Math]::Round($storedY * $sy) }

        Write-Verbose ('rescale {0}: profile monitor {1}x{2} -> now {3}x{4}; rect ({5},{6}) {7}x{8} -> ({9},{10})' -f `
                'window', $pm.w, $pm.h, $cm.w, $cm.h, $x, $y, $w, $h, $toX, $toY)
        $x = $toX; $y = $toY
    }

    if ($bounds) {
        $x = [Math]::Max([int]$bounds.x - $slack, [Math]::Min($x, [int]$bounds.x + [int]$bounds.w - $w + $slack))
        $y = [Math]::Max([int]$bounds.y - $slack, [Math]::Min($y, [int]$bounds.y + [int]$bounds.h - $h + $slack))
    }
    return [pscustomobject]@{ x = $x; y = $y; w = $w; h = $h }
}

# ==========================================================================
#  -Save : capture the hand-made layout
# ==========================================================================
if ($Save) {
    $ctx = Get-Ctx
    $saved = @()
    foreach ($entry in $profile.windows) {
        $w = Select-Window -Ctx $ctx -Rule $entry.match
        if (-not $w) {
            Write-Warning ("no window matched id '{0}' ({1})" -f $entry.id, $entry.match.process)
            continue
        }
        $entry.rect = [pscustomobject]@{ x = $w.X; y = $w.Y; w = $w.Wd; h = $w.Ht }
        $saved += [pscustomobject]@{ id = $entry.id; rect = $entry.rect; window = (Get-WinLabel $w); showCmd = $w.ShowCmd; handle = [long]$w.H }
    }

    # Never store a partial layout: a miss here would later make the restore
    # move the wrong window into that slot.
    if ($saved.Count -ne @($profile.windows).Count) {
        Write-Host ''
        Write-Warning ("only {0} of {1} windows matched; profile NOT saved." -f $saved.Count, @($profile.windows).Count)
        Write-Host 'Make sure every window is open, then re-run with -Save.'
        exit 1
    }

    # z-order: zOrder is 0 for the bottom-most window; zOrderTopToBottom is
    # ordered top -> bottom, so it is the reverse of an ascending zOrder sort.
    $z = @($ctx.List | Sort-Object Z)
    $order = @()
    foreach ($s in $saved) {
        $idx = [array]::IndexOf(($z | ForEach-Object { [long]$_.H }), [long]$s.handle)
        $order += [pscustomobject]@{ id = $s.id; zIndex = $idx }
    }
    $profile.zOrderTopToBottom = @($order | Sort-Object zIndex -Descending | ForEach-Object { $_.id })

    $json = $profile | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($ProfilePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host 'Saved layout:' -ForegroundColor Green
    foreach ($s in $saved) {
        Write-Host ('  {0,-10} ({1},{2}) {3}x{4}   <- {5}' -f $s.id, $s.rect.x, $s.rect.y, $s.rect.w, $s.rect.h, $s.window)
    }
    Write-Host ('  z-order (top->bottom): {0}' -f ($profile.zOrderTopToBottom -join ' > '))
    Write-Host ('  profile: {0}' -f $ProfilePath)
    return
}

# ==========================================================================
#  Normal run : launch what is missing, then restore geometry + z-order
# ==========================================================================
Write-Host '=== dev desktop layout ===' -ForegroundColor Cyan

$lim = Get-CurrentMonitor
$ctx = Get-Ctx
$plan = @()

# Diagnostics: show what this script considers its own host, so a wrong
# exclusion is visible instead of silently hiding a window.
if ($VerbosePreference -ne 'SilentlyContinue') {
    Write-Host ('  this shell : pid={0} elevated={1} console-hwnd={2} console-is-terminal={3} host-is-terminal={4}' -f `
            $PID, $ctx.SelfElev, [DshWin32]::GetConsoleWindow(), $ctx.ConsoleIsTerminal, $ctx.HostIsTerminal)
    if ($ctx.HostTerminalWindows.Count -gt 0) {
        Write-Host ('  home win   : {0}  (this shell''s own terminal; offered to the layout)' -f ($ctx.HostTerminalWindows -join ', '))
    }

    # the parent chain, and whether any of it owns a visible window
    Write-Host '  host chain :'
    foreach ($hp in $ctx.HostIds) {
        $procName = '?'
        try { $procName = (Get-Process -Id $hp -ErrorAction Stop).ProcessName } catch { }
        $owned = @($ctx.All | Where-Object { $_.Pid -eq $hp })
        $ownerText = if ($owned.Count -gt 0) {
            ($owned | ForEach-Object { '({0},{1}) {2}x{3} [{4}]' -f $_.X, $_.Y, $_.Wd, $_.Ht, $_.Title.Substring(0, [Math]::Min(30, $_.Title.Length)) }) -join ' + '
        } else { '(no visible window)' }
        Write-Host ('    pid={0,-8} {1,-22} {2}' -f $hp, $procName, $ownerText)
    }

    Write-Host '  excluded   :'
    $byH = @{}
    foreach ($w in $ctx.All) { $byH[[long]$w.H] = $w }
    foreach ($ex in $ctx.Excluded) {
        if ($byH.ContainsKey([long]$ex)) {
            $w = $byH[[long]$ex]
            Write-Host ('    ({0},{1}) {2}x{3} pid={4} :: {5}' -f $w.X, $w.Y, $w.Wd, $w.Ht, $w.Pid, $w.Title)
        } else {
            Write-Host ('    hwnd={0} (no title / not visible)' -f $ex)
        }
    }

    Write-Host '  candidates :'
    foreach ($w in $ctx.List) {
        if ($w.Class -eq 'CASCADIA_HOSTING_WINDOW_CLASS' -or $w.Class -eq 'Chrome_WidgetWin_1') {
            Write-Host ('    pid={0,-8} ({1},{2}) {3}x{4} :: {5}' -f $w.Pid, $w.X, $w.Y, $w.Wd, $w.Ht, $w.Title.Substring(0, [Math]::Min(40, $w.Title.Length)))
        }
    }
}

# The console window that hosts this very process (possibly zero, or a hidden
# console when launched from a .bat).  It is never a layout target.
function Get-SelfConsoleWindows {
    $h = [DshWin32]::GetConsoleWindow()
    if ($h -eq [IntPtr]::Zero) { return @() }
    return , @([long]$h)
}

# A terminal window that happens to be open already is NOT this script's to# take over, and adopting it would silently skip creating the required tabs.
# The one exception is the window hosting this script when that host IS a
# terminal (running the script from inside the layout's own terminal): then
# positioning it is exactly what the user asked for.
function Test-AdoptableTerminal {
    param($Ctx, $Win)
    $selfConsoles = Get-SelfConsoleWindows
    if ($selfConsoles -contains [long]$Win.H) { return $false }
    return ($Ctx.HostTerminalWindows -contains [long]$Win.H)
}

foreach ($entry in $profile.windows) {
    $isTerminalEntry = ($entry.match.process -eq 'WindowsTerminal')
    $adopt = $null
    while ($true) {
        $w = Select-Window -Ctx $ctx -Rule $entry.match
        if (-not $w) { break }
        if (-not $isTerminalEntry) { $adopt = $w; break }
        if (Test-AdoptableTerminal $ctx $w) { $adopt = $w; break }
        # Not ours to take over (a terminal the user already had open, or this
        # script's own console).  Select-Window already marked it as claimed,
        # so the next call moves on to the following candidate.
    }
    if ($adopt) {
        $plan += [pscustomobject]@{ Entry = $entry; Win = $adopt; Existed = $true }
    } else {
        $plan += [pscustomobject]@{ Entry = $entry; Win = $null; Existed = $false }
    }
}

# ---- elevation pre-flight ---------------------------------------------------
if ($WhatIf) {
    Write-Host ''
    Write-Host 'what-if plan (nothing was moved or launched):' -ForegroundColor Cyan
    foreach ($p in $plan) {
        if ($p.Win) {
            Write-Host ('  {0,-10} adopt existing  {1}' -f $p.Entry.id, (Get-WinLabel $p.Win))
        } else {
            Write-Host ('  {0,-10} WOULD LAUNCH     (no matching window found)' -f $p.Entry.id) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host 'done (what-if).'
    return
}

# A process cannot move a window owned by a higher integrity level process:
# SetWindowPos reports success but nothing happens.  Detect it up front and
# re-launch elevated instead of printing a misleading "moved" line.
$selfElevated = $ctx.SelfElev
$elevBlocked = @()
if (-not $selfElevated) {
    foreach ($p in $plan) {
        if ($p.Win -and (Get-ProcessElevation $ctx ([uint32]$p.Win.Pid))) {
            $elevBlocked += $p.Entry.id
        }
    }
}

if ($elevBlocked.Count -gt 0) {
    if ($NoElevate) {
        Write-Warning ('window(s) {0} belong to an elevated process; this shell is not elevated, so they cannot be moved.' -f ($elevBlocked -join ', '))
        Write-Warning 'Re-run from an Administrator terminal, or drop -NoElevate to get a UAC prompt.'
    } else {
        Write-Host ''
        Write-Host ('window(s) {0} are owned by an elevated process - re-launching this script elevated (UAC)...' -f ($elevBlocked -join ', ')) -ForegroundColor Yellow
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        if ($Save) { $relaunch += '-Save' }
        if ($NoLaunch) { $relaunch += '-NoLaunch' }
        if ($ProfilePath -ne (Join-Path $PSScriptRoot 'WindowsLayout.json')) {
            $relaunch += @('-ProfilePath', ('"{0}"' -f $ProfilePath))
        }
        $relaunch += '-NoElevate'
        try {
            Start-Process 'pwsh' -Verb RunAs -ArgumentList $relaunch -Wait
        } catch {
            Write-Warning ('elevation was cancelled or failed: {0}' -f $_.Exception.Message)
            Write-Warning 'Falling back to this shell; elevated windows will not move.'
        }
        return
    }
}

# ---- launch missing windows -------------------------------------------------
if (-not $NoLaunch) {
    $missing = @($plan | Where-Object { -not $_.Existed })
    if ($missing.Count -gt 0) {
        Write-Host ('launching {0} missing window(s)...' -f $missing.Count)

        # Snapshot every window that already exists.  A terminal window that is
        # already on screen (for example one the user opened by hand) is NOT
        # this script's to take over: it must not be mistaken for "the terminal
        # the layout asked for", otherwise no tabs are created.  Only a window
        # that appears AFTER this point counts as newly launched.
        $before = @{}
        foreach ($w in $ctx.All) { $before[[long]$w.H] = $true }

        foreach ($m in ($missing | Sort-Object { $_.Entry.launchOrder })) {
            $e = $m.Entry
            $url = [string]$e.launch
            $extra = @($e.extraUrls | Where-Object { $_ })

            # no URL configured for this entry -> nothing to open
            if ([string]::IsNullOrWhiteSpace($url) -and $extra.Count -eq 0) { continue }

            switch ($e.id) {
                'weather' {
                    Start-Process 'msedge' -ArgumentList @('--new-window', $url)
                }
                'rightedge' {
                    Start-Process 'msedge' -ArgumentList (@('--new-window', $url) + $extra)
                }
                'terminal' {
                    $tabs = $profile.terminal.tabs

                    # Built as ONE command line and handed to cmd /c.  Handing
                    # wt.exe an argument array does not survive the quoting, and
                    # a plain '-Command "a; b"' is split by wt's OWN parser into
                    # extra tabs (verified: it produced 4 tabs instead of 2).
                    # -EncodedCommand keeps an embedded ';' inside one argument.
                    # "-w new" forces a new window instead of reusing one.
                    $line = 'wt.exe -w new'
                    for ($i = 0; $i -lt $tabs.Count; $i++) {
                        if ($i -gt 0) { $line += ' ;' }
                        $line += ' new-tab -d "' + $tabs[$i].dir + '"'
                        $cmd = [string]$tabs[$i].command
                        if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                            $line += ' pwsh -NoExit -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd)
                        }
                    }
                    # -WindowStyle Hidden alone.  -NoNewWindow cannot be combined
                    # with it (Start-Process throws), and that combination was
                    # what made the terminal launch fail outright.
                    Start-Process 'cmd.exe' -ArgumentList @('/c', $line) -WindowStyle Hidden
                }
                default {
                    if ($e.launch) { Start-Process $e.launch }
                }
            }
        }

        # Poll for the new windows instead of guessing a fixed delay.  Each
        # poll searches ONLY windows that were not present in the snapshot, so
        # pre-existing windows can never be captured.
        $deadline = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 700
            $pending = @($plan | Where-Object { -not $_.Existed -and -not $_.Win })
            if ($pending.Count -eq 0) { break }
            $ctx = Get-Ctx
            $fresh = @($ctx.List | Where-Object { -not $before.ContainsKey([long]$_.H) })
            foreach ($p in $pending) {
                $rule = $p.Entry.match
                # Never let a launched window that is this script's own console
                # be adopted, even if it is new.
                $selfConsoles = Get-SelfConsoleWindows
                $cand = @($fresh | Where-Object {
                    $_.Proc -eq $rule.process -and
                    $selfConsoles -notcontains [long]$_.H -and
                    (Test-WindowTitle $_ $rule)
                })
                if ($rule.class) { $cand = @($cand | Where-Object { $_.Class -eq $rule.class }) }
                if ($cand.Count -gt 0) {
                    $p.Win = $cand | Select-Object -First 1
                    [void]$ctx.Claimed.Add([long]$p.Win.H)
                }
            }
        }
    }
}

# ---- geometry ---------------------------------------------------------------
$targets = @{}
$unmoved = @()
Write-Host ''
foreach ($p in $plan) {
    $e = $p.Entry
    $r = Resolve-Rect $e.rect $lim
    $targets[$e.id] = $r
    if (-not $p.Win) {
        Write-Host ('  {0,-10} SKIP  (no window, launch disabled or failed)' -f $e.id) -ForegroundColor Yellow
        continue
    }
    $w = $p.Win
    if (Test-Rect $w $r) {
        Write-Host ('  {0,-10} already at ({1},{2}) {3}x{4}' -f $e.id, $r.x, $r.y, $r.w, $r.h) -ForegroundColor Green
        continue
    }
    Write-Host ('  {0,-10} moving from ({1},{2}) {3}x{4} -> ({5},{6}) {7}x{8}' -f `
            $e.id, $w.X, $w.Y, $w.Wd, $w.Ht, $r.x, $r.y, $r.w, $r.h)

    # A maximised window silently swallows a plain SetWindowPos move: it
    # reports success and stays exactly where it was (verified on this
    # machine).  The maximised test must come from the window placement
    # (showCmd == 3), never from a size comparison: a maximised rect is
    # slightly SMALLER than the monitor (3868x2080 vs 3840x2160), so an
    # "is it full screen" size check quietly fails to detect it.
    $res = Move-WindowTo $w.H $r
    if (-not $res.Ok) {
        $res = Move-WindowTo $w.H $r -Restore
    }
    if (-not $res.Ok) {
        # last retry: aero snapping or a slow window can swallow a single move
        Start-Sleep -Milliseconds 300
        $res = Move-WindowTo $w.H $r
    }
    if (-not $res.Ok) {
        $unmoved += [pscustomobject]@{ Id = $e.id; Want = $r; Got = $res; Pid = $w.Pid }
        Write-Host ('  {0,-10} MOVE FAILED - still at ({1},{2}) {3}x{4}' -f $e.id, $res.X, $res.Y, $res.W, $res.H) -ForegroundColor Red
    }
}

# ---- optional: zoom + scroll the weather page --------------------------------
# Done BEFORE the z-order pass on purpose: activating the weather window brings
# it to the front, so the stacking must be re-established afterwards or the
# weather page would hide the other windows.
if ($WeatherView) {
    Write-Host ''
    Write-Host 'applying weather view (zoom + scroll)...' -ForegroundColor Cyan
    Set-WeatherView -ZoomPercent $ZoomPercent -ScrollTicks $ScrollTicks -Refresh:$Refresh
}

# ---- collect the windows, then set the stacking ------------------------------
Start-Sleep -Milliseconds 400
$byId = @{}
foreach ($p in $plan) { if ($p.Win) { $byId[$p.Entry.id] = $p.Win } }

$zOrder = @($profile.zOrderTopToBottom)
if ($zOrder.Count -eq 0) { $zOrder = @($plan | Sort-Object { $_.Entry.zOrder } | ForEach-Object { $_.Entry.id }) }

$unmovedIds = @($unmoved | ForEach-Object { $_.Id })

# ---- activate the right Edge window, then stack, then put the terminal in front ----
# Step 1: dsh web opens the 3080 page as a tab in the Edge window that was most
# recently active, so the right Edge window is activated first.  Activating a
# window also raises it, which is why this cannot be the last step.
#
# Step 2: the layout order is weather (bottom, full screen) -> right Edge ->
# terminal (front).  Each window is set explicitly instead of relying on what
# activation happens to do to the stack.
#
# Step 3: bring the terminal to the front again, last, so the activation in
# step 1 cannot leave it buried.  Do NOT re-activate the weather window here -
# that would undo step 1.
$stack = @($zOrder)
if ($stack.Count -eq 0) { $stack = @($plan | Sort-Object { $_.Entry.zOrder } | ForEach-Object { $_.Entry.id }) }

# Which layout window is where in the real stack right now, front-most first.
function Get-ActualStack {
    param($HandleById)
    $out = @()
    foreach ($h in [DshWin32]::TopLevelZOrder()) {
        $k = [int64]$h
        if ($HandleById.ContainsKey($k)) { $out += $HandleById[$k] }
    }
    return , $out
}

# Step 1: dsh web opens the 3080 page as a tab in the Edge window that was most
# recently active, so the right Edge window is activated first.  Activating a
# window both raises and focuses it, which is exactly why the front-most window
# has to be activated AFTER it.
if ($byId.ContainsKey('rightedge') -and ($unmovedIds -notcontains 'rightedge')) {
    [void][DshWin32]::Activate($byId['rightedge'].H)
    Start-Sleep -Milliseconds 250
}

# Step 2: raise the layout windows by activating them, bottom one first, so the
# last activation leaves the profile's front-most window in front.
#
# Activating is used instead of SetWindowPos(HWND_TOP) because on this machine
# SetWindowPos reordering has NO effect at all: it returns success and the
# z-order never changes (verified by raising one window eight times in a row),
# while BringWindowToTop + SetForegroundWindow does reorder.
$bottomUp = @($stack)
[array]::Reverse($bottomUp)
foreach ($id in $bottomUp) {
    if (-not $byId.ContainsKey($id)) { continue }
    if ($unmovedIds -contains $id) { continue }
    [void][DshWin32]::ActivateTopmost($byId[$id].H)
    Start-Sleep -Milliseconds 200
}

# Step 3: confirm the stack and retry if the window manager swallowed a raise.
$handleById = @{}
foreach ($id in $zOrder) { if ($byId.ContainsKey($id)) { $handleById[[int64]$byId[$id].H] = $id } }

for ($attempt = 1; $attempt -le 3; $attempt++) {
    $actual = Get-ActualStack $handleById
    if (($actual -join ',') -eq ($stack -join ',')) { break }
    Write-Host ('  stacking retry {0}: actual {1}' -f $attempt, ($actual -join ' > ')) -ForegroundColor Yellow
    foreach ($id in $bottomUp) {
        if (-not $byId.ContainsKey($id)) { continue }
        if ($unmovedIds -contains $id) { continue }
        [void][DshWin32]::ActivateTopmost($byId[$id].H)
        Start-Sleep -Milliseconds 220
    }
}

# ---- verify -----------------------------------------------------------------
Start-Sleep -Milliseconds 300
$ctx2 = Get-Ctx

# Rectangle check, in real top-level z-order (EnumWindows order is not z-order).
$byH = @{}
foreach ($w in $ctx2.All) { $byH[[long]$w.H] = $w }

$bad = 0
foreach ($h in [DshWin32]::TopLevelZOrder()) {
    $key = [int64]$h
    if (-not $handleById.ContainsKey($key)) { continue }
    $id = $handleById[$key]
    $r = $targets[$id]
    $w = $byH[$key]
    $ok = Test-Rect $w $r
    if (-not $ok) { $bad++ }
    Write-Host ('  [{0}] {1,-10} want ({2},{3}) {4}x{5}' -f $(if ($ok) { 'OK   ' } else { 'CHECK' }), $id, $r.x, $r.y, $r.w, $r.h) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
    Write-Host ('         got  {0}' -f (Get-WinLabel $w))
}

# Stacking check, top -> bottom, against zOrderTopToBottom (same helper the
# stacking pass itself uses, so the two can never disagree).
Write-Host ''
Write-Host ('stack (top -> bottom), profile says: {0}' -f ($zOrder -join ' > ')) -ForegroundColor Cyan
$actual = Get-ActualStack $handleById
Write-Host ('stack (top -> bottom), actual     : {0}' -f ($actual -join ' > ')) `
    -ForegroundColor $(if (($actual -join ',') -eq ($zOrder -join ',')) { 'Green' } else { 'Red' })
if (($actual -join ',') -ne ($zOrder -join ',')) {
    Write-Warning 'the window stack does not match the profile order'
}
if ($unmoved.Count -gt 0) {
    Write-Host ''
    Write-Warning ('{0} window(s) could not be moved: {1}' -f $unmoved.Count, (($unmoved | ForEach-Object { $_.Id }) -join ', '))
    if (-not [DshWin32]::IsElevated(0)) {
        Write-Warning 'They belong to an elevated process. Run this script from an Administrator terminal.'
    } else {
        Write-Warning 'The target process may be at a higher integrity level, or the window is refusing the move.'
    }
} elseif ($bad -gt 0) {
    Write-Warning ('{0} window(s) did not reach the requested rectangle.' -f $bad)
}

Write-Host ''
Write-Host 'done.'
