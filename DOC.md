# DOC — Explorer Session Save/Restore

How the program is put together and what it does at runtime. `CLAUDE.md` holds the rules that must not be broken and `.claude/rules/script.md` the detail behind each; this file holds everything else.

---

## Files

| File | What it is |
|---|---|
| `Save Explorer Windows.ps1` | The entry point: a save by hand, `-Auto` for the scheduled run, `-ShowIncident` for the lost-folder window. Its name stays fixed, since the scheduled task names it |
| `Explorer Windows Shared.psm1` | Everything else: the scan, the restore-file format, `Settings.ini`, `state.json`, and the cleanup and loss rules. Must sit beside the script. Holds the program's version, `$ProgramVersion`, which a run by hand prints and every save records |
| `Set up automatic backups.ps1` | Installs, updates or removes the scheduled task, from `New-AutoBackupTask` in the module. Run by a person; asks before changing anything, and refuses to run elevated |
| `Settings.ini` | The automatic backups' settings, each explained in the file. Rewritten with the defaults when missing; an unreadable value counts as its default and is logged |
| `Tests\Run tests.ps1` | The module's checks. Needs no open Explorer window, and never registers a task |
| `README.md` | For people using it: how to save, set up the task and restore, and what to expect, in plain words |

Every save goes under one folder beside the script, `Saved sessions\`:

| Folder | Holds |
|---|---|
| `Saved sessions\Manual saves\` | One restore script per save by hand: `Restore Explorer Session <yyyy.MM.dd HH-mm-ss>[_label].ps1`. Never cleaned up |
| `Saved sessions\Automatic backups\` | The scheduled run's restore scripts (no label), `log.txt` and `state.json` |

Running a restore script reopens its session with the original window/tab grouping, maximized. Each one is self-contained: its paths, any frozen-tab report and its metadata are base64-embedded in it.

---

## Running it

**By hand**: asks for an optional label (with the hidden `debug` switch, `.claude/rules/script.md`), scans, prints the frozen-tab report if there is one, and writes into `Saved sessions\Manual saves\`.

**`-Auto`**: what Task Scheduler runs. In order:

1. Takes the mutex `Local\SaveExplorerWindows.Auto`, so only one run goes at a time.
2. Reads `Settings.ini`.
3. Waits until the taskbar's explorer.exe, the boot and any Explorer crash event are 5 minutes old. Right after a sign-in Windows is still reopening folder windows ("Restore previous folder windows at logon"), and a scan then would report most of them lost.
4. Scans (*The scan*, below), keeping each tab's `LocationName` too.
5. Under the mutex `Local\SaveExplorerWindows.State`, `Update-AutomaticBackups` picks the comparison point, checks for restarts, releases finished locks, judges the loss, locks, saves, cleans up, logs, decides on the window and writes the state.
6. For a new loss, starts `-ShowIncident` as a separate hidden process, so this run ends and the next can start while the window waits.

**`-ShowIncident`**: a MessageBox about the newest loss (Yes/No, No by default, `DefaultDesktopOnly` so it stays on top without taking focus): the missing folders' names with their parent folder, the cause, and the locked file. Yes releases the lock (`Remove-BackupIncident`, logged). No keeps it and opens Explorer with that backup selected. A placeholder until the compare window (*Next*).

**Parameters**: `-BackupFolder`, `-ManualFolder`, `-SettingsPath` (each defaulting to beside the script), and `-NoWindow`, which with `-Auto` records a loss without opening the window, for tests. A start in an MTA host relaunches with `-STA` and passes them on.

### The scheduled task

`Set up automatic backups.ps1` registers it from `New-AutoBackupTask`, the one definition the tests check:

- Name: `Save Explorer Windows every 2 hours`.
- Trigger: daily at 00:50, repeating every 2 hours, so at ten to every odd hour. Runs only while the user is logged on, not elevated; a missed run starts as soon as possible; a run still going is not started twice; stopped after 15 minutes.
- Action: `conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<folder>\Save Explorer Windows.ps1" -Auto`. `conhost --headless` keeps a console window from flashing up.

The action names the script file, so renaming or moving it stops the backups until the action is updated. Whether a run worked shows in `Saved sessions\Automatic backups\log.txt`, and the task's last run result in Task Scheduler.

---

## Architecture

```
Save Explorer Windows.ps1
├─ STA relaunch guard (passes the parameters on)
├─ Import the module
├─ Frozen-tab report: Add-ReportLine / Format-ReportText, New-FrozenReport
├─ By hand: label prompt → Invoke-ExplorerScan → report → Saved sessions\Manual saves\
├─ -Auto: mutex → settings → wait for Explorer to settle → scan → Update-AutomaticBackups → maybe -ShowIncident
├─ -ShowIncident: MessageBox → Remove-BackupIncident, or show the locked file
└─ finally: [Environment]::Exit if a COM worker was abandoned

Explorer Windows Shared.psm1
├─ COM worker: New-ComWorker / Reset-ComWorker, Invoke-ComStep,
│  Resolve-ComError, $RpcFailureHResults, $ReadWindowScript / $CountWindowsScript
├─ ExplorerWindowProbe2 (C#, @"..."@): the Win32 view, and the taskbar's process
├─ Invoke-ExplorerScan, Get-ScanGroups, Test-ScanComplete
├─ Compare-SessionFolders, Test-SameFolders, Get-FolderDisplayName
├─ $RestoreTemplate (@'...'@), Write-RestoreScript, Read-SessionBackup, Get-SessionBackups
├─ Settings.ini: Read-BackupSettings, Write-DefaultSettingsFile
├─ state.json: Read-BackupState, Write-BackupState; Write-BackupLog; named mutexes
├─ Get-ExplorerRestartInfo, Get-LostFolderVerdict, Get-CleanupPlan
├─ Update-AutomaticBackups, Remove-BackupIncident
├─ Get-DefaultPaths, Move-LegacySaveFolders, Resolve-SaveFolder, Initialize-SaveFolder
└─ The task: Get-AutoBackupTaskName, New-AutoBackupTask, Get-TaskScriptPath

Set up automatic backups.ps1
└─ refuse if elevated → task present? update / remove / quit : install / quit → offer one run now
```

---

## The scan

`Shell.Application.Windows()` is a flat collection: one entry per **tab**, and tabs of one window share that window's HWND. Grouping by HWND recovers the window/tab structure.

Every entry is read on a worker runspace with a per-tab deadline, `$TabReadTimeoutMs` in the module, because a call into a hung window never returns. Each frozen tab costs that much wall clock. Per entry the worker reads `HWND` → `LocationName` → `LocationURL` → `Document.Folder.Self.Path`, publishing each into `$Progress` as it goes, so a hang partway through still leaves something behind.

| Outcome | Effect |
|---|---|
| Answered with a path | Added to its HWND's group |
| Answered without one | Counted as a non-folder window (This PC, Control Panel) |
| Overran the deadline | Worker abandoned, entry recorded as frozen, scan continues |
| RPC-family HRESULT | Scan stops; everything collected so far is still saved |

A scan with a frozen tab or a stop partway is **incomplete**.

### What a frozen tab yields

Usually nothing: a hung window blocks at `Windows().Item($i)`, before any property comes back. When it blocks later, whatever was read is kept and reported, a recovered `LocationURL` shown decoded, since it names a path the restore file will not contain.

Identification otherwise comes from the window manager. Any Explorer HWND that no successful COM read reported is where the frozen tabs live, and its title ("Downloads and 1 more tab - File Explorer") names the active tab and counts the rest. The address-bar probe returns nothing on Windows 11, which draws it in XAML.

The report is printed and embedded in the restore script, so the missing tabs are still named when that script runs weeks later. Short by default, full with `debug` in the label: `Add-ReportLine` tags each line `-DebugOnly` / `-QuietOnly` as it is built, and `Format-ReportText` renders one level.

---

## Automatic backups: the rules

All in the module, and all covered by `Tests\Run tests.ps1`.

- **Same folders**: paths compared as a multiset, ignoring letter case and which window a tab was in. A folder open in two tabs counts twice.
- **Cleanup after each automatic save**, deleting permanently:
  - older automatic backups holding the same folders as the new one, but only when the new scan is complete;
  - of the rest, all but the newest `KeepBackups`. Locked backups are kept on top and not counted, and the newest complete backup and the new file are never deleted;
  - nothing at all when `state.json` cannot be read; it is renamed `state (unreadable <time>).json`.
- **Comparison point**: the newest complete automatic backup, or a later scan that found nothing open (`lastEmptyAt`).
- **Was it the user?** A loss is taken as not the user's doing if, since the comparison point, the PC booted; the taskbar's explorer.exe (owner of `Shell_TrayWnd`) started, meaning a sign-out, a Fast Startup shutdown or an Explorer restart; or the Application log holds event 1000 or 1002 for explorer.exe. The folder windows' own process tells nothing: with "Launch folder windows in a separate process" on, it exits by itself once the last window closes.
- **When it warns** (`Settings.ini`):
  - `Warnings = off`: never, and no backup is ever locked (fully manual).
  - After a restart, sign-out or crash: when at least `RestartMinFolders` folders are missing.
  - Otherwise: `DropWarnings = on`, at least `DropMinFolders` missing, and those at least `DropMinPercent` percent of the folders before. Never when nothing is open now (below).
- **An incomplete scan** is saved, but never judged, never replaces another backup and never becomes the comparison point.
- **A loss (an "incident") locks the backup from before it.** The lock goes when the person answers that they closed the folders, when every missing folder is open again (as a multiset), or when the locked file is gone. A backup holds at most one lock.

### Closing every folder never warns

When a scan finds no folder open at all, and the PC, the sign-in and Explorer all stayed up since the last backup, the check takes it as the user closing everything on purpose: no warning, nothing saved, and "nothing open" becomes what the next scan is compared with, so folders opened later never count as lost. Without this, the big-drop warning would fire every time someone closed all their folders, and again when they next opened a couple, compared with the full set from before.

Losing everything to a restart, a sign-out or a crash that Windows recorded still warns. A crash Windows does not record, leaving nothing open, does not. Even then the last full backup is not deleted at once: it stays until `KeepBackups` newer, different backups have replaced it.

---

## Data formats

**Restore script**: the template plus three base64-of-UTF-8 values:

- `$dataB64`: the windows, an array of arrays of paths, tabs in order.
- `$noteB64`: the frozen-tab report, empty when nothing was frozen.
- `$metaB64`: JSON with `format`, `version` (the program's, from 6.2 on), `savedAt` (ISO 8601 with offset), `kind` (`auto` or `manual`), `label`, `complete`, `frozenTabs`, `names` (display names, arrays parallel to the windows), `bootTime` and `shellStart`. The restore code never reads it.

Saves from v5.3, which had no metadata, still read: their time comes from the file name, and they count as complete when they carry no frozen-tab report. `Read-SessionBackup` returns `$null` for anything it cannot read, so cleanup never touches such a file.

**`state.json`**: `{ format, lastEmptyAt, incidents: [ { id, detectedAt, baselineFile, baselineSavedAt, currentFile, cause, reason, missing: [paths], notified } ] }`, `cause` being `restart`, `explorer-restart`, `crash` or `drop`. Written to `state.json.tmp`, then swapped in with `File.Replace`.

**`log.txt`**: one line per run, naming files and counts, never folder paths. Past 400 KB it is cut to its last 2000 lines.

**Mutexes**: `Local\SaveExplorerWindows.Auto`, `Local\SaveExplorerWindows.State`, `Local\SaveExplorerWindows.IncidentWindow`.

---

## Keeping saves out of backups and sync

Every restore script and `state.json` lists open folders.

- **Kopia**: `Initialize-SaveFolder` writes a `.kopiaignore` holding `*` into each save folder on first use, and an automatic run into `Saved sessions` itself; Kopia's default policy reads `.kopiaignore` files, leaving out everything in and below the folder. An edited `.kopiaignore` is left alone. Not a `CACHEDIR.TAG`, though Kopia honours that too: the tag declares a folder disposable in full, and tools that trust it may delete its contents unasked. These are backups.
- **Syncthing** reads neither file. On each device that syncs the folder holding the script, its `.stignore` (at the synced folder's root) needs `Saved sessions` by its path from that root: `/<path>/Saved sessions`. On a receiving device the same line stops copies arriving; ones that arrived before stay until removed by hand.
- **git**: `.gitignore` covers `Saved sessions` and any restore script.

### Upgrading a PC that runs v6.0 or v6.1

- The script is `Save Explorer Windows.ps1`. Replace the old script and the module, and point the scheduled task's action at the new name; from then on the name stays.
- The first automatic run moves `Automatic backups\` and `Manual saves\` from beside the script into `Saved sessions\` (`Move-LegacySaveFolders`), logging each move; until then, everything keeps using them where they are. A folder whose new place already exists is left alone. v6.0's saves by hand, which lay beside the script itself, stay where they are.
- A device syncing the script's folder needs `/<path>/Saved sessions` in its `.stignore` before the upgrade, or the moved folders are synced. Its lines for the old folders can go once the move is logged.
- The per-tab deadline is 2 s instead of 1 s, and `KeepBackups` defaults to 20 instead of 10. An existing `Settings.ini` keeps its own value until it is edited.

---

## The generated restore script

Contains its own STA guard, the three base64 values, `Get-ComId` / `Wait-For` helpers, a P/Invoke block for `SetForegroundWindow`/`ShowWindow`, `Open-ExplorerGroup` and `Select-MissingFolders`.

First it reads the paths open now and drops them from the saved windows (`Select-MissingFolders`): as a multiset, ignoring letter case, so a folder open once is skipped once. A window left with no folders is not opened. A restore run again after a partial loss therefore reopens only what is missing; a missing folder whose tab-mates are still open opens in a window of its own, not beside them (the compare window, *Next*, is to fix that). Restore scripts written before 6.4 lack this and open everything. Reading the open paths goes through COM on the main thread, so a frozen Explorer window holds the restore up until it is closed.

Then, per window group left:

1. `Shell.Application.Open(firstPath)`: no argument parsing, so spaces and special characters are safe
2. Poll for the new HWND
3. `ShowWindow(hwnd, 3)`: SW_MAXIMIZE
4. For each additional path:
   - snapshot COM identities of existing tabs
   - `SetForegroundWindow` → `SendKeys '^t'`
   - poll for a tab with matching HWND and a new COM identity
   - `$newTab.Navigate2($path)`
   - poll `$newTab.Busy` until false
   - re-maximize

---

## Do / do not, and why

The numbered traps in `CLAUDE.md` are the rest of this list; these are the ones tied to no single trap.

**Do read a file from disk before editing.** The restore template is a here-string inside the module, so template edits and module edits look identical in a diff and behave completely differently.

**Do run the verification checklist after every edit** (`.claude/rules/script.md`), including `Tests\Run tests.ps1` and both report levels.

**Do leave the startup diagnostics in.** Apartment state and the raw `Shell.Application` window count are one-line diagnoses for three separate causes that all present as "no windows found": MTA, elevation and HWND overflow.

**Do not open paths with `Start-Process -ArgumentList`.** It splits on spaces, turning one path into two folders. `Shell.Open()` takes the string whole.

**Keep each restore script self-contained.** One that depends on a sidecar breaks when it is moved.

**Do not `-NoExit` the generated script or add a `cmd /k` launcher.** The `finally` block's `Read-Host` keeps the window open on its own.

**Do not "simplify" `Invoke-ComStep` into a direct COM call.** It is the most inviting cleanup in the module and the most destructive: trap 11.

---

## Open questions for the maintainer

Raise these with the maintainer when work next touches them; each is theirs to settle.

- **Closing every folder never warns** (*Automatic backups: the rules*): are the specifics as wanted? That a scan finding nothing open, with no recorded restart, counts as deliberate and saves nothing; that a crash Windows does not record, leaving nothing open, gives no warning; and that the last full backup lasts until `KeepBackups` newer, different backups replace it. `KeepBackups` was raised from 10 to 20 in the meantime.

## Publishing

`master` stays local: its history holds private details in old commits and in its authors' addresses. What is published is the `public` branch, whose commits each hold a whole tree of `master`, authored with the maintainer's GitHub no-reply address, one commit per release:

```bash
(
  export GIT_AUTHOR_NAME=Ikkoru GIT_COMMITTER_NAME=Ikkoru
  export GIT_AUTHOR_EMAIL=58905922+Ikkoru@users.noreply.github.com
  export GIT_COMMITTER_EMAIL=58905922+Ikkoru@users.noreply.github.com
  git branch -f public "$(git commit-tree 'master^{tree}' -p public -m 'Save Explorer Windows <version>')"
)
```

Before each: `git grep` over `master`'s tree for private data (machine paths, people's names, e-mail addresses, window titles or folder names from a real session; `CLAUDE.md` trap 16), and only `public` is pushed, never `master`.

## Next: the compare window

Asked for, not started:

- Two lists side by side: the current backup and the previous one. Red: folders of the previous backup it counts as missed. Orange: folders in the current backup the previous one lacks.
- Select folders from either list and open them now. Where a currently open window holds a former tab-mate of a selected folder, open the selected one as a tab in that window, so tabs that were together stay together as far as possible.
- It opens by itself when a loss is found: `-ShowIncident` hands over to it instead of the MessageBox.
- A way to change the settings: how many folders it takes to warn, whether drops warn, whether it warns at all.

What the module already has for it: `Get-SessionBackups` and `Read-SessionBackup` (`Groups`, `Names`, `SavedAt`, `Kind`, `Complete`), `Compare-SessionFolders` (`Missing` and `Added`, each with its window and tab position), `Invoke-ExplorerScan` with `Get-ScanGroups` (`-Names`) for what is open now, `Read-BackupState` (an incident gives the locked backup, the current file and the missing paths), `Remove-BackupIncident` for a "mark as checked" button, `Read-BackupSettings` and `Write-DefaultSettingsFile`, `Get-FolderDisplayName`, and `Get-DefaultPaths().Compare` for the window's own file name.

Suggested design:

- A dropdown above each list: by default an incident's locked backup against its current file, otherwise the two newest automatic backups; saves by hand listed too, and "open right now" offered on the right.
- Rows grouped by window, with checkboxes. Buttons: select all missing, open selected, refresh, mark as checked.
- Opening: skip folders already open. For each selected folder, find the open window holding the most of its former tab-mates and add a tab there; otherwise open it in a new window, which later tab-mates then join. Repeat until nothing is left.
- `Shell.Application.Open()` opens a new window; no "open in new tab" behaviour has been seen. The restore script's Ctrl+T route needs focus and the IME off. Try ways that need no focus first: `WM_COMMAND 0xA21B` sent to the window's `ShellTabWindowClass` child, or `Navigate2` with `navOpenInNewTab` (0x800). Needs live testing.
- COM objects made on the scan's worker runspace cannot be used from the window's thread: open tabs through a `Shell.Application` made on the window's thread, or on another worker.
- WinForms works (the MessageBox does). Keep the script ASCII, and launch it without a console flash: `conhost.exe --headless powershell.exe -STA -File ...`.

## Later

1. **A UIA fallback for a dead COM service.** When the shell window service is unreachable (trap 12) nothing can be read, but windows that still answer messages would likely give up their active tab's path through UI Automation: a partial save instead of none. Per window, not per tab.
2. **Restore tab order deterministically.** COM enumeration order usually matches visual order but is not guaranteed. Check whether `IShellBrowser` exposes a tab index.
3. **Preserve window geometry.** Everything is maximized; `GetWindowRect` at save time and `SetWindowPos` at restore would keep other layouts.
4. **Record the active tab.** Restore leaves the last-opened tab focused.
5. **Drop the `Ctrl+T` SendKeys** if a way to open a tab without focus works (*Next*). It is the last fragile piece and the only reason IME must be off during restore.
