# Set up automatic backups.ps1
#
# Creates, updates or removes the Task Scheduler task that runs
# "Save Explorer Windows.ps1 -Auto", every hour unless another interval is
# chosen. Right-click this file and choose "Run with PowerShell", then
# answer the questions.
#
# Needs "Save Explorer Windows.ps1" and "Explorer Windows Shared.psm1"
# beside it. Changes only this one task, for the signed-in user, and needs
# no administrator rights. Pure ASCII, like the other scripts.

$ErrorActionPreference = 'Stop'

function Read-Choice {
    # Asks until one of $Keys (single letters) is typed; Enter picks the first.
    param([string]$Prompt, [string[]]$Keys)
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if (-not $answer) { return $Keys[0] }
        $hit = @($Keys | Where-Object { $_ -eq $answer.Substring(0, 1) })
        if ($hit.Count -gt 0) { return $hit[0] }
        Write-Host ("Please type one of: {0}" -f ($Keys -join ', '))
    }
}

function Read-Interval {
    # Asks until one of the offered intervals is typed; Enter picks
    # $Default. Returns minutes.
    param([int]$Default)
    $offer = "10, 20 or 30 minutes, or 1, 2, 3, 4, 6, 8 or 12 hours"
    Write-Host ""
    Write-Host "How often should it save? Type one of:"
    Write-Host ("    {0}" -f $offer)
    Write-Host ("Saving more often keeps more backups: by default enough to reach {0} hours" -f (Get-AutoKeepHours))
    Write-Host "back (KeepBackups = auto in Settings.ini), 48 at every hour, 288 at 10 minutes."
    while ($true) {
        $answer = (Read-Host ("How often [Enter = {0}]" -f (Format-TaskInterval $Default))).Trim()
        if (-not $answer) { return $Default }
        $minutes = ConvertFrom-IntervalText $answer
        if ($minutes) { return $minutes }
        Write-Host ("Please type one of: {0}" -f $offer)
    }
}

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'Explorer Windows Shared.psm1') -Force -DisableNameChecking
    $script = Join-Path $PSScriptRoot 'Save Explorer Windows.ps1'
    if (-not [IO.File]::Exists($script)) { throw "'Save Explorer Windows.ps1' is not beside this file." }

    Write-Host ("Save Explorer Windows {0} - automatic backups" -f (Get-ProgramVersion))
    Write-Host ""

    # An elevated session would register the task for whoever elevated it,
    # which may be another account, and the task must run as the person
    # whose windows it saves.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Host "This window is running as administrator. Close it and run this file again" -ForegroundColor Yellow
        Write-Host "with a normal right-click > Run with PowerShell, so the backups run as you." -ForegroundColor Yellow
        return
    }

    $name     = Get-AutoBackupTaskName
    $existing = Get-AutoBackupTask
    $folder   = Get-DefaultPaths
    $minutes  = Get-DefaultTaskInterval

    if ($existing) {
        $runs = Get-TaskScriptPath $existing
        $current = Get-TaskInterval $existing
        # Offered back as the default only when it is still a choice: a
        # task an earlier setup made once a day falls back to the default.
        if (@(Get-TaskIntervalChoices) -contains $current) { $minutes = $current }
        $how = if ($current -gt 0) { Format-TaskInterval $current } else { 'on a schedule set by hand' }
        if ($runs -and [string]::Equals($runs, $script, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host ("Automatic backups are set up, {0}, and run this copy of the script." -f $how)
        } else {
            Write-Host ("Automatic backups are set up, {0}, but they run a different copy of the script:" -f $how)
            Write-Host ("    {0}" -f $(if ($runs) { $runs } else { '(unknown)' }))
        }
        Write-Host ""
        Write-Host "  U  Update the task to run this copy, and choose how often (keeps your backups)"
        Write-Host "  R  Remove the task (your backups stay where they are)"
        Write-Host "  Q  Quit and change nothing"
        $choice = Read-Choice -Prompt "Your choice [U/R/Q]" -Keys @('U', 'R', 'Q')
    } else {
        Write-Host "This sets up a task that saves your open File Explorer windows on a"
        Write-Host ("schedule ({0} unless you choose otherwise), while you are signed in, into:" -f (Format-TaskInterval $minutes))
        Write-Host ("    {0}" -f $folder.AutoFolder)
        Write-Host "It keeps the newest backups (see Settings.ini) and warns you when folders"
        Write-Host "seem to have been lost, for example to a restart."
        Write-Host ""
        Write-Host "  I  Install it"
        Write-Host "  Q  Quit and change nothing"
        $choice = Read-Choice -Prompt "Your choice [I/Q]" -Keys @('I', 'Q')
    }

    switch ($choice) {
        'Q' { Write-Host "Nothing changed." }
        'R' {
            Unregister-ScheduledTask -TaskName $existing.TaskName -TaskPath $existing.TaskPath -Confirm:$false
            Write-Host "The task is removed. No more automatic backups will be made." -ForegroundColor Green
        }
        default {
            $minutes = Read-Interval -Default $minutes
            [void](Register-ScheduledTask -TaskName $name -InputObject (New-AutoBackupTask -ScriptPath $script -Minutes $minutes) -Force)
            # A task an earlier setup made under another name would keep
            # running beside the new one.
            if ($existing -and $existing.TaskName -ne $name) {
                Unregister-ScheduledTask -TaskName $existing.TaskName -TaskPath $existing.TaskPath -Confirm:$false
            }
            $next = (Get-ScheduledTaskInfo -TaskName $name).NextRunTime
            Write-Host ("Done. The next automatic backup is at {0:HH:mm}, then {1}." -f $next, (Format-TaskInterval $minutes)) -ForegroundColor Green
            $keepSetting = (Read-BackupSettings -Path $folder.Settings).KeepBackups
            $keepCount = Resolve-KeepCount -KeepBackups $keepSetting -IntervalMinutes $minutes
            if ($keepSetting -eq 0) {
                Write-Host ("It keeps the newest {0} backups, {1} hours' worth (KeepBackups = auto)." -f $keepCount, (Get-AutoKeepHours))
            } else {
                Write-Host ("It keeps the newest {0} backups, {1} at this interval (KeepBackups in Settings.ini)." -f $keepCount, (Format-KeepSpan -Count $keepCount -IntervalMinutes $minutes))
            }
            Write-Host ""
            if ((Read-Choice -Prompt "Make one now, to check it works? [Y/N]" -Keys @('Y', 'N')) -eq 'Y') {
                Start-ScheduledTask -TaskName $name
                Write-Host "Working..."
                $deadline = (Get-Date).AddMinutes(10)
                Start-Sleep -Seconds 2
                while ((Get-ScheduledTask -TaskName $name).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
                $log = Join-Path $folder.AutoFolder 'log.txt'
                if ([IO.File]::Exists($log)) {
                    Write-Host "Last line of the log:"
                    Write-Host ("    {0}" -f @([IO.File]::ReadAllLines($log, [Text.Encoding]::UTF8))[-1])
                } else {
                    Write-Host "No log yet; look in Task Scheduler for the task's last result." -ForegroundColor Yellow
                }
            }
        }
    }
} catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
} finally {
    Read-Host "`nPress Enter to exit"
}
