# Explorer Windows Shared.psm1
#
# Code shared by "Save Explorer Windows" (run by hand, or on a schedule by
# Task Scheduler) and the compare window: reading Explorer's windows, the
# restore-file format, the settings file, the automatic backups' state, and
# the rules for cleanup and for spotting folders that closed without anyone
# closing them. Not meant to be run on its own.
#
# Target environment: Windows 11, Japanese system locale (CP932), paths holding
# Japanese, emoji, [], !, apostrophes and Unicode lookalikes. Windows
# PowerShell 5.1 reads a file without a BOM in the ANSI code page, so this file
# stays pure ASCII, and paths and names only ever travel as base64 of UTF-8 or
# through files read and written with an explicit UTF-8 encoding.
#
# Frozen windows: a hung Explorer window never answers a COM call, and a COM
# call into a hung apartment has no timeout - it blocks forever. Every read is
# therefore done on a disposable STA worker runspace with a per-tab deadline.
# A tab that overruns it is abandoned, counted and reported, and the rest of
# the session is still saved.

$ErrorActionPreference = 'Stop'

# Per-tab budget covering all COM reads of one window/tab entry. Each frozen tab
# costs this much wall clock, so a hung 8-tab window adds 8x this to a scan.
$script:TabReadTimeoutMs = 2000

$script:Utf8NoBom = New-Object Text.UTF8Encoding $false

# The program's version: the script and this module ship together, and the
# script's file name stays fixed because a scheduled task names it. Raise it
# with any change to either file; it is printed by a run by hand and stored
# in every save's metadata.
$script:ProgramVersion = '7.1'

function Get-ProgramVersion { $script:ProgramVersion }

# ---------------------------------------------------------------------------
# COM reads on an abandonable worker thread
#
# The worker is a real STA runspace, not a job: it lives in this process (so
# results come back as live objects, not serialized text) and it can be walked
# away from while its thread is still stuck inside a COM call. Nothing can
# interrupt a blocked COM call - Stop(), Dispose() and Ctrl+C all block too -
# so abandoning the whole runspace is the only exit.
# ---------------------------------------------------------------------------

$script:ComWorker        = $null
$script:AbandonedWorkers = New-Object 'System.Collections.Generic.List[object]'

function New-ComWorker {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::STA   # trap #2 applies to the worker too
    $rs.ThreadOptions  = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [pscustomobject]@{ Runspace = $rs; PowerShell = $ps }
}

function Reset-ComWorker {
    # Throws away a *healthy* worker so the next call re-activates COM from
    # scratch. Safe to Dispose precisely because it is not stuck - a stuck one
    # goes to $AbandonedWorkers and is never touched again.
    if ($null -ne $script:ComWorker) {
        try {
            $script:ComWorker.PowerShell.Dispose()
            $script:ComWorker.Runspace.Dispose()
        } catch { }
        $script:ComWorker = $null
    }
}

function Get-AbandonedComWorkerCount {
    # A worker thread parked inside a COM call to a frozen window keeps the
    # process alive past its last statement - it never exits on its own,
    # despite runspace threads being background threads. A caller that sees a
    # non-zero count ends the process outright once everything is written.
    $script:AbandonedWorkers.Count
}

function Resolve-ComError {
    # EndInvoke wraps the real failure a couple of layers deep, and the message
    # is localized - so dig out the innermost exception and keep the HRESULT,
    # which is the only part that can be matched on reliably.
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $hr = 0
    try { $hr = [int]$ex.HResult } catch { }
    [pscustomobject]@{
        Message    = ("{0} (0x{1:X8})" -f $ex.Message.Trim(), $hr)
        HResultHex = ('0x{0:X8}' -f $hr)
    }
}

# A COM failure from this family means the shell's window service is gone, not
# that one window is unreadable: retrying other tabs is pointless. Compared as
# hex strings because an HRESULT is a negative Int32 and 0x80010100 is not.
$script:RpcFailureHResults = @(
    '0x80010100',   # RPC_E_SYS_CALL_FAILED
    '0x80010108',   # RPC_E_DISCONNECTED
    '0x800706BA',   # RPC_S_SERVER_UNAVAILABLE
    '0x80010001',   # RPC_E_CALL_REJECTED
    '0x8001010A'    # RPC_E_SERVERCALL_RETRYLATER
)

function Test-RpcFailure {
    param([string]$HResultHex)
    [bool]($HResultHex -and $script:RpcFailureHResults -contains $HResultHex)
}

function Invoke-ComStep {
    # Runs $Script on the worker and waits at most $TimeoutMs for it. On timeout
    # the worker is abandoned - its thread is parked inside a call that will
    # never return - and the next call gets a fresh one. Abandoned workers stay
    # referenced so their finalizers never run: a finalizer touching a stuck RCW
    # would block the finalizer thread as well.
    #
    # $Script receives ($Argument, $Progress). $Progress is a synchronized
    # hashtable it writes into as it goes, so a call that never comes back still
    # leaves behind whatever it managed to read.
    param([scriptblock]$Script, $Argument, [int]$TimeoutMs = $script:TabReadTimeoutMs)

    $progress = [hashtable]::Synchronized(@{ Stage = 'starting' })

    if ($null -eq $script:ComWorker) { $script:ComWorker = New-ComWorker }
    $ps = $script:ComWorker.PowerShell
    $ps.Commands.Clear()
    $ps.Streams.Error.Clear()
    $null = $ps.AddScript($Script).AddArgument($Argument).AddArgument($progress)

    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        $script:AbandonedWorkers.Add($script:ComWorker)
        $script:ComWorker = $null
        return [pscustomobject]@{ TimedOut = $true; Output = $null; Error = $null; HResultHex = $null; Progress = $progress }
    }

    $out    = $null
    $err    = $null
    $errHex = $null
    try {
        $out = @($ps.EndInvoke($async))
    } catch {
        $detail = Resolve-ComError $_
        $err    = $detail.Message
        $errHex = $detail.HResultHex
    }
    if ($null -eq $err -and $ps.Streams.Error.Count -gt 0) {
        $detail = Resolve-ComError $ps.Streams.Error[0]
        $err    = $detail.Message
        $errHex = $detail.HResultHex
    }
    $ps.Streams.Error.Clear()
    [pscustomobject]@{
        TimedOut   = $false
        Output     = $(if ($out -and $out.Count -gt 0) { $out[0] } else { $null })
        Error      = $err
        HResultHex = $errHex
        Progress   = $progress
    }
}

# Runs on the worker. Reads one Shell.Application entry (one tab), cheapest and
# most identifying properties first, so a hang partway through still yields the
# earlier ones. Shell.Application and its Windows() collection are cached in the
# worker's own globals - both are live objects, and re-creating them per tab
# costs more than the reads themselves.
$script:ReadWindowScript = {
    param([int]$Index, $Progress)
    $ErrorActionPreference = 'Stop'
    $info = [ordered]@{ Index = $Index; Hwnd = $null; Name = $null; Url = $null; Path = $null; Error = $null; HResult = $null }
    $Progress['Info'] = $info
    try {
        $Progress['Stage'] = 'Shell.Application'
        if ($null -eq $global:SaveShell)   { $global:SaveShell   = New-Object -ComObject Shell.Application }
        $Progress['Stage'] = 'Windows()'
        if ($null -eq $global:SaveWindows) { $global:SaveWindows = $global:SaveShell.Windows() }
        $Progress['Stage'] = "Windows().Item($Index)"
        $w = $global:SaveWindows.Item($Index)
        if ($null -eq $w) { $info.Error = 'window entry was null'; return [pscustomobject]$info }
        $Progress['Stage'] = 'HWND'
        try { $info.Hwnd = [int64]$w.HWND } catch { }          # [int64], never [int] - trap #1
        $Progress['Stage'] = 'LocationName'
        try { $info.Name = [string]$w.LocationName } catch { }
        $Progress['Stage'] = 'LocationURL'
        try { $info.Url = [string]$w.LocationURL } catch { }
        $Progress['Stage'] = 'Document.Folder.Self.Path'
        $info.Path = [string]$w.Document.Folder.Self.Path
    } catch {
        # Usually just a non-folder window (This PC, special view, legacy IE).
        # The HRESULT is what separates that from the shell service dying, and
        # unlike the message it is not localized.
        $info.Error = $_.Exception.Message
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        try { $info.HResult = ('0x{0:X8}' -f [int]$ex.HResult) } catch { }
    }
    $Progress['Stage'] = 'done'
    [pscustomobject]$info
}

$script:CountWindowsScript = {
    param($Unused, $Progress)
    $ErrorActionPreference = 'Stop'
    $Progress['Stage'] = 'Shell.Application'
    if ($null -eq $global:SaveShell)   { $global:SaveShell   = New-Object -ComObject Shell.Application }
    $Progress['Stage'] = 'Windows()'
    if ($null -eq $global:SaveWindows) { $global:SaveWindows = $global:SaveShell.Windows() }
    $Progress['Stage'] = 'Windows().Count'
    [int]$global:SaveWindows.Count
}

# ---------------------------------------------------------------------------
# Win32-only view of Explorer's windows
#
# The only way to say anything about a frozen tab: COM is unreachable, but the
# window manager still knows the window. Nothing below sends an untimed message
# - GetWindowText returns another process's cached caption by design, and child
# text goes through SendMessageTimeout with SMTO_ABORTIFHUNG - so this is safe
# to call against a hung window.
#
# The C# lives in a DOUBLE-quoted here-string and must stay that way: a
# single-quoted one would put a second line starting with '@ in this file and
# silently truncate the restore template far below. (It contains no $ or
# backticks, so nothing gets interpolated.)
# ---------------------------------------------------------------------------

function Initialize-ExplorerWindowProbe {
    if (-not ('ExplorerWindowProbe3' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ExplorerWindowProbe3
{
    public class Info {
        public long Hwnd;
        public string ClassName;
        public string Title;
        public bool Hung;
        public bool Visible;
        public bool Minimized;
        public int ProcessId;
        public int Left;
        public int Top;
        public int Width;
        public int Height;
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", EntryPoint="FindWindowW", CharSet=CharSet.Unicode)] private static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] private static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out UIntPtr result);

    private const uint WM_GETTEXT = 0x000D;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    private static string ClassOf(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    private static string TitleOf(IntPtr h) {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static Info[] Enumerate(string[] classes) {
        List<Info> list = new List<Info>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            string cls = ClassOf(h);
            bool want = false;
            foreach (string c in classes) {
                if (string.Equals(c, cls, StringComparison.OrdinalIgnoreCase)) { want = true; break; }
            }
            if (want) {
                Info i = new Info();
                i.Hwnd = h.ToInt64();
                i.ClassName = cls;
                i.Title = TitleOf(h);
                i.Hung = IsHungAppWindow(h);
                i.Visible = IsWindowVisible(h);
                i.Minimized = IsIconic(h);
                uint procId;
                GetWindowThreadProcessId(h, out procId);
                i.ProcessId = (int)procId;
                RECT r;
                if (GetWindowRect(h, out r)) {
                    i.Left = r.Left; i.Top = r.Top;
                    i.Width = r.Right - r.Left; i.Height = r.Bottom - r.Top;
                }
                list.Add(i);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    // Classic (pre-XAML) Explorer keeps the current path in the breadcrumb
    // toolbar's window text. Windows 11 usually yields nothing here; when it
    // does yield something it is the full path of a tab nothing else can see.
    public static string ProbeChildText(long hwnd, uint timeoutMs) {
        List<string> found = new List<string>();
        EnumChildWindows(new IntPtr(hwnd), delegate(IntPtr c, IntPtr l) {
            string cls = ClassOf(c);
            if (cls == "ToolbarWindow32" || cls == "Edit" || cls == "ComboBoxEx32" || cls == "Breadcrumb Parent") {
                StringBuilder sb = new StringBuilder(1024);
                UIntPtr res;
                IntPtr ok = SendMessageTimeout(c, WM_GETTEXT, (IntPtr)sb.Capacity, sb, SMTO_ABORTIFHUNG, timeoutMs, out res);
                if (ok != IntPtr.Zero) {
                    string t = sb.ToString().Trim();
                    if (t.Length > 1) {
                        if (t.Length > 260) t = t.Substring(0, 260) + "...";
                        string entry = cls + ": " + t;
                        if (!found.Contains(entry)) found.Add(entry);
                    }
                }
            }
            return found.Count < 6;
        }, IntPtr.Zero);
        return found.Count == 0 ? null : string.Join(" | ", found.ToArray());
    }

    // The taskbar belongs to the shell's own explorer.exe. With "Launch folder
    // windows in a separate process" on, folder windows live in another one
    // that comes and goes on its own, so only this process's start time says
    // whether Explorer itself was restarted.
    public static int ShellProcessId() {
        IntPtr h = FindWindowW("Shell_TrayWnd", null);
        if (h == IntPtr.Zero) return 0;
        uint procId;
        GetWindowThreadProcessId(h, out procId);
        return (int)procId;
    }

    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);

    // Asks an Explorer window for a new tab the way its own "+" button does:
    // WM_COMMAND 0xA21B posted to its ShellTabWindowClass, which sits several
    // levels down (FindWindowEx would miss it). No keystrokes, so an input
    // method cannot swallow it and focus does not matter. False when the
    // window has no such child.
    public static bool RequestNewTab(long hwnd) {
        IntPtr tab = IntPtr.Zero;
        EnumChildWindows(new IntPtr(hwnd), delegate(IntPtr c, IntPtr l) {
            if (ClassOf(c) == "ShellTabWindowClass") { tab = c; return false; }
            return true;
        }, IntPtr.Zero);
        if (tab == IntPtr.Zero) return false;
        return PostMessageW(tab, 0x0111, new IntPtr(0xA21B), IntPtr.Zero);
    }

    public static bool WindowExists(long hwnd) { return IsWindow(new IntPtr(hwnd)); }

    // WM_CLOSE. On a window with several tabs one message may close only
    // some of them, so a caller closing a whole window repeats it.
    public static void Close(long hwnd) { PostMessageW(new IntPtr(hwnd), 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
"@ -ErrorAction Stop
    }
}

function Get-ExplorerWindowProbe {
    Initialize-ExplorerWindowProbe
    [ExplorerWindowProbe3]::Enumerate(@('CabinetWClass', 'ExplorerWClass', 'Ghost'))
}

function Get-ExplorerChildText {
    param([long]$Hwnd, [int]$TimeoutMs = 200)
    Initialize-ExplorerWindowProbe
    [ExplorerWindowProbe3]::ProbeChildText($Hwnd, $TimeoutMs)
}

# ---------------------------------------------------------------------------
# Reading the open windows
# ---------------------------------------------------------------------------

function Invoke-ExplorerScan {
    # Reads every open Explorer tab, grouped by window (tabs share their
    # window's HWND), and returns that with everything the frozen-tab report
    # needs. -ShowProgress prints the console lines of a run by hand.
    param([switch]$ShowProgress)

    $timeoutMs  = $script:TabReadTimeoutMs
    $timeoutSec = [math]::Round($timeoutMs / 1000, 1)
    if ($ShowProgress) {
        Write-Host ("Apartment state: {0}" -f [Threading.Thread]::CurrentThread.GetApartmentState())
        Write-Host ("Reading open Explorer windows (timeout {0}s per tab)..." -f $timeoutSec)
    }

    # A worker left over from an earlier scan in this process holds a cached
    # Windows() collection; start from scratch so the read is current.
    Reset-ComWorker

    $rawCount           = 0
    $enumerationBlocked = $false
    $enumerationError   = $null
    $enumerationHResult = $null

    $countResult = Invoke-ComStep -Script $script:CountWindowsScript -Argument 0 -TimeoutMs $timeoutMs
    if (-not $countResult.TimedOut -and $countResult.Error) {
        # One retry on a brand-new worker. COM is activated from scratch there,
        # which is the only thing that ever clears a transient RPC failure -
        # and when it does not clear, it fails fast, so this costs nothing.
        if ($ShowProgress) { Write-Host "First attempt failed; retrying with a fresh COM connection..." }
        Reset-ComWorker
        Start-Sleep -Milliseconds 500
        $countResult = Invoke-ComStep -Script $script:CountWindowsScript -Argument 0 -TimeoutMs $timeoutMs
    }

    if ($countResult.TimedOut) {
        $enumerationBlocked = $true
        $enumerationError = ("Shell.Application did not answer within {0}s (blocked at: {1}). Explorer itself may be hung." -f $timeoutSec, $countResult.Progress['Stage'])
        if ($ShowProgress) { Write-Warning $enumerationError }
    } elseif ($countResult.Error) {
        $enumerationBlocked = $true
        $enumerationHResult = $countResult.HResultHex
        $enumerationError = ("Shell.Application refused the call: {0}" -f $countResult.Error)
        if ($ShowProgress) { Write-Warning $enumerationError }
    } elseif ($null -ne $countResult.Output) {
        $rawCount = [int]$countResult.Output
    }
    if ($ShowProgress) { Write-Host ("Shell.Application reports {0} window object(s)." -f $rawCount) }

    $groups           = [ordered]@{}
    $names            = @{}
    $seenHwnds        = New-Object 'System.Collections.Generic.HashSet[long]'
    $frozen           = New-Object 'System.Collections.Generic.List[object]'
    $skippedNonFolder = 0

    for ($i = 0; $i -lt $rawCount; $i++) {
        $result = Invoke-ComStep -Script $script:ReadWindowScript -Argument $i -TimeoutMs $timeoutMs

        if ($result.TimedOut) {
            $partial = $result.Progress['Info']
            $frozen.Add([pscustomobject]@{
                Index = $i
                Stage = [string]$result.Progress['Stage']
                Hwnd  = $(if ($partial) { $partial['Hwnd'] } else { $null })
                Name  = $(if ($partial) { $partial['Name'] } else { $null })
                Url   = $(if ($partial) { $partial['Url'] }  else { $null })
            })
            if ($ShowProgress) {
                Write-Warning ("Tab entry #{0} did not respond within {1}s (blocked at: {2}) - skipped." -f $i, $timeoutSec, $result.Progress['Stage'])
            }
            continue
        }

        $info = $result.Output

        # The shell service can die partway through a scan. Once it does no later
        # tab can be read either, so stop rather than logging every remaining
        # window as "non-folder". Whatever was collected so far still saves.
        # The failure arrives by one of two routes - the worker caught it and put
        # the HRESULT in $info, or the call itself threw and Invoke-ComStep did.
        # Check both, or a thrown one is silently miscounted as a non-folder window.
        $failureHResult = if ($info -and $info.HResult) { $info.HResult } else { $result.HResultHex }
        if (Test-RpcFailure $failureHResult) {
            $enumerationBlocked = $true
            $enumerationHResult = $failureHResult
            $reason = if ($info -and $info.Error) { "$($info.Error) ($failureHResult)" } else { $result.Error }
            $enumerationError = ("Explorer stopped answering COM at tab entry #{0}: {1}" -f $i, $reason)
            if ($ShowProgress) { Write-Warning $enumerationError }
            break
        }

        if ($null -eq $info) { $skippedNonFolder++; continue }
        if ($info.Hwnd) { [void]$seenHwnds.Add([int64]$info.Hwnd) }

        $path = [string]$info.Path
        if ([string]::IsNullOrWhiteSpace($path)) { $skippedNonFolder++; continue }

        # Fall back to a per-entry key when HWND was unreadable, so unrelated
        # tabs never get merged into one window under a shared 0.
        $hwnd = if ($info.Hwnd) { [int64]$info.Hwnd } else { [int64](-1 - $i) }
        if (-not $groups.Contains($hwnd)) {
            $groups[$hwnd] = [Collections.Generic.List[string]]::new()
            $names[$hwnd]  = [Collections.Generic.List[string]]::new()
        }
        $groups[$hwnd].Add($path)
        $names[$hwnd].Add([string]$info.Name)
    }

    [pscustomobject]@{
        Groups           = $groups        # HWND -> paths, tabs in order
        Names            = $names         # HWND -> display names, parallel to Groups
        Frozen           = $frozen
        SeenHwnds        = $seenHwnds
        RawCount         = $rawCount
        SkippedNonFolder = $skippedNonFolder
        Blocked          = $enumerationBlocked
        Error            = $enumerationError
        HResult          = $enumerationHResult
        TimeoutSec       = $timeoutSec
    }
}

function Get-ScanGroups {
    # A scan's windows as an array of string[] (tabs in order): the shape the
    # restore format and the comparisons take. -Names gives the display names.
    param($Scan, [switch]$Names)
    $source = if ($Names) { $Scan.Names } else { $Scan.Groups }
    ,@(foreach ($key in $Scan.Groups.Keys) { ,[string[]]$source[$key].ToArray() })
}

function Test-ScanComplete {
    # A scan that skipped frozen tabs, or lost Explorer partway, saw only part
    # of the session.
    param($Scan)
    ($Scan.Frozen.Count -eq 0) -and (-not $Scan.Blocked)
}

# ---------------------------------------------------------------------------
# Comparing sessions
# ---------------------------------------------------------------------------

function ConvertTo-TabList {
    param([object[]]$Groups)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $w = 0
    foreach ($g in @($Groups)) {
        $t = 0
        foreach ($p in @($g)) {
            if (-not [string]::IsNullOrEmpty($p)) {
                $list.Add([pscustomobject]@{ Path = [string]$p; Window = $w; Tab = $t })
            }
            $t++
        }
        $w++
    }
    ,$list
}

function Get-UnmatchedTabs {
    # The tabs of $From with no partner left in $Against, pairing equal paths
    # one to one, so a folder open twice needs two partners.
    param($From, $Against)
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($tab in $Against) {
        $n = 0
        [void]$counts.TryGetValue($tab.Path, [ref]$n)
        $counts[$tab.Path] = $n + 1
    }
    foreach ($tab in $From) {
        $n = 0
        if ($counts.TryGetValue($tab.Path, [ref]$n) -and $n -gt 0) {
            $counts[$tab.Path] = $n - 1
        } else {
            $tab
        }
    }
}

function Compare-SessionFolders {
    # Which folder tabs are in one session but not the other, ignoring which
    # window a tab was in and letter case (Windows paths are case-insensitive).
    # Missing: tabs of -Before with no partner in -After. Added: the reverse.
    # Each keeps its window and tab position for display.
    param([object[]]$Before, [object[]]$After)
    $beforeList = ConvertTo-TabList $Before
    $afterList  = ConvertTo-TabList $After
    [pscustomobject]@{
        Missing     = @(Get-UnmatchedTabs -From $beforeList -Against $afterList)
        Added       = @(Get-UnmatchedTabs -From $afterList -Against $beforeList)
        BeforeCount = $beforeList.Count
        AfterCount  = $afterList.Count
    }
}

function Test-SameFolders {
    param([object[]]$A, [object[]]$B)
    $diff = Compare-SessionFolders -Before $A -After $B
    ($diff.Missing.Count -eq 0) -and ($diff.Added.Count -eq 0)
}

function Get-FolderDisplayName {
    # The last part of a path, for lists a person reads. Shell locations
    # (::{GUID}...) and drive roots have no useful last part and stay whole.
    param([string]$Path)
    $trimmed = $Path.TrimEnd('\')
    $leaf = $trimmed.Substring($trimmed.LastIndexOf('\') + 1)
    if ([string]::IsNullOrEmpty($leaf) -or $leaf.StartsWith('::') -or $leaf.EndsWith(':')) { return $Path }
    $leaf
}

# ---------------------------------------------------------------------------
# The restore file
#
# A save is a self-contained restore script: running it reopens the windows.
# Its data rides inside as base64 of UTF-8 JSON, which is plain ASCII and so
# survives any encoding the file passes through:
#   $dataB64 - the windows: an array of arrays of paths, tabs in order
#   $noteB64 - the frozen-tab report, '' when nothing was frozen
#   $metaB64 - facts about the save (when, kind, label, whether it is
#              complete, display names) for the cleanup and the compare
#              window; the restore code never reads it
# ---------------------------------------------------------------------------

# Restore-script template. The @@@...@@@ markers get replaced with the data.
# Note: this is a single-quoted here-string (@'...'@) so $variables, backticks,
# and quotes inside are all literal. The only constraint is that no line inside
# may start with '@ (the closing delimiter).
$script:RestoreTemplate = @'
# Windows Explorer session restore script
# Generated by Save Explorer Windows (template in Explorer Windows Shared.psm1) - edit that, not this file.
# Requires Windows 11 22H2+ for tab restoration.
#
# Tabs are added without keystrokes, so an input method (IME) does not get in
# the way. Only if a window does not answer that request does this press
# Ctrl+T for it, and an active IME can swallow that keypress.

$ErrorActionPreference = 'Stop'

# Shell.Application needs a Single-Threaded Apartment. PowerShell 7 / some hosts
# default to MTA where COM window enumeration fails. Relaunch in STA if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath
        exit
    } else {
        Write-Warning "Not running in STA mode and cannot self-relaunch. Run with Windows PowerShell."
    }
}

try {

# Path data: UTF-8 JSON, base64-encoded
$dataB64 = '@@@DATA_B64@@@'
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dataB64))
# Cast each group to [string[]] so single-element groups stay arrays
$groups = @(($json | ConvertFrom-Json) | ForEach-Object { ,[string[]]@($_) })

# Report of tabs that were frozen at save time and are therefore missing here.
# Empty unless that save run hit one. Base64 for the same reason as the paths.
$noteB64 = '@@@NOTE_B64@@@'
if ($noteB64.Length -gt 0) {
    Write-Warning "Some Explorer tabs were frozen when this session was saved and are NOT in this file:"
    Write-Host ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($noteB64))) -ForegroundColor Yellow
    Write-Host ""
}

# Facts about this save for Save Explorer Windows' cleanup and compare window.
# Nothing in this script reads it.
$metaB64 = '@@@META_B64@@@'

# RequestNewTab asks a window for a new tab the way its own "+" button does:
# WM_COMMAND 0xA21B posted to its ShellTabWindowClass, which sits several
# levels below the window. Named apart from older restore scripts' WinAPI
# class, which a second restore in the same console would otherwise find.
Add-Type -ErrorAction SilentlyContinue -TypeDefinition (@(
    'using System; using System.Text; using System.Runtime.InteropServices;'
    'public class SewRestoreApi {'
    '  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);'
    '  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
    '  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);'
    '  delegate bool EnumProc(IntPtr h, IntPtr l);'
    '  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);'
    '  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);'
    '  public static bool RequestNewTab(IntPtr top) {'
    '    IntPtr tab = IntPtr.Zero;'
    '    EnumChildWindows(top, delegate(IntPtr c, IntPtr l) {'
    '      StringBuilder s = new StringBuilder(256); GetClassNameW(c, s, 256);'
    '      if (s.ToString() == "ShellTabWindowClass") { tab = c; return false; }'
    '      return true;'
    '    }, IntPtr.Zero);'
    '    if (tab == IntPtr.Zero) return false;'
    '    return PostMessageW(tab, 0x0111, new IntPtr(0xA21B), IntPtr.Zero);'
    '  }'
    '}'
) -join "`n")

Add-Type -AssemblyName System.Windows.Forms

$shellCom = New-Object -ComObject Shell.Application

# Returns the IUnknown pointer of a COM object (as long) for identity comparison.
# Two RCWs for the same underlying COM object may be different wrappers; the pointer is stable.
function Get-ComId {
    param($obj)
    $ptr = [Runtime.InteropServices.Marshal]::GetIUnknownForObject($obj)
    try { $ptr.ToInt64() }
    finally { [Runtime.InteropServices.Marshal]::Release($ptr) | Out-Null }
}

function Wait-For {
    param([scriptblock]$Predicate, [int]$TimeoutMs = 5000, [int]$PollMs = 50)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $result = & $Predicate
        if ($result) { return $result }
        Start-Sleep -Milliseconds $PollMs
    }
    $null
}

function Open-ExplorerGroup {
    param([string[]]$Paths)

    if (-not $Paths -or $Paths.Count -eq 0) { return }

    $firstPath = [string]$Paths[0]
    $beforeHwnds = @($shellCom.Windows() | ForEach-Object { [int64]$_.HWND })

    # Open first path - new window
    if ($firstPath.Length -ge 2 -and $firstPath.Substring(0, 2) -eq '::') {
        $shellCom.Open('shell:' + $firstPath)
    } else {
        $shellCom.Open($firstPath)
    }

    # Poll for the new window's HWND
    $newHwnd = Wait-For -TimeoutMs 5000 -Predicate {
        $current = @($shellCom.Windows() | ForEach-Object { [int64]$_.HWND })
        $new = $current | Where-Object { $beforeHwnds -notcontains $_ }
        if ($new.Count -gt 0) { [int64]$new[0] } else { $null }
    }

    if (-not $newHwnd) {
        Write-Warning "Timed out waiting for Explorer window for: $firstPath"
        return
    }

    $hwnd = [IntPtr][int64]$newHwnd
    [SewRestoreApi]::ShowWindow($hwnd, 3) | Out-Null  # SW_MAXIMIZE

    # The new tab: same HWND, a COM identity not seen before the request.
    $findNewTab = {
        foreach ($w in @($shellCom.Windows())) {
            try {
                if ([int64]$w.HWND -eq $newHwnd -and -not $beforeIds.Contains((Get-ComId $w))) {
                    return $w
                }
            } catch { }
        }
        $null
    }

    if ($Paths.Count -gt 1) {
        foreach ($path in $Paths[1..($Paths.Count - 1)]) {
            try {
                # Snapshot existing tab identities so we can spot the new one
                $beforeIds = New-Object 'System.Collections.Generic.HashSet[long]'
                foreach ($w in @($shellCom.Windows())) {
                    $beforeIds.Add((Get-ComId $w)) | Out-Null
                }

                # Ask for the tab without keystrokes; Ctrl+T only when the
                # window does not answer that, which needs focus and no IME.
                $newTab = $null
                if ([SewRestoreApi]::RequestNewTab($hwnd)) {
                    $newTab = Wait-For -TimeoutMs 3000 -Predicate $findNewTab
                }
                if (-not $newTab) {
                    [SewRestoreApi]::ShowWindow($hwnd, 3) | Out-Null
                    [SewRestoreApi]::SetForegroundWindow($hwnd) | Out-Null
                    Start-Sleep -Milliseconds 150
                    [System.Windows.Forms.SendKeys]::SendWait('^t')
                    $newTab = Wait-For -TimeoutMs 5000 -Predicate $findNewTab
                }

                if (-not $newTab) {
                    Write-Warning "Timed out waiting for new tab for: $path"
                    continue
                }

                # Navigate the new tab directly via COM (no SendKeys, no clipboard, no address bar)
                $navPath = if ($path.Length -ge 2 -and $path.Substring(0, 2) -eq '::') { 'shell:' + $path } else { $path }
                $newTab.Navigate2($navPath)

                # Wait for navigation to complete
                Wait-For -TimeoutMs 5000 -Predicate {
                    try { -not $newTab.Busy } catch { $true }
                } | Out-Null

                [SewRestoreApi]::ShowWindow($hwnd, 3) | Out-Null  # Re-maximize
            } catch {
                Write-Warning "Failed to open tab for '$path': $_"
            }
        }
    }
}

function Select-MissingFolders {
    # The windows to open: each saved window without the folders already
    # open. Counted as a multiset, ignoring letter case: a folder open once is
    # skipped once, so one saved in two tabs still opens its second. The tests
    # run this function as written here, taken from a restore file.
    param([object[]]$Groups, [string[]]$OpenPaths)
    $open = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($OpenPaths)) {
        if ($p) { $n = 0; [void]$open.TryGetValue($p, [ref]$n); $open[$p] = $n + 1 }
    }
    $skipped = 0
    $left = New-Object 'System.Collections.Generic.List[object]'
    foreach ($group in @($Groups)) {
        $keep = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in @($group)) {
            $n = 0
            if ($open.TryGetValue($p, [ref]$n) -and $n -gt 0) { $open[$p] = $n - 1; $skipped++ } else { $keep.Add($p) }
        }
        if ($keep.Count -gt 0) { $left.Add([string[]]$keep.ToArray()) }
    }
    [pscustomobject]@{ Groups = $left.ToArray(); Skipped = $skipped }
}

if ($groups.Count -eq 0) {
    Write-Warning "No path groups found in this restore script."
} else {
    # Folders already open are skipped, so running this again after some
    # were lost reopens only the missing ones. A frozen Explorer window holds
    # this up until it is closed.
    $openPaths = @(foreach ($w in @($shellCom.Windows())) { try { [string]$w.Document.Folder.Self.Path } catch { } })
    $plan = Select-MissingFolders -Groups $groups -OpenPaths $openPaths
    if ($plan.Skipped -gt 0) { Write-Host ("{0} folder(s) already open, so not opened again." -f $plan.Skipped) }
    if ($plan.Groups.Count -eq 0) {
        Write-Host "`nEvery folder in this file is already open." -ForegroundColor Green
    } else {
        foreach ($group in $plan.Groups) {
            Open-ExplorerGroup -Paths $group
            Start-Sleep -Milliseconds 200
        }
        Write-Host ("`nDone. {0} window(s) restored." -f $plan.Groups.Count) -ForegroundColor Green
    }
}

} catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Read-Host "`nPress Enter to exit"
'@

function ConvertTo-Base64Utf8 {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-Base64Utf8 {
    param([string]$Base64)
    if ([string]::IsNullOrEmpty($Base64)) { return '' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function New-RestoreScriptText {
    param(
        [object[]]$Groups,   # one string[] per window, tabs in order
        [string]$Note,       # frozen-tab report, '' when nothing was frozen
        $Meta                # dictionary stored as JSON in $metaB64
    )
    $groupArrays = @(foreach ($g in $Groups) { ,@($g) })
    $json     = ConvertTo-Json -InputObject $groupArrays -Depth 3 -Compress
    $metaJson = ConvertTo-Json -InputObject $Meta -Depth 5 -Compress
    $text = $script:RestoreTemplate.Replace('@@@DATA_B64@@@', (ConvertTo-Base64Utf8 $json))
    $text = $text.Replace('@@@NOTE_B64@@@', (ConvertTo-Base64Utf8 $Note))
    $text.Replace('@@@META_B64@@@', (ConvertTo-Base64Utf8 $metaJson))
}

function Write-RestoreScript {
    param([string]$Path, [object[]]$Groups, [string]$Note, $Meta)
    $content = New-RestoreScriptText -Groups $Groups -Note $Note -Meta $Meta
    # UTF-8 without BOM; the content is ASCII anyway.
    [IO.File]::WriteAllText($Path, $content, $script:Utf8NoBom)
}

function ConvertTo-Moment {
    # A stored time (ISO 8601 text, or a DateTime some JSON reader made of it)
    # as a DateTimeOffset, so times from different sources compare correctly.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-StringArrays {
    # JSON arrays of arrays of strings back into an array of string[].
    # ConvertFrom-Json hands a one-element array back as a bare value, hence
    # the re-wrapping.
    param($Value)
    if ($null -eq $Value) { return ,@() }
    ,@(foreach ($item in @($Value)) { ,[string[]]@($item) })
}

function Read-SessionBackup {
    # One restore script as an object, or $null when the file is not a
    # readable restore script: callers never act on, or delete, a file they
    # do not understand.
    param([string]$Path)
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $dataMatch = [regex]::Match($text, '(?m)^\$dataB64 = ''([A-Za-z0-9+/=]*)''')
        if (-not $dataMatch.Success) { return $null }
        $json   = ConvertFrom-Base64Utf8 $dataMatch.Groups[1].Value
        $groups = @(($json | ConvertFrom-Json) | ForEach-Object { ,[string[]]@($_) })

        $noteMatch = [regex]::Match($text, '(?m)^\$noteB64 = ''([A-Za-z0-9+/=]*)''')
        $note = if ($noteMatch.Success) { ConvertFrom-Base64Utf8 $noteMatch.Groups[1].Value } else { '' }

        $meta = $null
        $metaMatch = [regex]::Match($text, '(?m)^\$metaB64 = ''([A-Za-z0-9+/=]*)''')
        if ($metaMatch.Success -and $metaMatch.Groups[1].Value) {
            $meta = (ConvertFrom-Base64Utf8 $metaMatch.Groups[1].Value) | ConvertFrom-Json
        }
    } catch {
        return $null
    }

    $file = [IO.Path]::GetFileName($Path)
    $savedAt = $null
    if ($meta -and $meta.savedAt) {
        try { $savedAt = ConvertTo-Moment $meta.savedAt } catch { }
    }
    if (-not $savedAt) {
        # Saves made before the metadata existed carry their time in the name.
        $nameMatch = [regex]::Match($file, '^Restore Explorer Session (\d{4}\.\d{2}\.\d{2} \d{2}-\d{2}-\d{2})')
        if ($nameMatch.Success) {
            $savedAt = [DateTimeOffset][DateTime]::ParseExact($nameMatch.Groups[1].Value, 'yyyy.MM.dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
        } else {
            $savedAt = [DateTimeOffset][IO.File]::GetLastWriteTime($Path)
        }
    }

    $count = 0
    foreach ($g in $groups) { $count += $g.Count }

    [pscustomobject]@{
        Path     = $Path
        File     = $file
        SavedAt  = $savedAt
        Kind     = $(if ($meta -and $meta.kind) { [string]$meta.kind } else { '' })
        Version  = $(if ($meta -and $meta.version) { [string]$meta.version } else { '' })
        Label    = $(if ($meta -and $meta.label) { [string]$meta.label } else { '' })
        # Older saves have no flag; their frozen-tab report is the same signal.
        Complete = $(if ($meta -and $null -ne $meta.complete) { [bool]$meta.complete } else { -not $note })
        Groups   = $groups
        Names    = $(if ($meta -and $null -ne $meta.names) { ConvertTo-StringArrays $meta.names } else { $null })
        Count    = $count
        Note     = $note
    }
}

function Get-SessionBackups {
    # Every readable restore script directly inside $Folder, newest first.
    param([string]$Folder)
    if (-not [IO.Directory]::Exists($Folder)) { return }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in [IO.Directory]::GetFiles($Folder, 'Restore Explorer Session *')) {
        # GetFiles' pattern also matches longer extensions; be exact.
        if (-not $p.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $b = Read-SessionBackup -Path $p
        if ($b) { $list.Add($b) }
    }
    if ($list.Count -eq 0) { return }
    $list | Sort-Object -Property @{ Expression = { $_.SavedAt }; Descending = $true }, @{ Expression = { $_.File }; Descending = $true }
}

# ---------------------------------------------------------------------------
# Settings.ini
# ---------------------------------------------------------------------------

# KeepBackups 0 is "auto" in the file: enough backups for $AutoKeepHours
# at the task's interval (Resolve-KeepCount).
$script:SettingsDefaults = [ordered]@{
    KeepBackups       = 0
    Warnings          = $true
    RestartMinFolders = 1
    DropWarnings      = $true
    DropMinFolders    = 3
    DropMinPercent    = 50
}

# Allowed range of each number.
$script:SettingsRanges = @{
    KeepBackups       = @(1, 1000)
    RestartMinFolders = @(1, 1000)
    DropMinFolders    = @(1, 1000)
    DropMinPercent    = @(1, 100)
}

$script:SettingsTemplate = @'
; Save Explorer Windows - settings for the automatic backups
;
; Change a value after the = sign and save this file: the next automatic
; backup uses it. A value that cannot be read counts as its default, and
; the log in "Automatic backups" says so.

; How many automatic backups to keep: auto for enough to reach 48 hours
; back at the interval the setup chose (48 when it saves every hour, 144
; every 20 minutes), or a number. A backup locked after folders were lost
; is kept on top of these.
KeepBackups = auto

; The lost-folder check: on, or off to be fully manual (no warnings, and no
; backup is ever locked).
Warnings = on

; Folders lost to a PC restart, a sign-out or an Explorer crash: warn when
; at least this many are missing.
RestartMinFolders = 1

; Folders that vanished with no restart or crash: on to warn when many go
; at once, off to never warn about it. Closing every folder never counts:
; that is taken as done on purpose.
DropWarnings = on

; What counts as many: at least this many folders...
DropMinFolders = 3

; ...that were at least this percentage of the folders open before.
DropMinPercent = 50
'@

function Write-DefaultSettingsFile {
    param([string]$Path)
    [IO.File]::WriteAllText($Path, $script:SettingsTemplate.Replace("`r`n", "`n").Replace("`n", "`r`n") + "`r`n", $script:Utf8NoBom)
}

function Write-BackupSettings {
    # Writes Settings.ini from the template, its explanations included, with
    # the given values. Comments of the person's own in the old file are not
    # kept. Throws on a value outside its range rather than writing one that
    # would only be read back as its default.
    param([string]$Path, $Values)
    $text = $script:SettingsTemplate.Replace("`r`n", "`n")
    foreach ($key in $script:SettingsDefaults.Keys) {
        $value = $Values.$key
        if ($null -eq $value) { $value = $script:SettingsDefaults[$key] }
        if ($script:SettingsDefaults[$key] -is [bool]) {
            $shown = if ([bool]$value) { 'on' } else { 'off' }
        } elseif ($key -eq 'KeepBackups' -and [int]$value -eq 0) {
            $shown = 'auto'
        } else {
            $range = $script:SettingsRanges[$key]
            $number = [int]$value
            if ($number -lt $range[0] -or $number -gt $range[1]) {
                throw ("{0} must be from {1} to {2}, not {3}." -f $key, $range[0], $range[1], $number)
            }
            $shown = [string]$number
        }
        $text = [regex]::Replace($text, ('(?m)^{0} = .*$' -f $key), ('{0} = {1}' -f $key, $shown))
    }
    [IO.File]::WriteAllText($Path, $text.Replace("`n", "`r`n") + "`r`n", $script:Utf8NoBom)
}

function Read-BackupSettings {
    # Settings.ini as an object, every value valid: anything unreadable falls
    # back to its default and is described in Problems.
    param([string]$Path)
    $values = [ordered]@{}
    foreach ($key in $script:SettingsDefaults.Keys) { $values[$key] = $script:SettingsDefaults[$key] }
    $problems = New-Object 'System.Collections.Generic.List[string]'

    if ([IO.File]::Exists($Path)) {
        $lineNo = 0
        foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
            $lineNo++
            $text = ($line -replace '[;#].*$', '').Trim()
            if (-not $text) { continue }
            if ($text -notmatch '^([A-Za-z]+)\s*=\s*(.*)$') {
                $problems.Add(("line {0} is not 'name = value'" -f $lineNo))
                continue
            }
            $name = $Matches[1]
            $raw  = $Matches[2].Trim()
            $key  = @($script:SettingsDefaults.Keys | Where-Object { $_ -eq $name }) | Select-Object -First 1
            if (-not $key) {
                $problems.Add(("line {0}: unknown setting '{1}'" -f $lineNo, $name))
                continue
            }
            if ($script:SettingsDefaults[$key] -is [bool]) {
                if ($raw -match '^(on|yes|true|1)$') { $values[$key] = $true }
                elseif ($raw -match '^(off|no|false|0)$') { $values[$key] = $false }
                else { $problems.Add(("line {0}: {1} must be on or off, not '{2}'" -f $lineNo, $key, $raw)) }
            } elseif ($key -eq 'KeepBackups' -and $raw -match '^auto$') {
                $values[$key] = 0
            } else {
                $range = $script:SettingsRanges[$key]
                $number = 0
                if ([int]::TryParse($raw, [ref]$number) -and $number -ge $range[0] -and $number -le $range[1]) {
                    $values[$key] = $number
                } else {
                    $orAuto = if ($key -eq 'KeepBackups') { ' or auto' } else { '' }
                    $problems.Add(("line {0}: {1} must be a whole number from {2} to {3}{4}, not '{5}'" -f $lineNo, $key, $range[0], $range[1], $orAuto, $raw))
                }
            }
        }
    }

    $values['Problems'] = $problems.ToArray()
    [pscustomobject]$values
}

# ---------------------------------------------------------------------------
# The automatic backups' state (state.json beside them)
#
# Holds the locks: an incident is a loss the check spotted, and its baseline
# backup (the last one from before the loss) stays out of cleanup until the
# incident is resolved. Also the time of the last scan that found nothing
# open, which then counts as the latest session.
# ---------------------------------------------------------------------------

function New-BackupState {
    [pscustomobject]@{
        LastEmptyAt = $null
        Incidents   = New-Object 'System.Collections.Generic.List[object]'
        Unreadable  = $false
    }
}

function Read-BackupState {
    # An unreadable state.json is set aside (renamed, never deleted) and
    # reported through Unreadable; the caller must then not delete anything,
    # since it cannot know what was locked.
    param([string]$Folder)
    $path  = Join-Path $Folder 'state.json'
    $state = New-BackupState
    if (-not [IO.File]::Exists($path)) { return $state }
    try {
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $state.LastEmptyAt = ConvertTo-Moment $raw.lastEmptyAt
        foreach ($i in @($raw.incidents)) {
            if ($null -eq $i) { continue }
            # Assigned directly, not as the value of an if: that would unwrap
            # a one-path list into a bare string.
            $missing = [string[]]@()
            if ($null -ne $i.missing) { $missing = [string[]]@($i.missing) }
            $state.Incidents.Add([pscustomobject]@{
                Id              = [string]$i.id
                DetectedAt      = ConvertTo-Moment $i.detectedAt
                BaselineFile    = [string]$i.baselineFile
                BaselineSavedAt = ConvertTo-Moment $i.baselineSavedAt
                CurrentFile     = [string]$i.currentFile
                Cause           = [string]$i.cause
                Reason          = [string]$i.reason
                Missing         = $missing
                Notified        = [bool]$i.notified
            })
        }
    } catch {
        $state = New-BackupState
        $state.Unreadable = $true
        $aside = Join-Path $Folder ('state (unreadable {0}).json' -f (Get-Date -Format 'yyyy.MM.dd HH-mm-ss'))
        try { [IO.File]::Move($path, $aside) } catch { }
    }
    $state
}

function Write-BackupState {
    # Written to a side file first and swapped in, so a run cut short never
    # leaves a half-written state.json behind.
    param([string]$Folder, $State)
    $incidents = @(foreach ($i in $State.Incidents) {
        [ordered]@{
            id              = $i.Id
            detectedAt      = $(if ($i.DetectedAt) { $i.DetectedAt.ToString('o') } else { $null })
            baselineFile    = $i.BaselineFile
            baselineSavedAt = $(if ($i.BaselineSavedAt) { $i.BaselineSavedAt.ToString('o') } else { $null })
            currentFile     = $i.CurrentFile
            cause           = $i.Cause
            reason          = $i.Reason
            missing         = @($i.Missing)
            notified        = [bool]$i.Notified
        }
    })
    $obj = [ordered]@{
        format      = 1
        lastEmptyAt = $(if ($State.LastEmptyAt) { $State.LastEmptyAt.ToString('o') } else { $null })
        incidents   = $incidents
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 6
    $path = Join-Path $Folder 'state.json'
    $tmp  = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    # [NullString]: PowerShell hands a plain $null to .NET as "", which
    # Replace rejects as a backup file name.
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Write-BackupLog {
    # One line per event in log.txt beside the automatic backups. It names
    # backup files and counts, never folder paths. Trimmed to its newest lines
    # once it grows past a few hundred KB.
    param([string]$Folder, [string]$Message)
    $path = Join-Path $Folder 'log.txt'
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [IO.File]::AppendAllText($path, $line + "`r`n", $script:Utf8NoBom)
    if ((New-Object IO.FileInfo $path).Length -gt 400KB) {
        $keep = [string[]]@([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8) | Select-Object -Last 2000)
        [IO.File]::WriteAllLines($path, $keep, $script:Utf8NoBom)
    }
}

function Enter-NamedMutex {
    # A held Mutex, or $null when another process holds it past $TimeoutMs.
    # A holder that died without letting go counts as letting go.
    param([string]$Name, [int]$TimeoutMs = 0)
    $mutex = New-Object Threading.Mutex($false, $Name)
    $held = $false
    try { $held = $mutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { $held = $true }
    if ($held) { return $mutex }
    $mutex.Dispose()
    $null
}

function Exit-NamedMutex {
    param($Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        $Mutex.Dispose()
    }
}

function Test-NamedMutexHeld {
    param([string]$Name)
    $existing = $null
    if ([Threading.Mutex]::TryOpenExisting($Name, [ref]$existing)) {
        $existing.Dispose()
        return $true
    }
    $false
}

# ---------------------------------------------------------------------------
# Was it the user who closed them?
#
# Windows only closes folder windows on its own when Explorer's process goes
# away. Three ways to see that it did since a given moment:
#   - the PC booted since then;
#   - the shell's explorer.exe (the taskbar's) started since then: a sign-out,
#     a shutdown with Fast Startup (which keeps the boot time), or Explorer
#     restarting;
#   - the Application log holds an Application Error (1000) or Application
#     Hang (1002) event for explorer.exe since then.
# The folder windows' own process cannot be used: with "Launch folder windows
# in a separate process" on, it exits by itself once the last window closes.
# ---------------------------------------------------------------------------

function Get-ExplorerRestartInfo {
    param([DateTimeOffset]$Since)
    $boot = $null
    try { $boot = [DateTimeOffset](Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime } catch { }

    $shellStart = $null
    try {
        Initialize-ExplorerWindowProbe
        $shellPid = [ExplorerWindowProbe3]::ShellProcessId()
        if ($shellPid -gt 0) { $shellStart = [DateTimeOffset](Get-Process -Id $shellPid).StartTime }
    } catch { }

    $crashes = @()
    $eventLogError = $null
    try {
        $filter = @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $Since.LocalDateTime }
        $crashes = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
            Where-Object {
                $_.ProviderName -in @('Application Error', 'Application Hang') -and
                $_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq 'explorer.exe'
            } |
            ForEach-Object { [DateTimeOffset]$_.TimeCreated })
    } catch {
        # "No events found" arrives as an error; it is the normal answer.
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $eventLogError = $_.Exception.Message }
    }

    [pscustomobject]@{
        BootTime      = $boot
        ShellStart    = $shellStart
        CrashTimes    = $crashes
        EventLogError = $eventLogError
    }
}

function Get-LostFolderVerdict {
    # Decides whether the folders missing since the baseline call for a
    # warning. Pure: everything it needs comes in as arguments.
    param(
        [object[]]$BaselineGroups,
        [DateTimeOffset]$BaselineTime,
        [object[]]$CurrentGroups,
        $RestartInfo,     # Get-ExplorerRestartInfo output (or the same shape)
        $Settings         # Read-BackupSettings output (or the same shape)
    )
    $diff   = Compare-SessionFolders -Before $BaselineGroups -After $CurrentGroups
    $before = $diff.BeforeCount
    $after  = $diff.AfterCount
    $lost   = $diff.Missing.Count

    $cause  = $null
    $reason = $null
    if ($RestartInfo) {
        if ($RestartInfo.BootTime -and $RestartInfo.BootTime -gt $BaselineTime) {
            $cause = 'restart'; $reason = 'the PC restarted'
        } elseif ($RestartInfo.ShellStart -and $RestartInfo.ShellStart -gt $BaselineTime) {
            $cause = 'explorer-restart'; $reason = 'Explorer was restarted (a shutdown, sign-out or crash)'
        } elseif (@($RestartInfo.CrashTimes | Where-Object { $_ -gt $BaselineTime }).Count -gt 0) {
            $cause = 'crash'; $reason = 'Explorer crashed or stopped responding'
        }
    }

    $incident = $false
    if ($Settings.Warnings) {
        if ($cause) {
            $incident = ($lost -ge $Settings.RestartMinFolders)
        } elseif ($Settings.DropWarnings -and $after -gt 0 -and $lost -ge $Settings.DropMinFolders -and
                  ($lost * 100) -ge ($Settings.DropMinPercent * $before)) {
            # $after -gt 0: closing everything is taken as deliberate.
            $incident = $true
            $cause  = 'drop'
            $reason = ('{0} of the {1} folders were closed between two backups' -f $lost, $before)
        }
    }

    [pscustomobject]@{
        Incident    = $incident
        Cause       = $cause
        Reason      = $reason
        Missing     = $diff.Missing
        Added       = $diff.Added
        BeforeCount = $before
        AfterCount  = $after
    }
}

function Get-CleanupPlan {
    # Which automatic backups to delete after a save. Pure: decides, deletes
    # nothing. Never chosen: a locked backup, the one just saved, and the
    # newest complete one (so a run of incomplete scans cannot push the last
    # full record out).
    param(
        [object[]]$Backups,       # Read-SessionBackup objects
        [string]$NewestFile,      # file name of the backup just saved
        [string[]]$LockedFiles,   # baseline files of unresolved incidents
        [int]$Keep
    )
    $locked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($LockedFiles)) { if ($f) { [void]$locked.Add($f) } }

    $sorted = @($Backups | Sort-Object -Property @{ Expression = { $_.SavedAt }; Descending = $true }, @{ Expression = { $_.File }; Descending = $true })
    $newest = $sorted | Where-Object { $_.File -eq $NewestFile } | Select-Object -First 1
    $newestComplete = $sorted | Where-Object { $_.Complete } | Select-Object -First 1
    $gone = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Same folders as the new save: it says all they say. Only a complete save
    # can stand in for another.
    if ($newest -and $newest.Complete) {
        foreach ($b in $sorted) {
            if ($b.File -eq $newest.File -or $locked.Contains($b.File)) { continue }
            if (Test-SameFolders $newest.Groups $b.Groups) {
                [void]$gone.Add($b.File)
                [pscustomobject]@{ Path = $b.Path; File = $b.File; Why = 'same folders as the new backup' }
            }
        }
    }

    # Then the newest $Keep of what is left; locked ones are kept on top.
    $kept = 0
    foreach ($b in $sorted) {
        if ($gone.Contains($b.File) -or $locked.Contains($b.File)) { continue }
        $kept++
        if ($kept -le $Keep) { continue }
        if ($b.File -eq $NewestFile) { continue }
        if ($newestComplete -and $b.File -eq $newestComplete.File) { continue }
        [void]$gone.Add($b.File)
        [pscustomobject]@{ Path = $b.Path; File = $b.File; Why = ('more than {0} backups' -f $Keep) }
    }
}

# ---------------------------------------------------------------------------
# One automatic run, after the scan
#
# Everything comes in as arguments (the scan's result, the time, how to look
# up restarts), so the tests can drive whole sequences of runs with made-up
# scans. The caller holds the state mutex around it.
#
# Windows PowerShell 5.1 throws "Argument types do not match" for @() around
# a List kept on an object, so copies of $state.Incidents use ToArray().
# ---------------------------------------------------------------------------

function Update-AutomaticBackups {
    param(
        [string]$Folder,
        [object[]]$Groups,                 # the scan's windows: string[] each
        [object[]]$Names,                  # display names, parallel to $Groups
        [bool]$Complete,                   # Test-ScanComplete
        [int]$FrozenCount,
        [string]$ScanError,
        [string]$Note,                     # frozen-tab report for the restore file
        [DateTimeOffset]$Now,
        $Settings,                         # Read-BackupSettings output
        [int]$IntervalMinutes = 60,        # the task's, for KeepBackups = auto
        [scriptblock]$RestartInfoSince,    # { param($Since) ... } -> Get-ExplorerRestartInfo shape
        [switch]$NoWindow,                 # never ask for the window (tests)
        [switch]$WindowOpen                # the lost-folder window is already up
    )
    if ($null -eq $Groups) { $Groups = @() }

    $state = Read-BackupState -Folder $Folder
    if ($state.Unreadable) {
        Write-BackupLog $Folder 'state.json could not be read; it was renamed and kept. Nothing is deleted this run.'
    }
    $lastComplete = @(Get-SessionBackups -Folder $Folder) | Where-Object { $_.Complete } | Select-Object -First 1

    # The session to compare with: the newest complete backup, or a later
    # scan that found nothing open.
    $baseline = $null
    if ($state.LastEmptyAt -and (-not $lastComplete -or $state.LastEmptyAt -gt $lastComplete.SavedAt)) {
        $baseline = [pscustomobject]@{ File = $null; Groups = @(); SavedAt = $state.LastEmptyAt }
    } elseif ($lastComplete) {
        $baseline = $lastComplete
    }
    $restart = & $RestartInfoSince $(if ($baseline) { $baseline.SavedAt } else { $Now })
    if ($restart.EventLogError) {
        Write-BackupLog $Folder ("Could not read the Application log, so crashes go unnoticed this run: {0}" -f $restart.EventLogError)
    }

    # Locks whose job is done.
    foreach ($incident in $state.Incidents.ToArray()) {
        if (-not [IO.File]::Exists((Join-Path $Folder $incident.BaselineFile))) {
            [void]$state.Incidents.Remove($incident)
            Write-BackupLog $Folder ("Lock released: '{0}' is gone." -f $incident.BaselineFile)
        } elseif ($Complete) {
            $still = Compare-SessionFolders -Before @(, $incident.Missing) -After $Groups
            if ($still.Missing.Count -eq 0) {
                [void]$state.Incidents.Remove($incident)
                Write-BackupLog $Folder ("Lock released: all {0} folder(s) lost since '{1}' are open again." -f $incident.Missing.Count, $incident.BaselineFile)
            }
        }
    }

    # A partial scan says nothing about what closed, so only a complete one
    # is judged.
    $verdict = $null
    if ($Complete -and $baseline) {
        $verdict = Get-LostFolderVerdict -BaselineGroups $baseline.Groups -BaselineTime $baseline.SavedAt `
            -CurrentGroups $Groups -RestartInfo $restart -Settings $Settings
    }
    $newIncident = $null
    if ($verdict -and $verdict.Incident -and $baseline.File -and
        @($state.Incidents | Where-Object { $_.BaselineFile -eq $baseline.File }).Count -eq 0) {
        $newIncident = [pscustomobject]@{
            Id              = $Now.ToString('yyyyMMdd-HHmmss')
            DetectedAt      = $Now
            BaselineFile    = $baseline.File
            BaselineSavedAt = $baseline.SavedAt
            CurrentFile     = ''
            Cause           = $verdict.Cause
            Reason          = $verdict.Reason
            Missing         = [string[]]@($verdict.Missing | ForEach-Object { $_.Path })
            Notified        = $false
        }
        $state.Incidents.Add($newIncident)
    }

    $savedFile = $null
    if ($Groups.Count -gt 0) {
        $savedFile = 'Restore Explorer Session {0}.ps1' -f $Now.ToString('yyyy.MM.dd HH-mm-ss')
        $meta = [ordered]@{
            format     = 1
            version    = $script:ProgramVersion
            savedAt    = $Now.ToString('o')
            kind       = 'auto'
            label      = ''
            complete   = $Complete
            frozenTabs = $FrozenCount
            names      = $Names
            bootTime   = $(if ($restart.BootTime) { $restart.BootTime.ToString('o') } else { $null })
            shellStart = $(if ($restart.ShellStart) { $restart.ShellStart.ToString('o') } else { $null })
        }
        Write-RestoreScript -Path (Join-Path $Folder $savedFile) -Groups $Groups -Note $Note -Meta $meta
        if ($newIncident) { $newIncident.CurrentFile = $savedFile }
    } elseif ($Complete -and -not ($verdict -and $verdict.Incident)) {
        # Everything closed, and nothing says it happened by itself: taken
        # as deliberate, and the next scan compares with that.
        $state.LastEmptyAt = $Now
    }

    $removed = New-Object 'System.Collections.Generic.List[object]'
    if ($savedFile -and -not $state.Unreadable) {
        $locked = @($state.Incidents | ForEach-Object { $_.BaselineFile })
        $plan = @(Get-CleanupPlan -Backups @(Get-SessionBackups -Folder $Folder) -NewestFile $savedFile `
            -LockedFiles $locked -Keep (Resolve-KeepCount -KeepBackups $Settings.KeepBackups -IntervalMinutes $IntervalMinutes))
        foreach ($item in $plan) {
            try {
                [IO.File]::Delete($item.Path)
                $removed.Add($item)
            } catch {
                Write-BackupLog $Folder ("Could not delete '{0}': {1}" -f $item.File, $_.Exception.Message)
            }
        }
    }

    # One line for the run, one more for a loss.
    $folderCount = 0
    foreach ($g in $Groups) { $folderCount += @($g).Count }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($savedFile) {
        $parts.Add(("Saved '{0}': {1} folder(s) in {2} window(s)" -f $savedFile, $folderCount, $Groups.Count))
    } elseif ($Complete) {
        $parts.Add('Nothing saved: no folder is open')
    } else {
        $parts.Add('Nothing saved: Explorer did not answer')
    }
    if (-not $Complete) {
        $parts.Add(("INCOMPLETE: {0} tab(s) did not answer{1}" -f $FrozenCount, $(if ($ScanError) { ', ' + $ScanError } else { '' })))
    }
    if ($verdict) {
        $since = if ($baseline.File) { "'{0}'" -f $baseline.File } else { 'the empty scan at {0}' -f $baseline.SavedAt.ToString('yyyy-MM-dd HH:mm') }
        $parts.Add(("since {0}: {1} missing, {2} new{3}" -f $since, $verdict.Missing.Count, $verdict.Added.Count,
            $(if ($verdict.Cause) { ' - ' + $verdict.Reason } else { '' })))
    }
    if ($removed.Count -gt 0) {
        $parts.Add(('deleted ' + (($removed | ForEach-Object { "'{0}' ({1})" -f $_.File, $_.Why }) -join ', ')))
    }
    Write-BackupLog $Folder ($parts.ToArray() -join '; ')
    if ($newIncident) {
        Write-BackupLog $Folder ("LOST FOLDERS: {0} of the {1} folders in '{2}' are gone - {3}. That backup is locked until the loss is checked." -f $verdict.Missing.Count, $verdict.BeforeCount, $newIncident.BaselineFile, $verdict.Reason)
    }

    $launch = $false
    $pending = @($state.Incidents | Where-Object { -not $_.Notified })
    if ($pending.Count -gt 0 -and $Settings.Warnings) {
        if ($NoWindow) {
            Write-BackupLog $Folder 'The lost-folder window was not opened (-NoWindow).'
        } elseif ($WindowOpen) {
            Write-BackupLog $Folder 'The lost-folder window is already open; the newer loss will be shown after it.'
        } else {
            foreach ($p in $pending) { $p.Notified = $true }
            $launch = $true
        }
    }

    Write-BackupState -Folder $Folder -State $state

    [pscustomobject]@{
        SavedFile   = $savedFile
        Removed     = $removed.ToArray()
        NewIncident = $newIncident
        Verdict     = $verdict
        Launch      = $launch
    }
}

function Remove-BackupIncident {
    # Releases one lock after the person has dealt with the loss. Takes the
    # state mutex itself. Returns $false when the state could not be changed.
    param([string]$Folder, [string]$Id, [string]$Why)
    $stateLock = Enter-NamedMutex -Name 'Local\SaveExplorerWindows.State' -TimeoutMs 30000
    if (-not $stateLock) { return $false }
    try {
        $state = Read-BackupState -Folder $Folder
        if ($state.Unreadable) { return $false }
        foreach ($match in @($state.Incidents | Where-Object { $_.Id -eq $Id })) {
            [void]$state.Incidents.Remove($match)
            Write-BackupLog $Folder ("Lock released on '{0}': {1}." -f $match.BaselineFile, $Why)
        }
        Write-BackupState -Folder $Folder -State $state
        $true
    } finally {
        Exit-NamedMutex $stateLock
    }
}

function Get-DefaultPaths {
    # Everything lives beside this module. Every saved session is under
    # "Saved sessions", so one .stignore line keeps them all out of sync.
    $saves = Join-Path $PSScriptRoot 'Saved sessions'
    [pscustomobject]@{
        Folder       = $PSScriptRoot
        SavesFolder  = $saves
        AutoFolder   = Join-Path $saves 'Automatic backups'
        ManualFolder = Join-Path $saves 'Manual saves'
        Settings     = Join-Path $PSScriptRoot 'Settings.ini'
        Compare      = Join-Path $PSScriptRoot 'Compare Explorer Backups.ps1'
    }
}

function Move-LegacySaveFolders {
    # Versions 6.0 and 6.1 kept "Automatic backups" and "Manual saves"
    # directly beside the script. Moves each into "Saved sessions" when its
    # new place does not exist yet, so a PC upgraded in place keeps its
    # backups, locks and comparison point. One line per folder found, for
    # the log. Run by an automatic run only, under its mutex: nothing else
    # writes into "Automatic backups".
    param([string]$Root)
    $saves = Join-Path $Root 'Saved sessions'
    foreach ($name in 'Automatic backups', 'Manual saves') {
        $old = Join-Path $Root $name
        $new = Join-Path $saves $name
        if (-not [IO.Directory]::Exists($old)) { continue }
        if ([IO.Directory]::Exists($new)) {
            "'$name' beside the script left as it is: 'Saved sessions\$name' already exists."
            continue
        }
        try {
            if (-not [IO.Directory]::Exists($saves)) { [void][IO.Directory]::CreateDirectory($saves) }
            [IO.Directory]::Move($old, $new)
            "Moved '$name' into 'Saved sessions'."
        } catch {
            "Could not move '$name' into 'Saved sessions', so it stays in use where it is: $($_.Exception.Message)"
        }
    }
}

function Resolve-SaveFolder {
    # The folder to use: the default one, or the one beside the script that
    # 6.0 and 6.1 used, while it has not been moved yet.
    param([string]$Folder, [string]$Legacy)
    if (-not [IO.Directory]::Exists($Folder) -and $Legacy -and [IO.Directory]::Exists($Legacy)) { return $Legacy }
    $Folder
}

# ---------------------------------------------------------------------------
# The save folders
#
# Every restore script, and state.json, lists someone's open folders, so the
# folders holding them stay out of backups and file sync. Kopia reads a
# .kopiaignore in any folder; "*" leaves out everything in and below it.
#
# Not a CACHEDIR.TAG, though Kopia honours that too: the tag declares a
# folder disposable in full, and tools that trust it (cleanup scripts,
# delete guards) may then remove its contents unasked. These are backups.
#
# Syncthing reads neither file. It needs the folder named in the .stignore
# at the root of the synced folder, on each device (DOC.md).
# ---------------------------------------------------------------------------

# A plain string, not a here-string: every here-string adds a line starting
# with '@ to this file, and the checks for a truncated restore template count
# those (.claude/rules/script.md).
$script:KopiaIgnoreText = @(
    '# Save Explorer Windows: saved Explorer sessions. Every file here lists'
    '# open folders, so Kopia leaves this folder out. These are backups, not a'
    '# cache: do not swap this file for a CACHEDIR.TAG.'
    '*'
) -join "`n"

function Initialize-SaveFolder {
    # Creates a save folder and its .kopiaignore. An existing .kopiaignore is
    # left as it is: someone may have edited it on purpose.
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { [void][IO.Directory]::CreateDirectory($Path) }
    $marker = Join-Path $Path '.kopiaignore'
    if (-not [IO.File]::Exists($marker)) {
        [IO.File]::WriteAllText($marker, $script:KopiaIgnoreText + "`n", $script:Utf8NoBom)
    }
}

# ---------------------------------------------------------------------------
# The compare window's logic
#
# "Compare Explorer Backups.ps1" is only the window. What each list shows,
# where each chosen folder opens, and the opening itself live here, so the
# tests can drive them without a screen.
# ---------------------------------------------------------------------------

function New-CompareRowList {
    param([object[]]$Groups, [object[]]$Names, $Marked, [string]$Mark)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $w = 0
    foreach ($g in @($Groups)) {
        $t = 0
        foreach ($p in @($g)) {
            if (-not [string]::IsNullOrEmpty($p)) {
                $name = $null
                if ($Names -and $w -lt @($Names).Count) {
                    $nw = @(@($Names)[$w])
                    if ($t -lt $nw.Count) { $name = [string]$nw[$t] }
                }
                if ([string]::IsNullOrWhiteSpace($name)) { $name = Get-FolderDisplayName $p }
                $status = if ($Marked.Contains(('{0}:{1}' -f $w, $t))) { $Mark } else { 'same' }
                $rows.Add([pscustomobject]@{ Window = $w; Tab = $t; Path = [string]$p; Name = $name; Status = $status })
            }
            $t++
        }
        $w++
    }
    ,$rows.ToArray()
}

function Get-CompareRows {
    # One row per tab of each session, in window and tab order. A Before row
    # is 'missing' when After lacks it, an After row 'added' when Before
    # lacks it, others 'same'; paired as Compare-SessionFolders pairs them,
    # as a multiset in any letter case.
    param([object[]]$Before, [object[]]$After, [object[]]$BeforeNames, [object[]]$AfterNames)
    $diff = Compare-SessionFolders -Before $Before -After $After
    $missing = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in $diff.Missing) { [void]$missing.Add(('{0}:{1}' -f $m.Window, $m.Tab)) }
    $added = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($a in $diff.Added) { [void]$added.Add(('{0}:{1}' -f $a.Window, $a.Tab)) }
    [pscustomobject]@{
        Before = New-CompareRowList -Groups $Before -Names $BeforeNames -Marked $missing -Mark 'missing'
        After  = New-CompareRowList -Groups $After -Names $AfterNames -Marked $added -Mark 'added'
    }
}

function New-OpenPlan {
    # Decides where each chosen folder opens, opening nothing. -Selected:
    # objects with Path and Group (every path of the saved window it came
    # from). -Open: the windows open now, objects with Key (the HWND) and
    # Paths.
    # A folder already open is skipped. Any other goes in as a tab of the
    # window holding most of its former tab-mates, whether open now or opened
    # earlier in the plan; with none, it gets a new window, which its later
    # tab-mates then join. So tabs that were together end up together as
    # far as the windows open now allow.
    param([object[]]$Selected, [object[]]$Open)
    $ignoreCase = [StringComparer]::OrdinalIgnoreCase
    $windows = New-Object 'System.Collections.Generic.List[object]'
    $isOpen  = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
    foreach ($o in @($Open)) {
        $paths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in @($o.Paths)) { if ($p) { $paths.Add([string]$p); [void]$isOpen.Add([string]$p) } }
        $windows.Add([pscustomobject]@{ Key = [string]$o.Key; Paths = $paths })
    }
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    $newWindows = 0
    foreach ($sel in @($Selected)) {
        $path = [string]$sel.Path
        if ($isOpen.Contains($path)) { $skipped++; continue }
        $mates = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        foreach ($p in @($sel.Group)) { if ($p) { [void]$mates.Add([string]$p) } }
        [void]$mates.Remove($path)
        $best = $null
        $bestScore = 0
        foreach ($w in $windows) {
            $score = 0
            foreach ($p in $w.Paths) { if ($mates.Contains($p)) { $score++ } }
            if ($score -gt $bestScore) { $best = $w; $bestScore = $score }
        }
        if ($best) {
            $steps.Add([pscustomobject]@{ Kind = 'Tab'; Key = $best.Key; Path = $path })
            $best.Paths.Add($path)
        } else {
            $newWindows++
            $key = 'new' + $newWindows
            $steps.Add([pscustomobject]@{ Kind = 'Window'; Key = $key; Path = $path })
            $first = New-Object 'System.Collections.Generic.List[string]'
            $first.Add($path)
            $windows.Add([pscustomobject]@{ Key = $key; Paths = $first })
        }
        [void]$isOpen.Add($path)
    }
    [pscustomobject]@{ Steps = $steps.ToArray(); Skipped = $skipped }
}

function Get-ComIdentity {
    # Two wrappers of one COM object are not -eq; the IUnknown pointer is.
    param($Object)
    $ptr = [Runtime.InteropServices.Marshal]::GetIUnknownForObject($Object)
    try { $ptr.ToInt64() } finally { [void][Runtime.InteropServices.Marshal]::Release($ptr) }
}

function ConvertTo-ShellTarget {
    # Shell locations (::{GUID}) open through "shell:"; paths as they are.
    param([string]$Path)
    if ($Path.StartsWith('::')) { 'shell:' + $Path } else { $Path }
}

function Open-ShellWindow {
    # A new Explorer window on $Path; its HWND, or $null after 10 s.
    param($Shell, [string]$Path)
    $before = @(foreach ($w in @($Shell.Windows())) { try { [int64]$w.HWND } catch { } })
    $Shell.Open((ConvertTo-ShellTarget $Path))
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $new = @(foreach ($w in @($Shell.Windows())) { try { [int64]$w.HWND } catch { } }) | Where-Object { $before -notcontains $_ }
        if (@($new).Count -gt 0) { return [int64]@($new)[0] }
    }
    $null
}

function Add-ShellTab {
    # A new tab on $Path in the window $Hwnd, asked for without keystrokes
    # (ExplorerWindowProbe3.RequestNewTab). $false when the window adds none
    # within 5 s; nothing here ever presses keys.
    param($Shell, [int64]$Hwnd, [string]$Path)
    Initialize-ExplorerWindowProbe
    $before = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($w in @($Shell.Windows())) { try { [void]$before.Add((Get-ComIdentity $w)) } catch { } }
    if (-not [ExplorerWindowProbe3]::RequestNewTab($Hwnd)) { return $false }
    $tab = $null
    $deadline = (Get-Date).AddSeconds(5)
    while (-not $tab -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        foreach ($w in @($Shell.Windows())) {
            try {
                if ([int64]$w.HWND -eq $Hwnd -and -not $before.Contains((Get-ComIdentity $w))) { $tab = $w; break }
            } catch { }
        }
    }
    if (-not $tab) { return $false }
    $tab.Navigate2((ConvertTo-ShellTarget $Path))
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        try { if (-not $tab.Busy) { break } } catch { break }
        Start-Sleep -Milliseconds 100
    }
    $true
}

function Invoke-OpenPlan {
    # Carries out New-OpenPlan's steps through Shell.Application on the
    # calling thread, which must be STA. Run it off a window's own thread: a
    # frozen Explorer window makes any of these calls wait for good.
    # Reports through the synchronized hashtable $Progress: Total, Done,
    # Current, and at the end Failed (paths) and Finished.
    # A tab the window does not add opens as a new window instead, and that
    # window's later tab-mates follow it there.
    param([object[]]$Steps, $Progress)
    Initialize-ExplorerWindowProbe
    $sh = New-Object -ComObject Shell.Application
    $hwndOf = @{}
    $failed = New-Object 'System.Collections.Generic.List[string]'
    if ($Progress) { $Progress['Total'] = @($Steps).Count; $Progress['Done'] = 0 }
    foreach ($step in @($Steps)) {
        if ($Progress) { $Progress['Current'] = $step.Path }
        $ok = $false
        try {
            if ($step.Kind -eq 'Tab') {
                $hwnd = $null
                if ($hwndOf.ContainsKey($step.Key)) { $hwnd = $hwndOf[$step.Key] }
                elseif ($step.Key -match '^\d+$') { $hwnd = [int64]$step.Key }
                if ($hwnd -and [ExplorerWindowProbe3]::WindowExists($hwnd)) {
                    $ok = Add-ShellTab -Shell $sh -Hwnd $hwnd -Path $step.Path
                }
            }
            if (-not $ok) {
                $new = Open-ShellWindow -Shell $sh -Path $step.Path
                if ($new) { $hwndOf[$step.Key] = $new; $ok = $true }
            }
        } catch {
            $ok = $false
        }
        if (-not $ok) { $failed.Add($step.Path) }
        if ($Progress) { $Progress['Done'] = [int]$Progress['Done'] + 1 }
    }
    if ($Progress) { $Progress['Failed'] = $failed.ToArray(); $Progress['Finished'] = $true }
    [pscustomobject]@{ Failed = $failed.ToArray(); Windows = $hwndOf }
}

# ---------------------------------------------------------------------------
# The scheduled task
#
# One definition, used by "Set up automatic backups.ps1" and checked by the
# tests. The task runs the script, so the script's file name is fixed: a
# rename stops the backups until the setup is run again.
# ---------------------------------------------------------------------------

$script:TaskName = 'Save Explorer Windows'
# Names an earlier setup registered the task under. Get-AutoBackupTask
# finds one, so the setup can replace it with the current name instead
# of leaving a second task running beside the new one.
$script:LegacyTaskNames = @('Save Explorer Windows every 2 hours')

# The intervals the setup offers, in minutes: each divides a day, so the
# runs fall at the same times every day. Nothing shorter than 10 minutes:
# a run after a sign-in waits 5 minutes before it scans, and
# KeepBackups = auto would keep hundreds of files (288 at 10 minutes).
$script:TaskIntervalMinutes = @(10, 20, 30, 60, 120, 180, 240, 360, 480, 720)
$script:DefaultTaskIntervalMinutes = 60

function Get-AutoBackupTaskName { $script:TaskName }
function Get-TaskIntervalChoices { $script:TaskIntervalMinutes }
function Get-DefaultTaskInterval { $script:DefaultTaskIntervalMinutes }

# How far back KeepBackups = auto reaches.
$script:AutoKeepHours = 48

function Get-AutoKeepHours { $script:AutoKeepHours }

function Resolve-KeepCount {
    # The number of backups cleanup keeps: KeepBackups itself, or for auto
    # (0) enough to cover $AutoKeepHours at the given interval, rounded up.
    # Backups holding the same folders replace each other, so a quiet
    # period makes the kept ones reach further back still.
    param([int]$KeepBackups, [int]$IntervalMinutes)
    if ($KeepBackups -gt 0) { return $KeepBackups }
    if ($IntervalMinutes -le 0) { $IntervalMinutes = $script:DefaultTaskIntervalMinutes }
    [int][math]::Ceiling($script:AutoKeepHours * 60 / $IntervalMinutes)
}

function Format-KeepSpan {
    # How far back $Count backups at $IntervalMinutes reach, at least.
    param([int]$Count, [int]$IntervalMinutes)
    $hours = $Count * $IntervalMinutes / 60
    if ($hours -lt 1) { '{0} minutes' -f ($Count * $IntervalMinutes) }
    elseif ($hours -eq [math]::Floor($hours)) { '{0} hours' -f $hours }
    else { '{0:0.#} hours' -f $hours }
}

function Get-AutoBackupInterval {
    # The registered task's interval in minutes, or the default when there
    # is no task or its interval cannot be read.
    $minutes = 0
    try { $task = Get-AutoBackupTask; if ($task) { $minutes = Get-TaskInterval $task } } catch { }
    if ($minutes -gt 0) { $minutes } else { $script:DefaultTaskIntervalMinutes }
}

function ConvertFrom-IntervalText {
    # What a person typed at the setup's question, in minutes; $null when it
    # is not one of the offered intervals. A bare 10, 20 or 30 is minutes,
    # any other bare number hours, since the two lists share no number;
    # "m"/"min"/"minutes" and "h"/"hour"/"hours" say which.
    param([string]$Text)
    $m = [regex]::Match($Text.Trim().ToLowerInvariant(), '^(\d{1,4})\s*(m|min|mins|minutes?|h|hours?)?$')
    if (-not $m.Success) { return $null }
    $n = [int]$m.Groups[1].Value
    $unit = $m.Groups[2].Value
    $minutes = if ($unit.StartsWith('m')) { $n }
               elseif ($unit) { $n * 60 }
               elseif ($n -lt 60 -and $script:TaskIntervalMinutes -contains $n) { $n }
               else { $n * 60 }
    if ($script:TaskIntervalMinutes -contains $minutes) { $minutes } else { $null }
}

function Get-AutoBackupTask {
    # The registered task under its current name, else under a legacy one;
    # $null when there is none.
    foreach ($n in @($script:TaskName) + $script:LegacyTaskNames) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) { return $t }
    }
    $null
}

function Format-TaskInterval {
    param([int]$Minutes)
    if ($Minutes -eq 60) { 'every hour' }
    elseif ($Minutes -eq 1440) { 'once a day' }
    elseif ($Minutes % 60 -eq 0) { 'every {0} hours' -f ($Minutes / 60) }
    else { 'every {0} minutes' -f $Minutes }
}

function New-AutoBackupTask {
    # The task's definition, not registered. conhost --headless keeps a
    # console window from flashing up at every run. The arguments are one
    # string, the path quoted, since paths here hold spaces and commas.
    # Interactive + Limited: runs only while the user is signed in, without
    # administrator rights - an elevated process sees no Explorer windows.
    param([string]$ScriptPath, [int]$Minutes = $script:DefaultTaskIntervalMinutes)
    if ($script:TaskIntervalMinutes -notcontains $Minutes) {
        throw ("An interval of {0} minutes is not one of: {1}" -f $Minutes, ($script:TaskIntervalMinutes -join ', '))
    }
    $folder = Split-Path -Parent $ScriptPath
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -WorkingDirectory $folder `
        -Argument ('--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Auto' -f $ScriptPath)
    # Daily from ten to one, repeating every $Minutes for the day.
    $trigger = New-ScheduledTaskTrigger -Daily -At '00:50'
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:50' -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description ('Saves the open Explorer windows {0} into "Saved sessions\Automatic backups" beside {1}, removes old backups and warns about lost folders.' -f (Format-TaskInterval $Minutes), (Split-Path -Leaf $ScriptPath))
}

function Get-TaskInterval {
    # An existing task's interval in minutes, from its first trigger's
    # repetition (ISO 8601, "PT20M", "PT2H"); none means once a day, 1440.
    # 0 when it holds no whole number of minutes. The setup offers the
    # value back only when it is one of its choices.
    param($Task)
    $trigger = @($Task.Triggers)[0]
    if (-not $trigger) { return 0 }
    $interval = [string]$trigger.Repetition.Interval
    if (-not $interval) { return 1440 }
    try { $span = [Xml.XmlConvert]::ToTimeSpan($interval) } catch { return 0 }
    if ($span.TotalMinutes -ge 1 -and $span.TotalMinutes -eq [math]::Floor($span.TotalMinutes)) { [int]$span.TotalMinutes } else { 0 }
}

function Get-TaskScriptPath {
    # The script an existing task runs, from its action's arguments.
    param($Task)
    $arguments = [string](@($Task.Actions)[0].Arguments)
    $m = [regex]::Match($arguments, '-File "([^"]+)"')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

Export-ModuleMember -Function *
