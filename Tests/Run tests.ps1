# Run tests.ps1
#
# Checks the parts of "Explorer Windows Shared.psm1" that need no open
# Explorer window: comparing sessions, the cleanup plan, the lost-folder
# verdict, Settings.ini, state.json and the restore-file format.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File "Tests\Run tests.ps1"
#
# Exit code 0 when every check passes. -ModulePath tests another copy of the
# module, which is how a deliberately broken copy is shown to fail.
#
# Pure ASCII: Windows PowerShell reads this file in the ANSI code page, so the
# Japanese and emoji test paths are built from character codes.

param([string]$ModulePath)

$ErrorActionPreference = 'Stop'
if (-not $ModulePath) { $ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Explorer Windows Shared.psm1' }
Import-Module -Name $ModulePath -Force -DisableNameChecking

$script:Failures = 0
$script:Checks   = 0
function Check {
    param([string]$Name, $Condition)
    $script:Checks++
    if ($Condition) {
        Write-Host ("ok    {0}" -f $Name)
    } else {
        Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
        $script:Failures++
    }
}

# Windows as an array of string[]: G 'a','b' 'c' is two windows, a+b and c.
function G { ,@(foreach ($window in $args) { ,[string[]]@($window) }) }

function Join-Paths { param($Items) (@($Items) -join '|') }

$jp        = -join [char[]](0x65E5, 0x672C, 0x8A9E, 0x30D5, 0x30A9, 0x30EB, 0x30C0)
$emoji     = [char]::ConvertFromUtf32(0x1F600)
$lookalike = [string][char]0x2215                                  # division slash
$fullwidth = [string][char]0xFF3B + 'x' + [string][char]0xFF3D     # fullwidth brackets
$tricky = @(
    "C:\Test\$jp",
    "C:\Test\$emoji smile",
    'C:\Test\[brackets] and !bang',
    "C:\Test\it's here",
    "C:\Test\a$($lookalike)b $fullwidth",
    'C:\Test\cost $5 `tick'
)
$base = [DateTimeOffset]::new(2026, 10, 10, 12, 0, 0, [TimeSpan]::FromHours(1))
$utf8 = New-Object Text.UTF8Encoding $false

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sew-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)
try {

    # --- Comparing sessions -------------------------------------------------

    Check 'which window a folder is in does not count' (Test-SameFolders (G 'C:\A', 'C:\B' 'C:\C') (G 'C:\C', 'C:\A' 'C:\B'))
    Check 'letter case does not count' (Test-SameFolders (G 'C:\Folder') (G 'c:\FOLDER'))
    Check 'different folders differ' (-not (Test-SameFolders (G 'C:\A') (G 'C:\B')))
    Check 'a folder open twice is not the same as once' (-not (Test-SameFolders (G 'C:\A', 'C:\A') (G 'C:\A')))
    $d = Compare-SessionFolders -Before (G 'C:\A', 'C:\A', 'C:\B' 'C:\C') -After (G 'c:\a' 'C:\D')
    Check 'missing: each unmatched tab, duplicates included' ((Join-Paths ($d.Missing | ForEach-Object Path)) -eq 'C:\A|C:\B|C:\C')
    Check 'added: tabs only in the later session' ((Join-Paths ($d.Added | ForEach-Object Path)) -eq 'C:\D')
    Check 'missing tabs keep their window and position' ($d.Missing[2].Window -eq 1 -and $d.Missing[2].Tab -eq 0)
    Check 'counts' ($d.BeforeCount -eq 4 -and $d.AfterCount -eq 2)
    $e = Compare-SessionFolders -Before @() -After (G 'C:\A')
    Check 'an empty session misses nothing' ($e.Missing.Count -eq 0 -and $e.Added.Count -eq 1)

    Check 'display name: last part' ((Get-FolderDisplayName 'C:\A\Last') -eq 'Last')
    Check 'display name: trailing backslash' ((Get-FolderDisplayName 'C:\A\Last\') -eq 'Last')
    Check 'display name: drive root stays whole' ((Get-FolderDisplayName 'C:\') -eq 'C:\')
    Check 'display name: shell location stays whole' ((Get-FolderDisplayName '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}') -eq '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}')

    # --- Cleanup plan -------------------------------------------------------

    function New-Fake {
        param([string]$Name, [int]$MinutesAgo, $Groups, [bool]$Complete = $true)
        [pscustomobject]@{
            File = "$Name.ps1"; Path = "Z:\nowhere\$Name.ps1"; SavedAt = $base.AddMinutes(-$MinutesAgo)
            Complete = $Complete; Groups = $Groups
        }
    }
    function New-Fakes {
        # b00 (newest) to b11, ten minutes apart, each with its own folder.
        @(0..11 | ForEach-Object { New-Fake ('b{0:D2}' -f $_) ($_ * 10) (G "C:\F$_") })
    }
    function Get-PlanFiles { param($Plan) Join-Paths ($Plan | ForEach-Object File | Sort-Object) }

    $fakes = New-Fakes
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @() -Keep 10)
    Check 'cleanup: keeps the newest 10' ((Get-PlanFiles $plan) -eq 'b10.ps1|b11.ps1')

    $fakes = New-Fakes
    $fakes[0].Groups = G 'C:\X', 'C:\Y'
    $fakes[3].Groups = G 'C:\Y' 'c:\x'
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @() -Keep 10)
    Check 'cleanup: drops an older backup with the same folders' ((Get-PlanFiles $plan) -eq 'b03.ps1|b11.ps1')
    Check 'cleanup: says why' ((@($plan | Where-Object File -eq 'b03.ps1')[0].Why) -eq 'same folders as the new backup')

    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @('b03.ps1') -Keep 10)
    Check 'cleanup: a locked backup stays, and is kept on top of the 10' ((Get-PlanFiles $plan) -eq 'b11.ps1')

    $fakes = New-Fakes
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @('B11.PS1') -Keep 10)
    Check 'cleanup: an old locked backup stays (any letter case)' ((Get-PlanFiles $plan) -eq 'b10.ps1')

    $fakes = New-Fakes
    $fakes[0].Groups = G 'C:\X'
    $fakes[0].Complete = $false
    $fakes[3].Groups = G 'C:\X'
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @() -Keep 10)
    Check 'cleanup: an incomplete save replaces nothing' ((Get-PlanFiles $plan) -eq 'b10.ps1|b11.ps1')

    $fakes = New-Fakes
    foreach ($f in $fakes[0..10]) { $f.Complete = $false }
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @() -Keep 10)
    Check 'cleanup: the newest complete backup outlives incomplete ones' ((Get-PlanFiles $plan) -eq 'b10.ps1')

    $fakes = New-Fakes
    $plan = @(Get-CleanupPlan -Backups $fakes -NewestFile 'b00.ps1' -LockedFiles @() -Keep 1)
    Check 'cleanup: Keep 1 leaves only the new one' ($plan.Count -eq 11 -and -not ($plan | Where-Object File -eq 'b00.ps1'))

    # --- Lost-folder verdict ------------------------------------------------

    function New-Settings {
        param([bool]$Warnings = $true, [int]$RestartMin = 1, [bool]$Drops = $true, [int]$DropMin = 3, [int]$DropPercent = 50)
        [pscustomobject]@{
            KeepBackups = 10; Warnings = $Warnings; RestartMinFolders = $RestartMin
            DropWarnings = $Drops; DropMinFolders = $DropMin; DropMinPercent = $DropPercent
        }
    }
    function New-Restart { param($Boot, $Shell, $Crashes = @()) [pscustomobject]@{ BootTime = $Boot; ShellStart = $Shell; CrashTimes = @($Crashes) } }
    $quiet    = New-Restart $base.AddDays(-2) $base.AddDays(-2)
    $rebooted = New-Restart $base.AddMinutes(30) $base.AddMinutes(31)
    $relogged = New-Restart $base.AddDays(-2) $base.AddMinutes(30)
    $crashed  = New-Restart $base.AddDays(-2) $base.AddDays(-2) @($base.AddMinutes(20))
    $oldCrash = New-Restart $base.AddDays(-2) $base.AddDays(-2) @($base.AddMinutes(-20))
    function V {
        param($Before, $After, $Restart, $Settings = (New-Settings))
        Get-LostFolderVerdict -BaselineGroups $Before -BaselineTime $base -CurrentGroups $After -RestartInfo $Restart -Settings $Settings
    }
    $five  = G 'C:\1', 'C:\2' 'C:\3', 'C:\4' 'C:\5'
    $seven = G 'C:\1', 'C:\2', 'C:\3', 'C:\4', 'C:\5', 'C:\6', 'C:\7'

    $v = V $five (G 'C:\1', 'C:\2' 'C:\3', 'C:\4') $rebooted
    Check 'verdict: one folder lost to a restart warns' ($v.Incident -and $v.Cause -eq 'restart' -and $v.Missing.Count -eq 1)
    Check 'verdict: restart nothing missing is quiet' (-not (V $five $five $rebooted).Incident)
    Check 'verdict: RestartMinFolders is honoured' (-not (V $five (G 'C:\1', 'C:\2' 'C:\3', 'C:\4') $rebooted (New-Settings -RestartMin 2)).Incident)
    $v = V $five (G 'C:\1', 'C:\2') $relogged
    Check 'verdict: an Explorer restart warns' ($v.Incident -and $v.Cause -eq 'explorer-restart')
    $v = V $five (G 'C:\1', 'C:\2', 'C:\3', 'C:\4') $crashed
    Check 'verdict: a crash warns' ($v.Incident -and $v.Cause -eq 'crash')
    Check 'verdict: a crash before the baseline does not count' (-not (V $five (G 'C:\1', 'C:\2', 'C:\3', 'C:\4') $oldCrash).Incident)
    $v = V $five @() $rebooted
    Check 'verdict: everything gone after a restart warns' ($v.Incident -and $v.Missing.Count -eq 5)
    $v = V $five (G 'C:\1', 'C:\2') $quiet
    Check 'verdict: 3 of 5 closed at once warns' ($v.Incident -and $v.Cause -eq 'drop')
    Check 'verdict: 3 of 7 (under half) is quiet' (-not (V $seven (G 'C:\1', 'C:\2', 'C:\3', 'C:\4') $quiet).Incident)
    Check 'verdict: 2 of 3 is under DropMinFolders' (-not (V (G 'C:\1', 'C:\2', 'C:\3') (G 'C:\1') $quiet).Incident)
    Check 'verdict: DropMinFolders and DropMinPercent are honoured' ((V (G 'C:\1', 'C:\2', 'C:\3') (G 'C:\1') $quiet (New-Settings -DropMin 2 -DropPercent 60)).Incident)
    Check 'verdict: closing everything is taken as deliberate' (-not (V $five @() $quiet).Incident)
    Check 'verdict: DropWarnings off' (-not (V $five (G 'C:\1', 'C:\2') $quiet (New-Settings -Drops $false)).Incident)
    Check 'verdict: Warnings off silences restarts too' (-not (V $five (G 'C:\1') $rebooted (New-Settings -Warnings $false)).Incident)
    Check 'verdict: regrouped tabs are no loss' (-not (V $five (G 'c:\5' 'C:\4', 'C:\3' 'C:\2', 'C:\1') $rebooted).Incident)
    Check 'verdict: an empty baseline loses nothing' (-not (V @() (G 'C:\1') $rebooted).Incident)

    # --- Settings.ini -------------------------------------------------------

    $ini = Join-Path $tmp 'Settings.ini'
    Write-DefaultSettingsFile -Path $ini
    $r = Read-BackupSettings -Path $ini
    Check 'settings: the default file reads back as the defaults' ($r.Problems.Count -eq 0 -and $r.KeepBackups -eq 20 -and
        $r.Warnings -eq $true -and $r.RestartMinFolders -eq 1 -and $r.DropWarnings -eq $true -and $r.DropMinFolders -eq 3 -and $r.DropMinPercent -eq 50)
    $lines = @('KeepBackups = 4 ; four', 'warnings=OFF', 'DropMinPercent = 101', 'DropMinFolders = abc', 'Bogus = 1', 'junk line', '# comment', '')
    [IO.File]::WriteAllText($ini, ($lines -join "`r`n"), $utf8)
    $r = Read-BackupSettings -Path $ini
    Check 'settings: numbers, with a comment after them' ($r.KeepBackups -eq 4)
    Check 'settings: names and on/off in any case' ($r.Warnings -eq $false)
    Check 'settings: out of range falls back' ($r.DropMinPercent -eq 50)
    Check 'settings: not a number falls back' ($r.DropMinFolders -eq 3)
    Check 'settings: every problem is reported' ($r.Problems.Count -eq 4)
    [IO.File]::WriteAllText($ini, "KeepBackups = 7`r`n", (New-Object Text.UTF8Encoding $true))
    Check 'settings: a file saved with a BOM' ((Read-BackupSettings -Path $ini).KeepBackups -eq 7)
    $r = Read-BackupSettings -Path (Join-Path $tmp 'missing.ini')
    Check 'settings: no file gives the defaults' ($r.KeepBackups -eq 20 -and $r.Problems.Count -eq 0)
    # --- The save folders ---------------------------------------------------

    $sv = Join-Path $tmp 'saves\Manual saves'
    Initialize-SaveFolder -Path $sv
    $marker = Join-Path $sv '.kopiaignore'
    Check 'save folder: created, with any missing parent' ([IO.Directory]::Exists($sv))
    $rules = @([IO.File]::ReadAllLines($marker, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    Check 'save folder: its .kopiaignore leaves out everything in it' ($rules.Count -eq 1 -and $rules[0].Trim() -eq '*')
    Check 'save folder: not marked disposable (no CACHEDIR.TAG)' (-not [IO.File]::Exists((Join-Path $sv 'CACHEDIR.TAG')))
    [IO.File]::WriteAllText($marker, "# edited`n*.ps1`n", $utf8)
    Initialize-SaveFolder -Path $sv
    Check 'save folder: an edited .kopiaignore is kept' ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) -eq "# edited`n*.ps1`n")
    $dp = Get-DefaultPaths
    Check 'save folder: both save folders sit in "Saved sessions"' ((Split-Path -Leaf $dp.ManualFolder) -eq 'Manual saves' -and
        (Split-Path -Leaf $dp.AutoFolder) -eq 'Automatic backups' -and
        (Split-Path -Parent $dp.ManualFolder) -eq $dp.SavesFolder -and (Split-Path -Parent $dp.AutoFolder) -eq $dp.SavesFolder -and
        (Split-Path -Leaf $dp.SavesFolder) -eq 'Saved sessions')

    # Folders where 6.0 and 6.1 kept them, beside the script.
    $lr = Join-Path $tmp 'legacy'
    [void][IO.Directory]::CreateDirectory((Join-Path $lr 'Automatic backups'))
    [void][IO.Directory]::CreateDirectory((Join-Path $lr 'Manual saves'))
    [IO.File]::WriteAllText((Join-Path $lr 'Automatic backups\state.json'), '{}', $utf8)
    [IO.File]::WriteAllText((Join-Path $lr 'Manual saves\m.ps1'), 'x', $utf8)
    $notes = @(Move-LegacySaveFolders -Root $lr)
    Check 'legacy folders: both moved into "Saved sessions", contents and all' ($notes.Count -eq 2 -and
        [IO.File]::Exists((Join-Path $lr 'Saved sessions\Automatic backups\state.json')) -and
        [IO.File]::Exists((Join-Path $lr 'Saved sessions\Manual saves\m.ps1')) -and
        -not [IO.Directory]::Exists((Join-Path $lr 'Automatic backups')))
    [void][IO.Directory]::CreateDirectory((Join-Path $lr 'Manual saves'))
    [IO.File]::WriteAllText((Join-Path $lr 'Manual saves\late.ps1'), 'y', $utf8)
    $notes = @(Move-LegacySaveFolders -Root $lr)
    Check 'legacy folders: never moved over a folder that exists, and the log says why' ($notes.Count -eq 1 -and $notes[0] -like "'Manual saves' beside the script left as it is*" -and
        [IO.File]::Exists((Join-Path $lr 'Manual saves\late.ps1')) -and -not [IO.File]::Exists((Join-Path $lr 'Saved sessions\Manual saves\late.ps1')))
    Check 'legacy folders: nothing to move is no news' (@(Move-LegacySaveFolders -Root (Join-Path $tmp 'nowhere')).Count -eq 0)
    $lr2 = Join-Path $tmp 'legacy2'
    [void][IO.Directory]::CreateDirectory((Join-Path $lr2 'Automatic backups'))
    Check 'legacy folders: used where they are until moved' ((Resolve-SaveFolder (Join-Path $lr2 'Saved sessions\Automatic backups') (Join-Path $lr2 'Automatic backups')) -eq (Join-Path $lr2 'Automatic backups') -and
        (Resolve-SaveFolder (Join-Path $lr 'Saved sessions\Automatic backups') (Join-Path $lr 'Automatic backups')) -eq (Join-Path $lr 'Saved sessions\Automatic backups'))

    # --- The compare window's logic -----------------------------------------

    $cr = Get-CompareRows -Before (G 'C:\A', 'C:\B' 'C:\C') -After (G 'c:\b' 'C:\D') -BeforeNames @([string[]]@('Aye', ''), [string[]]@('See'))
    Check 'compare: rows in window and tab order, marked missing or same' ((($cr.Before | ForEach-Object { '{0}{1}{2}' -f $_.Window, $_.Tab, $_.Status }) -join ' ') -eq '00missing 01same 10missing')
    Check 'compare: the right side marks what is new' ((($cr.After | ForEach-Object { '{0}:{1}' -f $_.Path, $_.Status }) -join ' ') -eq 'c:\b:same C:\D:added')
    Check 'compare: saved names are used, the folder name when there is none' ((($cr.Before | ForEach-Object Name) -join '|') -eq 'Aye|B|See')
    Check 'compare: an empty side gives no rows' (@((Get-CompareRows -Before @() -After (G 'C:\A')).Before).Count -eq 0)

    function Sel { param([string]$Path, [string[]]$Group) [pscustomobject]@{ Path = $Path; Group = $Group } }
    function Win { param([string]$Key, [string[]]$Paths) [pscustomobject]@{ Key = $Key; Paths = $Paths } }
    function Steps { param($Plan) ($Plan.Steps | ForEach-Object { '{0} {1} {2}' -f $_.Kind, $_.Key, $_.Path }) -join '; ' }
    $abc = [string[]]@('C:\A', 'C:\B', 'C:\C')
    $xy  = [string[]]@('C:\X', 'C:\Y')
    $plan = New-OpenPlan -Selected @((Sel 'C:\A' $abc), (Sel 'C:\B' $abc), (Sel 'C:\C' $abc), (Sel 'C:\X' $xy), (Sel 'C:\Y' $xy)) -Open @((Win '100' @('c:\a')))
    Check 'open plan: an open folder is skipped, its tab-mates join its window' ((Steps $plan) -eq 'Tab 100 C:\B; Tab 100 C:\C; Window new1 C:\X; Tab new1 C:\Y' -and $plan.Skipped -eq 1)
    $plan = New-OpenPlan -Selected @((Sel 'C:\D' ([string[]]@('C:\A', 'C:\B', 'C:\C', 'C:\D')))) -Open @((Win '1' @('C:\A')), (Win '2' @('C:\B', 'C:\C')))
    Check 'open plan: the window holding most tab-mates wins' ((Steps $plan) -eq 'Tab 2 C:\D')
    $plan = New-OpenPlan -Selected @((Sel 'C:\Q' ([string[]]@('C:\Q'))), (Sel 'c:\q' ([string[]]@('c:\q')))) -Open @()
    Check 'open plan: a folder ticked twice opens once' ((Steps $plan) -eq 'Window new1 C:\Q' -and $plan.Skipped -eq 1)
    $plan = New-OpenPlan -Selected @((Sel 'C:\M' ([string[]]@('C:\M', 'C:\N')))) -Open @((Win '7' @('C:\Unrelated')))
    Check 'open plan: no tab-mate open means a new window' ((Steps $plan) -eq 'Window new1 C:\M')

    # --- Writing Settings.ini -----------------------------------------------

    $ini2 = Join-Path $tmp 'Settings2.ini'
    Write-BackupSettings -Path $ini2 -Values ([pscustomobject]@{ KeepBackups = 7; Warnings = $false; RestartMinFolders = 2; DropWarnings = $false; DropMinFolders = 5; DropMinPercent = 80 })
    $w2 = Read-BackupSettings -Path $ini2
    Check 'settings: written values read back' ($w2.Problems.Count -eq 0 -and $w2.KeepBackups -eq 7 -and -not $w2.Warnings -and $w2.RestartMinFolders -eq 2 -and
        -not $w2.DropWarnings -and $w2.DropMinFolders -eq 5 -and $w2.DropMinPercent -eq 80)
    $w2text = [IO.File]::ReadAllText($ini2, [Text.Encoding]::UTF8)
    Check 'settings: the written file keeps its explanations, CRLF' ($w2text.Contains('; How many automatic backups to keep') -and $w2text.Contains("KeepBackups = 7`r`n"))
    $threw = $false
    try { Write-BackupSettings -Path $ini2 -Values ([pscustomobject]@{ DropMinPercent = 101 }) } catch { $threw = $true }
    Check 'settings: a value out of range is refused, the file left alone' ($threw -and (Read-BackupSettings -Path $ini2).DropMinPercent -eq 80)

    # --- The scheduled task (defined, never registered here) -----------------

    $taskScript = 'C:\Some folder, etc\Save Explorer Windows.ps1'
    $def = New-AutoBackupTask -ScriptPath $taskScript
    $act = @($def.Actions)[0]
    Check 'task: runs the script hidden, with -Auto, its path quoted' ($act.Execute -eq 'conhost.exe' -and
        $act.Arguments -eq ('--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Auto' -f $taskScript))
    Check 'task: the path reads back from the action' ((Get-TaskScriptPath $def) -eq $taskScript)
    $trg = @($def.Triggers)[0]
    Check 'task: every 2 hours, all day' ($trg.Repetition.Interval -eq 'PT2H' -and $trg.Repetition.Duration -eq 'P1D')
    Check 'task: only while signed in, without administrator rights' ([string]$def.Principal.LogonType -eq 'Interactive' -and [string]$def.Principal.RunLevel -eq 'Limited')
    Check 'task: catches up, never runs twice at once, stopped after 15 minutes' ($def.Settings.StartWhenAvailable -and
        [string]$def.Settings.MultipleInstances -eq 'IgnoreNew' -and $def.Settings.ExecutionTimeLimit -eq 'PT15M')

    # --- state.json ---------------------------------------------------------

    $sf = Join-Path $tmp 'state'
    [void][IO.Directory]::CreateDirectory($sf)
    $st = New-BackupState
    $st.LastEmptyAt = $base
    $st.Incidents.Add([pscustomobject]@{
        Id = 'one'; DetectedAt = $base; BaselineFile = 'Restore Explorer Session 2026.10.10 10-00-00.ps1'
        BaselineSavedAt = $base.AddHours(-2); CurrentFile = ''; Cause = 'restart'; Reason = 'the PC restarted'
        Missing = [string[]]$tricky; Notified = $false
    })
    $st.Incidents.Add([pscustomobject]@{
        Id = 'two'; DetectedAt = $base; BaselineFile = 'b.ps1'; BaselineSavedAt = $base; CurrentFile = 'c.ps1'
        Cause = 'drop'; Reason = 'r'; Missing = [string[]]@($tricky[1]); Notified = $true
    })
    Write-BackupState -Folder $sf -State $st
    $back = Read-BackupState -Folder $sf
    Check 'state: incidents survive' ($back.Incidents.Count -eq 2 -and -not $back.Unreadable)
    Check 'state: tricky paths survive exactly' ((Join-Paths $back.Incidents[0].Missing) -ceq (Join-Paths $tricky))
    Check 'state: a single missing path stays a list' ($back.Incidents[1].Missing.Count -eq 1 -and $back.Incidents[1].Missing[0] -ceq $tricky[1])
    Check 'state: times survive' ($back.LastEmptyAt -eq $base -and $back.Incidents[0].BaselineSavedAt -eq $base.AddHours(-2))
    Check 'state: flags and names survive' ($back.Incidents[0].Notified -eq $false -and $back.Incidents[1].Notified -eq $true -and $back.Incidents[1].CurrentFile -eq 'c.ps1')
    [IO.File]::WriteAllText((Join-Path $sf 'state.json'), '{ not json', $utf8)
    $bad = Read-BackupState -Folder $sf
    Check 'state: an unreadable file is reported' ($bad.Unreadable -and $bad.Incidents.Count -eq 0)
    Check 'state: an unreadable file is set aside, not lost' (@([IO.Directory]::GetFiles($sf, 'state (unreadable*')).Count -eq 1 -and
        -not [IO.File]::Exists((Join-Path $sf 'state.json')))

    # --- The restore file ---------------------------------------------------

    $rf = Join-Path $tmp 'Restore Explorer Session 2026.10.10 12-00-00.ps1'
    $groups = @([string[]]@($tricky[0], $tricky[1]), [string[]]@($tricky[2]), [string[]]@($tricky[3], $tricky[4], $tricky[5]))
    $names  = @([string[]]@($jp, 'smile'), [string[]]@('[brackets]'), [string[]]@('a', 'b', 'c'))
    $meta = [ordered]@{ format = 1; savedAt = $base.ToString('o'); kind = 'auto'; label = ''; complete = $true; frozenTabs = 0; names = $names }
    Write-RestoreScript -Path $rf -Groups $groups -Note '' -Meta $meta
    $high = 0
    foreach ($byte in [IO.File]::ReadAllBytes($rf)) { if ($byte -gt 127) { $high++ } }
    Check 'restore file: pure ASCII' ($high -eq 0)
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($rf, [ref]$tokens, [ref]$errors)
    Check 'restore file: parses as PowerShell' ($errors.Count -eq 0)
    # A line starting with '@ inside the template would end it early; the
    # restore file must still carry the template's first and last lines.
    $restoreText = [IO.File]::ReadAllText($rf, [Text.Encoding]::UTF8)
    Check 'restore file: the whole template made it, every marker filled' (
        $restoreText.StartsWith('# Windows Explorer session restore script') -and
        $restoreText.Contains('function Open-ExplorerGroup') -and
        $restoreText.TrimEnd().EndsWith('Read-Host "`nPress Enter to exit"') -and -not $restoreText.Contains('@@@'))
    # The filter that skips folders already open, as the restore file holds it.
    $restoreAst = [Management.Automation.Language.Parser]::ParseFile($rf, [ref]$null, [ref]$null)
    $filter = $restoreAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-MissingFolders' }, $true)
    Check 'restore file: carries the filter for folders already open' ($null -ne $filter)
    if ($filter) {
        . ([scriptblock]::Create($filter.Extent.Text))
        $plan = Select-MissingFolders -Groups (G 'C:\A', 'C:\B' 'C:\C' 'C:\A') -OpenPaths @('c:\a', 'C:\C', 'C:\Elsewhere')
        Check 'restore: open folders skipped, each once, any letter case' ($plan.Skipped -eq 2 -and $plan.Groups.Count -eq 2 -and
            (Join-Paths $plan.Groups[0]) -eq 'C:\B' -and (Join-Paths $plan.Groups[1]) -eq 'C:\A')
        Check 'restore: everything open opens nothing' ((Select-MissingFolders -Groups (G 'C:\A' 'C:\B') -OpenPaths @('C:\B', 'C:\A')).Groups.Count -eq 0)
        $one = Select-MissingFolders -Groups (G 'C:\X') -OpenPaths @()
        Check 'restore: nothing open opens everything, one tab staying a window' ($one.Skipped -eq 0 -and $one.Groups.Count -eq 1 -and
            $one.Groups[0].Count -eq 1 -and $one.Groups[0][0] -eq 'C:\X')
    }

    $b = Read-SessionBackup -Path $rf
    $same = $b.Groups.Count -eq 3
    for ($i = 0; $same -and $i -lt 3; $i++) { $same = (Join-Paths $b.Groups[$i]) -ceq (Join-Paths $groups[$i]) }
    Check 'restore file: windows and tricky paths round-trip exactly' ($same)
    Check 'restore file: display names round-trip' ($b.Names.Count -eq 3 -and $b.Names[0][0] -ceq $jp -and $b.Names[2][2] -eq 'c')
    Check 'restore file: time, kind, completeness, count' ($b.SavedAt -eq $base -and $b.Kind -eq 'auto' -and $b.Complete -and $b.Count -eq 6)

    $rf1 = Join-Path $tmp 'Restore Explorer Session 2026.10.10 13-00-00.ps1'
    $meta1 = [ordered]@{ format = 1; savedAt = $base.AddHours(1).ToString('o'); kind = 'auto'; label = ''; complete = $false; frozenTabs = 1; names = @(, [string[]]@('smile')) }
    Write-RestoreScript -Path $rf1 -Groups @(, [string[]]@($tricky[1])) -Note 'frozen!' -Meta $meta1
    $b1 = Read-SessionBackup -Path $rf1
    Check 'restore file: one window of one tab stays that shape' ($b1.Groups.Count -eq 1 -and $b1.Groups[0].Count -eq 1 -and $b1.Groups[0][0] -ceq $tricky[1])
    Check 'restore file: one name stays that shape' ($b1.Names.Count -eq 1 -and $b1.Names[0].Count -eq 1 -and $b1.Names[0][0] -eq 'smile')
    Check 'restore file: incomplete flag and frozen report survive' ((-not $b1.Complete) -and $b1.Note -eq 'frozen!')

    # A save from before the metadata: time from the name, complete unless a
    # frozen report rides along.
    $oldData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[["C:\\Old"]]'))
    $old = Join-Path $tmp 'Restore Explorer Session 2026.10.09 08-30-00_label.ps1'
    [IO.File]::WriteAllText($old, ("# old`n`$dataB64 = '{0}'`n`$noteB64 = ''`n" -f $oldData), $utf8)
    $bo = Read-SessionBackup -Path $old
    Check 'old restore file: read without metadata' ($bo -and $bo.Groups[0][0] -eq 'C:\Old' -and $bo.Complete -and $bo.Kind -eq '' -and
        $bo.SavedAt.DateTime -eq [DateTime]::new(2026, 10, 9, 8, 30, 0))

    [IO.File]::WriteAllText((Join-Path $tmp 'Restore Explorer Session junk.ps1'), "# not a restore script`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp 'Restore Explorer Session note.txt'), "text`n", $utf8)
    Check 'unreadable file: Read-SessionBackup gives nothing' ($null -eq (Read-SessionBackup -Path (Join-Path $tmp 'Restore Explorer Session junk.ps1')))
    $listed = Join-Paths (@(Get-SessionBackups -Folder $tmp) | ForEach-Object File)
    Check 'Get-SessionBackups: newest first, nothing else' ($listed -eq ('Restore Explorer Session 2026.10.10 13-00-00.ps1|' +
        'Restore Explorer Session 2026.10.10 12-00-00.ps1|Restore Explorer Session 2026.10.09 08-30-00_label.ps1'))
    Check 'Get-SessionBackups: a missing folder gives nothing' (@(Get-SessionBackups -Folder (Join-Path $tmp 'nope')).Count -eq 0)

    # --- A sequence of automatic runs --------------------------------------
    # Made-up scans two hours apart, KeepBackups 3. Backups are named by
    # their hour below.

    $auto = Join-Path $tmp 'auto'
    [void][IO.Directory]::CreateDirectory($auto)
    $script:FakeRestart = $quiet
    $keep3 = New-Settings
    $keep3.KeepBackups = 3
    function Invoke-Run {
        param([int]$Hour, $Groups, [bool]$Complete = $true, [switch]$WindowOpen)
        $names = @(foreach ($g in @($Groups)) { , [string[]]@(@($g) | ForEach-Object { Get-FolderDisplayName $_ }) })
        Update-AutomaticBackups -Folder $auto -Groups $Groups -Names $names -Complete $Complete `
            -FrozenCount $(if ($Complete) { 0 } else { 1 }) -ScanError '' -Note $(if ($Complete) { '' } else { 'frozen' }) `
            -Now $base.AddHours($Hour) -Settings $keep3 -RestartInfoSince { param($Since) $script:FakeRestart } -WindowOpen:$WindowOpen
    }
    function Get-Hours { Join-Paths (@(Get-SessionBackups -Folder $auto) | ForEach-Object { [int]($_.SavedAt - $base).TotalHours }) }
    function Get-Incidents { (Read-BackupState -Folder $auto).Incidents }
    function Get-FileAt { param([int]$Hour) 'Restore Explorer Session {0}.ps1' -f $base.AddHours($Hour).ToString('yyyy.MM.dd HH-mm-ss') }

    try {
    $r = Invoke-Run 0 (G 'C:\1', 'C:\2' 'C:\3')
    Check 'runs: the first run saves' ((Get-Hours) -eq '0' -and $r.SavedFile -eq (Get-FileAt 0) -and $null -eq $r.Verdict)
    Check 'runs: a save records the program version' ((Read-SessionBackup -Path (Join-Path $auto (Get-FileAt 0))).Version -eq (Get-ProgramVersion) -and
        (Get-ProgramVersion) -match '^\d+\.\d+$')
    $r = Invoke-Run 2 (G 'C:\3', 'C:\1' 'C:\2')
    Check 'runs: same folders regrouped replace the older backup' ((Get-Hours) -eq '2' -and $r.Removed.Count -eq 1)
    $r = Invoke-Run 4 (G 'C:\1', 'C:\2')
    Check 'runs: one folder closed is no loss' ((Get-Hours) -eq '4|2' -and -not $r.NewIncident -and -not $r.Launch)

    $script:FakeRestart = New-Restart $base.AddHours(5) $base.AddHours(5)
    $r = Invoke-Run 6 (G 'C:\1')
    Check 'runs: a folder lost to a restart is a loss' ($r.NewIncident -and $r.NewIncident.Cause -eq 'restart' -and
        (Join-Paths $r.NewIncident.Missing) -eq 'C:\2')
    Check 'runs: the loss locks the backup from before it' ($r.NewIncident.BaselineFile -eq (Get-FileAt 4) -and $r.NewIncident.CurrentFile -eq (Get-FileAt 6))
    Check 'runs: the loss asks for the window, once' ($r.Launch -and @(Get-Incidents)[0].Notified)

    $r = Invoke-Run 8 (G 'C:\1', 'C:\x8')
    Check 'runs: the restart before the new baseline no longer counts' (-not $r.NewIncident -and -not $r.Launch -and (Get-Hours) -eq '8|6|4|2')
    [void](Invoke-Run 10 (G 'C:\1', 'C:\x10'))
    $r = Invoke-Run 12 (G 'C:\1', 'C:\x12')
    Check 'runs: rotation passes over the locked backup' ((Get-Hours) -eq '12|10|8|4')

    $r = Invoke-Run 14 (G 'C:\1', 'C:\2', 'C:\x12')
    Check 'runs: the lock goes once the lost folder is open again' (@(Get-Incidents).Count -eq 0)
    Check 'runs: ...and the unlocked backup ages out' ((Get-Hours) -eq '14|12|10')

    $r = Invoke-Run 16 @()
    Check 'runs: nothing open saves nothing and warns of nothing' ($null -eq $r.SavedFile -and -not $r.NewIncident -and (Get-Hours) -eq '14|12|10')
    Check 'runs: ...and is remembered as the latest session' ((Read-BackupState -Folder $auto).LastEmptyAt -eq $base.AddHours(16))
    $r = Invoke-Run 18 (G 'C:\9')
    Check 'runs: after an empty scan, nothing counts as lost' (-not $r.NewIncident -and $r.Verdict.Missing.Count -eq 0 -and (Get-Hours) -eq '18|14|12')

    $r = Invoke-Run 20 (G 'C:\9') -Complete $false
    Check 'runs: an incomplete scan is saved but judged on nothing' ($r.SavedFile -and $null -eq $r.Verdict -and (Get-Hours) -eq '20|18|14')

    $script:FakeRestart = New-Restart $base.AddHours(21) $base.AddHours(21)
    $r = Invoke-Run 22 @() -WindowOpen
    Check 'runs: everything gone after a restart is a loss, measured from the last complete backup' ($r.NewIncident -and
        $r.NewIncident.BaselineFile -eq (Get-FileAt 18) -and $r.NewIncident.CurrentFile -eq '' -and $null -eq $r.SavedFile)
    Check 'runs: with the window already open, the loss waits' (-not $r.Launch -and -not @(Get-Incidents)[0].Notified)
    Check 'runs: a loss is not remembered as an empty session' ((Read-BackupState -Folder $auto).LastEmptyAt -eq $base.AddHours(16))
    $r = Invoke-Run 24 @()
    Check 'runs: the same loss is not counted twice, and its window opens later' (-not $r.NewIncident -and $r.Launch -and @(Get-Incidents).Count -eq 1)

    [IO.File]::WriteAllText((Join-Path $auto 'state.json'), 'garbage', $utf8)
    $r = Invoke-Run 26 (G 'C:\26')
    Check 'runs: with state.json unreadable, nothing is deleted' ($r.Removed.Count -eq 0 -and (Get-Hours) -eq '26|20|18|14')
    $logText = [IO.File]::ReadAllText((Join-Path $auto 'log.txt'), [Text.Encoding]::UTF8)
    Check 'runs: the log records losses, locks and deletions' ($logText.Contains('LOST FOLDERS') -and $logText.Contains('Lock released') -and
        $logText.Contains('(same folders as the new backup)') -and $logText.Contains('could not be read'))
    } catch {
        Check ("runs: the sequence ran to the end (stopped by: {0})" -f $_.Exception.Message) $false
    }

    # --- This PC ------------------------------------------------------------

    $ri = Get-ExplorerRestartInfo -Since ([DateTimeOffset]::Now.AddDays(-1))
    Check 'this PC: boot time read' ($null -ne $ri.BootTime)
    Check 'this PC: Application log readable' ($null -eq $ri.EventLogError)

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host ("All {0} checks passed." -f $script:Checks) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} of {1} checks FAILED." -f $script:Failures, $script:Checks) -ForegroundColor Red
exit 1
