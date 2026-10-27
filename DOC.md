# DOC — Explorer Session Save/Restore

How the program is put together and what it does at runtime. `CLAUDE.md` holds the rules that must not be broken and `.claude/rules/script.md` the detail behind each; this file holds everything else.

---

## Files

| File | What it is |
|---|---|
| `Save Explorer Windows.ps1` | The entry point: a save by hand, `-Auto` for the scheduled run, `-ShowIncident` for the lost-folder window. Its name stays fixed, since the scheduled task names it |
| `Explorer Windows Shared.psm1` | Everything else: the scan, the restore-file format, `Settings.ini`, `state.json`, and the cleanup and loss rules. Must sit beside the script. Holds the program's version, `$ProgramVersion`, which a run by hand prints and every save records |
| `Compare Explorer Backups.ps1` | The compare window: two sessions side by side, reopening chosen folders beside their old tab-mates, settings. Run by a person, or by `-ShowIncident` for a loss |
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

**`-ShowIncident`**: takes the mutex `Local\SaveExplorerWindows.IncidentWindow` and runs the compare window (*The compare window*) in the same process for the newest loss. A copy without `Compare Explorer Backups.ps1` falls back to a MessageBox (Yes releases the lock; No keeps it and shows the backup in Explorer).

**Parameters**: `-BackupFolder`, `-ManualFolder`, `-SettingsPath` (each defaulting to beside the script), and `-NoWindow`, which with `-Auto` records a loss without opening the window, for tests. A start in an MTA host relaunches with `-STA` and passes them on.

### The scheduled task

`Set up automatic backups.ps1` registers it from `New-AutoBackupTask`, the one definition the tests check:

- Name: `Save Explorer Windows`. `Get-AutoBackupTask` also finds one under a name an earlier setup used (`$LegacyTaskNames`), and the setup's U replaces it with the current name.
- Trigger: daily at 00:50, repeating every hour by default, so at ten to every hour. The setup asks for the interval: 10, 20 or 30 minutes, or 1 to 12 hours where they divide a day (`$TaskIntervalMinutes`). `ConvertFrom-IntervalText` reads the answer, a bare 10, 20 or 30 as minutes and any other number as hours. On U the task's current interval is the default when it is still offered; `Get-TaskInterval` reads it back. Nothing under 10 minutes is offered: a run after a sign-in waits 5 minutes before scanning, and `KeepBackups = auto` would keep hundreds of files. Runs only while the user is logged on, not elevated; a missed run starts as soon as possible; a run still going is not started twice; stopped after 15 minutes.
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
├─ -ShowIncident: the compare window, in this process (MessageBox if it is missing)
└─ finally: [Environment]::Exit if a COM worker was abandoned

Compare Explorer Backups.ps1
├─ hide the console; read backups (both folders), state.json, the incident shown
├─ two sides: drop-down (a backup, or "Open right now" on the right) + ListView by window
├─ Get-CompareRows → colours; Tick all missing / Untick all / Refresh / Mark as checked
├─ Open ticked: Invoke-ExplorerScan → New-OpenPlan → Invoke-OpenPlan on its own STA runspace, polled by a timer
├─ Settings...: a dialog → Write-BackupSettings
└─ -RenderTo: draw the window and the dialog to PNGs, for tests

Explorer Windows Shared.psm1
├─ COM worker: New-ComWorker / Reset-ComWorker, Invoke-ComStep,
│  Resolve-ComError, $RpcFailureHResults, $ReadWindowScript / $CountWindowsScript
├─ ExplorerWindowProbe3 (C#, @"..."@): the Win32 view, and the taskbar's process
├─ Invoke-ExplorerScan, Get-ScanGroups, Test-ScanComplete
├─ Compare-SessionFolders, Test-SameFolders, Get-FolderDisplayName
├─ $RestoreTemplate (@'...'@), Write-RestoreScript, Read-SessionBackup, Get-SessionBackups
├─ Settings.ini: Read-BackupSettings, Write-DefaultSettingsFile, Write-BackupSettings
├─ state.json: Read-BackupState, Write-BackupState; Write-BackupLog; named mutexes
├─ Get-ExplorerRestartInfo, Get-LostFolderVerdict, Get-CleanupPlan
├─ Update-AutomaticBackups, Remove-BackupIncident
├─ Get-DefaultPaths, Move-LegacySaveFolders, Resolve-SaveFolder, Initialize-SaveFolder
├─ The compare window's logic: Get-CompareRows, New-OpenPlan (pure), Invoke-OpenPlan,
│  Open-ShellWindow, Add-ShellTab, Get-ComIdentity
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
  - of the rest, all but the newest `KeepBackups`. `auto`, the default (0 inside the module), is `Resolve-KeepCount`: enough for `$AutoKeepHours` at the task's interval, rounded up, the interval read from the registered task at each run (`Get-AutoBackupInterval`, hourly when there is none). Locked backups are kept on top and not counted, and the newest complete backup and the new file are never deleted;
  - nothing at all when `state.json` cannot be read; it is renamed `state (unreadable <time>).json`.
- **Comparison point**: the newest complete automatic backup, or a later scan that found nothing open (`lastEmptyAt`).
- **Was it the user?** A loss is taken as not the user's doing if, since the comparison point:
  - the PC booted;
  - the taskbar's explorer.exe (owner of `Shell_TrayWnd`) started, meaning a sign-out, a Fast Startup shutdown or an Explorer restart; or
  - the Application log holds event 1000 or 1002 for explorer.exe.

  The folder windows' own process tells nothing: with "Launch folder windows in a separate process" on, it exits by itself once the last window closes.
- **When it warns** (`Settings.ini`):
  - `Warnings = off`: never, and no backup is ever locked (fully manual).
  - After a restart, sign-out or crash: when at least `RestartMinFolders` folders are missing.
  - Otherwise: `DropWarnings = on`, at least `DropMinFolders` missing, and those at least `DropMinPercent` percent of the folders before. Never when nothing is open now (below).
- **An incomplete scan** is saved, but never judged, never replaces another backup and never becomes the comparison point.
- **A loss (an "incident") locks the backup from before it.** The lock goes in any of three ways: the person clicks "Mark as checked" in the compare window, every missing folder is open again (as a multiset), or the locked file is gone. A backup holds at most one lock.

### Closing every folder never warns

A scan may find no folder open at all while the PC, the sign-in and Explorer all stayed up since the last backup. The check takes that as the user closing everything on purpose: no warning, and nothing saved. "Nothing open" then becomes what the next scan is compared with, so folders opened later never count as lost. Without this, the big-drop warning would fire every time someone closed all their folders, and again when they next opened a couple, compared with the full set from before.

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

- The script is `Save Explorer Windows.ps1`. Replace the old script and the module, and add `Compare Explorer Backups.ps1` and `Set up automatic backups.ps1`; without the compare script, a loss falls back to the message box. Then point the scheduled task's action at the new name, or run the setup and choose U. From then on the name stays.
- The first automatic run moves `Automatic backups\` and `Manual saves\` from beside the script into `Saved sessions\` (`Move-LegacySaveFolders`), logging each move; until then, everything keeps using them where they are. A folder whose new place already exists is left alone. v6.0's saves by hand, which lay beside the script itself, stay where they are.
- A device syncing the script's folder needs `/<path>/Saved sessions` in its `.stignore` before the upgrade, or the moved folders are synced. Its lines for the old folders can go once the move is logged.
- The per-tab deadline is 2 s instead of 1 s, and `KeepBackups` defaults to `auto` (48 hours' worth) instead of 10. An existing `Settings.ini` keeps its own value until it is edited.
- The task runs every hour unless the setup is told otherwise, under the name `Save Explorer Windows`; the setup's U renames a task registered as `Save Explorer Windows every 2 hours` and offers its interval as the default.
- On a PC that has never allowed scripts, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` first, and unblock the ZIP before unpacking: Windows 11's **Run with PowerShell** runs `powershell.exe -File` with no policy override, so the window closes at once on the policy error, before the script can catch anything. The task itself passes `-ExecutionPolicy Bypass` and needs neither.

---

## The generated restore script

Contains its own STA guard, the three base64 values, `Get-ComId` / `Wait-For` helpers, the `SewRestoreApi` P/Invoke class (`RequestNewTab`, `SetForegroundWindow`, `ShowWindow`), `Open-ExplorerGroup` and `Select-MissingFolders`.

First it reads the paths open now and drops them from the saved windows (`Select-MissingFolders`): as a multiset, ignoring letter case, so a folder open once is skipped once. A window left with no folders is not opened. A restore run again after a partial loss therefore reopens only what is missing; a missing folder whose tab-mates are still open opens in a window of its own, not beside them (the compare window does that). Restore scripts written before 6.4 lack this and open everything. Reading the open paths goes through COM on the main thread, so a frozen Explorer window holds the restore up until it is closed.

Then, per window group left:

1. `Shell.Application.Open(firstPath)`: no argument parsing, so spaces and special characters are safe
2. Poll for the new HWND
3. `ShowWindow(hwnd, 3)`: SW_MAXIMIZE
4. For each additional path:
   - snapshot COM identities of existing tabs
   - `RequestNewTab`: `WM_COMMAND 0xA21B` posted to the window's `ShellTabWindowClass`, found among all its descendants; no keystrokes, no focus needed
   - poll up to 3 s for a tab with matching HWND and a new COM identity
   - none: `SetForegroundWindow` → `SendKeys '^t'`, poll again (this fallback needs focus and no IME)
   - `$newTab.Navigate2($path)`
   - poll `$newTab.Busy` until false
   - re-maximize

Restore files written before 7.0 always press Ctrl+T.

---

## The compare window

`Compare Explorer Backups.ps1`, a WinForms window. Started by hand, or by `-ShowIncident` for a loss.

**What it shows.** Each side has a drop-down of every readable save in both save folders, newest first, showing whether it was automatic or by hand, its label and its folder count. A locked one is marked "kept after a loss", an incomplete one "incomplete". The right side also offers "Open right now", a fresh `Invoke-ExplorerScan`. By default: for a loss, its locked backup against its current file (or "Open right now" when that file is gone); otherwise the second-newest automatic backup against the newest. The lists are `ListView`s grouped by window. `Get-CompareRows` marks a left row red when the right lacks it and a right row orange when the left lacks it, pairing as `Compare-SessionFolders` does.

**View checkboxes**, beside the legend. "Only windows with red or orange" leaves out each window none of whose rows is marked, and keeps every tab of a window that has one, so the tab-mates a folder goes back beside stay in sight; windows keep their numbers. "Show full paths" turns the "In" column into "Full path", the folder's own name included. Toggling either refills both lists and ticks again the rows still shown. Both are remembered in `compare window.json` beside the save folders (`Saved sessions\`, or the parent of `-BackupFolder`), written on each toggle, and nothing is remembered while that folder does not exist.

**Opening.** "Open ticked" scans what is open now, builds a plan with `New-OpenPlan`, and hands it to `Invoke-OpenPlan` on a separate STA runspace, which a timer polls for progress. A frozen Explorer window can then hold up only the opening, never the window. The plan skips folders already open. Any other folder goes in as a tab of the window holding most of its former tab-mates, open now or opened earlier in the plan; failing that, into a new window that its later tab-mates join. `Add-ShellTab` asks for tabs with `RequestNewTab` only; when a window does not answer, the folder opens in a new window instead and its later tab-mates follow it there. Nothing in the compare window presses keys.

**Other buttons.** "Tick all missing" ticks every red row. "Mark as checked" calls `Remove-BackupIncident`. "Settings..." edits the six values of `Settings.ini` with controls bounded by their allowed ranges and writes it with `Write-BackupSettings`, which keeps the template's explanations but not a person's own comments.

**Behaviour.** The console window a "Run with PowerShell" start leaves behind is hidden; errors go to a message box. Opened for a loss, the window stays on top until the person has been in it and moved on. On closing, a process with a scan or an opening still stuck on a frozen window ends with `[Environment]::Exit`.

**Testing it.** `-RenderTo <png>` builds the window from whatever saves the folder parameters point at, draws it and the settings dialog to PNGs, and quits, for looking at with fake sessions; a `compare window.json` beside `-BackupFolder` sets the checkboxes. Clicks can be driven with UI Automation, but from Windows PowerShell every WinForms control shows only as a pane with no InvokePattern: find a button or checkbox by its name and post `BM_CLICK` (`0x00F5`) to its `NativeWindowHandle`. A list row is ticked by sending its `SysListView32` `WM_KEYDOWN` for Home, Down and Space, and read back with `LVM_GETITEMSTATE` (state image 2 is ticked); both work across processes, where `LVM_SETITEMSTATE` would need a structure in the window's own memory.

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

## Known limitations

- **Tab restore needs Windows 11 22H2+.** On older builds each path opens as a separate window.
- **An IME can still swallow the restore's fallback `Ctrl+T`**, used only when a window does not answer the tab request, and by restore files written before 7.0, which always press it.
- **Restore opens windows, and each new window takes the keyboard.** Don't type during restore.
- **Tab order within a window** follows COM enumeration order, which usually but not always matches visual left-to-right order.
- **A frozen window's paths are reported, not recovered.** Its tabs are skipped after the per-tab deadline each and described from Win32 data (title, HWND, PID, placement, hung flag). A path only survives in the rare case where the tab answered `LocationURL` before blocking; the usual block point is `Windows().Item($i)`, which yields nothing. Windows 11 draws the address bar in XAML, so even `WM_GETTEXT` gives nothing back, and the title is all there is. Closing the hung window and re-running the save script captures everything else cleanly.
- **Each frozen tab costs a scan the full per-tab deadline** (`$TabReadTimeoutMs` in the module), so a hung window costs that times its tab count.
- **If the shell COM service itself is down (trap 12), nothing can be saved** — not one path, from any window. The run degrades to the Win32 window list and recovery advice. Waiting for the hung window to free itself is the only fix that keeps the session.

## Later

1. **A UIA fallback for a dead COM service.** When the shell window service is unreachable (trap 12), nothing can be read. Windows that still answer messages would likely give up their active tab's path through UI Automation, though: a partial save instead of none. Per window, not per tab.
2. **Restore tab order deterministically.** COM enumeration order usually matches visual order but is not guaranteed. Check whether `IShellBrowser` exposes a tab index.
3. **Preserve window geometry.** Everything is maximized; `GetWindowRect` at save time and `SetWindowPos` at restore would keep other layouts.
4. **Record the active tab.** Restore leaves the last-opened tab focused.
5. **Restore files could put folders beside open tab-mates** as the compare window does, instead of opening each saved window anew; they would need `New-OpenPlan`'s logic inside the file, since a restore file stands alone.
