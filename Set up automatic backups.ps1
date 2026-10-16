# Set up automatic backups.ps1
#
# Creates, updates or removes the Task Scheduler task that runs
# "Save Explorer Windows.ps1 -Auto" every two hours. Right-click this file
# and choose "Run with PowerShell", then answer the questions.
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
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    $folder   = Get-DefaultPaths

    if ($existing) {
        $runs = Get-TaskScriptPath $existing
        if ($runs -and [string]::Equals($runs, $script, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "Automatic backups are set up and run this copy of the script."
        } else {
            Write-Host "Automatic backups are set up, but they run a different copy of the script:"
            Write-Host ("    {0}" -f $(if ($runs) { $runs } else { '(unknown)' }))
        }
        Write-Host ""
        Write-Host "  U  Update the task to run this copy (keeps your backups)"
        Write-Host "  R  Remove the task (your backups stay where they are)"
        Write-Host "  Q  Quit and change nothing"
        $choice = Read-Choice -Prompt "Your choice [U/R/Q]" -Keys @('U', 'R', 'Q')
    } else {
        Write-Host "This sets up a task that saves your open File Explorer windows every two"
        Write-Host "hours, while you are signed in, into:"
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
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "The task is removed. No more automatic backups will be made." -ForegroundColor Green
        }
        default {
            [void](Register-ScheduledTask -TaskName $name -InputObject (New-AutoBackupTask -ScriptPath $script) -Force)
            $next = (Get-ScheduledTaskInfo -TaskName $name).NextRunTime
            Write-Host ("Done. The next automatic backup is at {0:HH:mm}, then every two hours." -f $next) -ForegroundColor Green
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
