# CLAUDE.md — Explorer Session Save/Restore

## What this is

Save Explorer Windows enumerates open Windows Explorer windows (and their tabs), then writes a **self-contained restore `.ps1`** that reopens them with the same window/tab grouping: by hand, or every two hours from Task Scheduler (`-Auto`), which also cleans up old backups and warns about folders lost to a restart, a sign-out, a crash or a big drop.

`Save Explorer Windows.ps1` is the entry point and `Explorer Windows Shared.psm1` everything else; the module must sit beside the script. The version is `$ProgramVersion` in the module, not in the file name. `Compare Explorer Backups.ps1` is the compare window: two sessions side by side, reopening chosen folders beside their old tab-mates, and the settings; `-ShowIncident` opens it for a loss. `Set up automatic backups.ps1` installs, updates or removes the scheduled task for a person. `README.md` is for people using it, in plain words for someone who doesn't code; keep it true when behaviour changes. `Tests\Run tests.ps1` checks the module. The previous, single-file v5.3 is in the git history; its saves still read. Each save is one self-contained restore script; no `.bat` and no launcher.

A frozen Explorer window is expected, not exceptional: its tabs are skipped after a per-tab deadline (`$TabReadTimeoutMs`), counted, and described from Win32 data, and the rest of the session is saved normally (trap 11).

`DOC.md` covers the files, the runs, the automatic backups' rules, the data formats and what to build next. This file is the rules: break one and the failure is silent. `.claude/rules/script.md`, which loads whenever a script or the module is read, holds the detail behind each rule: the debug label's report levels, every trap's story, code and diagnosis, and the verification checklist.

**Target environment:** Windows 11, **Japanese system locale (CP932)**, paths containing Japanese, emoji, `[]`, `!`, apostrophes, and Unicode lookalikes such as `⧸` (U+29F8 BIG SOLIDUS, used in folder names where `/` is illegal).

## The hidden `debug` label

The prompt `Enter descriptive label (optional):` is the script's only switch: a label containing the word `debug` (any case) prints the full diagnostic report, and embeds it in the restore script, instead of the short one; the word is stripped from the filename. It is **never mentioned** at the prompt or on a clean run, only in one grey hint after a run that failed. One report builder renders both levels (`Add-ReportLine`, `Format-ReportText`): never fork it into two.

## Load-bearing traps

Each was hit and diagnosed here; the rule file has the full account. Do not "simplify" these away.

1. **`HWND` must be `[int64]`, never `[int]`** ⚠️ highest severity: the Int32 overflow lands in a skip-on-error `try/catch`, and the script reports "No Explorer folder windows are currently open" while windows are open.
2. **`Shell.Application` requires STA**: in an MTA thread (PowerShell 7's default) `Windows()` silently returns nothing. Keep the self-relaunch guard in both scripts, and the printed apartment state.
3. **An elevated process sees no non-elevated Explorer windows.** Keep the warning for zero windows while elevated.
4. **`ConvertFrom-Json` unwraps one-element arrays**: the groups are re-cast with `,[string[]]@($_)`, both parts required.
5. **Path data travels as base64 of UTF-8 JSON**, never as literals in the generated script: the tooling layers around COM garble paths otherwise.
6. **Tabs are added and navigated without keystrokes**: a new tab is asked for with `WM_COMMAND 0xA21B` posted to the window's `ShellTabWindowClass`, which lies several levels down (`RequestNewTab`), then `Navigate2`, polling `Busy`. Only a restore file falls back to `Ctrl+T`, when a window does not answer; the compare window never presses keys.
7. **COM identity is compared by IUnknown pointer** (`Get-ComId`), released in a `finally`.
8. **Poll with `Wait-For`, don't sleep**; the two fixed sleeps that remain are deliberate.
9. **Each tab navigates in its own `try/catch`**, so one bad path doesn't abort the window's other tabs.
10. **The restore template is a single-quoted here-string**, and no line inside it may begin with `'@`, or it ends early and silently truncates the restore script.
11. **A COM call into a frozen window never returns**: every COM read runs on an abandonable STA worker (`Invoke-ComStep`) with a per-tab deadline; abandoned workers are kept and never disposed, and the process ends with `[Environment]::Exit`.
12. **One hung window can take the shell's COM service down** (`0x80010100 RPC_E_SYS_CALL_FAILED` for every window): only the Win32 probe still works then. HRESULTs are matched as hex strings (`Resolve-ComError`), and `EndInvoke`'s exception is unwrapped to its innermost `InnerException`.
13. **Never route any of this through cmd**: no `.bat`, `.cmd` or launcher layer, generated or not.
14. **Saved sessions stay out of backups and sync.** Every restore script and `state.json` lists someone's open folders, and all of them live under `Saved sessions\`. Its folders get a `.kopiaignore` holding `*` (`Initialize-SaveFolder`), **never a `CACHEDIR.TAG`**: the tag declares a folder disposable in full, and this machine's delete guard then lets deletes inside it through without the Recycle Bin. Syncthing reads neither; it needs a `.stignore` line on each device (`DOC.md`).
15. **The scheduled task names the script file**, so its name stays `Save Explorer Windows.ps1`: renaming or moving it stops the automatic backups, silently, until the task's action is updated. The task's settings live in one place, `New-AutoBackupTask`. A session creates or changes a task only when the maintainer asks, and then with `Register-ScheduledTask` in a command the guard can see; it never runs `Set up automatic backups.ps1` itself except to quit at its first question, since a script file hides the registration from the guard.
16. **Never print, log or test with someone's open folders.** Output and `log.txt` give counts and file names, never folder paths; live tests use folders made for the test, or write into the scratchpad and report counts.
17. **Windows PowerShell 5.1 traps the module works around**, carried by the kit's `powershell-scripts.md`; the rule file names each workaround's site, where a tidy-up would undo it.
18. **Only the `public` branch is ever pushed, never `master`**, whose old commits and authors hold private details. `public` takes `master`'s tree one commit per release, under the maintainer's GitHub no-reply address, after a check of the tree for private data (`DOC.md`, *Publishing*).

## The project folder is the live install

The maintainer's scheduled task runs `Save Explorer Windows.ps1` from this folder every two hours, so the working tree is what runs: an edit takes effect at the next run, and a half-finished one breaks the backups until it is finished. Finish and test a change in one go; the tests and live runs don't need the real folders.

`Saved sessions\` and `Settings.ini` here are the maintainer's real data and settings. Tests and live runs write elsewhere: through `-BackupFolder`, `-ManualFolder` and `-SettingsPath` pointing into the scratchpad, or from a copy of the script and module in the scratchpad. Never run `-Auto` against this folder's own `Saved sessions`. `Settings.ini` is tracked with the defaults, so an edit of the maintainer's shows up in `git status` as theirs to commit.

## Non-negotiable invariants

- All HWND values are `[int64]`
- STA guard present in **both** the save script and the generated template
- Path data travels as base64-encoded UTF-8 JSON, never as literals
- `ConvertFrom-Json` output always re-cast with `,[string[]]@($_)`
- `Get-ComId` releases its IUnknown pointer in `finally`
- Every line starting with `'@` or `"@` ends a here-string, and the tests' *the whole template made it* check passes
- Final pause is in a `finally` block (an early `return` must not skip it)
- **No COM call runs on the main thread** — every one goes through `Invoke-ComStep` on an abandonable STA worker
- Abandoned workers are kept in `$AbandonedWorkers` and never disposed
- `[Environment]::Exit(0)` closes the `finally` block whenever a worker was abandoned
- The frozen-tab report travels to the restore script as base64 too, for the same reason the paths do
- HRESULTs are compared as hex strings, never as numeric literals
- One report builder, two rendered levels — never two builders
- Scripts, the module and the tests stay pure ASCII; non-ASCII test strings are built from character codes
- Save folders carry a `.kopiaignore`, never a `CACHEDIR.TAG`
- `$ProgramVersion` is raised with any change to the script or the module; the file names stay fixed
- Nothing is deleted while `state.json` cannot be read; it is set aside, never deleted
- Cleanup never deletes a locked backup, the newest complete backup, the file just saved, or a file `Read-SessionBackup` cannot read

## Known limitations

- **Tab restore needs Windows 11 22H2+.** On older builds each path opens as a separate window.
- **An IME can still swallow the restore's fallback `Ctrl+T`**, used only when a window does not answer the tab request, and by restore files written before 7.0, which always press it.
- **Restore opens windows, and each new window takes the keyboard.** Don't type during restore.
- **Running a restore needs the maintainer's go-ahead**: a stray key or click of theirs lands in it. Unless they have said they are away.
- **Tab order within a window** follows COM enumeration order, which usually but not always matches visual left-to-right order.
- **A frozen window's paths are reported, not recovered.** Its tabs are skipped after the per-tab deadline each and described from Win32 data (title, HWND, PID, placement, hung flag). A path only survives in the rare case where the tab answered `LocationURL` before blocking; the usual block point is `Windows().Item($i)`, which yields nothing. Windows 11 draws the address bar in XAML, so even `WM_GETTEXT` gives nothing back, and the title is all there is. Closing the hung window and re-running the save script captures everything else cleanly.
- **Each frozen tab costs a scan the full per-tab deadline** (`$TabReadTimeoutMs` in the module), so a hung window costs that times its tab count.
- **If the shell COM service itself is down (trap 12), nothing can be saved** — not one path, from any window. The run degrades to the Win32 window list and recovery advice. Waiting for the hung window to free itself is the only fix that keeps the session.

## Before a change is done

Run the verification checklist in `.claude/rules/script.md`: `Tests\Run tests.ps1`, the terminator, HWND-cast and STA greps, a parse of the scripts and the template, a live run by hand with an empty label and with `debug`, and a live `-Auto -NoWindow` run into the scratchpad. To exercise the frozen path without a hung window, the same file has the stubs.
