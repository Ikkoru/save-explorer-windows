---
paths:
  - "**/*.ps1"
  - "**/*.psm1"
---

# The save script in full: its debug label, its traps, and how to verify a change

`CLAUDE.md` states each rule in a line; this file holds the detail behind it, and loads whenever a script or the module is read. Every trap below is a bug that was actually hit and diagnosed in this project. Do not "simplify" these away.

## The debug label

The prompt `Enter descriptive label (optional):` doubles as the only switch this script has. **If the label contains the word `debug` (any case), the full diagnostic report is printed instead of the short one**, and the same full text is what gets embedded in the generated restore script.

The word is stripped from the label afterwards, so it never reaches the output filename — `debug session A` saves as `Restore Explorer Session <date>_session A.ps1`. Matching is `(?i)\bdebug\w*`: anchored at a word start and eating the rest of the word, so `debugging` counts, while `predebugged` is left alone rather than being gutted into `preged`.

It is **not** mentioned at the prompt, and the only place it surfaces at all is a single grey hint printed after a run that already failed — the person who needs the full report is exactly the one who would not know to ask for it. Keep it to that: no mention on a clean run, and none in the prompt text.

Report levels, and what each line is tagged with in `Add-ReportLine`:

| Level | Default (no `debug`) | `debug` |
|---|---|---|
| Error/summary line | ✅ | ✅ |
| Counts (`N answered COM, M did not`) | ✅ | ✅ |
| Window `Title`, `[NOT RESPONDING]` | ✅ | ✅ |
| `Address bar` | only when actually readable | always, with the reason when not |
| Path recovered from a frozen tab | ✅ decoded to a real path | ✅ plus raw `LocationURL` |
| Recovery advice | condensed | full, with the cause explained |
| `HWND`, `Class / PID`, `Placement` | ❌ | ✅ |
| Frozen tab index + blocking COM call | ❌ | ✅ |
| Ghost windows | ❌ | ✅ |
| "re-run with debug" hint | ✅ console only, after a failure | ❌ |

The hint is console-only by design: a generated restore script cannot be re-run with a label, so putting it in the embedded note would be advice nobody can act on.

`Add-ReportLine ... -DebugOnly` / `-QuietOnly` tags a line as it is built, and `Format-ReportText` renders one level and collapses the blank-line runs that dropping lines leaves behind. One builder, two outputs — don't fork it into two.

## The traps

### 1. `HWND` must be `[int64]`, never `[int]` ⚠️ HIGHEST SEVERITY

On 64-bit Windows 11, `$window.HWND` returns a value that **overflows Int32**.

```powershell
$hwnd = [int]$w.HWND      # WRONG — throws OverflowException on every window
$hwnd = [int64]$w.HWND    # correct
```

**Why this is insidious:** the throw usually lands inside a `try/catch` intended to skip non-folder windows. Every window gets silently classified as "not a folder window," and the script reports **"No Explorer folder windows are currently open"** while 20 windows are visibly open. The symptom points nowhere near the cause.

**Diagnostic that found it:** printing the path *and* the skip message per window. Seeing the path print successfully and *then* "skipped" proved the failure was on the line after path extraction.

All HWND handling sites must use `[int64]`: dictionary keys, before/after snapshots, comparisons, and `[IntPtr][int64]$hwnd` when constructing an IntPtr.

### 2. `Shell.Application` requires STA

`Shell.Application.Windows()` **silently returns an empty collection** in an MTA thread. No error, no warning.

- Windows PowerShell 5.1 (`powershell.exe`) → STA by default ✅
- PowerShell 7 (`pwsh`) → MTA by default ❌
- Windows Terminal / VS Code hosts → varies ❌

Both the save script and the generated restore script carry a self-relaunch guard (`GetApartmentState()` → relaunch via `powershell.exe -STA`). Keep it in both. The script also prints its apartment state — leave that in; it makes this class of failure a one-line diagnosis.

### 3. Elevation breaks window visibility

An elevated (admin) process **cannot see non-elevated Explorer windows** due to UAC integrity isolation. Explorer normally runs non-elevated, so running this script as administrator yields zero windows.

Same symptom as traps 1 and 2. The script detects `IsInRole(Administrator)` and emits a specific warning when it finds zero windows while elevated. Keep it.

### 4. `ConvertFrom-Json` unwraps single-element arrays

The mechanism is in the kit's `powershell-scripts.md`. Here, adjacent bare strings concatenated into a single malformed path (observed symptom: Explorer complaining about a path containing two folders at once, e.g. `Z:\A\B Z:\C\D`).

```powershell
$groups = @(($json | ConvertFrom-Json) | ForEach-Object { ,[string[]]@($_) })
```

The `,` (unary array-construction operator) and the explicit `[string[]]@()` cast are both required. Neither is redundant.

### 5. Encoding: base64 the data, don't trust the pipeline

Path strings were garbled (UTF-8 read as CP932) even with `WriteAllText` + explicit UTF-8 encoding, because the path survived COM but not the surrounding tooling layers.

**The fix that actually worked:** serialize paths to JSON → UTF-8 bytes → **base64** → embed in the output script as an ASCII string. Base64 is pure ASCII, so no code page can corrupt it. The restore script decodes at runtime.

Emoji survive because JSON escapes surrogate pairs as `\uXXXX\uXXXX`.

Do not replace this with plain-text path literals in the generated script, no matter how much cleaner it looks.

### 6. Navigate tabs via COM, not keystrokes

Do **not** drive tab navigation with `Alt+D` → clipboard → `Ctrl+V` → `Enter`. That path is slow, IME-fragile, and depends on the address bar's state.

Instead: snapshot COM object identities → `Ctrl+T` → poll for the new tab entry → `$newTab.Navigate2($path)` → poll `$newTab.Busy` until false.

`Ctrl+T` via `SendKeys` is the **only** keystroke that remains, because there is no COM method to open a new tab in an existing Explorer window. It is irreducible; don't spend time hunting for an alternative unless the Windows Shell API gains one.

### 7. COM object identity needs IUnknown pointers

Two RCWs (runtime callable wrappers) for the same underlying COM object are not reliably `-eq`. To detect "which tab is new," compare `Marshal::GetIUnknownForObject($obj).ToInt64()` — the pointer is stable where the wrapper is not.

**Always `Marshal::Release` the pointer** in a `finally`. `GetIUnknownForObject` adds a reference; leaking it leaks COM objects. See `Get-ComId`.

### 8. Polling beats fixed sleeps

Fixed sleeps between every UI step are fragile on slow machines and wasteful on fast ones.

The `Wait-For` helper polls a predicate with a timeout. The only fixed sleeps are 150 ms after `SetForegroundWindow` (to let focus settle before `Ctrl+T`) and 200 ms between window groups.

### 9. Per-tab error isolation

Each tab's navigation is wrapped in its own `try/catch`. Without this, one bad path aborts every remaining tab in that window. A failed tab should log a warning and continue.

### 10. Here-string hygiene

The restore template is a **single-quoted** here-string (`@'...'@`). Nothing inside is interpreted — no `$variable` expansion, no backtick escapes, no quote doubling. Keep it single-quoted: the moment it interpolates, every `$path` and `$_` in the template becomes an escaping problem.

**The one constraint:** no line inside the template may begin with `'@`, or the here-string terminates early — silently, producing a truncated restore script that only fails when someone runs it. In v6 the template is `$RestoreTemplate` in the module, which holds other here-strings too (`$SettingsTemplate`, and the C# probe's `@"..."@`), so after every edit:

```bash
grep -n "^'@\|^\"@" "Explorer Windows Shared.psm1"   # each line listed must END a here-string
```

and `Tests\Run tests.ps1`, whose check *the whole template made it* fails when a restore file lacks the template's first or last line. Text the module writes out goes in a plain string rather than one more here-string where it can (`$KopiaIgnoreText`), to keep that list short.

### 11. A COM call into a frozen window never returns

A hung Explorer window does not pump messages, so a COM call to it blocks **forever**. Local COM RPC has no default timeout, and nothing on the calling side can break it: `PowerShell.Stop()`, `Dispose()`, `Marshal.ReleaseComObject` and Ctrl+C all block on the same call. There is no "read with timeout" here.

The only exit is to stop waiting and walk away from the thread. Every COM read therefore runs on a dedicated STA runspace via `Invoke-ComStep`, one tab at a time, with a per-tab deadline, `$TabReadTimeoutMs` in the module. A healthy tab answers in a small fraction of it; each frozen one costs all of it:

```powershell
$async = $ps.BeginInvoke()
if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
    $script:AbandonedWorkers.Add($script:ComWorker)   # never Dispose it
    $script:ComWorker = $null                         # next call gets a fresh one
}
```

Three details are load-bearing:

- **Never `Dispose()` an abandoned worker**, and keep it referenced in `$AbandonedWorkers`. Disposal blocks, and letting it be collected runs a finalizer that touches a stuck RCW, which blocks the finalizer thread too.
- **The process will not exit on its own** once a worker is parked in a COM call — verified: it hangs indefinitely after the last statement, even though runspace threads are background threads. The `finally` block ends with `[Environment]::Exit(0)` when anything was abandoned.
- **The worker reads properties cheapest-first** (`HWND` → `LocationName` → `LocationURL` → `Document.Folder.Self.Path`) and publishes each into a synchronized `$Progress` hashtable, so a call that never returns still leaves behind whatever it managed to read. In practice a hung window blocks at `Windows().Item($i)` and yields nothing at all — which is why the Win32 probe below exists.

To say anything about a tab that COM cannot reach, ask the window manager instead (`ExplorerWindowProbe`). It is safe against hung windows because nothing in it sends an untimed message: `GetWindowText` returns another process's cached caption by design, and child-control text goes through `SendMessageTimeout` with `SMTO_ABORTIFHUNG`. `IsHungAppWindow` names the culprit outright, and any Explorer HWND that no successful COM read reported is the window the frozen tabs belong to. The window title ("Downloads and 1 more tab - File Explorer") is realistically the only identifying information left.

Note the C# for that probe is in a **double-quoted** here-string (`@"..."@`). That is deliberate: a single-quoted one would put a second line starting with `'@` in the file and silently truncate the restore template (trap #10).

### 12. One hung window can take the whole COM service down

Worse failure mode than trap #11, and hit in practice: `Shell.Application` is created fine, then **`.Windows()` throws `0x80010100 RPC_E_SYS_CALL_FAILED`**. Not a timeout — an immediate refusal, on every thread, for every window, including the ones that were perfectly responsive.

Verified during the incident:

- the main thread fails identically to the worker → **not** a threading bug
- activating the `ShellWindows` CLSID directly (`9BA05972-F6A8-11CF-A442-00A0C90A8F39`) fails the same way, at the *class factory*, so it is not `Shell.Application` specifically
- retrying five times over five seconds does not help; it is not transient
- `IsHungAppWindow` reported exactly one hung window, and every explorer.exe still reported `Responding = True` at the process level

So: one stuck thread inside explorer.exe can make the shell window service unreachable process-wide. Nothing in this script can restore it, and there is no COM fallback — the Win32 probe from trap #11 is the *only* thing that still works, which is why the failure path dumps the full window list.

HRESULTs are matched as hex strings, never message text (the kit's `powershell-scripts.md`): `Resolve-ComError` returns `('0x{0:X8}' -f $hr)` and everything matches on that. `EndInvoke` also wraps the real exception two or three layers deep — dig to the innermost `InnerException` or the user sees `Exception calling "EndInvoke" with "1" argument(s)` and nothing useful.

### 13. Never route any of this through cmd

**Do not add a `.bat`, `.cmd`, or launcher layer, and do not generate one.** Every trap below is live the moment cmd touches this project's paths, which routinely contain `!`, spaces, apostrophes and non-ASCII:

- `setlocal enabledelayedexpansion` eats `!` in paths **and** consumes `!` in PowerShell code passed through it, so `!$var` arrives as garbage.
- `chcp 65001` has to run **before** any `set /p`, or typed non-ASCII input is read as CP932.
- `FOR /F` splits on spaces, so any datetime format containing one truncates silently. `Get-Date -Format` has no such failure mode.
- `%~dp0` inside a generated line expands at *generation* time, not run time; it needs escaping as `%%~dp0`.
- `\"` inside a PowerShell single-quoted string is a literal backslash-quote, not a quote — `[char]34` is the only reliable way to emit one through cmd.
- PowerShell rejects trailing commas in array literals, so any loop that appends `item + ','` generates a file that will not parse. Use `-join`.

Pure PowerShell writing a pure PowerShell file avoids all six. Nearly every bug this project ever had was a cmd→PowerShell quoting or encoding bug, not a logic bug — that is the reason for the rule, not nostalgia.

### 14. Saved sessions stay out of backups and sync

`Initialize-SaveFolder` gives each save folder a `.kopiaignore` holding `*`. On this machine Kopia's global policy reads `.kopiaignore` files, and `kopia snapshot estimate` over a folder holding one left out every file and subfolder below it, the marker included. A `CACHEDIR.TAG` would keep Kopia out as well, but the machine's delete guard treats any folder with a valid tag as disposable and lets deletes inside it through without the Recycle Bin, and these files are backups. The tests check that the marker holds `*`, that no `CACHEDIR.TAG` is written, and that an edited marker survives.

Syncthing reads neither file; only the `.stignore` at a synced folder's root keeps a path out, on each device (`DOC.md`, *Keeping saves out of backups and sync*). `.gitignore` covers both folders.

### 15. The scheduled task names the script file

The task's action is `... -File "<folder>\Save Explorer Windows.ps1" -Auto`. A rename or a move makes every run fail silently until the action is updated, which is why the version lives in the module (`$ProgramVersion`) and not in the file name. A task is created or changed only when the maintainer asks for it, by `Register-ScheduledTask` / `Set-ScheduledTask` run as a command the guard can see. Never from a script file: that hides the change from the guard, and on a machine whose profile refuses task changes it would route around the refusal.

### 16. Open folders are someone else's business

The folders open on a machine are private. Console output of an automatic run, `log.txt` and test output give counts and file names, never folder paths. A live test writes into the scratchpad and reports counts; a test that needs known paths makes its own folders.

### 17. Windows PowerShell 5.1 traps the module works around

The kit's `powershell-scripts.md`, which loads with any script here, carries them. The module's workarounds, where a tidy-up would undo one:

- **`@()` over a `List[object]` throws "Argument types do not match"**: `Update-AutomaticBackups` copies `$state.Incidents` with `.ToArray()`.
- **A `$null` string argument reaches .NET as `""`**: `Write-BackupState` passes `[NullString]::Value` to `File.Replace`.
- **An `if` used as a value unwraps a one-element array**: `Read-BackupState` assigns `$missing` inside the branch.
- **`ConvertFrom-Json` output needs parentheses before it enumerates**: `(... | ConvertFrom-Json) | ForEach-Object ...` in `Read-SessionBackup`.
- **`Start-Process -Wait` waits for every process the target starts**, so waiting on a run that opens `-ShowIncident` waits for the window too.

## Verification checklist

Before considering a change done. Run the greps from Git Bash with the patterns in a file read by `grep -f` where they hold a backslash: Git Bash halves backslashes on a command line started from a Windows program.

```bash
s="Save Explorer Windows.ps1"; m="Explorer Windows Shared.psm1"

grep -n "^'@" "$s" "$m"          # each line listed ENDS a here-string (trap 10)
grep -n '^"@' "$s" "$m"          # likewise: the C# probe's
grep -n '\[int\].*HWND' "$s" "$m"   # must be empty (trap 1)
grep -c 'GetApartmentState' "$s" "$m"   # the script's guard; the template's guard and the printed state
LC_ALL=C grep -c '[^ -~	]' "$s" "$m" "Tests/Run tests.ps1"   # 0 each: pure ASCII
```

Then:

1. **The tests**: `powershell -NoProfile -ExecutionPolicy Bypass -File "Tests\Run tests.ps1"`, exit 0. A new rule gets a check, and the check is shown to fail on a broken copy of the module (`-ModulePath`).
2. **A parse** of the script and the module (`[Management.Automation.Language.Parser]::ParseFile`, errors empty). The tests parse a written restore file.
3. **A live run by hand**, twice, with `-ManualFolder` in the scratchpad: once with an empty label, once with `debug`, since the two report levels are rendered by different filters over the same lines. Answer the prompts by redirecting stdin (`"label`n`n" | powershell -File ...`). The apartment state should print `STA`, the window count should match reality, and the process should exit rather than hang after the final prompt.
4. **A live `-Auto -NoWindow` run** with `-BackupFolder` and `-SettingsPath` in the scratchpad: `log.txt` gets one line, and the save folder holds a `.kopiaignore`. A change to the default folders or the move from old ones is run from a copy of the script and module in the scratchpad, with no folder parameters, laid out as the old version left it.
5. **Restoring** reopens windows on the maintainer's screen and needs their go-ahead.

Report counts only (trap 16).

### Testing the frozen path without a hung window

You cannot summon a hung Explorer window on demand, so stub the two worker scriptblocks instead. They are the only code that touches COM, and they are plain `$script:` variables of the module. Copy the script and the module into the scratchpad, insert the override into the copied module just before `Export-ModuleMember`, and run the copied script by hand and with `-Auto -NoWindow`. That exercises everything else for real: the deadline, the abandon path, both report levels, the base64 payloads, the save folders and an incomplete automatic save:

```powershell
$script:TabReadTimeoutMs = 1500
$script:CountWindowsScript = { param($Unused, $Progress) 4 }
$script:ReadWindowScript = {
    param([int]$Index, $Progress)
    $info = [ordered]@{ Index=$Index; Hwnd=$null; Name=$null; Url=$null
                        Path=$null; Error=$null; HResult=$null }
    $Progress['Info'] = $info
    switch ($Index) {
        0 { $info.Hwnd = 111111; $info.Path = 'Z:\A B\C' }
        1 { $info.Hwnd = 111111; $info.Path = "Z:\D\E's F" }   # same window
        2 { $Progress['Stage'] = 'Windows().Item(2)'; Start-Sleep -Seconds 30 }
        3 { $info.Hwnd = 222222; $info.Name = 'partial'        # blocks with data
            $info.Url = 'file:///Z:/tmp/partial%20read'
            $Progress['Stage'] = 'Document.Folder.Self.Path'; Start-Sleep -Seconds 30 }
    }
    [pscustomobject]$info
}
```

Index 2 covers the normal freeze (nothing readable), index 3 the rare partial one. Both abandon a worker, so each run must still exit on its own, and the automatic one logs the save as `INCOMPLETE`.
