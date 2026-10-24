# CLAUDE.md — Explorer Session Save/Restore

## The program

Save Explorer Windows enumerates open Windows Explorer windows (and their tabs), then writes a **self-contained restore `.ps1`** that reopens them with the same window/tab grouping. It saves by hand, or on a schedule from Task Scheduler (`-Auto`), every hour unless the setup is given another interval. The scheduled run also cleans up old backups and warns about folders lost to a restart, a sign-out, a crash or a big drop.

`Save Explorer Windows.ps1` is the entry point and `Explorer Windows Shared.psm1` everything else; the module must sit beside the script. `Compare Explorer Backups.ps1` is the compare window, `Set up automatic backups.ps1` the task installer; `DOC.md`, *Files*, has the rest. The version is `$ProgramVersion` in the module, not in the file name. `README.md` is for people using it, in plain words for someone who doesn't code; keep it true when behaviour changes.

`DOC.md` covers the files, the runs, the automatic backups' rules, the data formats, the known limitations and what to build next. This file is the rules: break one and the failure is silent. `.claude/rules/script.md`, which loads whenever a script or the module is read, holds the detail behind each rule: the debug label's report levels, every trap's story, code and diagnosis, and the verification checklist.

**Target environment:** Windows 11, **Japanese system locale (CP932)**, paths containing Japanese, emoji, `[]`, `!`, apostrophes, and Unicode lookalikes such as `⧸` (U+29F8 BIG SOLIDUS, used in folder names where `/` is illegal).

## The hidden `debug` label

A label containing the word `debug` (any case) at the prompt `Enter descriptive label (optional):` prints and embeds the full diagnostic report instead of the short one, and is stripped from the filename. It is **never mentioned** at the prompt or on a clean run, only in one grey hint after a run that failed. One report builder renders both levels (`Add-ReportLine`, `Format-ReportText`): never fork it into two.

## Load-bearing traps

The rule file has each one's full account. Do not "simplify" these away.

1. **`HWND` must be `[int64]`, never `[int]`** ⚠️ highest severity: the Int32 overflow lands in a skip-on-error `try/catch`, and the script reports "No Explorer folder windows are currently open" while windows are open.
2. **`Shell.Application` requires STA**: in an MTA thread (PowerShell 7's default) `Windows()` silently returns nothing. Keep the self-relaunch guard in the save script, the compare window and the restore template, and the printed apartment state.
3. **An elevated process sees no non-elevated Explorer windows.** Keep the warning for zero windows while elevated.
4. **`ConvertFrom-Json` unwraps one-element arrays**: the groups are re-cast with `,[string[]]@($_)`, both parts required.
5. **Path data and the frozen-tab report travel as base64 of UTF-8 JSON**, never as literals in the generated script: the tooling layers around COM garble them otherwise.
6. **Tabs are added and navigated without keystrokes**: `RequestNewTab` posts `WM_COMMAND 0xA21B` to the window's `ShellTabWindowClass`, then `Navigate2`, polling `Busy`. Only a restore file falls back to `Ctrl+T`, when a window does not answer; the compare window never presses keys.
7. **COM identity is compared by IUnknown pointer** (`Get-ComId`), released in a `finally`.
8. **Poll with `Wait-For`, don't sleep**; the two fixed sleeps that remain are deliberate.
9. **Each tab navigates in its own `try/catch`**, so one bad path doesn't abort the window's other tabs.
10. **The restore template is a single-quoted here-string**: any line beginning with `'@` or `"@` ends a here-string, so one inside the template silently truncates the restore script. The tests' *the whole template made it* check must pass.
11. **A COM call into a frozen window never returns**, so no COM call to Explorer runs on the save script's or the compare window's own thread: reads go through `Invoke-ComStep` on an abandonable STA worker with a per-tab deadline, opening through `Invoke-OpenPlan` on a runspace of its own. Only a restore file, which stands alone, calls COM directly. Abandoned workers are kept in `$AbandonedWorkers` and never disposed, and `[Environment]::Exit` ends the process whenever one was abandoned or the compare window closes with an opening under way.
12. **One hung window can take the shell's COM service down** (`0x80010100 RPC_E_SYS_CALL_FAILED` for every window): only the Win32 probe still works then. HRESULTs are matched as hex strings (`Resolve-ComError`), and `EndInvoke`'s exception is unwrapped to its innermost `InnerException`.
13. **Never route any of this through cmd**: no `.bat`, `.cmd` or launcher layer, generated or not.
14. **Saved sessions stay out of backups and sync.** Every restore script and `state.json` lists someone's open folders, and all of them live under `Saved sessions\`. Its folders get a `.kopiaignore` holding `*` (`Initialize-SaveFolder`), **never a `CACHEDIR.TAG`**: the tag declares a folder disposable in full, and this machine's delete guard then lets deletes inside it through without the Recycle Bin. Syncthing needs a `.stignore` line on each device (`DOC.md`).
15. **The scheduled task names the script file**, so its name stays `Save Explorer Windows.ps1`: renaming or moving it stops the automatic backups, silently, until the task's action is updated. The task's settings live in one place, `New-AutoBackupTask`. A session creates or changes a task only when the maintainer asks, with `Register-ScheduledTask` in a command the guard can see, and runs `Set up automatic backups.ps1` only to quit at its first question: a script file hides the registration from the guard.
16. **Never print, log or test with someone's open folders.** Output and `log.txt` give counts and file names, never folder paths; live tests use folders made for the test, or write into the scratchpad and report counts.
17. **Windows PowerShell 5.1 traps the module works around**, carried by the kit's `powershell-scripts.md`; the rule file names each workaround's site, where a tidy-up would undo it.
18. **Only the `public` branch is ever pushed, never `master`**, whose old commits and authors hold private details. `public` takes `master`'s tree one commit per release, under the maintainer's GitHub no-reply address, after a check of the tree for private data (`DOC.md`, *Publishing*).

## Other invariants

- Final pause is in a `finally` block (an early `return` must not skip it)
- Scripts, the module and the tests stay pure ASCII; non-ASCII test strings are built from character codes
- `$ProgramVersion` is raised with any change to the script or the module; the file names stay fixed
- Nothing is deleted while `state.json` cannot be read; it is set aside, never deleted
- Cleanup never deletes a locked backup, the newest complete backup, the file just saved, or a file `Read-SessionBackup` cannot read

## The project folder is the live install

The maintainer's scheduled task runs `Save Explorer Windows.ps1` from this folder every hour, so the working tree is what runs: an edit takes effect at the next run, and a half-finished one breaks the backups until it is finished. Finish and test a change in one go; the tests and live runs don't need the real folders.

`Saved sessions\` and `Settings.ini` here are the maintainer's real data and settings. Tests and live runs write elsewhere: through `-BackupFolder`, `-ManualFolder` and `-SettingsPath` pointing into the scratchpad, or from a copy of the script and module in the scratchpad. Never run `-Auto` against this folder's own `Saved sessions`. `Settings.ini` is tracked with the defaults, so an edit of the maintainer's shows up in `git status` as theirs to commit.

**Running a restore needs the maintainer's go-ahead**, unless they have said they are away: each new window takes the keyboard, so a stray key or click of theirs lands in it.

## Before a change is done

Run the verification checklist in `.claude/rules/script.md`. It covers `Tests\Run tests.ps1`, the terminator, HWND-cast and STA greps, and a parse of the scripts and the template. Then live runs: by hand with an empty label and with `debug`, `-Auto -NoWindow` into the scratchpad, and `-RenderTo` pictures of the compare window over fake sessions. To exercise the frozen path without a hung window, the same file has the stubs.
