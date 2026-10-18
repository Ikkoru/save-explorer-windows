# Save Explorer Windows.ps1
#
# Saves currently open Explorer windows to a self-contained restore .ps1.
# Tab grouping is preserved.
#
# Run by hand, it asks for an optional label and saves into
# "Saved sessions\Manual saves" beside this script. Those saves are never
# cleaned up.
#
# Every save lives under "Saved sessions". Its folders get a .kopiaignore, so
# Kopia leaves them out; Syncthing needs a line in its .stignore instead
# (DOC.md).
#
# Keep this file's name: a Task Scheduler task names it, and a rename stops
# the automatic backups until the task's action is updated. The version is
# $ProgramVersion in the module, printed by a run by hand.
#
# With -Auto (Task Scheduler runs it every two hours) it asks nothing, saves
# into "Saved sessions\Automatic backups", and then:
#   - deletes older automatic backups holding the same folders as the new one
#     (which window a folder was a tab in does not count);
#   - keeps only the newest few (KeepBackups in Settings.ini);
#   - checks for folders that closed without anyone closing them: lost to a
#     PC restart, a sign-out or an Explorer crash, or many gone at once
#     (thresholds in Settings.ini). The last backup from before such a loss
#     is locked against cleanup, and a window about it opens.
# A scan that finds no folder open is never kept. log.txt beside the
# automatic backups records every automatic run.
#
# First-time setup for running by hand (one of):
#   1. In a PowerShell window, run:  Set-ExecutionPolicy RemoteSigned -CurrentUser
#   2. Right-click this file and choose "Run with PowerShell" (may prompt)
#
# Needs "Explorer Windows Shared.psm1" beside it; that file also describes
# the target environment and how frozen windows are handled. This file stays
# pure ASCII for the same reason it does.

param(
    [switch]$Auto,            # the scheduled run described above
    [switch]$ShowIncident,    # opens the window about the newest unhandled loss
    [string]$BackupFolder,    # automatic backups; default "Saved sessions\Automatic backups"
    [string]$ManualFolder,    # saves by hand; default "Saved sessions\Manual saves"
    [string]$SettingsPath,    # default Settings.ini beside this script
    [switch]$NoWindow         # with -Auto: record a loss but open no window (tests)
)

$ErrorActionPreference = 'Stop'

# Shell.Application's window enumeration only works from a Single-Threaded
# Apartment. Windows PowerShell 5.1 is STA by default, but PowerShell 7 (pwsh)
# and some hosts default to MTA, where Windows() silently returns nothing.
# If we're not in STA, relaunch under Windows PowerShell with -STA, passing the
# parameters along.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($name in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$name]
            if ($value -is [switch]) {
                if ($value.IsPresent) { $relaunch += "-$name" }
            } else {
                $relaunch += "-$name"
                $relaunch += [string]$value
            }
        }
        powershell.exe @relaunch
        exit $LASTEXITCODE
    } else {
        Write-Warning "Not running in STA mode and cannot self-relaunch. Run with Windows PowerShell."
    }
}

Import-Module -Name (Join-Path $PSScriptRoot 'Explorer Windows Shared.psm1') -Force -DisableNameChecking

$defaults = Get-DefaultPaths
# A default save folder may still be where 6.0 and 6.1 kept it, beside this
# script, until an automatic run moves it (Move-LegacySaveFolders).
$legacyAuto   = $null
$legacyManual = $null
if (-not $BackupFolder) { $BackupFolder = $defaults.AutoFolder;   $legacyAuto   = Join-Path $defaults.Folder 'Automatic backups' }
if (-not $ManualFolder) { $ManualFolder = $defaults.ManualFolder; $legacyManual = Join-Path $defaults.Folder 'Manual saves' }
if (-not $SettingsPath) { $SettingsPath = $defaults.Settings }
$BackupFolder = $BackupFolder.TrimEnd('\')
$ManualFolder = $ManualFolder.TrimEnd('\')

# ---------------------------------------------------------------------------
# Report lines carry their own visibility
#
# The diagnostic report exists at two levels: a short one for a normal run, and
# the full one when the label typed at the prompt contains "debug". Tagging each
# line as it is built keeps one code path; do not fork this into two builders
# that then drift apart. .claude/rules/script.md holds the level-by-level table.
# ---------------------------------------------------------------------------

function Add-ReportLine {
    param(
        [System.Collections.Generic.List[object]]$Lines,
        [string]$Text = '',
        [switch]$DebugOnly,     # full report only - internals, IDs, explanations
        [switch]$QuietOnly      # short report only - a condensed restatement
    )
    [void]$Lines.Add([pscustomobject]@{
        Text  = $Text
        Quiet = -not $DebugOnly
        Full  = -not $QuietOnly
    })
}

function Format-ReportText {
    # Renders one level of the report. Dropping lines leaves runs of blank ones
    # behind, so collapse them rather than shipping a gappy report.
    param([System.Collections.Generic.List[object]]$Lines, [switch]$Full)
    $kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Lines) {
        if ($Full) { if (-not $entry.Full) { continue } } else { if (-not $entry.Quiet) { continue } }
        if ([string]::IsNullOrWhiteSpace($entry.Text) -and
            ($kept.Count -eq 0 -or [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1]))) { continue }
        [void]$kept.Add($entry.Text)
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }
    ($kept -join "`r`n")
}

function New-FrozenReport {
    # The frozen-tab report as text, '' when every tab answered. Embedded
    # (base64) in the restore script, and printed by a run by hand, so the
    # finding survives the console window closing.
    param($Scan, [switch]$DebugReport)

    $frozen             = $Scan.Frozen
    $enumerationBlocked = $Scan.Blocked
    $enumerationError   = $Scan.Error
    $enumerationHResult = $Scan.HResult
    $timeoutSec         = $Scan.TimeoutSec
    if ($frozen.Count -eq 0 -and -not $enumerationBlocked) { return '' }

    $lines = New-Object 'System.Collections.Generic.List[object]'
    if ($enumerationBlocked) {
        Add-ReportLine $lines $enumerationError
        if ($Scan.Groups.Count -gt 0) {
            Add-ReportLine $lines ("The scan stopped there. The {0} window(s) read before that point were still saved." -f $Scan.Groups.Count)
        } else {
            Add-ReportLine $lines 'No tab could be read at all, so no paths were saved.'
        }
        if (Test-RpcFailure $enumerationHResult) {
            Add-ReportLine $lines
            Add-ReportLine $lines ("{0} means the shell window service inside explorer.exe is not" -f $enumerationHResult) -DebugOnly
            Add-ReportLine $lines 'reachable. It is normally a knock-on effect of a hung Explorer window:' -DebugOnly
            Add-ReportLine $lines 'one stuck thread takes the COM service down with it, so no path can be' -DebugOnly
            Add-ReportLine $lines 'read from ANY window, hung or not.' -DebugOnly
            Add-ReportLine $lines 'What tends to work, in order:'
            Add-ReportLine $lines '  - Wait. A window stalled on a network or removable path frees itself'
            Add-ReportLine $lines '    once that access times out, and COM comes back with it. Re-run then.'
            Add-ReportLine $lines '  - Do NOT end the hung window in Task Manager. Every window listed here'
            Add-ReportLine $lines '    shares one explorer.exe, so ending it closes them all.'
            try {
                $persist = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name PersistBrowsers -ErrorAction Stop).PersistBrowsers
            } catch { $persist = 0 }
            if ($persist -eq 1) {
                Add-ReportLine $lines '  - "Restore previous folder windows at logon" is ON for this account,'
                Add-ReportLine $lines '    so signing out and back in reopens these windows. That is the only'
                Add-ReportLine $lines '    restart that does not simply lose them.'
            } else {
                Add-ReportLine $lines '  - "Restore previous folder windows at logon" is OFF for this account,'
                Add-ReportLine $lines '    so a sign-out will lose these windows. The titles below are then the'
                Add-ReportLine $lines '    only record - keep them.'
            }
        }
        Add-ReportLine $lines -DebugOnly
        Add-ReportLine $lines 'Everything below comes from the window manager, which stays responsive.' -DebugOnly
    } else {
        Add-ReportLine $lines ("{0} of {1} tab entries did not respond within {2}s and were NOT saved." -f $frozen.Count, $Scan.RawCount, $timeoutSec)
    }

    if ($frozen.Count -gt 0) {
        Add-ReportLine $lines
        Add-ReportLine $lines 'Frozen tab entries (index within the Shell.Application collection):' -DebugOnly
        foreach ($f in $frozen) {
            Add-ReportLine $lines ("  #{0} - the COM call blocked at: {1}" -f $f.Index, $f.Stage) -DebugOnly
            if ($f.Hwnd) { Add-ReportLine $lines ("      HWND         : {0} (0x{1:X8})" -f $f.Hwnd, $f.Hwnd) -DebugOnly }
            if ($f.Name) { Add-ReportLine $lines ("      Folder name  : {0}" -f $f.Name) -DebugOnly }
            if ($f.Url)  { Add-ReportLine $lines ("      Location URL : {0}" -f $f.Url) -DebugOnly }
            if (-not ($f.Hwnd -or $f.Name -or $f.Url)) {
                Add-ReportLine $lines '      (nothing readable - the call blocked before any property came back)' -DebugOnly
            }
            # Anything a frozen tab did give up names a path the restore file
            # will not contain, so it earns its place in the short report too.
            # LocationURL is percent-encoded; show it as a path a person can
            # paste into an address bar.
            if ($f.Name -or $f.Url) {
                $shown = $f.Name
                if ($f.Url) {
                    $shown = $f.Url
                    try { $shown = ([Uri]$f.Url).LocalPath } catch { }
                }
                Add-ReportLine $lines ("  Frozen tab: {0}" -f $shown) -QuietOnly
            }
        }
    }

    # Correlate with the window manager: every Explorer window whose HWND was
    # never seen by a successful COM read is a candidate for the frozen tabs.
    try {
        $probed          = @(Get-ExplorerWindowProbe)
        $explorerWindows = @($probed | Where-Object { $_.ClassName -ne 'Ghost' })
        $unaccounted     = @($explorerWindows | Where-Object { -not $Scan.SeenHwnds.Contains([int64]$_.Hwnd) })
        $ghosts          = @($probed | Where-Object { $_.ClassName -eq 'Ghost' })

        Add-ReportLine $lines
        Add-ReportLine $lines ("Explorer windows the window manager can see: {0} ({1} answered COM, {2} did not)" -f $explorerWindows.Count, ($explorerWindows.Count - $unaccounted.Count), $unaccounted.Count)

        if ($unaccounted.Count -gt 0) {
            Add-ReportLine $lines
            Add-ReportLine $lines 'Windows that could not be read:' -QuietOnly
            if ($frozen.Count -gt 0) {
                Add-ReportLine $lines 'Windows that never answered - the frozen tabs above belong to these:' -DebugOnly
            } else {
                Add-ReportLine $lines 'Every Explorer window currently open, none of which could be read:' -DebugOnly
            }
            # Every WM_GETTEXT is individually bounded, but a session with many
            # windows can still add them up, and on Windows 11 the whole probe
            # is a long shot. One shared budget, not one per window.
            $childProbeBudget = [Diagnostics.Stopwatch]::StartNew()

            foreach ($u in $unaccounted) {
                # Only feeds a debug line, so do not pay for it otherwise.
                $procName = ''
                if ($DebugReport) {
                    try { $procName = (Get-Process -Id $u.ProcessId -ErrorAction Stop).ProcessName } catch { }
                }
                $state = if ($u.Hung) { 'NOT RESPONDING' } else { 'answers window messages, but not COM' }
                $childText = $null
                if ($childProbeBudget.Elapsed.TotalSeconds -lt 2) {
                    try { $childText = Get-ExplorerChildText -Hwnd ([int64]$u.Hwnd) -TimeoutMs 200 } catch { }
                }

                # Title leads in both reports: it is the only field that
                # identifies the window to a person.
                Add-ReportLine $lines ("  {0}{1}" -f $u.Title, $(if ($u.Hung) { '   [NOT RESPONDING]' } else { '' }))
                if ($childText) { Add-ReportLine $lines ("      Address bar  : {0}" -f $childText) }

                Add-ReportLine $lines ("      HWND         : {0} (0x{1:X8}) - {2}" -f $u.Hwnd, $u.Hwnd, $state) -DebugOnly
                Add-ReportLine $lines ("      Class / PID  : {0} / {1} {2}" -f $u.ClassName, $u.ProcessId, $(if ($procName) { "($procName)" } else { '' })) -DebugOnly
                Add-ReportLine $lines ("      Placement    : {0}x{1} at {2},{3} ({4}{5})" -f $u.Width, $u.Height, $u.Left, $u.Top, $(if ($u.Visible) { 'visible' } else { 'hidden' }), $(if ($u.Minimized) { ', minimized' } else { '' })) -DebugOnly
                if (-not $childText) {
                    Add-ReportLine $lines '      Address bar  : (nothing readable - Windows 11 draws it in XAML, which needs the hung thread)' -DebugOnly
                }
            }
            Add-ReportLine $lines -DebugOnly
            Add-ReportLine $lines 'The title is the best identifier left: it names the active tab and counts' -DebugOnly
            Add-ReportLine $lines 'the rest.' -DebugOnly
            if (-not $enumerationBlocked) {
                Add-ReportLine $lines
                Add-ReportLine $lines 'Close that window (right-click its taskbar button) and re-run this script'
                Add-ReportLine $lines 'to capture everything else cleanly.'
            }
        }

        if ($ghosts.Count -gt 0) {
            Add-ReportLine $lines -DebugOnly
            Add-ReportLine $lines 'Ghost windows on screen (Windows draws one over any hung app, so these may' -DebugOnly
            Add-ReportLine $lines 'belong to other programs):' -DebugOnly
            foreach ($g in $ghosts) {
                Add-ReportLine $lines ("  '{0}' (HWND {1})" -f $g.Title, $g.Hwnd) -DebugOnly
            }
        }
    } catch {
        Add-ReportLine $lines
        Add-ReportLine $lines ("(Could not enumerate windows for correlation: {0})" -f $_.Exception.Message)
    }

    Format-ReportText -Lines $lines -Full:$DebugReport
}

function Show-FrozenReport {
    param($Scan, [string]$Note, [switch]$DebugReport)
    Write-Host ""
    if ($Scan.Frozen.Count -gt 0) { Write-Warning ("{0} frozen tab(s) skipped." -f $Scan.Frozen.Count) }
    # The first line repeats a warning already printed above; keep it in the
    # note (which travels alone) but not on screen.
    $consoleLines = @($Note -split "`r`n")
    if ($consoleLines.Count -gt 1 -and $Scan.Error -and $consoleLines[0] -eq $Scan.Error) {
        $consoleLines = $consoleLines[1..($consoleLines.Count - 1)]
    }
    foreach ($line in $consoleLines) { Write-Host $line -ForegroundColor Yellow }

    # Only surfaced once something has already gone wrong: the person who
    # needs the full report is exactly the one who does not know the label
    # trick. Console only - a restore script cannot be re-run with a label.
    if (-not $DebugReport) {
        Write-Host ""
        Write-Host 'For the full diagnostic report, re-run with the word "debug" in the label.' -ForegroundColor DarkGray
    }
    Write-Host ""
}

function New-SaveMeta {
    param($Scan, [string]$Kind, [string]$Label, [DateTimeOffset]$SavedAt, $RestartInfo)
    [ordered]@{
        format     = 1
        version    = (Get-ProgramVersion)
        savedAt    = $SavedAt.ToString('o')
        kind       = $Kind
        label      = $Label
        complete   = (Test-ScanComplete $Scan)
        frozenTabs = $Scan.Frozen.Count
        names      = (Get-ScanGroups $Scan -Names)
        bootTime   = $(if ($RestartInfo -and $RestartInfo.BootTime) { $RestartInfo.BootTime.ToString('o') } else { $null })
        shellStart = $(if ($RestartInfo -and $RestartInfo.ShellStart) { $RestartInfo.ShellStart.ToString('o') } else { $null })
    }
}

# ---------------------------------------------------------------------------
# Run by hand
# ---------------------------------------------------------------------------

function Invoke-ManualSave {
    param([string]$Folder)

    Write-Host ("Save Explorer Windows {0}" -f (Get-ProgramVersion))
    $docTitle = Read-Host "Enter descriptive label (optional)"

    # Hidden switch: a label containing the word "debug" (any case, anywhere)
    # turns on the full diagnostic report. The word is then stripped, so it never
    # reaches the output filename. Matching starts at a word boundary and eats
    # the rest of the word, so "debugging" counts but "predebugged" is left alone
    # rather than being silently gutted into "preged".
    # Keep it out of the prompt text and out of normal console output; the only
    # place it surfaces is one hint printed after a failed run. See
    # .claude/rules/script.md.
    $DebugReport = $false
    if ($docTitle -match '(?i)\bdebug') {
        $DebugReport = $true
        $docTitle = (($docTitle -replace '(?i)\bdebug\w*', '') -replace '\s{2,}', ' ').Trim()
    }

    $label = $docTitle
    if (-not [string]::IsNullOrWhiteSpace($docTitle)) { $docTitle = "_$docTitle" } else { $docTitle = '' }

    $now = [DateTimeOffset]::Now
    $filename = "Restore Explorer Session {0}{1}.ps1" -f $now.ToString('yyyy.MM.dd HH-mm-ss'), $docTitle
    $outputPath = Join-Path $Folder $filename

    $scan = Invoke-ExplorerScan -ShowProgress

    $frozenNote = New-FrozenReport -Scan $scan -DebugReport:$DebugReport
    if ($frozenNote) { Show-FrozenReport -Scan $scan -Note $frozenNote -DebugReport:$DebugReport }

    if ($scan.Groups.Count -eq 0) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Warning "No Explorer folder windows could be read. Nothing saved."
        if ($scan.Frozen.Count -gt 0) {
            Write-Warning ("All {0} tab entries were frozen - see the report above." -f $scan.Frozen.Count)
        }
        if ($isAdmin) {
            Write-Warning "This script is running elevated (as Administrator). Explorer normally runs non-elevated, and an elevated process cannot see non-elevated Explorer windows. Try running this script WITHOUT 'Run as administrator'."
        }
        return
    }

    $groups = Get-ScanGroups $scan
    $totalPaths = 0
    foreach ($g in $groups) { $totalPaths += $g.Count }
    Write-Host ("Found {0} window(s), {1} path(s) total." -f $groups.Count, $totalPaths)
    if ($scan.SkippedNonFolder -gt 0) {
        Write-Host ("Skipped {0} non-folder window(s) (This PC, Control Panel and similar)." -f $scan.SkippedNonFolder)
    }
    if ($scan.Frozen.Count -gt 0) {
        Write-Host ("Skipped {0} frozen tab(s) - details above, and repeated in the restore script." -f $scan.Frozen.Count) -ForegroundColor Yellow
    }

    $meta = New-SaveMeta -Scan $scan -Kind 'manual' -Label $label -SavedAt $now
    Initialize-SaveFolder -Path $Folder
    Write-RestoreScript -Path $outputPath -Groups $groups -Note $frozenNote -Meta $meta

    Write-Host ""
    Write-Host "Saved: $outputPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# The scheduled run
# ---------------------------------------------------------------------------

function Wait-ExplorerSettled {
    # Right after a sign-in or an Explorer restart, Windows is still reopening
    # the folder windows ("Restore previous folder windows at logon"), and a
    # scan then would report most of them lost. Wait until Explorer has been
    # up for a few minutes.
    param([string]$Folder)
    $settle  = [TimeSpan]::FromMinutes(5)
    $info    = Get-ExplorerRestartInfo -Since ([DateTimeOffset]::Now - $settle)
    $moments = @(@($info.ShellStart, $info.BootTime) + @($info.CrashTimes) | Where-Object { $_ })
    if ($moments.Count -eq 0) { return }
    $latest = $moments | Sort-Object -Descending | Select-Object -First 1
    $wait = ($latest + $settle) - [DateTimeOffset]::Now
    if ($wait -gt [TimeSpan]::Zero) {
        Write-BackupLog $Folder ("Explorer (re)started {0:N0} s ago; waiting {1:N0} s for its windows to reopen." -f ([DateTimeOffset]::Now - $latest).TotalSeconds, $wait.TotalSeconds)
        Start-Sleep -Seconds ([math]::Ceiling($wait.TotalSeconds))
    }
}

function Start-IncidentWindow {
    # A separate process, so this run can finish (and the next one start)
    # while the window waits for an answer.
    param([string]$Folder, [string]$SettingsFile)
    $arguments = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath), '-ShowIncident',
        '-BackupFolder', ('"{0}"' -f $Folder),
        '-SettingsPath', ('"{0}"' -f $SettingsFile)
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
}

function Invoke-AutoSave {
    # -LegacyRoot: the script's folder, when the default save folders are in
    # use and so may still need moving into "Saved sessions".
    param([string]$Folder, [string]$SettingsFile, [string]$LegacyRoot, [switch]$NoWindow)

    $legacyFolder = if ($LegacyRoot) { Join-Path $LegacyRoot 'Automatic backups' } else { $null }

    $runLock = Enter-NamedMutex -Name 'Local\SaveExplorerWindows.Auto'
    if (-not $runLock) {
        $Folder = Resolve-SaveFolder $Folder $legacyFolder
        Initialize-SaveFolder -Path $Folder
        Write-BackupLog $Folder 'Skipped: another automatic run was still going.'
        return
    }
    try {
        # Before anything creates the new folders, or the move would find its
        # target taken and leave the backups behind.
        $moved = @()
        if ($LegacyRoot) {
            $moved = @(Move-LegacySaveFolders -Root $LegacyRoot)
            $Folder = Resolve-SaveFolder $Folder $legacyFolder
            # Covers everything under it, a moved folder without a marker of
            # its own included.
            Initialize-SaveFolder -Path (Join-Path $LegacyRoot 'Saved sessions')
        }
        Initialize-SaveFolder -Path $Folder
        foreach ($line in $moved) { Write-BackupLog $Folder $line }

        if (-not [IO.File]::Exists($SettingsFile)) {
            Write-DefaultSettingsFile -Path $SettingsFile
            Write-BackupLog $Folder 'Settings.ini was missing; wrote one with the default settings.'
        }
        $settings = Read-BackupSettings -Path $SettingsFile
        foreach ($problem in $settings.Problems) {
            Write-BackupLog $Folder ("Settings.ini {0} - using the default." -f $problem)
        }

        Wait-ExplorerSettled -Folder $Folder

        $scan = Invoke-ExplorerScan

        $stateLock = Enter-NamedMutex -Name 'Local\SaveExplorerWindows.State' -TimeoutMs 30000
        if (-not $stateLock) {
            Write-BackupLog $Folder 'Skipped: the backups state stayed busy for 30 seconds.'
            return
        }
        try {
            $result = Update-AutomaticBackups -Folder $Folder `
                -Groups (Get-ScanGroups $scan) -Names (Get-ScanGroups $scan -Names) `
                -Complete (Test-ScanComplete $scan) -FrozenCount $scan.Frozen.Count -ScanError $scan.Error `
                -Note (New-FrozenReport -Scan $scan) -Now ([DateTimeOffset]::Now) -Settings $settings `
                -RestartInfoSince { param($Since) Get-ExplorerRestartInfo -Since $Since } `
                -NoWindow:$NoWindow -WindowOpen:(Test-NamedMutexHeld 'Local\SaveExplorerWindows.IncidentWindow')
        } finally {
            Exit-NamedMutex $stateLock
        }
        $launch = $result.Launch

        if ($launch) {
            try {
                Start-IncidentWindow -Folder $Folder -SettingsFile $SettingsFile
            } catch {
                Write-BackupLog $Folder ("Could not open the lost-folder window: {0}" -f $_.Exception.Message)
            }
        }
    } finally {
        Exit-NamedMutex $runLock
    }
}

# ---------------------------------------------------------------------------
# The lost-folder window
# ---------------------------------------------------------------------------

function Show-IncidentWindow {
    param([string]$Folder)
    $windowLock = Enter-NamedMutex -Name 'Local\SaveExplorerWindows.IncidentWindow'
    if (-not $windowLock) { return }
    try {
        $state = Read-BackupState -Folder $Folder
        $incident = @($state.Incidents | Sort-Object -Property { $_.DetectedAt } -Descending) | Select-Object -First 1
        if (-not $incident) { return }

        # The compare window shows the loss with both sessions side by side
        # and reopens folders beside their old tab-mates. It runs in this
        # process, which holds the window's mutex for as long as it is open.
        # The message box below is for a copy without it.
        $compare = (Get-DefaultPaths).Compare
        if ([IO.File]::Exists($compare)) {
            & $compare -Incident -IncidentId $incident.Id -BackupFolder $Folder `
                -ManualFolder (Resolve-SaveFolder $ManualFolder $legacyManual) -SettingsPath $SettingsPath
            return
        }

        # Names with their parent folder, not full paths: the message box
        # wraps long lines wherever it likes.
        $missing = @($incident.Missing)
        $listed  = @($missing | Select-Object -First 12 | ForEach-Object {
            $trimmed = $_.TrimEnd('\')
            $cut = $trimmed.LastIndexOf('\')
            $parent = if ($cut -gt 0) { Get-FolderDisplayName $trimmed.Substring(0, $cut) } else { '' }
            if ($parent -and $parent -ne $trimmed.Substring(0, $cut)) { '    {0}   (in {1})' -f (Get-FolderDisplayName $_), $parent }
            else { '    {0}' -f (Get-FolderDisplayName $_) }
        })
        $text = New-Object Text.StringBuilder
        $when = if ($incident.BaselineSavedAt) { $incident.BaselineSavedAt.LocalDateTime.ToString('HH:mm, dddd d MMMM') } else { 'the last backup' }
        [void]$text.AppendLine(("{0} folder(s) that were open at {1} are not open now." -f $missing.Count, $when))
        [void]$text.AppendLine(("What happened: {0}." -f $incident.Reason))
        [void]$text.AppendLine()
        foreach ($line in $listed) { [void]$text.AppendLine($line) }
        if ($missing.Count -gt $listed.Count) { [void]$text.AppendLine(("    ...and {0} more" -f ($missing.Count - $listed.Count))) }
        [void]$text.AppendLine()
        [void]$text.AppendLine(('The backup from then is kept until you decide: "{0}" in the "{1}" folder.' -f $incident.BaselineFile, (Get-FolderDisplayName $Folder)))
        [void]$text.AppendLine()
        [void]$text.AppendLine('Did you close these folders yourself?')
        [void]$text.AppendLine()
        [void]$text.AppendLine('Yes: release that backup (cleanup may remove it later).')
        [void]$text.AppendLine('No: keep it and show it in Explorer. To reopen its missing folders, right-click it and choose "Run with PowerShell" (folders already open are skipped).')

        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $text.ToString(), 'Save Explorer Windows - folders lost?',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2,
            [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Remove-BackupIncident -Folder $Folder -Id $incident.Id -Why 'you said you closed the folders yourself')
        } else {
            Write-BackupLog $Folder ("Kept '{0}' locked and showed it in Explorer." -f $incident.BaselineFile)
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f (Join-Path $Folder $incident.BaselineFile))
        }
    } finally {
        Exit-NamedMutex $windowLock
    }
}

# ---------------------------------------------------------------------------

if ($ShowIncident) {
    try {
        Show-IncidentWindow -Folder (Resolve-SaveFolder $BackupFolder $legacyAuto)
    } catch {
        try { Write-BackupLog (Resolve-SaveFolder $BackupFolder $legacyAuto) ("ERROR in the lost-folder window: {0}" -f $_) } catch { }
    }
    exit
}

if ($Auto) {
    $exitCode = 0
    try {
        Invoke-AutoSave -Folder $BackupFolder -SettingsFile $SettingsPath -NoWindow:$NoWindow `
            -LegacyRoot $(if ($legacyAuto) { $defaults.Folder } else { '' })
    } catch {
        $exitCode = 1
        try { Write-BackupLog (Resolve-SaveFolder $BackupFolder $legacyAuto) ("ERROR: {0} | {1}" -f $_, ($_.ScriptStackTrace -replace '\r?\n', ' / ')) } catch { }
    } finally {
        # Do not remove: a worker stuck on a frozen window keeps the process
        # alive forever (see Get-AbandonedComWorkerCount).
        if ((Get-AbandonedComWorkerCount) -gt 0) { [Environment]::Exit($exitCode) }
    }
    exit $exitCode
}

try {
    Invoke-ManualSave -Folder (Resolve-SaveFolder $ManualFolder $legacyManual)
} catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    Read-Host "`nPress Enter to exit"
    # Do not remove. A worker thread parked inside a COM call to a frozen window
    # keeps this process alive past the last statement - it never exits on its
    # own, despite runspace threads being background threads. Everything is
    # written and flushed by this point, so end it outright.
    if ((Get-AbandonedComWorkerCount) -gt 0) { [Environment]::Exit(0) }
}
