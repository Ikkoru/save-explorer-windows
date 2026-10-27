# Compare Explorer Backups.ps1
#
# A window that compares two saved Explorer sessions side by side, or one
# with what is open right now, and reopens chosen folders beside the tabs
# they used to be with. It opens by itself when the automatic backups find
# folders lost; right-click it and choose "Run with PowerShell" to open it
# any time.
#
# Needs "Explorer Windows Shared.psm1" beside it, which holds everything but
# the window: Get-CompareRows (the lists and their colours), New-OpenPlan
# (where each folder opens), Invoke-OpenPlan (the opening) and
# Write-BackupSettings. Pure ASCII, like the other scripts.

param(
    [switch]$Incident,        # opened about a loss: show the newest unresolved one
    [string]$IncidentId,      # ...or this one
    [string]$BackupFolder,    # default "Saved sessions\Automatic backups" beside this script
    [string]$ManualFolder,    # default "Saved sessions\Manual saves"
    [string]$SettingsPath,    # default Settings.ini beside this script
    [string]$RenderTo,        # tests: build the window, save a picture of it as this .png, quit
    [switch]$KeepConsole      # leave the console window showing, for diagnosing
)

$ErrorActionPreference = 'Stop'

# WinForms and Shell.Application both need a single-threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($name in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$name]
            if ($value -is [switch]) { if ($value.IsPresent) { $relaunch += "-$name" } }
            else { $relaunch += "-$name"; $relaunch += [string]$value }
        }
        powershell.exe @relaunch
        exit $LASTEXITCODE
    }
}

Import-Module -Name (Join-Path $PSScriptRoot 'Explorer Windows Shared.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$defaults = Get-DefaultPaths
if (-not $BackupFolder) { $BackupFolder = Resolve-SaveFolder $defaults.AutoFolder (Join-Path $defaults.Folder 'Automatic backups') }
if (-not $ManualFolder) { $ManualFolder = Resolve-SaveFolder $defaults.ManualFolder (Join-Path $defaults.Folder 'Manual saves') }
if (-not $SettingsPath) { $SettingsPath = $defaults.Settings }
# The window's own checkboxes are remembered beside the saves, so a run
# pointed elsewhere (tests) keeps its own; nothing is remembered until
# "Saved sessions" exists.
$OptionsPath = if ($PSBoundParameters.ContainsKey('BackupFolder')) { Join-Path (Split-Path -Parent $BackupFolder) 'compare window.json' }
               else { Join-Path $defaults.SavesFolder 'compare window.json' }

# Started with "Run with PowerShell", a console window sits behind this one
# doing nothing; hide it. Errors still reach the person, as message boxes.
if (-not $KeepConsole -and -not $RenderTo) {
    Add-Type -ErrorAction SilentlyContinue -TypeDefinition 'using System; using System.Runtime.InteropServices; public class SewConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); }'
    [void][SewConsole]::ShowWindow([SewConsole]::GetConsoleWindow(), 0)
}

$red    = [System.Drawing.Color]::FromArgb(200, 0, 0)
$orange = [System.Drawing.Color]::FromArgb(215, 110, 0)

$script:Backups = @()        # Read-SessionBackup objects, newest first
$script:State   = $null      # Read-BackupState
$script:Shown   = $null      # the incident on screen, if any
$script:Now     = $null      # the last scan of what is open
$script:Opening = $null      # the opening under way: PowerShell, Async, Progress, Skipped
$script:LeftSources  = New-Object 'System.Collections.Generic.List[object]'
$script:RightSources = New-Object 'System.Collections.Generic.List[object]'

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

function Get-AllBackups {
    $all = @(@(Get-SessionBackups -Folder $BackupFolder) + @(Get-SessionBackups -Folder $ManualFolder) | Where-Object { $_ })
    @($all | Sort-Object -Property @{ Expression = { $_.SavedAt }; Descending = $true }, @{ Expression = { $_.File }; Descending = $true })
}

function Test-ManualSave {
    param($Backup)
    $Backup.Kind -eq 'manual' -or ($Backup.Kind -ne 'auto' -and $Backup.Path.StartsWith($ManualFolder, [StringComparison]::OrdinalIgnoreCase))
}

function Format-Backup {
    param($Backup)
    $when = $Backup.SavedAt.LocalDateTime.ToString('ddd d MMM  HH:mm')
    $kind = if (Test-ManualSave $Backup) { 'saved by hand' } else { 'automatic' }
    $label = if ($Backup.Label) { " '{0}'" -f $Backup.Label } else { '' }
    $flags = ''
    if (@($script:State.Incidents | Where-Object { $_.BaselineFile -eq $Backup.File }).Count -gt 0) { $flags += '   [kept after a loss]' }
    if (-not $Backup.Complete) { $flags += '   [incomplete]' }
    '{0}  -  {1}{2}  -  {3} folders{4}' -f $when, $kind, $label, $Backup.Count, $flags
}

function Get-SourceSession {
    # A list entry's windows and their display names.
    param($Source)
    if ($null -eq $Source) { return [pscustomobject]@{ Groups = @(); Names = @() } }
    if ($Source.Kind -eq 'now') {
        if (-not $script:Now) { Update-NowScan }
        return [pscustomobject]@{ Groups = (Get-ScanGroups $script:Now); Names = (Get-ScanGroups $script:Now -Names) }
    }
    [pscustomobject]@{ Groups = $Source.Backup.Groups; Names = $Source.Backup.Names }
}

function Read-WindowOptions {
    # The checkboxes as last left; both off when nothing was remembered or
    # the file cannot be read.
    $o = [pscustomobject]@{ changedOnly = $false; fullPaths = $false }
    try {
        if ([IO.File]::Exists($OptionsPath)) {
            $saved = [IO.File]::ReadAllText($OptionsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $o.changedOnly = [bool]$saved.changedOnly
            $o.fullPaths = [bool]$saved.fullPaths
        }
    } catch { }
    $o
}

function Save-WindowOptions {
    try {
        if (-not [IO.Directory]::Exists((Split-Path -Parent $OptionsPath))) { return }
        $json = [pscustomobject]@{ changedOnly = $chkChanged.Checked; fullPaths = $chkFullPaths.Checked } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($OptionsPath, $json, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Update-NowScan {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $script:Now = Invoke-ExplorerScan } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Get-ParentText {
    param([string]$Path)
    if ($Path.StartsWith('::')) { return $Path }
    $cut = $Path.TrimEnd('\').LastIndexOf('\')
    if ($cut -lt 0) { return $Path }
    $Path.Substring(0, $cut + 1)
}

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Save Explorer Windows - compare backups'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 720)
$form.MinimumSize = New-Object System.Drawing.Size(820, 480)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$header = New-Object System.Windows.Forms.Label
$header.Dock = 'Top'
$header.Height = 58
$header.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterWidth = 8

function New-Side {
    param($Panel, [string]$Title)
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.ShowItemToolTips = $true
    $list.HideSelection = $false
    [void]$list.Columns.Add('Folder', 200)
    [void]$list.Columns.Add('In', 200)
    # The two columns share the list's width, so there is never a sideways
    # scroll bar.
    $list.Add_Resize({
        param($sender)
        $w = $sender.ClientSize.Width - 4
        if ($w -gt 100) {
            $sender.Columns[0].Width = [int]($w * 0.42)
            $sender.Columns[1].Width = $w - [int]($w * 0.42)
        }
    })
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Dock = 'Top'
    $combo.DropDownStyle = 'DropDownList'
    $caption = New-Object System.Windows.Forms.Label
    $caption.Dock = 'Top'
    $caption.Height = 22
    $caption.Text = $Title
    $caption.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $Panel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $Panel.Controls.Add($list)
    $Panel.Controls.Add($combo)
    $Panel.Controls.Add($caption)
    [pscustomobject]@{ List = $list; Combo = $combo }
}

$left  = New-Side -Panel $split.Panel1 -Title 'Before'
$right = New-Side -Panel $split.Panel2 -Title 'After'

$bottom = New-Object System.Windows.Forms.FlowLayoutPanel
$bottom.Dock = 'Bottom'
$bottom.Height = 44
$bottom.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

function New-Button {
    param([string]$Text, [int]$Width = 120)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $Width
    $b.Height = 28
    $bottom.Controls.Add($b)
    $b
}

$btnMissing  = New-Button 'Tick all missing' 130
$btnClear    = New-Button 'Untick all' 100
$btnOpen     = New-Button 'Open ticked' 120
$btnRefresh  = New-Button 'Refresh' 90
$btnChecked  = New-Button 'Mark as checked' 130
$btnSettings = New-Button 'Settings...' 100
$btnClose    = New-Button 'Close' 90

$legend = New-Object System.Windows.Forms.FlowLayoutPanel
$legend.Dock = 'Bottom'
$legend.Height = 26
$legend.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 0)
foreach ($part in @(@('Red:', $red), @(' on the left but not on the right.   ', $null), @('Orange:', $orange), @(' on the right but not on the left.', $null))) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.Text = $part[0]
    $l.Margin = New-Object System.Windows.Forms.Padding(0)
    if ($part[1]) { $l.ForeColor = $part[1]; $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
    $legend.Controls.Add($l)
}
function New-Option {
    param([string]$Text)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.AutoSize = $true
    $c.Text = $Text
    $c.Margin = New-Object System.Windows.Forms.Padding(28, 0, 0, 0)
    $legend.Controls.Add($c)
    $c
}
$chkChanged   = New-Option 'Only windows with red or orange'
$chkFullPaths = New-Option 'Show full paths'

$status = New-Object System.Windows.Forms.StatusStrip
$statusText = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusText.Spring = $true
$statusText.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusText)

# Both sides keep half the width as the window is resized.
$form.Add_Resize({ if ($split.Width -gt 200) { $split.SplitterDistance = [int](($split.Width - $split.SplitterWidth) / 2) } })
$form.Add_Load({ $split.SplitterDistance = [int](($split.Width - $split.SplitterWidth) / 2) })

$form.Controls.Add($split)
$form.Controls.Add($header)
$form.Controls.Add($legend)
$form.Controls.Add($bottom)
$form.Controls.Add($status)

function Set-Status { param([string]$Text) $statusText.Text = $Text }

# ---------------------------------------------------------------------------
# Filling it
# ---------------------------------------------------------------------------

function Update-Header {
    if ($script:Shown) {
        $i = $script:Shown
        $when = if ($i.BaselineSavedAt) { $i.BaselineSavedAt.LocalDateTime.ToString('HH:mm, ddd d MMM') } else { 'the last backup' }
        $header.Text = ("{0} folder(s) that were open at {1} are not open now: {2}.`r`nThe backup from then is on the left and is kept until you click ""Mark as checked"". Tick the folders you want back and click ""Open ticked""." -f @($i.Missing).Count, $when, $i.Reason)
        $header.ForeColor = $red
    } else {
        $header.Text = "Pick two saved sessions, or one and ""Open right now"", to see what changed between them.`r`nTick folders in either list and click ""Open ticked"": each goes back beside the tabs it was with, where those are open now."
        $header.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    $btnChecked.Enabled = [bool]$script:Shown
}

function Update-Sources {
    # Fills both drop-downs; keeps what each showed when it can.
    param($LeftFile, $RightFile)
    $script:State = Read-BackupState -Folder $BackupFolder
    $script:Backups = Get-AllBackups
    $script:LeftSources.Clear(); $script:RightSources.Clear()
    $left.Combo.Items.Clear(); $right.Combo.Items.Clear()
    $now = [pscustomobject]@{ Kind = 'now'; Backup = $null; Text = 'Open right now' }
    $script:RightSources.Add($now); [void]$right.Combo.Items.Add($now.Text)
    foreach ($b in $script:Backups) {
        $entry = [pscustomobject]@{ Kind = 'backup'; Backup = $b; Text = (Format-Backup $b) }
        $script:LeftSources.Add($entry); [void]$left.Combo.Items.Add($entry.Text)
        $script:RightSources.Add($entry); [void]$right.Combo.Items.Add($entry.Text)
    }
    $pick = {
        param($Sources, [string]$File)
        for ($k = 0; $k -lt $Sources.Count; $k++) {
            if ($File -eq 'now' -and $Sources[$k].Kind -eq 'now') { return $k }
            if ($File -and $Sources[$k].Backup -and $Sources[$k].Backup.File -eq $File) { return $k }
        }
        -1
    }
    $li = & $pick $script:LeftSources $LeftFile
    $ri = & $pick $script:RightSources $RightFile
    if ($li -lt 0 -and $script:LeftSources.Count -gt 0) { $li = [math]::Min(1, $script:LeftSources.Count - 1) }
    if ($ri -lt 0) { $ri = if ($script:RightSources.Count -gt 1) { 1 } else { 0 } }
    $script:Filling = $true
    $left.Combo.SelectedIndex = $li
    $right.Combo.SelectedIndex = $ri
    $script:Filling = $false
}

function Fill-List {
    # With -ChangedOnly, a window none of whose folders is red or orange is
    # left out whole; a window that has one keeps all its tabs, so the
    # tab-mates a folder goes back beside stay in sight. Windows keep their
    # numbers either way.
    param($List, $Rows, $Groups, [switch]$ChangedOnly, [switch]$FullPaths)
    $List.BeginUpdate()
    $List.Items.Clear()
    $List.Groups.Clear()
    $List.Columns[1].Text = if ($FullPaths) { 'Full path' } else { 'In' }
    $changed = @{}
    foreach ($r in @($Rows)) { if ($r.Status -eq 'missing' -or $r.Status -eq 'added') { $changed[$r.Window] = $true } }
    $byWindow = @{}
    $count = @($Groups).Count
    for ($w = 0; $w -lt $count; $w++) {
        if ($ChangedOnly -and -not $changed[$w]) { continue }
        $tabs = @(@($Groups)[$w]).Count
        $g = New-Object System.Windows.Forms.ListViewGroup(('Window {0}  -  {1} tab(s)' -f ($w + 1), $tabs))
        [void]$List.Groups.Add($g)
        $byWindow[$w] = $g
    }
    foreach ($r in @($Rows)) {
        if (-not $byWindow.ContainsKey($r.Window)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($r.Name)
        [void]$item.SubItems.Add($(if ($FullPaths) { $r.Path } else { Get-ParentText $r.Path }))
        $item.Group = $byWindow[$r.Window]
        $item.ToolTipText = $r.Path
        $item.Tag = [pscustomobject]@{ Row = $r; Group = [string[]]@(@($Groups)[$r.Window]) }
        if ($r.Status -eq 'missing') { $item.ForeColor = $red }
        elseif ($r.Status -eq 'added') { $item.ForeColor = $orange }
        [void]$List.Items.Add($item)
    }
    $List.EndUpdate()
}

function Update-Lists {
    $ls = if ($left.Combo.SelectedIndex -ge 0) { $script:LeftSources[$left.Combo.SelectedIndex] } else { $null }
    $rs = if ($right.Combo.SelectedIndex -ge 0) { $script:RightSources[$right.Combo.SelectedIndex] } else { $null }
    $a = Get-SourceSession $ls
    $b = Get-SourceSession $rs
    $rows = Get-CompareRows -Before $a.Groups -After $b.Groups -BeforeNames $a.Names -AfterNames $b.Names
    $view = @{ ChangedOnly = $chkChanged.Checked; FullPaths = $chkFullPaths.Checked }
    Fill-List -List $left.List -Rows $rows.Before -Groups $a.Groups @view
    Fill-List -List $right.List -Rows $rows.After -Groups $b.Groups @view
    $missing = @($rows.Before | Where-Object { $_.Status -eq 'missing' }).Count
    $added   = @($rows.After | Where-Object { $_.Status -eq 'added' }).Count
    $note = ''
    if ($rs -and $rs.Kind -eq 'now' -and $script:Now -and -not (Test-ScanComplete $script:Now)) {
        $note = '  Some Explorer windows did not answer, so "Open right now" may be missing folders.'
    }
    Set-Status ('{0} missing on the right, {1} new on the right.{2}' -f $missing, $added, $note)
}

# ---------------------------------------------------------------------------
# Opening
# ---------------------------------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300

function Set-Busy {
    param([bool]$Busy)
    foreach ($b in $btnMissing, $btnClear, $btnOpen, $btnRefresh, $btnSettings) { $b.Enabled = -not $Busy }
    $left.Combo.Enabled = -not $Busy
    $right.Combo.Enabled = -not $Busy
    $btnChecked.Enabled = (-not $Busy) -and [bool]$script:Shown
}

function Start-Opening {
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($list in $left.List, $right.List) {
        foreach ($item in $list.CheckedItems) {
            $selected.Add([pscustomobject]@{ Path = $item.Tag.Row.Path; Group = $item.Tag.Group })
        }
    }
    if ($selected.Count -eq 0) { Set-Status 'Tick the folders to open first.'; return }

    Set-Status 'Looking at what is open now...'
    Update-NowScan
    $open = @(foreach ($key in $script:Now.Groups.Keys) { [pscustomobject]@{ Key = [string]$key; Paths = $script:Now.Groups[$key].ToArray() } })
    $plan = New-OpenPlan -Selected $selected.ToArray() -Open $open
    if (@($plan.Steps).Count -eq 0) {
        Set-Status ('All {0} ticked folder(s) are already open.' -f $plan.Skipped)
        return
    }

    # On a thread of its own: a frozen Explorer window would otherwise freeze
    # this window too, for good.
    $progress = [hashtable]::Synchronized(@{ Done = 0; Total = @($plan.Steps).Count; Current = '' })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::STA
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        param($Module, $Steps, $Progress)
        Import-Module -Name $Module -Force -DisableNameChecking
        Invoke-OpenPlan -Steps $Steps -Progress $Progress
    }).AddArgument((Join-Path $PSScriptRoot 'Explorer Windows Shared.psm1')).AddArgument($plan.Steps).AddArgument($progress)
    $script:Opening = [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Async = $ps.BeginInvoke(); Progress = $progress; Skipped = $plan.Skipped }
    Set-Busy $true
    $timer.Start()
}

$timer.Add_Tick({
    $o = $script:Opening
    if (-not $o) { $timer.Stop(); return }
    $p = $o.Progress
    if (-not $p['Finished'] -and -not $o.Async.IsCompleted) {
        $name = if ($p['Current']) { Get-FolderDisplayName ([string]$p['Current']) } else { '' }
        Set-Status ('Opening {0} of {1}: {2}' -f ([int]$p['Done'] + 1), $p['Total'], $name)
        return
    }
    $timer.Stop()
    $problem = $null
    try { [void]$o.PowerShell.EndInvoke($o.Async) } catch { $problem = $_.Exception.Message }
    $failed = @()
    if ($p['Failed']) { $failed = @($p['Failed']) }
    $o.PowerShell.Dispose(); $o.Runspace.Dispose()
    $script:Opening = $null
    $opened = [int]$p['Total'] - $failed.Count
    $text = 'Opened {0} folder(s).' -f $opened
    if ($o.Skipped -gt 0) { $text += ' {0} were already open.' -f $o.Skipped }
    if ($failed.Count -gt 0) { $text += ' Could not open: {0}.' -f (($failed | ForEach-Object { Get-FolderDisplayName $_ }) -join ', ') }
    if ($problem) { $text += ' Error: ' + $problem }
    foreach ($list in $left.List, $right.List) { foreach ($item in @($list.CheckedItems)) { $item.Checked = $false } }
    $script:Now = $null
    if ($right.Combo.SelectedIndex -ge 0 -and $script:RightSources[$right.Combo.SelectedIndex].Kind -eq 'now') { Update-Lists }
    Set-Busy $false
    Set-Status $text
})

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

function Show-SettingsDialog {
    param([switch]$RenderOnly, [string]$RenderPath)
    $s = Read-BackupSettings -Path $SettingsPath
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Save Explorer Windows - settings'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    $d.Font = $form.Font
    $d.ClientSize = New-Object System.Drawing.Size(500, 370)
    $y = 14
    function New-Number { param([int]$Min, [int]$Max, [int]$Value)
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Minimum = $Min; $n.Maximum = $Max; $n.Value = $Value; $n.Width = 70
        $n
    }
    function New-Text { param([string]$Text, [int]$X, [int]$Y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($X, ($Y + 3))
        $d.Controls.Add($l)
    }
    $warn = New-Object System.Windows.Forms.CheckBox
    $warn.Text = 'Warn me when folders seem to have been lost'
    $warn.AutoSize = $true; $warn.Checked = $s.Warnings; $warn.Location = New-Object System.Drawing.Point(16, $y)
    $d.Controls.Add($warn)
    $y += 34
    New-Text 'After a restart, a sign-out or a crash, warn when' 36 $y
    $y += 26
    New-Text 'at least' 56 $y
    $restart = New-Number 1 1000 $s.RestartMinFolders
    $restart.Location = New-Object System.Drawing.Point(200, $y); $d.Controls.Add($restart)
    New-Text 'folder(s) are missing' 276 $y
    $y += 38
    $drops = New-Object System.Windows.Forms.CheckBox
    $drops.Text = 'Also warn when many folders close at once, with no restart'
    $drops.AutoSize = $true; $drops.Checked = $s.DropWarnings; $drops.Location = New-Object System.Drawing.Point(36, $y)
    $d.Controls.Add($drops)
    $y += 30
    New-Text 'Many means at least' 56 $y
    $dropMin = New-Number 1 1000 $s.DropMinFolders
    $dropMin.Location = New-Object System.Drawing.Point(200, $y); $d.Controls.Add($dropMin)
    New-Text 'folders,' 276 $y
    $y += 28
    New-Text 'and at least' 56 $y
    $dropPct = New-Number 1 100 $s.DropMinPercent
    $dropPct.Location = New-Object System.Drawing.Point(200, $y); $d.Controls.Add($dropPct)
    New-Text '% of the folders that were open' 276 $y
    $y += 44
    # Auto (KeepBackups 0) counts from the task's interval; the number box
    # shows what auto comes to, so switching to a number starts there.
    $interval = Get-AutoBackupInterval
    $autoCount = Resolve-KeepCount -KeepBackups 0 -IntervalMinutes $interval
    $keepAuto = New-Object System.Windows.Forms.RadioButton
    $keepAuto.Text = ("Keep {0} hours of automatic backups ({1} at {2})" -f (Get-AutoKeepHours), $autoCount, (Format-TaskInterval $interval))
    $keepAuto.AutoSize = $true; $keepAuto.Location = New-Object System.Drawing.Point(16, $y)
    $d.Controls.Add($keepAuto)
    $y += 30
    $keepFixed = New-Object System.Windows.Forms.RadioButton
    $keepFixed.Text = 'Keep the newest'
    $keepFixed.AutoSize = $true; $keepFixed.Location = New-Object System.Drawing.Point(16, ($y + 2))
    $d.Controls.Add($keepFixed)
    $keep = New-Number 1 1000 $(if ($s.KeepBackups -gt 0) { $s.KeepBackups } else { [math]::Min($autoCount, 1000) })
    $keep.Location = New-Object System.Drawing.Point(200, $y); $d.Controls.Add($keep)
    New-Text 'automatic backups' 276 $y
    $keepAuto.Checked = ($s.KeepBackups -eq 0); $keepFixed.Checked = ($s.KeepBackups -gt 0)
    $y += 46
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'; $ok.Width = 90; $ok.Location = New-Object System.Drawing.Point(300, $y)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Width = 90; $cancel.Location = New-Object System.Drawing.Point(396, $y)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $d.Controls.Add($ok); $d.Controls.Add($cancel)
    $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $sync = {
        $restart.Enabled = $warn.Checked
        $drops.Enabled = $warn.Checked
        $dropMin.Enabled = $warn.Checked -and $drops.Checked
        $dropPct.Enabled = $warn.Checked -and $drops.Checked
        $keep.Enabled = $keepFixed.Checked
    }
    $warn.Add_CheckedChanged($sync)
    $drops.Add_CheckedChanged($sync)
    $keepFixed.Add_CheckedChanged($sync)
    & $sync

    if ($RenderOnly) {
        $d.Show(); [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($d.Width, $d.Height)
        $d.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $d.Width, $d.Height)))
        $bmp.Save($RenderPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $d.Close()
        return
    }
    if ($d.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Write-BackupSettings -Path $SettingsPath -Values ([pscustomobject]@{
        KeepBackups = $(if ($keepAuto.Checked) { 0 } else { [int]$keep.Value }); Warnings = $warn.Checked; RestartMinFolders = [int]$restart.Value
        DropWarnings = $drops.Checked; DropMinFolders = [int]$dropMin.Value; DropMinPercent = [int]$dropPct.Value
    })
    Set-Status 'Settings saved. The next automatic backup uses them.'
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

$changed = { if (-not $script:Filling) { Update-Lists } }
$left.Combo.Add_SelectedIndexChanged($changed)
$right.Combo.Add_SelectedIndexChanged($changed)

# A checkbox only changes the view, so ticked folders stay ticked: those
# still shown are ticked again after the lists are refilled.
$viewChanged = {
    if ($script:Filling) { return }
    Save-WindowOptions
    $ticked = @{}
    foreach ($side in $left, $right) {
        $ticked[$side] = @($side.List.CheckedItems | ForEach-Object { '{0}|{1}' -f $_.Tag.Row.Window, $_.Tag.Row.Path })
    }
    Update-Lists
    foreach ($side in $left, $right) {
        foreach ($item in $side.List.Items) {
            if ($ticked[$side] -contains ('{0}|{1}' -f $item.Tag.Row.Window, $item.Tag.Row.Path)) { $item.Checked = $true }
        }
    }
}
$chkChanged.Add_CheckedChanged($viewChanged)
$chkFullPaths.Add_CheckedChanged($viewChanged)

$btnMissing.Add_Click({
    foreach ($item in $left.List.Items) { if ($item.Tag.Row.Status -eq 'missing') { $item.Checked = $true } }
})
$btnClear.Add_Click({
    foreach ($list in $left.List, $right.List) { foreach ($item in @($list.CheckedItems)) { $item.Checked = $false } }
})
$btnOpen.Add_Click({ Start-Opening })
$btnRefresh.Add_Click({
    $lf = if ($left.Combo.SelectedIndex -ge 0) { $script:LeftSources[$left.Combo.SelectedIndex] } else { $null }
    $rf = if ($right.Combo.SelectedIndex -ge 0) { $script:RightSources[$right.Combo.SelectedIndex] } else { $null }
    $script:Now = $null
    Update-Sources -LeftFile $(if ($lf -and $lf.Backup) { $lf.Backup.File }) -RightFile $(if ($rf -and $rf.Kind -eq 'now') { 'now' } elseif ($rf -and $rf.Backup) { $rf.Backup.File })
    Update-Lists
})
$btnChecked.Add_Click({
    if (-not $script:Shown) { return }
    if (Remove-BackupIncident -Folder $BackupFolder -Id $script:Shown.Id -Why 'marked as checked in the compare window') {
        $script:Shown = $null
        Update-Header
        $btnRefresh.PerformClick()
        Set-Status 'Marked as checked. That backup is now cleaned up like any other.'
    } else {
        Set-Status 'Could not mark it as checked: the backups were busy. Try again in a moment.'
    }
})
$btnSettings.Add_Click({ Show-SettingsDialog })
$btnClose.Add_Click({ $form.Close() })

# Opened about a loss, the window stays on top, like the message box it
# replaces, until the person has been in it and moved on. Windows does not
# let a background process take the keyboard, so it does not interrupt
# typing elsewhere.
$script:WasActive = $false
$form.Add_Activated({ $script:WasActive = $true })
$form.Add_Deactivate({ if ($script:WasActive) { $form.TopMost = $false } })

# ---------------------------------------------------------------------------

try {
    $options = Read-WindowOptions
    $script:Filling = $true
    $chkChanged.Checked = $options.changedOnly
    $chkFullPaths.Checked = $options.fullPaths
    $script:Filling = $false
    $script:State = Read-BackupState -Folder $BackupFolder
    $pending = @($script:State.Incidents | Sort-Object -Property { $_.DetectedAt } -Descending)
    if ($IncidentId) { $pending = @($pending | Where-Object { $_.Id -eq $IncidentId }) }
    if ($Incident -or $IncidentId -or $pending.Count -gt 0) { $script:Shown = $pending | Select-Object -First 1 }

    if ($script:Shown) {
        $rightFile = if ($script:Shown.CurrentFile -and [IO.File]::Exists((Join-Path $BackupFolder $script:Shown.CurrentFile))) { $script:Shown.CurrentFile } else { 'now' }
        Update-Sources -LeftFile $script:Shown.BaselineFile -RightFile $rightFile
    } else {
        $autos = @(Get-AllBackups | Where-Object { -not (Test-ManualSave $_) })
        Update-Sources -LeftFile $(if ($autos.Count -gt 1) { $autos[1].File } elseif ($autos.Count -eq 1) { $autos[0].File }) -RightFile $(if ($autos.Count -gt 0) { $autos[0].File } else { 'now' })
    }
    Update-Header
    Update-Lists
    if ($script:Shown) { $form.TopMost = $true }

    if ($RenderTo) {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($RenderTo, [System.Drawing.Imaging.ImageFormat]::Png)
        Show-SettingsDialog -RenderOnly -RenderPath ([IO.Path]::ChangeExtension($RenderTo, '.settings.png'))
        $form.Close()
    } else {
        [void]$form.ShowDialog()
    }
} catch {
    if ($RenderTo) { [Console]::Error.WriteLine(("{0} | {1}" -f $_, $_.ScriptStackTrace)); $script:RenderFailed = $true }
    else { [void][System.Windows.Forms.MessageBox]::Show(("Something went wrong:`r`n`r`n{0}" -f $_), 'Save Explorer Windows', 'OK', 'Error') }
} finally {
    if ($script:RenderFailed) { [Environment]::Exit(1) }
    # Do not remove: a scan left waiting on a frozen window, or an opening
    # still under way, keeps this process alive after the window closes.
    if ($script:Opening -or (Get-AbandonedComWorkerCount) -gt 0) { [Environment]::Exit(0) }
}
